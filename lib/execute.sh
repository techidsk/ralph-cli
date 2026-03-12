#!/usr/bin/env bash
# Ralph CLI — 任务执行 (Worktree + Claude 调用)
# Claude Code 负责: 改代码、验证、修复、提交
# Ralph 只负责: 调度、worktree 管理、nightly 分支
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/db.sh"

# ralph_execute <task_id> <model> <prompt> <complexity> <context_files>
# 输出 worktree 路径到 stdout
# 返回 0=成功, 1=失败
ralph_execute() {
  local task_id="$1"
  local model="${2:-$RALPH_DEFAULT_MODEL}"
  local prompt="$3"
  local complexity="${4:-simple}"
  local context_files="${5:-}"

  local start_time
  start_time="$(date +%s)"

  ralph_log_info "=== EXECUTE phase: $task_id (model=$model, complexity=$complexity) ==="

  # 创建 worktree (路径含项目名 + task_id 以支持并发和多项目隔离)
  local worktree="/tmp/ralph-wt-$RALPH_PROJECT-$task_id"
  local branch="ralph/task-$task_id"

  cd "$RALPH_CWD"

  # 确定 worktree 的基准：优先用 nightly 分支（包含之前任务的改动），否则用 HEAD
  local today
  today="$(date '+%m%d')"
  local nightly_branch="ralph/nightly-$today"
  local base_ref="HEAD"
  if git rev-parse --verify "$nightly_branch" >/dev/null 2>&1; then
    base_ref="$nightly_branch"
    ralph_log_info "Using nightly branch as base: $nightly_branch"
  fi
  ralph_log_debug "base_ref=$base_ref for $task_id"

  # 清理可能残留的同名 worktree/branch
  git worktree remove "$worktree" --force >/dev/null 2>&1 || true
  git branch -D "$branch" >/dev/null 2>&1 || true

  git worktree add "$worktree" -b "$branch" "$base_ref" >/dev/null 2>&1 || {
    ralph_log_error "Failed to create worktree at $worktree"
    return 1
  }
  ralph_log_info "Created worktree: $worktree (branch: $branch, base: $base_ref)"

  # 保存 base_ref 供 commit.sh 使用（多 commit format-patch）
  echo "$base_ref" > "/tmp/ralph-baseref-$task_id"

  # node_modules 符号链接（让 Claude 运行验证命令时能找到依赖）
  if [[ "${RALPH_VERIFY_SYMLINK_NODE_MODULES:-true}" == "true" ]]; then
    if [[ ! -d "$worktree/node_modules" && -d "$RALPH_CWD/node_modules" ]]; then
      ln -s "$RALPH_CWD/node_modules" "$worktree/node_modules" 2>/dev/null || true
    fi
    for pkg_nm in "$RALPH_CWD"/packages/*/node_modules; do
      [[ -d "$pkg_nm" ]] || continue
      local pkg_rel="${pkg_nm#$RALPH_CWD/}"
      local pkg_dir
      pkg_dir="$(dirname "$pkg_rel")"
      if [[ ! -d "$worktree/$pkg_rel" ]]; then
        mkdir -p "$worktree/$pkg_dir" 2>/dev/null || true
        ln -s "$pkg_nm" "$worktree/$pkg_rel" 2>/dev/null || true
      fi
    done
  fi

  # 构建增强 prompt —— 单次调用完成 execute + verify + commit
  local enhanced_prompt=""

  # 注入 context-brief
  if [[ -f "$RALPH_CONTEXT_BRIEF" ]]; then
    enhanced_prompt+="## 近期任务上下文
$(cat "$RALPH_CONTEXT_BRIEF")

"
  fi

  # 注入 lessons
  if [[ -f "$RALPH_LESSONS" ]]; then
    enhanced_prompt+="## 项目经验
$(cat "$RALPH_LESSONS")

"
  fi

  # 注入 context_files 内容提示
  if [[ -n "$context_files" ]]; then
    enhanced_prompt+="## 相关文件
请重点关注以下文件: $context_files

"
  fi

  # 复杂任务提示
  if [[ "$complexity" == "complex" ]]; then
    enhanced_prompt+="注意: 这是一个复杂任务。在动手修改前，先制定实现计划（列出步骤和涉及文件），然后按计划执行。

"
  fi

  # 构建验证命令段
  local verify_section=""
  if [[ -n "${RALPH_VERIFY_COMMANDS:-}" ]]; then
    verify_section="## 验证
完成代码修改后，逐条运行以下命令验证:
"
    IFS='|' read -ra _verify_cmds <<< "$RALPH_VERIFY_COMMANDS"
    for _cmd in "${_verify_cmds[@]}"; do
      [[ -z "$_cmd" ]] && continue
      verify_section+="- \`$_cmd\`
"
    done
    verify_section+="如果失败，修复后重新运行，直到全部通过。

"
  fi

  # 构建 hook 控制提示
  local hook_hint=""
  if [[ "${RALPH_SKIP_HOOKS:-false}" == "true" ]]; then
    hook_hint="- hook 控制: 提交时使用 HUSKY=0 git commit --no-verify"
  fi

  enhanced_prompt+="## 任务
$prompt

${verify_section}## 提交
所有验证通过后（或没有验证命令时，完成代码修改后），提交你的修改:
- 使用 conventional commits 格式: type(scope): 描述
- commit body 中包含 \"task-id: $task_id\"
- 遵循项目 CLAUDE.md 中的 commit 规范（如果存在）
${hook_hint}

## 规则
1. 你在 git worktree 中工作，当前目录是项目根
2. 只做任务要求的修改，不要过度工程化
3. 遵循项目 CLAUDE.md 规范（如果存在）
4. 可以使用项目中定义的 skill
5. 发现其他问题追加到 $RALPH_DISCOVERIES 文件（JSON 格式）:
   {\"description\":\"问题描述\",\"source_task\":\"$task_id\",\"severity\":\"low|medium|high\"}
"

  ralph_log_debug "Prompt length: ${#enhanced_prompt} chars"

  local max_turns="$RALPH_MAX_TURNS_SIMPLE"
  if [[ "$complexity" == "complex" ]]; then
    max_turns="$RALPH_MAX_TURNS_COMPLEX"
  fi

  local exit_code=0

  # 执行主调用
  ralph_log_info "Calling Claude (model=$model, max-turns=$max_turns)..."
  ralph_db_update_task_status "$task_id" "running"

  # Session 持久化: 检查是否有已保存的 session (用于 retry 场景)
  local session_id=""
  local existing_session=""
  existing_session="$(ralph_db_get_task_session "$task_id" 2>/dev/null || echo "")"

  local result claude_stderr
  claude_stderr="/tmp/ralph-claude-stderr-$task_id"

  if [[ -n "$existing_session" ]]; then
    # 有已保存 session，使用 --resume 继续
    ralph_log_info "Resuming previous session: $existing_session"
    result="$(cd "$worktree" && claude --resume "$existing_session" -p "$enhanced_prompt" --model "$model" --max-turns "$max_turns" --dangerously-skip-permissions --output-format text 2>"$claude_stderr" </dev/null)" || {
      exit_code=$?
      ralph_log_error "Claude resume failed with exit code $exit_code, falling back to new session"
      # 回退到新 session
      session_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
      ralph_log_info "New session: $session_id"
      result="$(cd "$worktree" && claude -p "$enhanced_prompt" --session-id "$session_id" --model "$model" --max-turns "$max_turns" --dangerously-skip-permissions --output-format text 2>"$claude_stderr" </dev/null)" || {
        exit_code=$?
        ralph_log_error "Claude execution failed with exit code $exit_code"
        ralph_log_error "Claude stderr: $(head -5 "$claude_stderr" 2>/dev/null || echo 'N/A')"
      }
    }
  else
    # 新 session
    session_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    ralph_log_info "New session: $session_id"
    result="$(cd "$worktree" && claude -p "$enhanced_prompt" --session-id "$session_id" --model "$model" --max-turns "$max_turns" --dangerously-skip-permissions --output-format text 2>"$claude_stderr" </dev/null)" || {
      exit_code=$?
      ralph_log_error "Claude execution failed with exit code $exit_code"
      ralph_log_error "Claude stderr: $(head -5 "$claude_stderr" 2>/dev/null || echo 'N/A')"
    }
  fi

  # 保存 session_id 到 DB (无论成功失败，方便 retry 时 resume)
  local final_session="${session_id:-$existing_session}"
  ralph_log_debug "Claude call: session=$final_session, model=$model, max_turns=$max_turns"
  if [[ -n "$final_session" ]]; then
    ralph_db_update_task_session "$task_id" "$final_session"
  fi

  rm -f "$claude_stderr"

  local duration=$(( $(date +%s) - start_time ))
  ralph_log_info "Execute completed in ${duration}s (exit=$exit_code)"

  # 检查 worktree 是否有新 commit（Claude 自己提交）
  local commit_count
  commit_count="$(cd "$worktree" && git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo "0")"
  ralph_log_debug "Commit count: $commit_count (base=$base_ref)"

  if [[ "$commit_count" -eq 0 ]]; then
    # 检查是否有未提交的改动（Claude 改了代码但忘了 commit）
    local uncommitted_changes
    uncommitted_changes="$(cd "$worktree" && git status --short 2>/dev/null || echo "")"

    if [[ -n "$uncommitted_changes" ]]; then
      # Claude 有改动但没 commit，追加 prompt 要求提交
      ralph_log_warn "Changes detected but no commit, asking Claude to commit..."
      local commit_prompt="你已经完成了代码修改，但还没有提交。请现在提交你的修改:
- 使用 conventional commits 格式: type(scope): 描述
- commit body 中包含 \"task-id: $task_id\"
${hook_hint}"

      if [[ -n "$final_session" ]]; then
        cd "$worktree" && claude --resume "$final_session" -p "$commit_prompt" --model "$model" --max-turns 5 --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null || true
      else
        cd "$worktree" && claude -p "$commit_prompt" --model "$model" --max-turns 5 --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null || true
      fi

      # 重新检查
      commit_count="$(cd "$worktree" && git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo "0")"
    fi

    if [[ "$commit_count" -eq 0 ]]; then
      # 仍然没有 commit —— 用更多 turns 重试一次
      local escalated_turns=$((max_turns + 15))
      ralph_log_warn "No commits detected, retrying with escalated turns ($escalated_turns)..."

      local retry_prompt="你刚才分析了代码但没有做任何修改。请重新执行任务，这次直接动手修改代码。

任务要求:
$prompt

重要: 你必须修改文件来完成任务，然后提交。如果你不确定要改哪里，先用 grep/glob 搜索相关代码，然后直接修改。不要只分析不动手。
完成后使用 conventional commits 格式提交，body 中包含 \"task-id: $task_id\"。
${hook_hint}"

      local retry_result retry_exit=0
      if [[ -n "$final_session" ]]; then
        retry_result="$(cd "$worktree" && claude --resume "$final_session" -p "$retry_prompt" --model "$model" --max-turns "$escalated_turns" --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || retry_exit=$?
      else
        retry_result="$(cd "$worktree" && claude -p "$retry_prompt" --model "$model" --max-turns "$escalated_turns" --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || retry_exit=$?
      fi

      # 重新检查
      commit_count="$(cd "$worktree" && git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo "0")"

      if [[ "$commit_count" -eq 0 ]]; then
        ralph_log_warn "Still no commits after escalated retry"
        ralph_db_update_task_result "$task_id" "No changes made (even after escalated retry)" ""
        exit_code=1
      else
        ralph_log_info "Escalated retry produced $commit_count commit(s)"
        result="$retry_result"
      fi
    fi
  else
    ralph_log_info "Claude produced $commit_count commit(s)"
  fi

  # 消费执行中发现的 discoveries
  ralph_consume_discoveries_file 2>/dev/null || true

  # 记录 cycle log
  local summary
  summary="$(echo "$result" | tail -5 | head -3)"
  ralph_db_log_cycle 0 "execute" "$task_id" "$model" "$summary" "$exit_code" "$duration"

  # 输出 worktree 路径
  echo "$worktree"
  return $exit_code
}
