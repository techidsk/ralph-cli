#!/usr/bin/env bash
# Ralph Loop — 本地文件适配器 (JSONL, 开发调试用)
# 文件存储在 ~/.ralph/local-source/
set -euo pipefail

RALPH_LOCAL_SOURCE_DIR="$RALPH_PROJECT_DIR/local-source"
mkdir -p "$RALPH_LOCAL_SOURCE_DIR"

# ── inbox: 外部输入 ──

fetch_inbox() {
  if [[ -f "$RALPH_LOCAL_SOURCE_DIR/inbox.jsonl" ]]; then
    cat "$RALPH_LOCAL_SOURCE_DIR/inbox.jsonl"
  else
    echo ""
  fi
}

clear_inbox() {
  : > "$RALPH_LOCAL_SOURCE_DIR/inbox.jsonl" 2>/dev/null || true
}

# ── tasks: Ralph 管理的全量状态 ──

push_tasks() {
  cat > "$RALPH_LOCAL_SOURCE_DIR/tasks.jsonl"
}

# ── outbox: 任务结果追加 ──

append_outbox() {
  cat >> "$RALPH_LOCAL_SOURCE_DIR/outbox.jsonl"
}

# ── discoveries ──

fetch_discoveries() {
  if [[ -f "$RALPH_LOCAL_SOURCE_DIR/discoveries.jsonl" ]]; then
    cat "$RALPH_LOCAL_SOURCE_DIR/discoveries.jsonl"
  else
    echo ""
  fi
}

push_discoveries() {
  cat > "$RALPH_LOCAL_SOURCE_DIR/discoveries.jsonl"
}

# ── report ──

push_report() {
  cat > "$RALPH_LOCAL_SOURCE_DIR/report.md"
}
