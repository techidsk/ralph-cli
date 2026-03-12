#!/usr/bin/env bash
# Ralph Loop — 主循环（支持并发执行，多项目隔离）
set -euo pipefail

# 清除 Claude Code 嵌套检测，允许子进程调用 claude CLI
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

# ── 路径解析（resolve symlink） ──
_RALPH_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$_RALPH_SOURCE" ]]; do
  _RALPH_DIR="$(cd "$(dirname "$_RALPH_SOURCE")" && pwd)"
  _RALPH_SOURCE="$(readlink "$_RALPH_SOURCE")"
  [[ "$_RALPH_SOURCE" != /* ]] && _RALPH_SOURCE="$_RALPH_DIR/$_RALPH_SOURCE"
done
_RALPH_SELF="$(cd "$(dirname "$_RALPH_SOURCE")" && pwd)"
if [[ -d "$_RALPH_SELF/lib" ]]; then
  RALPH_LOOP_DIR="$_RALPH_SELF"
elif [[ -d "$_RALPH_SELF/../lib" ]]; then
  RALPH_LOOP_DIR="$(cd "$_RALPH_SELF/.." && pwd)"
else
  echo "错误: 无法定位 Ralph lib 目录" >&2; exit 1
fi

source "$RALPH_LOOP_DIR/lib/config.sh"
source "$RALPH_LOOP_DIR/lib/log.sh"
source "$RALPH_LOOP_DIR/lib/db.sh"
source "$RALPH_LOOP_DIR/lib/source.sh"
source "$RALPH_LOOP_DIR/lib/reflect.sh"
source "$RALPH_LOOP_DIR/lib/execute.sh"
source "$RALPH_LOOP_DIR/lib/verify.sh"
source "$RALPH_LOOP_DIR/lib/commit.sh"
source "$RALPH_LOOP_DIR/lib/webhook.sh"

# ── 阻止 Mac 休眠 ──
caffeinate -i -w $$ &
CAFFEINATE_PID=$!
trap 'ralph_notify "service_stopped" "" "" "PID=$$" 2>/dev/null || true; kill $CAFFEINATE_PID 2>/dev/null; ralph_log_info "Ralph loop exiting"' EXIT

# 写入 PID
echo $$ > "$RALPH_PID_FILE"

ralph_log_info "=========================================="
ralph_log_info "Ralph Loop started (PID: $$)"
ralph_log_info "Project: $RALPH_PROJECT"
ralph_log_info "Source: $RALPH_SOURCE"
ralph_log_info "CWD: $RALPH_CWD"
ralph_log_info "Max concurrent: $RALPH_MAX_CONCURRENT"
ralph_log_info "Poll interval: ${RALPH_POLL_INTERVAL}s"
ralph_log_info "=========================================="

# 通知服务已启动
ralph_notify "service_started" "" "" "PID=$$, concurrent=$RALPH_MAX_CONCURRENT" 2>/dev/null || true
ralph_daily_log "service_started" "-" "Ralph Loop started" "PID=$$"

# ── 孤儿 worktree 清理 ──

ralph_cleanup_orphan_worktrees() {
  local count=0
  # 使用项目前缀匹配 worktree
  for wt in /tmp/ralph-wt-$RALPH_PROJECT-*; do
    [[ -d "$wt" ]] || continue
    local task_id_part="${wt##*/tmp/ralph-wt-$RALPH_PROJECT-}"
    # 检查对应任务是否还在 running，如果不是则清理
    local status
    status="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" "SELECT status FROM tasks WHERE id='$task_id_part'" 2>/dev/null || echo "")"
    # ralph-db query 可能返回 JSON 数组或纯文本
    status="$(echo "$status" | tr -d '[]"{}[:space:]' | sed 's/status://')"
    if [[ "$status" != "running" && "$status" != "pending" ]]; then
      ralph_log_info "Cleaning orphan worktree: $wt"
      cd "$RALPH_CWD"
      git worktree remove "$wt" --force >/dev/null 2>&1 || rm -rf "$wt"
      git branch -D "ralph/task-$task_id_part" >/dev/null 2>&1 || true
      count=$((count + 1))
    fi
  done
  [[ $count -gt 0 ]] && ralph_log_info "Cleaned $count orphan worktree(s)" || true
}

