#!/usr/bin/env bash
# Ralph CLI — 最终验证 (trust-but-verify)
# Claude Code 已在 execute 阶段自行运行验证并修复
# 此处仅做 Ralph 侧的最终确认
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

  ralph_log_info "=== VERIFY (final check): $task_id ==="

  local failed=0

  # 确保 worktree 有 node_modules（幂等，execute.sh 已做但保险起见）
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

  # 运行验证命令
  if [[ -n "${RALPH_VERIFY_COMMANDS:-}" ]]; then
    IFS='|' read -ra verify_cmds <<< "$RALPH_VERIFY_COMMANDS"
    for cmd in "${verify_cmds[@]}"; do
      [[ -z "$cmd" ]] && continue
      ralph_log_info "Final check: $cmd"
      local verify_output
      verify_output="$(cd "$worktree" && eval "$cmd" 2>&1)" && {
        ralph_log_debug "Verify cmd output: $(echo "$verify_output" | head -5)"
        ralph_log_info "Passed: $cmd"
      } || {
        ralph_log_debug "Verify cmd output: $(echo "$verify_output" | head -5)"
        ralph_log_error "Final verify failed: $cmd"
        failed=1
        break
      }
    done
  else
    ralph_log_info "No verify commands configured, skipping"
  fi

  local duration=$(( $(date +%s) - start_time ))
  ralph_db_log_cycle 0 "verify" "$task_id" "" "pass=$((1 - failed))" "$failed" "$duration"

  ralph_log_info "Verify completed in ${duration}s ($([ $failed -eq 0 ] && echo 'PASS' || echo 'FAIL'))"
  return $failed
}
