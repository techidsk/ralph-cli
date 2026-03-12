#!/usr/bin/env bash
# Ralph v2 — 安装脚本
# 将 Ralph CLI 安装到 ~/.ralph/ 并创建 symlink
set -euo pipefail

RALPH_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_HOME="${RALPH_HOME:-$HOME/.ralph}"
INSTALL_LOG="$RALPH_HOME/install.log"

# ── 日志 ──

_log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local msg="[$ts] [$level] $*"
  echo "$msg" >> "$INSTALL_LOG"
  echo "$msg"
}

_log_info()  { _log INFO  "$@"; }
_log_warn()  { _log WARN  "$@"; }
_log_error() { _log ERROR "$@"; }

_log_section() {
  local title="$1"
  _log INFO "────────── $title ──────────"
}

# ── 安装 ──

echo ""
echo "╔══════════════════════════════════════╗"
echo "║       Ralph v${RALPH_VERSION} 安装程序        ║"
echo "╚══════════════════════════════════════╝"
echo ""

# 创建根目录 + 日志
mkdir -p "$RALPH_HOME"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] ========== 安装开始 (v${RALPH_VERSION}) ==========" >> "$INSTALL_LOG"
_log_info "安装源: $SCRIPT_DIR"
_log_info "安装目标: $RALPH_HOME"