# ── 上下文维护 ──

ralph_update_context_brief() {
  local task_id="$1" task_title="$2" checkpoint_tag="$3"

  local entry
  entry="## $(date '+%Y-%m-%dT%H:%M') — $task_title
- 改动: $(cd "$RALPH_CWD" && git diff --stat "${checkpoint_tag}~1..$checkpoint_tag" 2>/dev/null | tail -1 || echo "unknown")
- 分支: ralph/nightly-$(date '+%m%d')
- checkpoint: $checkpoint_tag
"

  if [[ -f "$RALPH_CONTEXT_BRIEF" ]]; then
    local tmp="/tmp/ralph-ctx-$$.md"
    echo "$entry" > "$tmp"
    cat "$RALPH_CONTEXT_BRIEF" >> "$tmp"
    head -n $(( RALPH_CONTEXT_BRIEF_MAX * 5 )) "$tmp" > "$RALPH_CONTEXT_BRIEF"
    rm -f "$tmp"
  else
    echo "$entry" > "$RALPH_CONTEXT_BRIEF"
  fi
}

ralph_add_lesson() {
  local lesson="$1"
  if [[ ! -f "$RALPH_LESSONS" ]]; then
    echo "$lesson" > "$RALPH_LESSONS"
    return
  fi

  if grep -qF "$lesson" "$RALPH_LESSONS" 2>/dev/null; then
    return
  fi

  echo "$lesson" >> "$RALPH_LESSONS"
  tail -n "$RALPH_LESSONS_MAX" "$RALPH_LESSONS" > "/tmp/ralph-lessons-$$.md"
  mv "/tmp/ralph-lessons-$$.md" "$RALPH_LESSONS"
}

# ── 单任务 Execute（后台子进程调用） ──
# 将 worktree 路径或 "FAILED" 写入结果文件

ralph_execute_bg() {
  local task_id="$1" model="$2" prompt="$3" complexity="$4" files="$5" result_file="$6"

  local worktree=""
  worktree="$(ralph_execute "$task_id" "$model" "$prompt" "$complexity" "$files")" && {
    echo "$worktree" > "$result_file"
  } || {
    echo "FAILED:$?" > "$result_file"
  }
}

# ── 单任务后半段: Verify → Commit → Update ──

ralph_finalize_task() {
  local task_id="$1" task_title="$2" worktree="$3"

  # VERIFY
  local verify_exit=0
  ralph_verify "$worktree" "$task_id" || verify_exit=$?

  if [[ $verify_exit -ne 0 ]]; then
    ralph_log_error "Verify failed for $task_id"
    ralph_db_update_task_status "$task_id" "failed"
    ralph_db_update_task_result "$task_id" "Verification failed" ""
    ralph_db_add_discovery "$task_id" "Task $task_id ($task_title) failed verification" "high"
    ralph_push_to_outbox "$task_id" "failed" "Verification failed" 2>/dev/null || true
    ralph_notify "task_failed" "$task_id" "$task_title" "验证失败" 2>/dev/null || true
    ralph_daily_log "task_failed" "$task_id" "$task_title" "Verification failed"
    ralph_rollback_worktree "$worktree" "$task_id"
    rm -f "/tmp/ralph-baseref-$task_id"
    return 1
  fi

  # COMMIT
  local checkpoint_tag=""
  checkpoint_tag="$(ralph_commit "$worktree" "$task_id" "$task_title")" || {
    ralph_log_error "Commit failed for $task_id"
    ralph_db_update_task_status "$task_id" "failed"
    ralph_db_update_task_result "$task_id" "Commit failed" ""
    ralph_push_to_outbox "$task_id" "failed" "Commit failed" 2>/dev/null || true
    ralph_notify "task_failed" "$task_id" "$task_title" "提交失败" 2>/dev/null || true
    ralph_daily_log "task_failed" "$task_id" "$task_title" "Commit failed"
    ralph_rollback_worktree "$worktree" "$task_id" 2>/dev/null || true
    rm -f "/tmp/ralph-baseref-$task_id"
    return 1
  }

  # UPDATE
  ralph_db_update_task_status "$task_id" "done"
  ralph_db_update_task_result "$task_id" "Completed successfully" "$checkpoint_tag"
  ralph_update_context_brief "$task_id" "$task_title" "$checkpoint_tag"

  ralph_log_info "✓ Task $task_id completed: $checkpoint_tag"

  # 清理临时文件
  rm -f "/tmp/ralph-baseref-$task_id"

  ralph_push_to_outbox "$task_id" "done" "Completed successfully" "$checkpoint_tag" 2>/dev/null || true
  ralph_notify "task_done" "$task_id" "$task_title" "checkpoint: $checkpoint_tag" 2>/dev/null || true
  ralph_daily_log "task_done" "$task_id" "$task_title" "checkpoint=$checkpoint_tag"

  return 0
}

