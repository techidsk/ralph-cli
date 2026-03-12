#!/usr/bin/env bash
# Ralph CLI — 配置常量与环境变量（多项目支持）
set -euo pipefail

RALPH_HOME="${RALPH_HOME:-$HOME/.ralph}"

# ── YAML 解析 ──

# 解析 YAML 扁平配置文件 (key: value)
# 环境变量优先，已有值不覆盖
_ralph_load_yaml() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.+)$ ]]; then
      _key="${BASH_REMATCH[1]}" _val="${BASH_REMATCH[2]}"
      _val="${_val%%#*}"
      _val="${_val%"${_val##*[![:space:]]}"}"
      _val="${_val#\"}" && _val="${_val%\"}"
      _val="${_val#\'}" && _val="${_val%\'}"
      if [[ -z "${!_key:-}" ]]; then
        export "$_key=$_val"
      fi
    fi
  done < "$file"
  unset _key _val 2>/dev/null || true
}

# 解析项目端 .ralph.yaml (key: value，映射到 RALPH_ 前缀变量)
# 支持嵌套结构的简易解析 (只支持一层)
_ralph_load_project_yaml() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local current_section=""
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # 顶级 key (无缩进)
    if [[ "$line" =~ ^([a-z_][a-z0-9_]*):[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
      val="${val%%#*}"
      val="${val%"${val##*[![:space:]]}"}"
      val="${val#\"}" && val="${val%\"}"
      val="${val#\'}" && val="${val%\'}"

      if [[ -z "$val" ]]; then
        # Section header (e.g., "verify:", "changeset:")
        current_section="$key"
        continue
      fi

      # Top-level scalar
      case "$key" in
        project)
          [[ -z "${RALPH_PROJECT:-}" ]] && RALPH_PROJECT="$val" ;;
        source)
          [[ -z "${RALPH_SOURCE:-}" ]] && RALPH_SOURCE="$val" ;;
        inbox_repo)
          [[ -z "${RALPH_INBOX_REPO:-}" ]] && RALPH_INBOX_REPO="$val" ;;
        webhook_url)
          [[ -z "${RALPH_WEBHOOK_URL:-}" ]] && RALPH_WEBHOOK_URL="$val" ;;
        default_model)
          [[ -z "${RALPH_DEFAULT_MODEL:-}" ]] && RALPH_DEFAULT_MODEL="$val" ;;
        merge_target)
          [[ -z "${RALPH_MERGE_TARGET:-}" ]] && RALPH_MERGE_TARGET="$val" ;;
        skip_hooks)
          [[ -z "${RALPH_SKIP_HOOKS:-}" ]] && RALPH_SKIP_HOOKS="$val" ;;
        notify_events)
          [[ -z "${RALPH_NOTIFY_EVENTS:-}" ]] && RALPH_NOTIFY_EVENTS="$val" ;;
      esac
      current_section=""

    # 缩进 key (section 内)
    elif [[ "$line" =~ ^[[:space:]]+([a-z_][a-z0-9_]*):[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
      val="${val%%#*}"
      val="${val%"${val##*[![:space:]]}"}"
      val="${val#\"}" && val="${val%\"}"
      val="${val#\'}" && val="${val%\'}"

      case "${current_section}_${key}" in
        verify_symlink_node_modules)
          [[ -z "${RALPH_VERIFY_SYMLINK_NODE_MODULES:-}" ]] && RALPH_VERIFY_SYMLINK_NODE_MODULES="$val" ;;
        verify_commands)
          # 不在这里处理列表 — 用下面的 list item 解析
          ;;
        changeset_enabled)
          [[ -z "${RALPH_CHANGESET_ENABLED:-}" ]] && RALPH_CHANGESET_ENABLED="$val" ;;
        changeset_package)
          [[ -z "${RALPH_CHANGESET_PACKAGE:-}" ]] && RALPH_CHANGESET_PACKAGE="$val" ;;
      esac

    # YAML list item (  - value)
    elif [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.+)$ ]]; then
      local val="${BASH_REMATCH[1]}"
      val="${val%%#*}"
      val="${val%"${val##*[![:space:]]}"}"

      case "$current_section" in
        verify)
          # 追加到 RALPH_VERIFY_COMMANDS (pipe-separated)
          # 只在首次加载时设置（防止多次 source 导致重复）
          if [[ -z "${_RALPH_VERIFY_COMMANDS_LOADED:-}" ]]; then
            if [[ -z "${RALPH_VERIFY_COMMANDS:-}" ]]; then
              RALPH_VERIFY_COMMANDS="$val"
            else
              RALPH_VERIFY_COMMANDS="${RALPH_VERIFY_COMMANDS}|${val}"
            fi
          fi
          ;;
      esac
    fi
  done < "$file"
  _RALPH_VERIFY_COMMANDS_LOADED=1
}

