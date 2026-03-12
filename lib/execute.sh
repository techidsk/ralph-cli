#!/usr/bin/env bash
# Ralph CLI — 任务执行 (Worktree + Claude 调用)
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

  # 清理可能残留的同名 worktree/branch
  git worktree remove "$worktree" --force >/dev/null 2>&1 || true
  git branch -D "$branch" >/dev/null 2>&1 || true

  git worktree add "$worktree" -b "$branch" "$base_ref" >/dev/null 2>&1 || {
    ralph_log_error "Failed to create worktree at $worktree"
    return 1
  }
  ralph_log_info "Created worktree: $worktree (branch: $branch, base: $base_ref)"

  # 构建增强 prompt
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

  enhanced_prompt+="## 任务
$prompt

## 重要规则
1. 你在一个 git worktree 中工作，当前目录就是项目根目录
2. 只做任务要求的修改，不要过度工程化
3. 遵循项目 CLAUDE.md 中的代码规范（如果存在）
4. 如果发现代码中其他问题（不在本次任务范围），将发现追加到 $RALPH_DISCOVERIES 文件，每行一个 JSON:
   {\"description\":\"问题描述\",\"source_task\":\"$task_id\",\"severity\":\"low|medium|high\"}
5. 不要提交代码，只做修改
"

  local max_turns="$RALPH_MAX_TURNS_SIMPLE"
  local exit_code=0

  if [[ "$complexity" == "complex" ]]; then
    max_turns="$RALPH_MAX_TURNS_COMPLEX"

    # complex 任务: 先规划再执行
    ralph_log_info "Complex task — running planning phase first"
    local plan_prompt="分析以下任务并制定实现计划，列出具体步骤和需要修改的文件:

$prompt"

    local plan_result
    plan_result="$(cd "$worktree" && claude -p "$plan_prompt" --model "$model" --max-turns 5 --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || true

    enhanced_prompt="## 实现计划
$plan_result

---

现在按照上述计划执行实现:

$enhanced_prompt"
  fi

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
  if [[ -n "$final_session" ]]; then
    ralph_db_update_task_session "$task_id" "$final_session"
  fi

  rm -f "$claude_stderr"

  local duration=$(( $(date +%s) - start_time ))
  ralph_log_info "Execute completed in ${duration}s (exit=$exit_code)"

  # 检查 worktree 是否有改动
  local has_changes
  has_changes="$(cd "$worktree" && git diff --stat HEAD 2>/dev/null || echo "")"
  if [[ -z "$has_changes" ]]; then
    has_changes="$(cd "$worktree" && git status --short 2>/dev/null || echo "")"
  fi

  if [[ -z "$has_changes" ]]; then
    # ── No changes: 用更多 turns 重试一次 ──
    local escalated_turns=$((max_turns + 15))
    ralph_log_warn "No changes detected, retrying with escalated turns ($escalated_turns)..."

    local retry_prompt="你刚才分析了代码但没有做任何修改。请重新执行任务，这次直接动手修改代码。

任务要求:
$prompt

重要: 你必须修改文件来完成任务。如果你不确定要改哪里，先用 grep/glob 搜索相关代码，然后直接修改。不要只分析不动手。"

    local retry_result retry_exit=0
    local final_session="${session_id:-$existing_session}"
    if [[ -n "$final_session" ]]; then
      retry_result="$(cd "$worktree" && claude --resume "$final_session" -p "$retry_prompt" --model "$model" --max-turns "$escalated_turns" --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || retry_exit=$?
    else
      retry_result="$(cd "$worktree" && claude -p "$retry_prompt" --model "$model" --max-turns "$escalated_turns" --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || retry_exit=$?
    fi

    # 重新检查
    has_changes="$(cd "$worktree" && git diff --stat HEAD 2>/dev/null || echo "")"
    if [[ -z "$has_changes" ]]; then
      has_changes="$(cd "$worktree" && git status --short 2>/dev/null || echo "")"
    fi

    if [[ -z "$has_changes" ]]; then
      ralph_log_warn "Still no changes after escalated retry"
      ralph_db_update_task_result "$task_id" "No changes made (even after escalated retry)" ""
      exit_code=1
    else
      ralph_log_info "Escalated retry produced changes"
      result="$retry_result"
    fi
  fi

  # 在 worktree 中 stage 所有改动
  if [[ $exit_code -eq 0 && -n "$has_changes" ]]; then
    cd "$worktree"
    git add -A >/dev/null 2>&1

    # 获取任务标题用于 commit message
    local task_json
    task_json="$(ralph_db_get_task "$task_id" 2>/dev/null)"
    local task_title_raw
    task_title_raw="$(echo "$task_json" | jq -r '.[0].title // "unknown"' 2>/dev/null || echo "$task_id")"
    [[ -z "$task_title_raw" ]] && task_title_raw="$task_id"

    # 生成变更摘要
    local diff_summary
    diff_summary="$(git diff --cached --stat 2>/dev/null | tail -1 | sed 's/^ *//' || echo "")"

    # 判断 commit 类型
    local commit_type="feat"
    if echo "$task_title_raw" | grep -qiE '(fix|修复|bug|问题|缺少|丢失|遮挡|异常|错误|失败)'; then
      commit_type="fix"
    elif echo "$task_title_raw" | grep -qiE '(refactor|重构|优化)'; then
      commit_type="refactor"
    elif echo "$task_title_raw" | grep -qiE '(style|样式|颜色|UI)'; then
      commit_type="style"
    fi

    # 从改动文件路径推断 scope
    local commit_scope=""
    local changed_files
    changed_files="$(git diff --cached --name-only 2>/dev/null | grep -v '^\.changeset/' || echo "")"
    if [[ -n "$changed_files" ]]; then
      local app_path
      app_path="$(echo "$changed_files" | grep -oE 'src/app/(\[lang\]/\([^)]+\)/|api/)([^/]+)' | head -1 | sed -E 's|.*/(.*)|\\1|')"
      if [[ -n "$app_path" ]]; then
        commit_scope="$app_path"
      else
        local comp_path
        comp_path="$(echo "$changed_files" | grep -oE 'src/(components|features)/([^/]+)' | head -1 | sed -E 's|.*/(.*)|\1|')"
        if [[ -n "$comp_path" ]]; then
          commit_scope="$comp_path"
        else
          commit_scope="$(echo "$changed_files" | head -1 | xargs dirname | xargs basename)"
        fi
      fi
    fi
    [[ -z "$commit_scope" ]] && commit_scope="general"

    local commit_msg="$commit_type($commit_scope): $task_title_raw

task-id: $task_id
$diff_summary"

    # hook 控制
    if [[ "${RALPH_SKIP_HOOKS:-false}" == "true" ]]; then
      HUSKY=0 git commit -m "$commit_msg" --no-verify >/dev/null 2>&1 || {
        ralph_log_warn "Failed to commit in worktree (may have no staged changes)"
        exit_code=1
      }
    else
      git commit -m "$commit_msg" >/dev/null 2>&1 || {
        ralph_log_warn "Failed to commit in worktree (may have no staged changes)"
        exit_code=1
      }
    fi
    cd "$RALPH_CWD"
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