# ── 选取待执行任务 (最多 N 个) ──

ralph_pick_tasks() {
  local max="$1"

  # 先让 reflect 选第一个任务（带智能分析）
  local reflect_result
  reflect_result="$(ralph_reflect 2>/dev/null)" || { ralph_log_warn "Reflect failed"; return 1; }
  [[ -z "$reflect_result" ]] && return 1

  local first_id
  first_id="$(echo "$reflect_result" | jq -r '.next.task_id // empty' 2>/dev/null)" || first_id=""
  if [[ -z "$first_id" || "$first_id" == "null" ]]; then
    ralph_log_warn "Reflect returned no next task, falling back to first pending"
    local raw_first
    raw_first="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" "SELECT id FROM tasks WHERE status='pending' ORDER BY priority ASC, created_at ASC LIMIT 1" 2>/dev/null || echo "")"
    # ralph-db query 可能返回纯文本或 JSON 数组
    first_id="$(echo "$raw_first" | jq -r '.[0].id // empty' 2>/dev/null)" || first_id=""
    [[ -z "$first_id" ]] && first_id="$(echo "$raw_first" | head -1 | tr -d '[:space:]')"
    [[ -z "$first_id" ]] && return 1
  fi

  # reflect 可能给出 enhanced prompt / model override
  local r_model r_prompt r_plan
  r_model="$(echo "$reflect_result" | jq -r '.next.model // empty' 2>/dev/null)" || r_model=""
  r_prompt="$(echo "$reflect_result" | jq -r '.next.enhanced_prompt // empty' 2>/dev/null)" || r_prompt=""
  r_plan="$(echo "$reflect_result" | jq -r '.next.plan_first // false' 2>/dev/null)" || r_plan="false"

  # 写第一个任务的 reflect overrides 到临时文件
  echo "$r_model" > "/tmp/ralph-reflect-model-$first_id"
  echo "$r_prompt" > "/tmp/ralph-reflect-prompt-$first_id"
  echo "$r_plan" > "/tmp/ralph-reflect-plan-$first_id"

  # 标记为 running
  ralph_db_update_task_status "$first_id" "running"

  echo "$first_id"

  # 取更多 pending 任务（按优先级排序，排除已选的）
  if [[ "$max" -gt 1 ]]; then
    local more
    more="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" "SELECT id FROM tasks WHERE status='pending' AND id!='$first_id' ORDER BY priority ASC, created_at ASC LIMIT $((max - 1))" 2>/dev/null)"
    # 从 JSON 数组中提取 id 值
    local ids
    ids="$(echo "$more" | jq -r '.[].id // empty' 2>/dev/null)" || ids=""
    for tid in $ids; do
      ralph_db_update_task_status "$tid" "running"
      echo "$tid"
    done
  fi
}

# ── 单轮 Cycle ──