# ── 加载顺序 ──
# 1. 环境变量（最高优先级）
# 2. ~/.ralph/config.yaml（全局配置）
# 3. 项目默认配置 (config.yaml.example)
_ralph_load_yaml "$RALPH_HOME/config.yaml"
_ralph_load_yaml "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.yaml"

# ── 项目识别 ──

# 定位 ralph-db
_ralph_find_db_bin() {
  if [[ -x "$RALPH_HOME/bin/ralph-db" ]]; then
    echo "$RALPH_HOME/bin/ralph-db"
  elif [[ -x "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/ralph-db" ]]; then
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/ralph-db"
  else
    echo ""
  fi
}

RALPH_CWD="${RALPH_CWD:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# 加载项目端 .ralph.yaml (在 resolve-project 之前，因为它可能定义 project)
_ralph_load_project_yaml "$RALPH_CWD/.ralph.yaml"

# 项目 slug 解析
if [[ -z "${RALPH_PROJECT:-}" ]]; then
  local_db_bin="$(_ralph_find_db_bin)"
  if [[ -n "$local_db_bin" ]]; then
    RALPH_PROJECT="$("$local_db_bin" resolve-project "$RALPH_CWD" 2>/dev/null)" || RALPH_PROJECT="default"
  else
    RALPH_PROJECT="default"
  fi
fi
export RALPH_PROJECT

# ── 数据目录（项目隔离） ──

RALPH_PROJECT_DIR="$RALPH_HOME/projects/$RALPH_PROJECT"
RALPH_DB="$RALPH_PROJECT_DIR/ralph.db"
RALPH_LOG="${RALPH_LOG:-$RALPH_PROJECT_DIR/ralph.log}"
RALPH_CONTEXT_BRIEF="$RALPH_PROJECT_DIR/context-brief.md"
RALPH_LESSONS="$RALPH_PROJECT_DIR/lessons.md"
RALPH_DISCOVERIES="$RALPH_PROJECT_DIR/discoveries.md"
RALPH_PAUSED_FILE="$RALPH_PROJECT_DIR/PAUSED"
RALPH_PID_FILE="$RALPH_PROJECT_DIR/ralph.pid"
RALPH_DAILY_LOG_DIR="$RALPH_PROJECT_DIR/logs"

# ── 全局配置 (可被 .ralph.yaml 覆盖) ──

RALPH_SOURCE="${RALPH_SOURCE:-repo}"
RALPH_INBOX_REPO="${RALPH_INBOX_REPO:-}"
RALPH_POLL_INTERVAL="${RALPH_POLL_INTERVAL:-300}"

# 模型
RALPH_DEFAULT_MODEL="${RALPH_DEFAULT_MODEL:-claude-sonnet-4-6}"
RALPH_REFLECT_MODEL="${RALPH_REFLECT_MODEL:-claude-sonnet-4-6}"

# 执行限制
RALPH_MAX_TURNS_SIMPLE="${RALPH_MAX_TURNS_SIMPLE:-35}"
RALPH_MAX_TURNS_COMPLEX="${RALPH_MAX_TURNS_COMPLEX:-55}"
RALPH_MAX_CONCURRENT="${RALPH_MAX_CONCURRENT:-3}"
RALPH_CONTEXT_BRIEF_MAX=10
RALPH_LESSONS_MAX=30

# Webhook
RALPH_WEBHOOK_URL="${RALPH_WEBHOOK_URL:-}"
RALPH_NOTIFY_EVENTS="${RALPH_NOTIFY_EVENTS:-all}"

# Verbose / Debug
RALPH_VERBOSE="${RALPH_VERBOSE:-false}"

# 项目特有配置 (从 .ralph.yaml 加载)
RALPH_MERGE_TARGET="${RALPH_MERGE_TARGET:-main}"
RALPH_SKIP_HOOKS="${RALPH_SKIP_HOOKS:-true}"
RALPH_CHANGESET_ENABLED="${RALPH_CHANGESET_ENABLED:-false}"
RALPH_CHANGESET_PACKAGE="${RALPH_CHANGESET_PACKAGE:-}"
RALPH_VERIFY_COMMANDS="${RALPH_VERIFY_COMMANDS:-}"
RALPH_VERIFY_SYMLINK_NODE_MODULES="${RALPH_VERIFY_SYMLINK_NODE_MODULES:-true}"

# ── 确保项目目录存在 ──
mkdir -p "$RALPH_PROJECT_DIR"
