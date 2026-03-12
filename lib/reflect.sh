#!/usr/bin/env bash
# Ralph Loop — Reflect+Triage (合并为 1 次 Claude 调用)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/db.sh"

ralph_reflect() {
  local start_time
  start_time="$(date +%s)"

  ralph_log_info "=== REFLECT+TRIAGE phase ==="

  # 收集输入
  local pending_tasks discoveries last_cycle git_status git_log lessons failed_tasks

  pending_tasks="$(ralph_db_list_pending)"
  failed_tasks="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" \
    "SELECT json_group_array(json_object('id',id,'title',title,'source',source,'result',result)) FROM tasks WHERE status='failed' AND created_at >= date('now','-3 days')" 2>/dev/null || echo "[]")"
  discoveries="$(ralph_db_get_unconsumed_discoveries)"
  last_cycle="$(ralph_db_get_last_cycle_log)"
  git_status="$(cd "$RALPH_CWD" && git status --short 2>/dev/null | head -30 || echo "N/A")"
  git_log="$(cd "$RALPH_CWD" && git log --oneline -10 2>/dev/null || echo "N/A")"
  lessons=""
  [[ -f "$RALPH_LESSONS" ]] && lessons="$(cat "$RALPH_LESSONS")"

  # 如果没有 pending 任务且没有 discoveries，直接返回
  if [[ "$pending_tasks" == "[]" && ("$discoveries" == "[]" || -z "$discoveries") ]]; then
    ralph_log_info "No pending tasks or discoveries, nothing to reflect on"
    echo ""
    return 0
  fi

  # 构建 prompt
  local prompt
  prompt="$(cat <<PROMPT
你是 Ralph 的调度器。分析以下信息，决定下一步执行什么任务。

## 当前 Pending 任务
$pending_tasks

## 近期 Failed 任务（含 discovered 衍生任务）
$failed_tasks

## 未消费的 Discoveries
$discoveries

## 上轮执行结果
$last_cycle

## Git 状态
$git_status

## 最近提交
$git_log

## 经验教训
$lessons

---

请输出严格 JSON（不要包含 markdown code block），格式如下:
{
  "analysis": "简短分析当前状况",
  "new_tasks": [
    {"title": "...", "priority": N, "prompt": "...", "model": "claude-sonnet-4-6", "source": "discovered:xxx"}
  ],
  "remove_ids": ["不再需要的任务ID"],
  "next": {
    "task_id": "下一个要执行的任务ID",
    "model": "建议使用的模型",
    "enhanced_prompt": "增强后的 prompt (加入上下文)",
    "plan_first": false
  }
}