ralph_run_cycle() {
  local cycle_num="$1"

  ralph_log_info "━━━━━ Cycle $cycle_num ━━━━━"

  # 清理孤儿 worktree
  ralph_cleanup_orphan_worktrees 2>/dev/null || true

  # 从 inbox 消费新任务
  ralph_consume_inbox 2>/dev/null || ralph_log_warn "Inbox consume failed"

  # 消费 discoveries
  ralph_sync_discoveries_from_source 2>/dev/null || true
  ralph_consume_discoveries_file 2>/dev/null || true

  # 检查 pending 任务数
  local pending_count
  pending_count="$(ralph_db_count_pending)"

  if [[ "$pending_count" -eq 0 ]]; then
    ralph_log_info "No pending tasks, sleeping ${RALPH_POLL_INTERVAL}s..."

    local today_done
    today_done="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" "SELECT COUNT(*) FROM tasks WHERE status IN ('done','failed') AND date(completed_at)=date('now','localtime')" 2>/dev/null || echo 0)"
    # 每天只生成一次报告（用日期 flag 文件防重复）
    local report_flag="$RALPH_PROJECT_DIR/.report-$(date '+%Y%m%d')"
    if [[ "$today_done" -gt 0 && "$today_done" != "0" && ! -f "$report_flag" ]]; then
      ralph_log_info "Generating end-of-batch report..."
      source "$RALPH_LOOP_DIR/lib/report.sh"
      if ralph_generate_report 2>/dev/null; then
        touch "$report_flag"
      else
        ralph_log_warn "Report generation failed"
      fi
    fi

    sleep "$RALPH_POLL_INTERVAL"
    return 0
  fi

  # 1. REFLECT + 选取任务（最多 RALPH_MAX_CONCURRENT 个）
  local task_ids=()
  while IFS= read -r tid; do
    [[ -n "$tid" ]] && task_ids+=("$tid")
  done < <(ralph_pick_tasks "$RALPH_MAX_CONCURRENT")

  if [[ ${#task_ids[@]} -eq 0 ]]; then
    ralph_log_info "No tasks selected, sleeping..."
    sleep "$RALPH_POLL_INTERVAL"
    return 0
  fi

  ralph_log_info "Selected ${#task_ids[@]} task(s) for execution"

  # ── Sliding Window 并发执行（bash 3.2 兼容） ──
  # 一个任务完成就立即补位新任务，不浪费空槽
  # 用两个平行数组模拟 pid→task_id 映射

  local result_dir="/tmp/ralph-results-$$"
  mkdir -p "$result_dir"

  _sw_pids=()    # 运行中的 PID 列表
  _sw_tasks=()   # 对应的 task_id 列表（与 _sw_pids 一一对应）

  # 启动单个任务
  _sw_launch() {
    local task_id="$1"

    # 防护: 空 task_id 或 JSON 残留直接跳过
    if [[ -z "$task_id" || "$task_id" == "[]" || "$task_id" == "null" || "$task_id" =~ ^\[.*\]$ ]]; then
      ralph_log_warn "Skipping invalid task_id in _sw_launch: '$task_id'"
      return
    fi

    local task_json
    task_json="$(ralph_db_get_task "$task_id")"
    local t_title t_prompt t_model t_complexity t_files
    t_title="$(echo "$task_json" | jq -r '.[0].title // "unknown"')"
    t_prompt="$(echo "$task_json" | jq -r '.[0].prompt // ""')"
    t_model="$(echo "$task_json" | jq -r '.[0].model // "'"$RALPH_DEFAULT_MODEL"'"')"
    t_complexity="$(echo "$task_json" | jq -r '.[0].complexity // "simple"')"
    t_files="$(echo "$task_json" | jq -r '.[0].context_files // ""')"

    if [[ -f "/tmp/ralph-reflect-model-$task_id" ]]; then
      local rm rp rpl
      rm="$(cat "/tmp/ralph-reflect-model-$task_id")"
      rp="$(cat "/tmp/ralph-reflect-prompt-$task_id")"
      rpl="$(cat "/tmp/ralph-reflect-plan-$task_id")"
      [[ -n "$rm" && "$rm" != "null" && "$rm" != "empty" ]] && t_model="$rm"
      [[ -n "$rp" && "$rp" != "null" && "$rp" != "empty" ]] && t_prompt="$rp"
      [[ "$rpl" == "true" ]] && t_complexity="complex"
      rm -f "/tmp/ralph-reflect-model-$task_id" "/tmp/ralph-reflect-prompt-$task_id" "/tmp/ralph-reflect-plan-$task_id"
    fi

    ralph_log_info "Launching: $task_id — $t_title (model=$t_model)"
    ralph_notify "task_started" "$task_id" "$t_title" "模型: $t_model, 复杂度: $t_complexity" 2>/dev/null || true
    ralph_daily_log "task_started" "$task_id" "$t_title" "model=$t_model, complexity=$t_complexity"

    ralph_execute_bg "$task_id" "$t_model" "$t_prompt" "$t_complexity" "$t_files" \
      "$result_dir/$task_id" &
    _sw_pids+=($!)
    _sw_tasks+=("$task_id")
    echo "$t_title" > "$result_dir/${task_id}.title"
  }

  # 处理已完成的任务
  _sw_handle() {
    local task_id="$1"

    # 防护: 空 task_id 或 JSON 残留直接跳过
    if [[ -z "$task_id" || "$task_id" == "[]" || "$task_id" == "null" || "$task_id" =~ ^\[.*\]$ ]]; then
      ralph_log_warn "Skipping invalid task_id in _sw_handle: '$task_id'"
      return
    fi

    local t_title
    t_title="$(cat "$result_dir/${task_id}.title" 2>/dev/null || echo "unknown")"

    local exec_result
    exec_result="$(cat "$result_dir/$task_id" 2>/dev/null || echo "FAILED:1")"

    if [[ "$exec_result" == FAILED:* ]]; then
      local exit_code="${exec_result#FAILED:}"
      ralph_log_error "Execute failed for $task_id"
      ralph_db_update_task_status "$task_id" "failed"
      ralph_db_update_task_result "$task_id" "Execution failed (exit=$exit_code)" ""
      ralph_db_add_discovery "$task_id" "Task $task_id ($t_title) failed during execution" "medium"

      local retry_info
      retry_info="$(ralph_db_get_task_retry_info "$task_id")"
      local retry_count max_retries
      retry_count="$(echo "$retry_info" | cut -d'|' -f1)"
      max_retries="$(echo "$retry_info" | cut -d'|' -f2)"
      if [[ "$retry_count" -lt "$max_retries" ]]; then
        ralph_log_info "Requeueing $task_id for retry ($retry_count/$max_retries)"
        ralph_db_increment_retry "$task_id"
        ralph_db_update_task_status "$task_id" "pending"
        ralph_daily_log "task_retried" "$task_id" "$t_title" "retry=$retry_count/$max_retries"
      else
        ralph_push_to_outbox "$task_id" "failed" "Execution failed (exit=$exit_code)" 2>/dev/null || true
        ralph_notify "task_failed" "$task_id" "$t_title" "执行失败 (exit=$exit_code)" 2>/dev/null || true
        ralph_daily_log "task_failed" "$task_id" "$t_title" "Execution failed (exit=$exit_code)"
      fi
      return
    fi

    local worktree="$exec_result"
    if [[ ! -d "$worktree" ]]; then
      ralph_log_error "Worktree not found for $task_id: $worktree"
      ralph_db_update_task_status "$task_id" "failed"
      ralph_db_update_task_result "$task_id" "Worktree missing" ""
      return
    fi

    ralph_finalize_task "$task_id" "$t_title" "$worktree" || true
  }

  # 从平行数组中移除指定索引
  _sw_remove_at() {
    local idx="$1"
    local new_pids=() new_tasks=()
    local i
    for i in "${!_sw_pids[@]}"; do
      if [[ "$i" -ne "$idx" ]]; then
        new_pids+=("${_sw_pids[$i]}")
        new_tasks+=("${_sw_tasks[$i]}")
      fi
    done
    _sw_pids=("${new_pids[@]+"${new_pids[@]}"}")
    _sw_tasks=("${new_tasks[@]+"${new_tasks[@]}"}")
  }

  # 补位：取一个新的 pending 任务
  _sw_backfill() {
    if [[ ${#_sw_pids[@]} -ge $RALPH_MAX_CONCURRENT ]]; then
      return
    fi
    # 排除当前运行中的 task_id
    local exclude=""
    local t
    for t in "${_sw_tasks[@]+"${_sw_tasks[@]}"}"; do
      [[ -n "$exclude" ]] && exclude+=","
      exclude+="'$t'"
    done
    local where="status='pending'"
    [[ -n "$exclude" ]] && where+=" AND id NOT IN ($exclude)"

    local raw_result
    raw_result="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" \
      "SELECT id FROM tasks WHERE $where ORDER BY priority ASC, created_at ASC LIMIT 1" 2>/dev/null || echo "")"

    # ralph-db 可能返回 JSON 数组或纯文本，统一提取
    local next_id=""
    next_id="$(echo "$raw_result" | jq -r '.[0].id // empty' 2>/dev/null)" || next_id=""
    ralph_log_debug "Backfill query result: $raw_result"
    if [[ -z "$next_id" ]]; then
      # 纯文本模式：取第一行，去掉空白和 []
      next_id="$(echo "$raw_result" | head -1 | tr -d '[:space:][]')"
    fi

    if [[ -n "$next_id" && "$next_id" != "null" ]]; then
      ralph_db_update_task_status "$next_id" "running"
      ralph_log_info "Backfilling slot with: $next_id"
      _sw_launch "$next_id"
    fi
  }

  # Phase 1: 初始启动
  for task_id in "${task_ids[@]}"; do
    _sw_launch "$task_id"
  done

  # Phase 2: 轮询等待完成 → 处理 → 补位
  while [[ ${#_sw_pids[@]} -gt 0 ]]; do
    # 暂停检测
    if [[ -f "$RALPH_PAUSED_FILE" ]]; then
      ralph_log_info "PAUSED detected, waiting for running tasks to finish..."
      local i
      for i in "${!_sw_pids[@]}"; do
        wait "${_sw_pids[$i]}" 2>/dev/null || true
        _sw_handle "${_sw_tasks[$i]}"
      done
      _sw_pids=()
      _sw_tasks=()
      break
    fi

    # 轮询检查哪些进程已退出
    local found_done=0
    ralph_log_debug "Slots: ${#_sw_pids[@]} running, backfill checking..."
    local i=0
    while [[ $i -lt ${#_sw_pids[@]} ]]; do
      local pid="${_sw_pids[$i]}"
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        local done_task="${_sw_tasks[$i]}"
        _sw_remove_at "$i"

        ralph_log_info "Task completed: $done_task (slot freed, ${#_sw_pids[@]} still running)"
        _sw_handle "$done_task"
        _sw_backfill
        found_done=1
        # 不递增 i，因为数组已重建
      else
        i=$((i + 1))
      fi
    done

    # 如果本轮没有任务完成，休眠后再查
    if [[ $found_done -eq 0 ]]; then
      sleep 3
    fi
  done

  unset -f _sw_launch _sw_handle _sw_remove_at _sw_backfill

  # 清理
  rm -rf "$result_dir"

  # 推送状态到 source
  ralph_push_tasks_to_source 2>/dev/null || ralph_log_warn "Failed to push tasks to source"
}

# ── 主循环 ──

CYCLE_NUM=0

while true; do
  CYCLE_NUM=$((CYCLE_NUM + 1))

  # 0. CHECK — 暂停检测
  if [[ -f "$RALPH_PAUSED_FILE" ]]; then
    ralph_log_info "PAUSED file detected, exiting loop"
    rm -f "$RALPH_PID_FILE"
    exit 0
  fi

  ralph_run_cycle "$CYCLE_NUM"

  # 暂停检测 (cycle 结束时再检查一次)
  if [[ -f "$RALPH_PAUSED_FILE" ]]; then
    ralph_log_info "PAUSED file detected after cycle, exiting"
    rm -f "$RALPH_PID_FILE"
    exit 0
  fi

  sleep 5
done
