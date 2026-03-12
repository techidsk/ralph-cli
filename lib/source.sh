#!/usr/bin/env bash
# Ralph Loop — 任务源适配层 (JSONL 格式)
# 根据 RALPH_SOURCE 环境变量加载对应适配器
#
# 数据流:
#   inbox.jsonl  — 外部只写（飞书 bot / 手动），Ralph 消费后清空
#   tasks.jsonl  — Ralph 渲染的全量状态（只读展示）
#   discoveries.jsonl — Ralph 管理
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/db.sh"

# 加载适配器实现
case "$RALPH_SOURCE" in
  repo)
    source "$SCRIPT_DIR/source-repo.sh"
    ;;
  local)
    source "$SCRIPT_DIR/source-local.sh"
    ;;
  *)
    ralph_log_error "Unknown RALPH_SOURCE: $RALPH_SOURCE (supported: repo, local)"
    exit 1
    ;;
esac

# ── inbox.jsonl 消费 → SQLite ──
#
# inbox 中每行一个 JSON（无 id 字段），Ralph 消费后清空 inbox
# 示例: {"title":"修复拖拽偏移","priority":1,"prompt":"...","files":"src/..."}
#
# 去重策略: ID = ralph-MMDD-<title+prompt 的 hash 前 6 位>
# 竞态保护: 先清空 inbox 再导入（宁可重复消费也不丢数据）

ralph_consume_inbox() {
  ralph_log_info "Checking inbox ($RALPH_SOURCE)..."
  local content
  content="$(fetch_inbox)" || { ralph_log_warn "Failed to fetch inbox"; return 1; }

  if [[ -z "$content" || "$content" =~ ^[[:space:]]*$ ]]; then
    ralph_log_info "Inbox empty"
    return 0
  fi

  # 用 content hash 判断 inbox 是否已消费过（防止远程清空失败时重复导入）
  local inbox_hash
  inbox_hash="$(echo "$content" | md5 -q 2>/dev/null || echo "$content" | md5sum | cut -c1-32)"
  local hash_file="${RALPH_PROJECT_DIR:-.}/.inbox-consumed-hash"
  if [[ -f "$hash_file" ]] && [[ "$(cat "$hash_file")" == "$inbox_hash" ]]; then
    ralph_log_info "Inbox already consumed (same content hash), skipping"
    return 0
  fi
  ralph_log_debug "Inbox hash: $inbox_hash (stored: $(cat "$hash_file" 2>/dev/null || echo 'none'))"

  # 先清空 inbox，防止竞态丢数据
  clear_inbox

  local imported=0

  while IFS= read -r line; do
    # 跳过空行
    [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]] && continue
    # 验证是合法 JSON
    echo "$line" | jq . >/dev/null 2>&1 || { ralph_log_warn "Skipping invalid JSON line"; continue; }

    # 解析字段
    local title prompt priority complexity files
    title="$(echo "$line" | jq -r '.title // empty')"
    prompt="$(echo "$line" | jq -r '.prompt // empty')"

    if [[ -z "$title" || -z "$prompt" ]]; then
      ralph_log_warn "Skipping task without title or prompt"
      continue
    fi

    priority="$(echo "$line" | jq -r '.priority // 3')"
    complexity="$(echo "$line" | jq -r '.complexity // "simple"')"
    files="$(echo "$line" | jq -r '.files // empty')"

    # ID: 优先使用 source_id（飞书 bot 闭环匹配），其次 id，否则自动生成
    local id
    id="$(echo "$line" | jq -r '.source_id // .id // empty')"
    if [[ -z "$id" ]]; then
      local hash6
      hash6="$(echo "${title}${prompt}" | md5 -q 2>/dev/null || echo "${title}${prompt}" | md5sum | cut -c1-6)"
      id="ralph-$(date '+%m%d')-${hash6:0:6}"
    fi

    # 去重: 只跳过 pending/running 的同 ID 任务
    # 已完成/失败的任务允许用新 ID 重新提交
    local active_count
    active_count="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" "SELECT COUNT(*) FROM tasks WHERE id='$id' AND status IN ('pending','running')" 2>/dev/null || echo "0")"
    if [[ "$active_count" != "0" ]]; then
      ralph_log_info "Skipping duplicate (active): $id — $title"
      continue
    fi

    # 如果存在同 ID 的已完成任务，加后缀区分
    local exists
    exists="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" "SELECT COUNT(*) FROM tasks WHERE id='$id'" 2>/dev/null || echo "0")"
    if [[ "$exists" != "0" ]]; then
      local suffix=1
      while true; do
        local new_id="${id}-${suffix}"
        exists="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" "SELECT COUNT(*) FROM tasks WHERE id='$new_id'" 2>/dev/null || echo "0")"
        if [[ "$exists" == "0" ]]; then
          id="$new_id"
          break
        fi
        suffix=$((suffix + 1))
      done
    fi

    ralph_db_add_task "$id" "$title" "$priority" "$RALPH_DEFAULT_MODEL" "$complexity" "$prompt" "$files" "inbox"
    ralph_log_debug "Inbox item: $id — $title"
    ralph_log_info "Imported from inbox: $id — $title"
    imported=$((imported + 1))
  done <<< "$content"

  ralph_log_info "Inbox consumed ($imported new tasks imported)"

  # 记录已消费的 inbox hash，防止远程清空失败时下轮重复导入
  echo "$inbox_hash" > "$hash_file"
}

