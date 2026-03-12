#!/usr/bin/env bash
# Ralph Loop — GitHub Gist 适配器 (JSONL)
# 依赖: gh CLI
#
# Gist 文件职责:
#   inbox.jsonl       — 外部写入（飞书 bot / 手动），Ralph 消费后清空
#   outbox.jsonl      — Ralph 追加任务结果，飞书 bot 消费后清空
#   tasks.jsonl       — Ralph 渲染的全量状态（只读展示）
#   discoveries.jsonl — Ralph 管理的发现列表
#   report.md         — Ralph 生成的晨报
set -euo pipefail

# ── inbox: 外部输入 ──

fetch_inbox() {
  gh gist view "$RALPH_GIST_ID" -f inbox.jsonl 2>/dev/null || echo ""
}

clear_inbox() {
  local tmp="/tmp/ralph-inbox-$$.jsonl"
  echo "" > "$tmp"
  gh gist edit "$RALPH_GIST_ID" -f inbox.jsonl "$tmp" 2>/dev/null || true
  rm -f "$tmp"
}

# ── tasks: Ralph 管理的全量状态 ──

push_tasks() {
  local tmp="/tmp/ralph-tasks-$$.jsonl"
  cat > "$tmp"
  gh gist edit "$RALPH_GIST_ID" -f tasks.jsonl "$tmp"
  rm -f "$tmp"
}

# ── outbox: 任务结果追加 ──

append_outbox() {
  # Gist 没有 append，需要先读再拼接
  local existing
  existing="$(gh gist view "$RALPH_GIST_ID" -f outbox.jsonl 2>/dev/null || echo "")"
  local tmp="/tmp/ralph-outbox-$$.jsonl"
  { echo "$existing"; cat; } | sed '/^$/d' > "$tmp"
  gh gist edit "$RALPH_GIST_ID" -f outbox.jsonl "$tmp" 2>/dev/null || true
  rm -f "$tmp"
}

# ── discoveries ──

fetch_discoveries() {
  gh gist view "$RALPH_GIST_ID" -f discoveries.jsonl 2>/dev/null || echo ""
}

push_discoveries() {
  local tmp="/tmp/ralph-disc-$$.jsonl"
  cat > "$tmp"
  gh gist edit "$RALPH_GIST_ID" -f discoveries.jsonl "$tmp"
  rm -f "$tmp"
}

# ── report ──

push_report() {
  local tmp="/tmp/ralph-report-$$.md"
  cat > "$tmp"
  gh gist edit "$RALPH_GIST_ID" -f report.md "$tmp"
  rm -f "$tmp"
}
