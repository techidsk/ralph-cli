#!/usr/bin/env bash
# Ralph Loop — Git 仓库适配器 (JSONL)
# 依赖: git
#
# 仓库文件职责:
#   inbox.jsonl       — 外部写入（飞书 bot / 手动），Ralph 消费后清空
#   outbox.jsonl      — Ralph 追加任务结果，飞书 bot 消费后清空
#   tasks.jsonl       — Ralph 渲染的全量状态（只读展示）
#   discoveries.jsonl — Ralph 管理的发现列表
#   report.md         — Ralph 生成的晨报
set -euo pipefail

RALPH_REPO_DIR="$RALPH_PROJECT_DIR/inbox-repo"

# ── 内部: 确保本地 clone 存在并拉取最新 ──

_repo_ensure() {
  if [[ ! -d "$RALPH_REPO_DIR/.git" ]]; then
    ralph_log_info "Cloning inbox repo: $RALPH_INBOX_REPO"
    git clone "$RALPH_INBOX_REPO" "$RALPH_REPO_DIR" 2>/dev/null || {
      ralph_log_error "Failed to clone $RALPH_INBOX_REPO"
      return 1
    }
  fi
}

_repo_pull() {
  _repo_ensure || return 1
  cd "$RALPH_REPO_DIR"
  git pull --rebase --quiet 2>/dev/null || {
    ralph_log_warn "Pull failed, resetting to remote"
    git fetch origin && git reset --hard origin/main 2>/dev/null || git reset --hard origin/master 2>/dev/null
  }
  cd - >/dev/null
}

_repo_commit_push() {
  local msg="$1"
  cd "$RALPH_REPO_DIR"
  git add -A
  # 只在有变更时提交
  if git diff --cached --quiet 2>/dev/null; then
    cd - >/dev/null
    return 0
  fi
  git commit -m "$msg" --quiet 2>/dev/null || true
  git push --quiet 2>/dev/null || {
    # push 冲突: pull rebase 后重试一次
    ralph_log_warn "Push conflict, retrying after rebase..."
    git pull --rebase --quiet 2>/dev/null && git push --quiet 2>/dev/null || {
      ralph_log_error "Push failed after retry"
      cd - >/dev/null
      return 1
    }
  }
  cd - >/dev/null
}

# ── inbox: 外部输入 ──

fetch_inbox() {
  _repo_pull || return 1
  if [[ -f "$RALPH_REPO_DIR/inbox.jsonl" ]]; then
    cat "$RALPH_REPO_DIR/inbox.jsonl"
  else
    echo ""
  fi
}

clear_inbox() {
  : > "$RALPH_REPO_DIR/inbox.jsonl"
  _repo_commit_push "ralph: consume inbox" || true
}

# ── tasks: Ralph 管理的全量状态 ──

push_tasks() {
  cat > "$RALPH_REPO_DIR/tasks.jsonl"
  _repo_commit_push "ralph: update tasks" || true
}

# ── outbox: 任务结果追加（飞书 bot 消费） ──

append_outbox() {
  # stdin 追加一行到 outbox.jsonl
  cat >> "$RALPH_REPO_DIR/outbox.jsonl"
  _repo_commit_push "ralph: append outbox" || true
}

# ── discoveries ──

fetch_discoveries() {
  _repo_pull || return 1
  if [[ -f "$RALPH_REPO_DIR/discoveries.jsonl" ]]; then
    cat "$RALPH_REPO_DIR/discoveries.jsonl"
  else
    echo ""
  fi
}

push_discoveries() {
  cat > "$RALPH_REPO_DIR/discoveries.jsonl"
  _repo_commit_push "ralph: update discoveries" || true
}

# ── report ──

push_report() {
  cat > "$RALPH_REPO_DIR/report.md"
  _repo_commit_push "ralph: update report" || true
}