# 检查是否有旧进程在跑
_log_section "检查运行状态"
for pid_file in "$RALPH_HOME"/projects/*/ralph.pid "$RALPH_HOME/ralph.pid"; do
  [[ -f "$pid_file" ]] || continue
  local_pid="$(cat "$pid_file" 2>/dev/null)" || continue
  if kill -0 "$local_pid" 2>/dev/null; then
    _log_warn "检测到运行中的 Ralph 进程 (PID: $local_pid, 来自 $pid_file)"
    _log_warn "建议先执行 'ralph stop' 再安装，否则热更新可能导致行为不一致"
  fi
done

# 创建目录结构
_log_section "创建目录结构"
for dir in bin lib templates projects; do
  mkdir -p "$RALPH_HOME/$dir"
  _log_info "  目录: $RALPH_HOME/$dir/"
done

# 安装 ralph-db (Python 数据层)
_log_section "安装可执行文件"

cp "$SCRIPT_DIR/bin/ralph-db" "$RALPH_HOME/bin/ralph-db"
chmod +x "$RALPH_HOME/bin/ralph-db"
_log_info "  ralph-db → $RALPH_HOME/bin/ralph-db"

# 验证 Python 可用
if python3 -c "import sqlite3, json, argparse" 2>/dev/null; then
  _log_info "  Python3 依赖检查: 通过 (sqlite3, json, argparse)"
else
  _log_error "  Python3 缺少必要模块，ralph-db 可能无法运行"
fi

# 安装 ralph CLI
cp "$SCRIPT_DIR/ralph.sh" "$RALPH_HOME/bin/ralph"
chmod +x "$RALPH_HOME/bin/ralph"
_log_info "  ralph   → $RALPH_HOME/bin/ralph"

# 安装 loop.sh
cp "$SCRIPT_DIR/loop.sh" "$RALPH_HOME/loop.sh"
_log_info "  loop.sh → $RALPH_HOME/loop.sh"

# 安装 lib/ 模块
_log_section "安装 lib 模块"
lib_count=0
for f in "$SCRIPT_DIR"/lib/*.sh; do
  [[ -f "$f" ]] || continue
  local_name="$(basename "$f")"
  cp "$f" "$RALPH_HOME/lib/$local_name"
  _log_info "  lib/$local_name"
  lib_count=$((lib_count + 1))
done
_log_info "  共 $lib_count 个模块"

# 安装配置和模板
_log_section "安装配置与模板"

if [[ ! -f "$RALPH_HOME/config.yaml" ]]; then
  cp "$SCRIPT_DIR/config.yaml.example" "$RALPH_HOME/config.yaml"
  _log_info "  config.yaml (全局配置，首次安装)"
else
  _log_info "  config.yaml 已存在，保留用户配置"
  # 但保存一份最新版本供参考
  cp "$SCRIPT_DIR/config.yaml.example" "$RALPH_HOME/config.yaml.default"
  _log_info "  config.yaml.default (最新默认配置，供参考)"
fi

cp "$SCRIPT_DIR/templates/"* "$RALPH_HOME/templates/" 2>/dev/null || true
_log_info "  templates/ (含 ralph.yaml.sample)"

# 记录版本
echo "$RALPH_VERSION" > "$RALPH_HOME/.version"
_log_info "  版本号: $RALPH_VERSION"

# 创建 symlink 到 PATH
_log_section "创建 PATH symlink"
LOCAL_BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
mkdir -p "$LOCAL_BIN"

for cmd in ralph ralph-db; do
  target="$RALPH_HOME/bin/$cmd"
  link="$LOCAL_BIN/$cmd"
  # 清理旧链接或文件
  if [[ -L "$link" || -f "$link" ]]; then
    rm -f "$link"
  fi
  ln -sf "$target" "$link"
  _log_info "  $link → $target"
done

# ── 安装后自检 ──

_log_section "安装自检"
errors=0

# 检查 ralph-db 可执行
if "$RALPH_HOME/bin/ralph-db" --help >/dev/null 2>&1; then
  _log_info "  ralph-db --help: 通过"
else
  _log_error "  ralph-db --help: 失败"
  errors=$((errors + 1))
fi

# 检查 ralph CLI 路径解析
if bash "$RALPH_HOME/bin/ralph" help >/dev/null 2>&1; then
  _log_info "  ralph help: 通过"
else
  _log_error "  ralph help: 失败 — 路径解析可能有问题"
  errors=$((errors + 1))
fi

# 检查 PATH
if echo "$PATH" | tr ':' '\n' | grep -qF "$LOCAL_BIN"; then
  _log_info "  PATH 包含 $LOCAL_BIN: 通过"
  # 进一步检查 symlink 能否被 shell 解析
  if command -v ralph >/dev/null 2>&1; then
    _log_info "  command -v ralph: 通过 ($(command -v ralph))"
  else
    _log_warn "  command -v ralph: 未找到 — 可能需要重启 shell (exec \$SHELL)"
  fi
else
  _log_warn "  $LOCAL_BIN 不在 PATH 中"
  errors=$((errors + 1))
fi

# 检查 jq
if command -v jq >/dev/null 2>&1; then
  _log_info "  jq: 通过 ($(jq --version 2>/dev/null || echo 'unknown'))"
else
  _log_error "  jq: 未安装 — Ralph 运行时依赖 jq"
  errors=$((errors + 1))
fi

# 检查 claude CLI
if command -v claude >/dev/null 2>&1; then
  _log_info "  claude CLI: 通过"
else
  _log_warn "  claude CLI: 未找到 — Ralph 执行任务时需要 claude 命令"
fi

# ── 结果 ──

_log_section "安装完成"
_log_info "安装日志: $INSTALL_LOG"

echo ""
if [[ $errors -gt 0 ]]; then
  echo "⚠️  安装完成，但有 $errors 个问题需要处理（见上方日志）"
else
  echo "✅ 安装成功"
fi

echo ""
echo "目录结构:"
echo "  $RALPH_HOME/"
echo "  ├── bin/ralph        CLI 入口"
echo "  ├── bin/ralph-db     数据层 (Python)"
echo "  ├── lib/             Bash 模块 ($lib_count 个)"
echo "  ├── loop.sh          主循环"
echo "  ├── config.yaml      全局配置"
echo "  ├── projects/        项目数据 (每项目独立)"
echo "  └── templates/       配置模板"
echo ""

# PATH 提示
if ! echo "$PATH" | tr ':' '\n' | grep -qF "$LOCAL_BIN"; then
  echo "📌 请将以下内容添加到 ~/.zshrc (或 ~/.bashrc):"
  echo ""
  echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
  echo "   然后执行: source ~/.zshrc"
  echo ""
fi

echo "快速开始:"
echo "  cd /path/to/your-project"
echo "  ralph init            # 初始化项目"
echo "  ralph add --title ... # 添加任务"
echo "  ralph start           # 启动执行"
echo ""
echo "升级:"
echo "  cd $(dirname "$SCRIPT_DIR")/ralph-cli  # 或 clone 所在目录"
echo "  git pull && bash install.sh"
