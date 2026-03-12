#!/usr/bin/env bash
# Ralph Loop — 验证 (可配置命令 + haiku cross-review)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/db.sh"

# ralph_verify <worktree_path> <task_id>
# 返回 0=通过, 1=失败
ralph_verify() {
  local worktree="$1"
  local task_id="$2"
  local start_time
  start_time="$(date +%s)"

  ralph_log_info "=== VERIFY phase: $task_id ==="

  local failed=0

  # 确保 worktree 有 node_modules（符号链接到主项目）
  if [[ "${RALPH_VERIFY_SYMLINK_NODE_MODULES:-true}" == "true" ]]; then
    if [[ ! -d "$worktree/node_modules" ]]; then
      ln -s "$RALPH_CWD/node_modules" "$worktree/node_modules" 2>/dev/null || true
    fi
    # 同步 packages 子目录的 node_modules
    for pkg_nm in "$RALPH_CWD"/packages/*/node_modules; do
      [[ -d "$pkg_nm" ]] || continue
      local pkg_rel="${pkg_nm#$RALPH_CWD/}"
      local pkg_dir="$(dirname "$pkg_rel")"
      if [[ ! -d "$worktree/$pkg_rel" ]]; then
        mkdir -p "$worktree/$pkg_dir" 2>/dev/null || true
        ln -s "$pkg_nm" "$worktree/$pkg_rel" 2>/dev/null || true
      fi
    done
  fi

  # 从 RALPH_VERIFY_COMMANDS 读取验证命令（pipe 分隔）
  # 验证失败时让 Claude 在一次多轮对话中自主修复+重验
  local max_fix_turns="${RALPH_VERIFY_FIX_MAX_TURNS:-20}"

  if [[ -n "${RALPH_VERIFY_COMMANDS:-}" ]]; then
    IFS='|' read -ra verify_cmds <<< "$RALPH_VERIFY_COMMANDS"
    for cmd in "${verify_cmds[@]}"; do
      [[ -z "$cmd" ]] && continue
      ralph_log_info "Running verify: $cmd"
      local cmd_output
      cmd_output="$(cd "$worktree" && eval "$cmd" 2>&1 | tail -30)" || {
        local cmd_exit=$?
        ralph_log_error "Verify command failed ($cmd) for $task_id"
        ralph_log_error "$cmd_output"

        # ── 自动修复: 让 Claude 在一次多轮对话中自主修复 ──
        ralph_log_info "Starting auto-fix for $task_id (max-turns=$max_fix_turns)..."

        # 获取任务的 session_id 用于 resume（保持完整上下文）
        local fix_session
        fix_session="$(ralph_db_get_task_session "$task_id" 2>/dev/null || echo "")"

        local fix_prompt="你刚才的代码改动导致验证失败。

验证命令: \`$cmd\`
错误信息:
\`\`\`
$cmd_output
\`\`\`

请修复这些错误。你可以:
1. 阅读相关文件理解上下文
2. 修改代码修复错误
3. 自己运行 \`$cmd\` 确认修复是否成功
4. 如果还有错误，继续修复直到通过

重要规则:
- 只修复验证错误，不要做其他改动
- 修复完成后运行 \`$cmd\` 确认通过
- 不需要 git commit"

        local fix_result fix_exit=0
        if [[ -n "$fix_session" ]]; then
          ralph_log_info "Resuming session $fix_session for auto-fix"
          fix_result="$(cd "$worktree" && claude --resume "$fix_session" -p "$fix_prompt" --model "${RALPH_DEFAULT_MODEL}" --max-turns "$max_fix_turns" --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || fix_exit=$?
        else
          ralph_log_info "Starting new session for auto-fix"
          fix_result="$(cd "$worktree" && claude -p "$fix_prompt" --model "${RALPH_DEFAULT_MODEL}" --max-turns "$max_fix_turns" --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || fix_exit=$?
        fi

        if [[ $fix_exit -ne 0 ]]; then
          ralph_log_warn "Auto-fix Claude call failed (exit=$fix_exit)"
          failed=1
          break
        fi

        # 重新 stage 修复的代码
        cd "$worktree" && git add -A >/dev/null 2>&1

        # amend 到之前的 commit
        if [[ "${RALPH_SKIP_HOOKS:-false}" == "true" ]]; then
          cd "$worktree" && HUSKY=0 git commit --amend --no-edit --no-verify >/dev/null 2>&1 || true
        else
          cd "$worktree" && git commit --amend --no-edit >/dev/null 2>&1 || true
        fi

        # 最终验证（Claude 可能说修好了但实际没有）
        ralph_log_info "Final verification after auto-fix..."
        cmd_output="$(cd "$worktree" && eval "$cmd" 2>&1 | tail -30)" && {
          ralph_log_info "Auto-fix succeeded! Verify passed: $cmd"
          continue
        }

        ralph_log_error "Auto-fix failed, verify still not passing:"
        ralph_log_error "$(echo "$cmd_output" | grep -E '(error TS|Error:)' | head -5)"
        failed=1
        break
      }
      ralph_log_info "Verify passed: $cmd"
    done
  else
    ralph_log_info "No verify commands configured, skipping command verification"
  fi

  # Haiku cross-review
  if [[ $failed -eq 0 ]]; then
    ralph_log_info "Running haiku cross-review..."
    local diff_content
    diff_content="$(cd "$worktree" && git diff HEAD~1 2>/dev/null | head -500 || echo "No diff available")"

    if [[ -n "$diff_content" && "$diff_content" != "No diff available" ]]; then
      local review_prompt
      review_prompt="Review this code diff for a task titled '$task_id'. Check for:
1. Obvious bugs or logic errors
2. Security issues (XSS, injection, etc)
3. Breaking changes to existing APIs
4. Violations of project conventions (check CLAUDE.md if present)

Diff:
$diff_content

Output strict JSON (no markdown code block):
{\"pass\": true/false, \"issues\": [\"issue description\"], \"severity\": \"low/medium/high\"}"

      local review_result
      review_result="$(cd "$worktree" && claude -p "$review_prompt" --model "$RALPH_REVIEW_MODEL" --max-turns 1 --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || {
        ralph_log_warn "Cross-review call failed, skipping"
        review_result='{"pass": true}'
      }

      # 解析 review 结果
      local review_json
      review_json="$(echo "$review_result" | sed -n '/^{/,/^}/p')"
      if [[ -z "$review_json" ]]; then
        review_json="$(echo "$review_result" | sed -n '/```json/,/```/p' | grep -v '```')"
      fi

      if echo "$review_json" | jq . >/dev/null 2>&1; then
        local pass
        pass="$(echo "$review_json" | jq -r '.pass // true')"
        if [[ "$pass" == "false" ]]; then
          local severity
          severity="$(echo "$review_json" | jq -r '.severity // "medium"')"
          local issues
          issues="$(echo "$review_json" | jq -r '.issues[]? // empty' | head -5)"

          if [[ "$severity" == "high" ]]; then
            ralph_log_error "Cross-review FAILED (severity=$severity): $issues"
            failed=1
          else
            ralph_log_warn "Cross-review found issues (severity=$severity): $issues"
            # 非 high 严重度的问题记为 discovery 但不阻断
            if [[ -n "$issues" ]]; then
              while IFS= read -r issue; do
                ralph_db_add_discovery "$task_id" "[review] $issue" "$severity"
              done <<< "$issues"
            fi
          fi
        else
          ralph_log_info "Cross-review passed"
        fi
      else
        ralph_log_warn "Could not parse review result, assuming pass"
      fi
    fi
  fi

  local duration=$(( $(date +%s) - start_time ))
  local exit_code=$failed
  ralph_db_log_cycle 0 "verify" "$task_id" "$RALPH_REVIEW_MODEL" "pass=$((1 - failed))" "$exit_code" "$duration"

  ralph_log_info "Verify completed in ${duration}s (result=$([ $failed -eq 0 ] && echo 'PASS' || echo 'FAIL'))"
  return $failed
}