规则:
- new_tasks: 从 discoveries 中转化出的新任务
- remove_ids: 已经被解决或不再需要的任务
- next: 从 pending 中选一个最合适的。如果不需要修改，model 和 enhanced_prompt 可为 null
- plan_first: 对于 complex 任务设为 true
- 如果没有可执行任务，next 设为 null
- **重建限制**: 查看 "近期 Failed 任务"，如果同一个 discovery 相关的任务（source 相同或 title 相似）已经失败 2 次以上，不要再创建新任务，在 analysis 中标记为"需要人工处理"
- **严禁换标题重建**: 不要通过修改 title（如加"重新诊断""第N轮""终态修复"等后缀）来绕过重建限制。只要核心问题相同，就算作同一个任务
- **去重**: new_tasks 中不要创建与现有 pending 或 failed 任务 title 相似的重复任务
PROMPT
)"

  # 调用 Claude
  local result
  result="$(claude -p "$prompt" --model "$RALPH_REFLECT_MODEL" --max-turns 1 --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || {
    ralph_log_error "Reflect Claude call failed"
    echo ""
    return 1
  }

  # 尝试提取 JSON (可能被包在 code block 中)
  local json
  json="$(echo "$result" | sed -n '/^{/,/^}/p')"
  if [[ -z "$json" ]]; then
    json="$(echo "$result" | sed -n '/```json/,/```/p' | grep -v '```')"
  fi
  if [[ -z "$json" ]]; then
    json="$(echo "$result" | sed -n '/```/,/```/p' | grep -v '```')"
  fi

  if ! echo "$json" | jq . >/dev/null 2>&1; then
    ralph_log_warn "Failed to parse reflect output as JSON, using first pending task"
    # Fallback: 返回第一个 pending 任务
    local first_task_id
    first_task_id="$(echo "$pending_tasks" | jq -r '.[0].id // empty')"
    if [[ -n "$first_task_id" ]]; then
      echo "{\"next\":{\"task_id\":\"$first_task_id\",\"model\":null,\"enhanced_prompt\":null,\"plan_first\":false},\"new_tasks\":[],\"remove_ids\":[]}"
    else
      echo ""
    fi
    return 0
  fi

  # 处理 new_tasks
  local new_tasks_count
  new_tasks_count="$(echo "$json" | jq '.new_tasks | length')"
  if [[ "$new_tasks_count" -gt 0 ]]; then
    for i in $(seq 0 $((new_tasks_count - 1))); do
      local t_title t_priority t_prompt t_model t_source
      t_title="$(echo "$json" | jq -r ".new_tasks[$i].title")"
      t_priority="$(echo "$json" | jq -r ".new_tasks[$i].priority // 3")"
      t_prompt="$(echo "$json" | jq -r ".new_tasks[$i].prompt")"
      t_model="$(echo "$json" | jq -r ".new_tasks[$i].model // \"$RALPH_DEFAULT_MODEL\"")"
      t_source="$(echo "$json" | jq -r ".new_tasks[$i].source // \"discovered\"")"

      # 检查同源失败次数：提取 title 前缀关键词做模糊匹配，防止换标题绕过去重
      # 例: "phone/bind 路由诊断（第四轮）" → 提取 "phone/bind" 做 LIKE 匹配
      local title_prefix
      title_prefix="$(echo "$t_title" | sed -E 's/[（(].*//' | sed 's/[[:space:]]*$//' | cut -c1-20 | sed "s/'/''/g")"
      local similar_fail_count
      similar_fail_count="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" \
        "SELECT COUNT(*) FROM tasks WHERE status IN ('failed','skipped') AND source LIKE 'discovered%' AND title LIKE '%${title_prefix}%' AND created_at >= date('now','-3 days')" 2>/dev/null || echo "0")"

      if [[ "$similar_fail_count" -ge 2 ]]; then
        ralph_log_warn "Discovery exceeded retry limit ($similar_fail_count failures): $t_title"
        ralph_daily_log "task_abandoned" "-" "$t_title" "同类失败${similar_fail_count}次，需人工处理"
        # 推送到 outbox 让人工接管
        ralph_push_to_outbox_raw "needs_human" "$t_title" \
          "自动修复失败${similar_fail_count}次，需人工介入" "$t_source"
        ralph_notify "needs_human" "-" "$t_title" "自动修复失败${similar_fail_count}次" 2>/dev/null || true
        continue
      fi

      local t_id
      t_id="ralph-$(date '+%m%d')-$(echo "$t_title" | md5sum | cut -c1-6 2>/dev/null || echo "$t_title" | md5 -q | cut -c1-6)"
      ralph_db_add_task "$t_id" "$t_title" "$t_priority" "$t_model" "simple" "$t_prompt" "" "$t_source"
      ralph_log_info "Created discovered task: $t_id — $t_title"
      ralph_daily_log "task_discovered" "$t_id" "$t_title" "source=$t_source"
    done
  fi

  # 处理 remove_ids
  local remove_ids
  remove_ids="$(echo "$json" | jq -r '.remove_ids[]? // empty')"
  if [[ -n "$remove_ids" ]]; then
    while IFS= read -r rid; do
      ralph_db_update_task_status "$rid" "skipped"
      ralph_log_info "Removed task: $rid"
    done <<< "$remove_ids"
  fi

  # 消费 discoveries
  ralph_db_consume_discoveries

  local duration=$(( $(date +%s) - start_time ))
  ralph_log_info "Reflect completed in ${duration}s"

  # 返回 JSON
  echo "$json"
}
