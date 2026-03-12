#!/usr/bin/env bash
# Ralph Loop — Webhook 通知（飞书富文本格式）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/log.sh"

# ralph_notify <event> <task_id> <title> [detail]
#
# event: task_started | task_done | task_failed | report | service_started | service_stopped
#
# 飞书 富文本(post) 格式:
# {"msg_type":"post","content":{"post":{"zh_cn":{"title":"...","content":[[...]]}}}}

ralph_notify() {
  local event="$1"
  local task_id="${2:-}"
  local title="${3:-}"
  local detail="${4:-}"

  # 未配置 webhook 则跳过
  if [[ -z "${RALPH_WEBHOOK_URL:-}" ]]; then
    return 0
  fi

  # 事件过滤
  if [[ "${RALPH_NOTIFY_EVENTS:-all}" != "all" ]]; then
    if ! echo ",$RALPH_NOTIFY_EVENTS," | grep -q ",$event,"; then
      ralph_log_debug "Webhook skipped (event '$event' not in RALPH_NOTIFY_EVENTS)"
      return 0
    fi
  fi

  local timestamp
  timestamp="$(date '+%m-%d %H:%M')"

  local post_title=""
  local content_json=""

  case "$event" in
    task_started)
      post_title="🚀 任务开始执行"
      content_json="$(jq -nc --arg title "$title" --arg id "$task_id" --arg ts "$timestamp" --arg detail "$detail" '
        [
          [{tag:"text",text:"任务: "},{tag:"text",text:($title + "\n")}],
          [{tag:"text",text:"ID: "},{tag:"text",text:($id + "\n")}],
          [{tag:"text",text:"时间: "},{tag:"text",text:($ts + "\n")}],
          [{tag:"text",text:$detail}]
        ]
      ')"
      ;;
    task_done)
      post_title="✅ 任务完成"
      content_json="$(jq -nc --arg title "$title" --arg id "$task_id" --arg ts "$timestamp" --arg detail "$detail" '
        [
          [{tag:"text",text:"任务: "},{tag:"text",text:($title + "\n")}],
          [{tag:"text",text:"ID: "},{tag:"text",text:($id + "\n")}],
          [{tag:"text",text:"时间: "},{tag:"text",text:($ts + "\n")}]
        ] + (if $detail != "" then [[{tag:"text",text:"详情: "},{tag:"text",text:$detail}]] else [] end)
      ')"
      ;;
    task_failed)
      post_title="❌ 任务失败"
      content_json="$(jq -nc --arg title "$title" --arg id "$task_id" --arg ts "$timestamp" --arg detail "$detail" '
        [
          [{tag:"text",text:"任务: "},{tag:"text",text:($title + "\n")}],
          [{tag:"text",text:"ID: "},{tag:"text",text:($id + "\n")}],
          [{tag:"text",text:"时间: "},{tag:"text",text:($ts + "\n")}]
        ] + (if $detail != "" then [[{tag:"text",text:"原因: "},{tag:"text",text:$detail}]] else [] end)
      ')"
      ;;
    report)
      post_title="📋 Ralph 晨报"
      content_json="$(jq -nc --arg ts "$timestamp" --arg detail "$detail" '
        [
          [{tag:"text",text:"日期: "},{tag:"text",text:($ts + "\n")}],
          [{tag:"text",text:$detail}]
        ]
      ')"
      ;;
    service_started)
      post_title="🟢 Ralph 已启动"
      content_json="$(jq -nc --arg ts "$timestamp" --arg project "${RALPH_PROJECT:-unknown}" --arg detail "$detail" '
        [
          [{tag:"text",text:"项目: "},{tag:"text",text:($project + "\n")}],
          [{tag:"text",text:"时间: "},{tag:"text",text:($ts + "\n")}]
        ] + (if $detail != "" then [[{tag:"text",text:$detail}]] else [] end)
      ')"
      ;;
    service_stopped)
      post_title="🔴 Ralph 已停止"
      content_json="$(jq -nc --arg ts "$timestamp" --arg project "${RALPH_PROJECT:-unknown}" --arg detail "$detail" '
        [
          [{tag:"text",text:"项目: "},{tag:"text",text:($project + "\n")}],
          [{tag:"text",text:"时间: "},{tag:"text",text:($ts + "\n")}]
        ] + (if $detail != "" then [[{tag:"text",text:"原因: "},{tag:"text",text:$detail}]] else [] end)
      ')"
      ;;
    needs_human)
      post_title="⚠️ 需要人工处理"
      content_json="$(jq -nc --arg title "$title" --arg ts "$timestamp" --arg detail "$detail" '
        [
          [{tag:"text",text:"问题: "},{tag:"text",text:($title + "\n")}],
          [{tag:"text",text:"时间: "},{tag:"text",text:($ts + "\n")}],
          [{tag:"text",text:"说明: "},{tag:"text",text:($detail + "\n")}],
          [{tag:"text",text:"Ralph 自动修复多次失败，请人工介入"}]
        ]
      ')"
      ;;
    *)
      post_title="Ralph 通知"
      content_json="$(jq -nc --arg event "$event" --arg id "$task_id" --arg title "$title" '
        [[{tag:"text",text:"[\($event)] \($id): \($title)"}]]
      ')"
      ;;
  esac

  # 构建飞书富文本 payload
  local payload
  payload="$(jq -nc --arg pt "$post_title" --argjson content "$content_json" '
    {
      msg_type: "post",
      content: {
        post: {
          zh_cn: {
            title: $pt,
            content: $content
          }
        }
      }
    }
  ')"

  # 异步发送，不阻塞主循环；失败时记录到日志
  (local http_code
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$RALPH_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 10 2>&1)" || true
  if [[ "$http_code" != "200" && "$http_code" != "000" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Webhook response: $http_code for event=$event" >> "${RALPH_LOG:-/dev/null}"
  fi) &

  ralph_log_info "Webhook sent: $event — $task_id"
}
