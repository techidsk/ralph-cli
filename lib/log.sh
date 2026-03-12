#!/usr/bin/env bash
# Ralph Loop — 日志工具函数
set -euo pipefail

_RALPH_LOG_FILE="${RALPH_LOG:-$HOME/.ralph/ralph.log}"

ralph_log() {
  local level="${1:-INFO}"
  shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [$level] $msg"
  echo "$line" >> "$_RALPH_LOG_FILE"
  # 仅在交互式终端时输出到 stderr，避免 nohup 重定向导致重复
  [[ -t 2 ]] && echo "$line" >&2 || true
}

ralph_log_info()  { ralph_log INFO  "$@"; }
ralph_log_warn()  { ralph_log WARN  "$@"; }
ralph_log_error() { ralph_log ERROR "$@"; }

# ── 每日事件日志 (JSONL，按天分割，保留 7 天) ──
#
# 用法: ralph_daily_log <event> <task_id> <title> [detail]
# event: task_started | task_done | task_failed | task_retried | task_discovered
#
# 输出: $RALPH_DAILY_LOG_DIR/YYYY-MM-DD.jsonl
ralph_daily_log() {
  local event="$1" task_id="$2" title="$3" detail="${4:-}"
  local log_dir="${RALPH_DAILY_LOG_DIR:-${RALPH_PROJECT_DIR:-$HOME/.ralph}/logs}"
  mkdir -p "$log_dir"

  local today
  today="$(date '+%Y-%m-%d')"
  local log_file="$log_dir/$today.jsonl"

  jq -nc \
    --arg time "$(date '+%H:%M:%S')" \
    --arg event "$event" \
    --arg id "$task_id" \
    --arg title "$title" \
    --arg detail "$detail" \
    '{time:$time, event:$event, task_id:$id, title:$title, detail:$detail}' \
    >> "$log_file" 2>/dev/null || true

  # 每天首次写入时清理 >7 天的旧日志
  local cleanup_flag="$log_dir/.cleanup-$today"
  if [[ ! -f "$cleanup_flag" ]]; then
    touch "$cleanup_flag"
    find "$log_dir" -name '*.jsonl' -mtime +7 -delete 2>/dev/null || true
    find "$log_dir" -name '.cleanup-*' ! -name ".cleanup-$today" -delete 2>/dev/null || true
  fi
}