# ── SQLite → tasks.jsonl 渲染 ──

ralph_render_tasks_jsonl() {
  # 输出所有任务，每行一个 JSON
  "$RALPH_DB_BIN" list-all "$RALPH_PROJECT" 2>/dev/null | jq -c '.[]' 2>/dev/null || true
}

# ── 推送状态到 source (tasks.jsonl 只读展示) ──

ralph_push_tasks_to_source() {
  ralph_log_info "Pushing tasks to source..."
  ralph_render_tasks_jsonl | push_tasks
}

# ── outbox: 任务结果回传（飞书 bot 消费） ──
#
# 每完成/失败一个任务追加一条 JSON 到 outbox.jsonl
# 飞书 bot 读取后清空，完成闭环
#
# 格式:
# {"id":"ralph-0310-a1b2c3","title":"...","status":"done","result":"...","checkpoint":"ralph/cp-0310-001","completed_at":"2026-03-10T23:05"}
# {"id":"ralph-0310-b2c3d4","title":"...","status":"failed","result":"Type-check failed","completed_at":"2026-03-10T23:15"}

ralph_push_to_outbox() {
  local task_id="$1" status="$2" result="$3" checkpoint="${4:-}"

  # 只推送用户提交的任务（inbox/manual），discovered 衍生任务不回传
  local task_source
  task_source="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" \
    "SELECT source FROM tasks WHERE id='$task_id'" 2>/dev/null || echo "")"
  if [[ "$task_source" != "inbox" && "$task_source" != "manual" ]]; then
    ralph_log_info "Skip outbox for non-user task: $task_id (source=$task_source)"
    return 0
  fi

  # 统一精简格式，只含 bot 需要的字段
  local task_title
  task_title="$("$RALPH_DB_BIN" query "$RALPH_PROJECT" \
    "SELECT title FROM tasks WHERE id='$task_id'" 2>/dev/null || echo "$task_id")"

  local outbox_entry
  outbox_entry="$(jq -nc \
    --arg id "$task_id" --arg title "$task_title" \
    --arg status "$status" --arg result "$result" \
    --arg cp "$checkpoint" --arg at "$(date '+%Y-%m-%dT%H:%M')" \
    '{id:$id, title:$title, status:$status, result:$result, checkpoint:$cp, completed_at:$at}')"

  ralph_log_info "Pushing to outbox: $task_id ($status)"
  echo "$outbox_entry" | append_outbox || ralph_log_warn "Failed to push to outbox"
}

# 直通版 outbox 推送（不做 source 过滤），用于 needs_human 等系统事件
# ralph_push_to_outbox_raw <status> <title> <result> [source]
ralph_push_to_outbox_raw() {
  local status="$1" title="$2" result="$3" source="${4:-}"

  local outbox_entry
  outbox_entry="$(jq -nc \
    --arg title "$title" --arg status "$status" \
    --arg result "$result" --arg source "$source" \
    --arg at "$(date '+%Y-%m-%dT%H:%M')" \
    '{id:"", title:$title, status:$status, result:$result, source:$source, completed_at:$at}')"

  ralph_log_info "Pushing to outbox (raw): $status — $title"
  echo "$outbox_entry" | append_outbox || ralph_log_warn "Failed to push to outbox"
}

# ── Discoveries 同步 ──

ralph_sync_discoveries_from_source() {
  local content
  content="$(fetch_discoveries)" || return 0

  [[ -z "$content" ]] && return 0

  local consumed=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq . >/dev/null 2>&1 || continue

    local desc source_task severity
    desc="$(echo "$line" | jq -r '.description // empty')"
    [[ -z "$desc" ]] && continue

    source_task="$(echo "$line" | jq -r '.source_task // "unknown"')"
    severity="$(echo "$line" | jq -r '.severity // "medium"')"

    ralph_db_add_discovery "$source_task" "$desc" "$severity"
    consumed=$((consumed + 1))
  done <<< "$content"

  # 清空远程 discoveries
  if [[ $consumed -gt 0 ]]; then
    echo "" | push_discoveries
    ralph_log_info "Consumed $consumed discoveries from source"
  fi
}

ralph_consume_discoveries_file() {
  # 消费本地 discoveries 文件 (Claude 执行时写入的)
  if [[ ! -f "$RALPH_DISCOVERIES" ]]; then return 0; fi

  local content
  content="$(cat "$RALPH_DISCOVERIES")"
  [[ -z "$content" ]] && return 0

  local consumed=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq . >/dev/null 2>&1 || continue

    local desc source_task severity
    desc="$(echo "$line" | jq -r '.description // empty')"
    [[ -z "$desc" ]] && continue

    source_task="$(echo "$line" | jq -r '.source_task // "runtime"')"
    severity="$(echo "$line" | jq -r '.severity // "medium"')"

    ralph_db_add_discovery "$source_task" "$desc" "$severity"
    consumed=$((consumed + 1))
  done <<< "$content"

  if [[ $consumed -gt 0 ]]; then
    : > "$RALPH_DISCOVERIES"
    ralph_log_info "Consumed $consumed local discoveries"
  fi
}
