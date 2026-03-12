#!/usr/bin/env bash
# Ralph Loop — 数据层 shim（委托 ralph-db Python 脚本）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/log.sh"

# 定位 ralph-db 可执行文件
# 优先使用 ~/.ralph/bin/ralph-db，其次使用脚本同级 bin/ 目录
if [[ -x "$RALPH_HOME/bin/ralph-db" ]]; then
  RALPH_DB_BIN="$RALPH_HOME/bin/ralph-db"
elif [[ -x "$SCRIPT_DIR/../bin/ralph-db" ]]; then
  RALPH_DB_BIN="$SCRIPT_DIR/../bin/ralph-db"
else
  ralph_log_error "ralph-db not found. Run install.sh or ensure ralph-db is in PATH."
  exit 1
fi

# ── 初始化 ──

ralph_db_init() {
  "$RALPH_DB_BIN" init "$RALPH_PROJECT" >/dev/null 2>&1
}

# ── Task CRUD ──

ralph_db_add_task() {
  local id="$1" title="$2" priority="$3" model="$4" complexity="$5"
  local prompt="$6" files="${7:-}" source="${8:-manual}"
  printf '%s' "$prompt" | "$RALPH_DB_BIN" add-task "$RALPH_PROJECT" \
    --id "$id" --title "$title" --priority "$priority" --model "$model" \
    --complexity "$complexity" --prompt - --files "$files" --source "$source" \
    >/dev/null
}

ralph_db_get_task() {
  "$RALPH_DB_BIN" get-task "$RALPH_PROJECT" "$1"
}

ralph_db_list_pending() {
  "$RALPH_DB_BIN" list-pending "$RALPH_PROJECT"
}

ralph_db_list_all() {
  "$RALPH_DB_BIN" list-all "$RALPH_PROJECT"
}

ralph_db_count_pending() {
  "$RALPH_DB_BIN" count-pending "$RALPH_PROJECT"
}

ralph_db_update_task_status() {
  "$RALPH_DB_BIN" update-status "$RALPH_PROJECT" "$1" "$2" >/dev/null
}

ralph_db_update_task_result() {
  local id="$1" result="$2" checkpoint_tag="${3:-}"
  "$RALPH_DB_BIN" update-result "$RALPH_PROJECT" "$id" \
    --result "$result" --checkpoint "$checkpoint_tag" >/dev/null
}

ralph_db_increment_retry() {
  "$RALPH_DB_BIN" increment-retry "$RALPH_PROJECT" "$1" >/dev/null
}

ralph_db_get_task_retry_info() {
  "$RALPH_DB_BIN" get-retry-info "$RALPH_PROJECT" "$1"
}

ralph_db_delete_task() {
  "$RALPH_DB_BIN" delete-task "$RALPH_PROJECT" "$1" >/dev/null
}

ralph_db_update_task_priority() {
  "$RALPH_DB_BIN" update-priority "$RALPH_PROJECT" "$1" "$2" >/dev/null
}

ralph_db_update_task_model() {
  "$RALPH_DB_BIN" update-model "$RALPH_PROJECT" "$1" "$2" >/dev/null
}

ralph_db_update_task_session() {
  "$RALPH_DB_BIN" update-session "$RALPH_PROJECT" "$1" "$2" >/dev/null
}

ralph_db_get_task_session() {
  "$RALPH_DB_BIN" get-session "$RALPH_PROJECT" "$1" 2>/dev/null
}

# ── Discovery CRUD ──

ralph_db_add_discovery() {
  local source_task="$1" description="$2" severity="${3:-medium}"
  printf '%s' "$description" | "$RALPH_DB_BIN" add-discovery "$RALPH_PROJECT" \
    --source-task "$source_task" --description - --severity "$severity" >/dev/null
}

ralph_db_get_unconsumed_discoveries() {
  "$RALPH_DB_BIN" get-unconsumed-discoveries "$RALPH_PROJECT"
}

ralph_db_consume_discoveries() {
  "$RALPH_DB_BIN" consume-discoveries "$RALPH_PROJECT" >/dev/null
}

# ── Cycle Log ──

ralph_db_log_cycle() {
  local cycle_num="$1" phase="$2" task_id="$3" model="$4" summary="$5" exit_code="$6" duration_sec="$7"
  printf '%s' "$summary" | "$RALPH_DB_BIN" log-cycle "$RALPH_PROJECT" \
    --cycle "$cycle_num" --phase "$phase" --task-id "$task_id" --model "$model" \
    --summary - --exit-code "$exit_code" --duration "$duration_sec" >/dev/null
}

ralph_db_get_last_cycle_log() {
  "$RALPH_DB_BIN" get-last-cycle-log "$RALPH_PROJECT"
}

ralph_db_get_today_cycle_logs() {
  "$RALPH_DB_BIN" get-today-cycle-logs "$RALPH_PROJECT"
}

ralph_db_get_today_completed_tasks() {
  "$RALPH_DB_BIN" get-today-completed-tasks "$RALPH_PROJECT"
}

# ── 兼容层: ralph_sqlite (供旧代码调用) ──

ralph_sqlite() {
  # 兼容旧代码中直接调用 ralph_sqlite 的场景
  # 新代码应直接使用 ralph_db_* 函数或 ralph-db query
  local db_file=""
  local args=()
  local json_mode=false

  for arg in "$@"; do
    if [[ "$arg" == "-json" ]]; then
      json_mode=true
    elif [[ "$arg" == "-separator" ]]; then
      # 跳过 -separator 和下一个参数
      continue
    elif [[ "$arg" == "$RALPH_DB" ]]; then
      db_file="$arg"
    elif [[ -z "$db_file" ]]; then
      args+=("$arg")
    else
      args+=("$arg")
    fi
  done

  # 使用 ralph-db query 处理
  if [[ ${#args[@]} -gt 0 ]]; then
    "$RALPH_DB_BIN" query "$RALPH_PROJECT" "${args[-1]}" 2>/dev/null
  fi
}

# ── 自动初始化 ──
ralph_db_init
