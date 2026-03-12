#!/usr/bin/env bash
# Ralph CLI — 主入口（多项目支持）
set -euo pipefail

# ── 路径解析 ──
# 支持三种调用方式：
#   1. 源码树直接调用:  bash ralph.sh
#   2. 安装后直接调用:  bash ~/.ralph/bin/ralph
#   3. symlink 调用:    ralph (→ ~/.local/bin/ralph → ~/.ralph/bin/ralph)
_RALPH_SOURCE="${BASH_SOURCE[0]}"
# resolve symlink chain
while [[ -L "$_RALPH_SOURCE" ]]; do
  _RALPH_DIR="$(cd "$(dirname "$_RALPH_SOURCE")" && pwd)"
  _RALPH_SOURCE="$(readlink "$_RALPH_SOURCE")"
  # 处理相对路径 symlink
  [[ "$_RALPH_SOURCE" != /* ]] && _RALPH_SOURCE="$_RALPH_DIR/$_RALPH_SOURCE"
done
_RALPH_SELF="$(cd "$(dirname "$_RALPH_SOURCE")" && pwd)"

if [[ -d "$_RALPH_SELF/lib" ]]; then
  RALPH_SCRIPT_DIR="$_RALPH_SELF"                     # 源码树
elif [[ -d "$_RALPH_SELF/../lib" ]]; then
  RALPH_SCRIPT_DIR="$(cd "$_RALPH_SELF/.." && pwd)"   # 安装后 (bin/ → ../)
else
  echo "错误: 无法定位 Ralph lib 目录 (搜索路径: $_RALPH_SELF)" >&2
  exit 1
fi

source "$RALPH_SCRIPT_DIR/lib/config.sh"
source "$RALPH_SCRIPT_DIR/lib/log.sh"
source "$RALPH_SCRIPT_DIR/lib/db.sh"

usage() {
  cat <<'EOF'
Ralph Loop — 自动化任务执行系统

用法:
  ralph start            后台启动主循环
  ralph stop             优雅停止（标记暂停）
  ralph restart          重启（stop + start）
  ralph resume           恢复执行
  ralph status           查看当前状态
  ralph log [N]          查看最近 N 行日志（默认 50，-f 实时跟踪）
  ralph add [options]    添加任务
  ralph task <id>        查看任务详情
  ralph task rm <id>     删除任务
  ralph task retry <id>  重新排队失败的任务
  ralph merge [branch]   将 nightly 分支合并到目标分支
  ralph report           手动生成晨报
  ralph config           显示当前生效的配置
  ralph clean            清理孤儿 worktree 和临时文件
  ralph init             初始化当前项目
  ralph projects         列出所有已注册项目
  ralph help             显示此帮助

添加任务选项:
  --title TEXT           任务标题 (必填)
  --prompt TEXT          任务描述/指令 (必填)
  --priority N           优先级 P0-P3，P0 最高 (默认 3)
  --model MODEL          模型 (默认 claude-sonnet-4-6)
  --complexity simple|complex  复杂度 (默认 simple)
  --files FILES          相关文件列表 (逗号分隔)

示例:
  ralph init                     # 初始化当前项目
  ralph add --title "修复拖拽偏移" --prompt "修复 clientX/Y 偏移" --priority 0
  ralph start
  ralph log -f                   # 实时查看日志
  ralph status
  ralph task ralph-0311-001      # 查看任务详情
  ralph merge                    # 合并最新 nightly 到目标分支
  ralph stop
EOF
}

cmd_init() {
  local project_slug=""
  local ralph_yaml="$RALPH_CWD/.ralph.yaml"

  # 从 ralph-db resolve-project 获取建议名称
  project_slug="$("$RALPH_DB_BIN" resolve-project "$RALPH_CWD" 2>/dev/null)" || project_slug=""

  if [[ -z "$project_slug" ]]; then
    project_slug="$(basename "$RALPH_CWD")"
  fi

  echo "=== Ralph 项目初始化 ==="
  echo "项目目录: $RALPH_CWD"
  echo "项目标识: $project_slug"
  echo ""

  # 创建 .ralph.yaml（如果不存在）
  if [[ ! -f "$ralph_yaml" ]]; then
    cat > "$ralph_yaml" <<YAML
project: $project_slug

verify:
  symlink_node_modules: true
  commands:
    # - pnpm type-check
    # - pnpm test:priority

changeset:
  enabled: false
  # package: $project_slug

merge_target: main
skip_hooks: true

# source: repo
# inbox_repo: git@github.com:user/inbox.git
# webhook_url:
# default_model: claude-sonnet-4-6
YAML
    echo "已创建 .ralph.yaml"
  else
    echo ".ralph.yaml 已存在，跳过创建"
  fi

  # 初始化数据目录和数据库
  "$RALPH_DB_BIN" init "$project_slug" 2>&1

  echo ""
  echo "项目已初始化。编辑 .ralph.yaml 以配置验证命令和其他选项。"
  echo "数据目录: $RALPH_HOME/projects/$project_slug/"
}

cmd_start() {
  # 双重防重复：PID 文件 + 进程扫描
  if [[ -f "$RALPH_PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$RALPH_PID_FILE")"
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "Ralph 已在运行 (PID: $old_pid, 项目: $RALPH_PROJECT)"
      echo "如需重启，先执行: ralph stop"
      return 1
    fi
    rm -f "$RALPH_PID_FILE"
  fi

  # 进程扫描兜底：检查是否有遗留的 loop.sh 进程
  local stale_pids
  stale_pids="$(pgrep -f "loop\.sh.*$RALPH_PROJECT\|loop\.sh" 2>/dev/null | grep -v "^$$\$" || true)"
  if [[ -n "$stale_pids" ]]; then
    echo "发现遗留 Ralph 进程: $stale_pids"
    echo "请先执行 ralph stop 或手动 kill，再重新启动"
    return 1
  fi

  # 验证必要配置
  if [[ "$RALPH_SOURCE" == "gist" && -z "$RALPH_GIST_ID" ]]; then
    echo "错误: 使用 Gist 源时需设置 RALPH_GIST_ID 环境变量"
    return 1
  fi

  rm -f "$RALPH_PAUSED_FILE"
  # 清除 Claude Code 嵌套检测变量，否则子进程调用 claude CLI 会被拒绝
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  nohup bash "$RALPH_SCRIPT_DIR/loop.sh" >> "$RALPH_LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$RALPH_PID_FILE"
  echo "Ralph 已启动 (PID: $pid, 项目: $RALPH_PROJECT)"
  echo "日志: tail -f $RALPH_LOG"
}

cmd_stop() {
  touch "$RALPH_PAUSED_FILE"
  echo "Ralph 已标记暂停 (项目: $RALPH_PROJECT)，当前 cycle 完成后将停止"

  if [[ -f "$RALPH_PID_FILE" ]]; then
    local pid
    pid="$(cat "$RALPH_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "运行中 PID: $pid"
      # 等待最多 30 秒让当前 cycle 结束
      local waited=0
      while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 30 ]]; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "进程未在 30 秒内退出，发送 SIGTERM..."
        kill "$pid" 2>/dev/null || true
        sleep 2
      fi
      if kill -0 "$pid" 2>/dev/null; then
        echo "强制终止..."
        kill -9 "$pid" 2>/dev/null || true
      fi
      echo "已停止"
    fi
    rm -f "$RALPH_PID_FILE"
  fi
  rm -f "$RALPH_PAUSED_FILE"
}

cmd_resume() {
  if [[ -f "$RALPH_PAUSED_FILE" ]]; then
    rm -f "$RALPH_PAUSED_FILE"
    echo "已移除暂停标记"
  fi

  # 检查进程是否还活着
  if [[ -f "$RALPH_PID_FILE" ]]; then
    local pid
    pid="$(cat "$RALPH_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "Ralph 进程仍在运行 (PID: $pid)，将在下个 cycle 继续"
      return 0
    fi
  fi

  # 进程已退出，重新启动
  echo "Ralph 进程已退出，重新启动..."
  cmd_start
}

cmd_add() {
  local title="" prompt="" priority=3 model="$RALPH_DEFAULT_MODEL"
  local complexity="simple" files=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)    title="$2"; shift 2 ;;
      --prompt)   prompt="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --model)    model="$2"; shift 2 ;;
      --complexity) complexity="$2"; shift 2 ;;
      --files)    files="$2"; shift 2 ;;
      *) echo "未知参数: $1"; return 1 ;;
    esac
  done

  if [[ -z "$title" ]]; then
    echo "错误: 需要 --title 参数"
    return 1
  fi
  if [[ -z "$prompt" ]]; then
    echo "错误: 需要 --prompt 参数"
    return 1
  fi

  # 生成任务 ID: ralph-MMDD-随机3位
  local id
  id="ralph-$(date '+%m%d')-$(printf '%03d' $((RANDOM % 1000)))"

  ralph_db_add_task "$id" "$title" "$priority" "$model" "$complexity" "$prompt" "$files" "manual"
  echo "已添加任务: $id — $title (P$priority, $model, 项目: $RALPH_PROJECT)"
}

cmd_status() {
  echo "=== Ralph 状态 (项目: $RALPH_PROJECT) ==="
  echo ""

  # 进程状态
  if [[ -f "$RALPH_PID_FILE" ]]; then
    local pid
    pid="$(cat "$RALPH_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "进程: 运行中 (PID: $pid)"
    else
      echo "进程: 已停止"
    fi
  else
    echo "进程: 未启动"
  fi

  if [[ -f "$RALPH_PAUSED_FILE" ]]; then
    echo "状态: 已暂停"
  else
    echo "状态: 活跃"
  fi
  echo ""

  # 任务统计
  local stats
  stats="$("$RALPH_DB_BIN" task-stats "$RALPH_PROJECT" 2>/dev/null)" || stats="{}"
  local pending running done failed
  pending="$(echo "$stats" | jq -r '.pending // 0')"
  running="$(echo "$stats" | jq -r '.running // 0')"
  done="$(echo "$stats" | jq -r '.done // 0')"
  failed="$(echo "$stats" | jq -r '.failed // 0')"

  echo "任务: $pending 待处理 | $running 执行中 | $done 完成 | $failed 失败"
  echo ""

  # 任务列表
  local tasks_json
  tasks_json="$(ralph_db_list_all)"
  if [[ "$tasks_json" != "[]" && -n "$tasks_json" ]]; then
    echo "--- 任务列表 ---"
    echo "$tasks_json" | jq -r '.[] | "[\(.status | ascii_upcase)] P\(.priority) \(.id) — \(.title) (\(.model))"'
  fi
}

cmd_report() {
  source "$RALPH_SCRIPT_DIR/lib/report.sh"
  ralph_generate_report
}

cmd_merge() {
  local target_branch="$RALPH_MERGE_TARGET"
  local nightly_branch="${1:-}"

  cd "$RALPH_CWD"

  # 自动查找最新 nightly 分支
  if [[ -z "$nightly_branch" ]]; then
    nightly_branch="$(git branch -a --list 'ralph/nightly-*' --sort=-creatordate | head -1 | tr -d ' *')"
    if [[ -z "$nightly_branch" ]]; then
      echo "错误: 未找到 ralph/nightly-* 分支"
      return 1
    fi
  fi

  echo "=== Ralph 合并 (项目: $RALPH_PROJECT) ==="
  echo "源分支: $nightly_branch"
  echo "目标: $target_branch"
  echo ""

  # 检查 nightly 是否已经被合并到 target
  if git merge-base --is-ancestor "$nightly_branch" "$target_branch" 2>/dev/null; then
    echo "$nightly_branch 已经完全合并到 $target_branch，无需重复合并"
    return 0
  fi

  # 展示改动预览（只看 nightly 相对于 target 的新提交）
  local diff_stat
  diff_stat="$(git diff --stat "$target_branch...$nightly_branch" 2>/dev/null || echo "")"
  if [[ -z "$diff_stat" ]]; then
    echo "无改动可合并"
    return 0
  fi

  echo "--- 新增提交 ---"
  git log --oneline "$target_branch..$nightly_branch" 2>/dev/null
  echo ""
  echo "--- 改动预览 ---"
  echo "$diff_stat"
  echo ""

  # 列出 checkpoint tags
  local today_short
  today_short="$(echo "$nightly_branch" | grep -oE '[0-9]{4}$')"
  if [[ -n "$today_short" ]]; then
    local tags
    tags="$(git tag -l "ralph/cp-$today_short-*" 2>/dev/null | sort)"
    if [[ -n "$tags" ]]; then
      echo "--- Checkpoint Tags ---"
      echo "$tags"
      echo ""
      echo "如需只合并部分任务:"
      echo "  git cherry-pick <tag1>..<tag2>"
      echo ""
    fi
  fi

  # 确认
  read -rp "确认合并到 $target_branch? (y/N) " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消"
    return 0
  fi

  # 执行合并
  git checkout "$target_branch"
  git merge "$nightly_branch" --no-ff -m "merge: ralph $nightly_branch → $target_branch"
  echo ""
  echo "合并完成。当前在 $target_branch 分支。"
  git log --oneline -3
}

cmd_projects() {
  echo "=== 已注册项目 ==="
  echo ""
  local projects_dir="$RALPH_HOME/projects"
  if [[ ! -d "$projects_dir" ]]; then
    echo "无已注册项目"
    return 0
  fi

  for proj_dir in "$projects_dir"/*/; do
    [[ -d "$proj_dir" ]] || continue
    local proj_name
    proj_name="$(basename "$proj_dir")"
    local status="inactive"
    local pid_info=""

    if [[ -f "$proj_dir/ralph.pid" ]]; then
      local pid
      pid="$(cat "$proj_dir/ralph.pid")"
      if kill -0 "$pid" 2>/dev/null; then
        status="running (PID: $pid)"
      fi
    fi
    if [[ -f "$proj_dir/PAUSED" ]]; then
      status="paused"
    fi

    local task_count=""
    if [[ -f "$proj_dir/ralph.db" ]]; then
      task_count="$("$RALPH_DB_BIN" count-pending "$proj_name" 2>/dev/null || echo "?")"
      task_count=" ($task_count pending)"
    fi

    printf "  %-20s %s%s\n" "$proj_name" "$status" "$task_count"
  done
}

cmd_restart() {
  echo "=== 重启 Ralph (项目: $RALPH_PROJECT) ==="

  # stop
  if [[ -f "$RALPH_PID_FILE" ]]; then
    local pid
    pid="$(cat "$RALPH_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "正在停止进程 (PID: $pid)..."
      touch "$RALPH_PAUSED_FILE"
      # 等待最多 10 秒
      local waited=0
      while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "进程未在 10 秒内退出，发送 SIGTERM..."
        kill "$pid" 2>/dev/null || true
        sleep 1
      fi
      echo "已停止"
    fi
    rm -f "$RALPH_PID_FILE"
  fi
  rm -f "$RALPH_PAUSED_FILE"

  # start
  cmd_start
}

cmd_log() {
  local arg="${1:--50}"

  if [[ ! -f "$RALPH_LOG" ]]; then
    echo "日志文件不存在: $RALPH_LOG"
    return 1
  fi

  case "$arg" in
    -f|--follow)
      echo "=== 实时日志 (项目: $RALPH_PROJECT) ==="
      echo "日志文件: $RALPH_LOG"
      echo "按 Ctrl+C 退出"
      echo "─────────────────────────────"
      tail -f "$RALPH_LOG"
      ;;
    --error|--errors)
      echo "=== 错误日志 (项目: $RALPH_PROJECT) ==="
      grep -E '\[ERROR\]|\[WARN\]' "$RALPH_LOG" | tail -"${2:-30}"
      ;;
    --cycle|--cycles)
      echo "=== Cycle 日志 (项目: $RALPH_PROJECT) ==="
      grep -E '━━━━|Cycle|REFLECT|EXECUTE|VERIFY|COMMIT|completed|failed' "$RALPH_LOG" | tail -"${2:-40}"
      ;;
    --daily)
      # 查看每日事件日志 (JSONL)
      local date_arg="${2:-$(date '+%Y-%m-%d')}"
      local daily_file="$RALPH_DAILY_LOG_DIR/$date_arg.jsonl"
      if [[ ! -f "$daily_file" ]]; then
        echo "无 $date_arg 的事件日志"
        echo "可用日志:"
        ls -1 "$RALPH_DAILY_LOG_DIR"/*.jsonl 2>/dev/null | while read -r f; do
          basename "$f" .jsonl
        done
        return 0
      fi
      echo "=== 每日事件日志: $date_arg (项目: $RALPH_PROJECT) ==="
      echo "─────────────────────────────"
      while IFS= read -r line; do
        local t ev tid ttl dtl
        t="$(echo "$line" | jq -r '.time // ""')"
        ev="$(echo "$line" | jq -r '.event // ""')"
        tid="$(echo "$line" | jq -r '.task_id // ""')"
        ttl="$(echo "$line" | jq -r '.title // ""')"
        dtl="$(echo "$line" | jq -r '.detail // ""')"
        case "$ev" in
          task_started)    printf "  %s  🚀 %-14s %-20s %s\n" "$t" "STARTED" "$tid" "$ttl" ;;
          task_done)       printf "  %s  ✅ %-14s %-20s %s  (%s)\n" "$t" "DONE" "$tid" "$ttl" "$dtl" ;;
          task_failed)     printf "  %s  ❌ %-14s %-20s %s  (%s)\n" "$t" "FAILED" "$tid" "$ttl" "$dtl" ;;
          task_retried)    printf "  %s  🔄 %-14s %-20s %s  (%s)\n" "$t" "RETRIED" "$tid" "$ttl" "$dtl" ;;
          task_discovered) printf "  %s  🔍 %-14s %-20s %s  (%s)\n" "$t" "DISCOVERED" "$tid" "$ttl" "$dtl" ;;
          *)               printf "  %s  %-16s %-20s %s\n" "$t" "$ev" "$tid" "$ttl" ;;
        esac
      done < "$daily_file"
      echo "─────────────────────────────"
      local total started done failed discovered
      total="$(wc -l < "$daily_file" | tr -d ' ')"
      started="$(grep -c '"task_started"' "$daily_file" 2>/dev/null || echo 0)"
      done="$(grep -c '"task_done"' "$daily_file" 2>/dev/null || echo 0)"
      failed="$(grep -c '"task_failed"' "$daily_file" 2>/dev/null || echo 0)"
      discovered="$(grep -c '"task_discovered"' "$daily_file" 2>/dev/null || echo 0)"
      echo "  共 $total 条 | 启动 $started | 完成 $done | 失败 $failed | 衍生 $discovered"
      ;;
    -*)
      # -N 形式: 取最后 N 行
      local n="${arg#-}"
      echo "=== 最近 ${n} 行日志 (项目: $RALPH_PROJECT) ==="
      echo "日志文件: $RALPH_LOG"
      echo "─────────────────────────────"
      tail -"$n" "$RALPH_LOG"
      ;;
    *)
      # 数字: 取最后 N 行
      echo "=== 最近 ${arg} 行日志 (项目: $RALPH_PROJECT) ==="
      echo "日志文件: $RALPH_LOG"
      echo "─────────────────────────────"
      tail -"$arg" "$RALPH_LOG"
      ;;
  esac
}

cmd_task() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    "")
      echo "用法: ralph task <task_id>         查看任务详情"
      echo "      ralph task rm <task_id>      删除任务"
      echo "      ralph task retry <task_id>   重新排队失败任务"
      return 0
      ;;
    rm|remove|delete)
      local task_id="${1:-}"
      if [[ -z "$task_id" ]]; then
        echo "错误: 需要 task_id"; return 1
      fi
      ralph_db_delete_task "$task_id"
      echo "已删除任务: $task_id"
      ;;
    retry|requeue)
      local task_id="${1:-}"
      if [[ -z "$task_id" ]]; then
        echo "错误: 需要 task_id"; return 1
      fi
      # 检查任务状态
      local task_json
      task_json="$(ralph_db_get_task "$task_id")"
      local task_status
      task_status="$(echo "$task_json" | jq -r '.[0].status // "unknown"' 2>/dev/null)"
      if [[ "$task_status" != "failed" && "$task_status" != "skipped" ]]; then
        echo "警告: 任务 $task_id 状态为 $task_status，通常只重试 failed/skipped 任务"
        read -rp "仍然继续? (y/N) " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0
      fi
      ralph_db_update_task_status "$task_id" "pending"
      echo "已将任务 $task_id 重新排队 (pending)"
      ;;
    *)
      # 当作 task_id 查询详情
      local task_id="$subcmd"
      local task_json
      task_json="$(ralph_db_get_task "$task_id")"

      if [[ "$task_json" == "[]" || -z "$task_json" ]]; then
        echo "任务未找到: $task_id"
        return 1
      fi

      echo "=== 任务详情 ==="
      echo "$task_json" | jq -r '.[0] | "
ID:         \(.id)
标题:       \(.title)
状态:       \(.status | ascii_upcase)
优先级:     P\(.priority)
模型:       \(.model)
复杂度:     \(.complexity)
来源:       \(.source)
创建时间:   \(.created_at)
完成时间:   \(.completed_at // "—")
Checkpoint: \(.checkpoint_tag // "—")
重试:       \(.retry_count)/\(.max_retries)
Session:    \(.session_id // "—")
相关文件:   \(.context_files // "—")
"'
      # 显示 prompt（可能很长，截断）
      local prompt
      prompt="$(echo "$task_json" | jq -r '.[0].prompt // ""')"
      if [[ -n "$prompt" ]]; then
        echo "--- Prompt ---"
        echo "$prompt" | head -20
        local lines
        lines="$(echo "$prompt" | wc -l | tr -d ' ')"
        if [[ "$lines" -gt 20 ]]; then
          echo "  ... (共 $lines 行，已截断)"
        fi
      fi

      # 显示结果
      local result
      result="$(echo "$task_json" | jq -r '.[0].result // ""')"
      if [[ -n "$result" ]]; then
        echo ""
        echo "--- 结果 ---"
        echo "$result"
      fi
      ;;
  esac
}

cmd_config() {
  echo "=== Ralph 配置 (项目: $RALPH_PROJECT) ==="
  echo ""
  echo "── 路径 ──"
  echo "  RALPH_HOME:         $RALPH_HOME"
  echo "  RALPH_PROJECT:      $RALPH_PROJECT"
  echo "  RALPH_PROJECT_DIR:  $RALPH_PROJECT_DIR"
  echo "  RALPH_CWD:          $RALPH_CWD"
  echo "  RALPH_DB:           $RALPH_DB"
  echo "  RALPH_LOG:          $RALPH_LOG"
  echo "  RALPH_SCRIPT_DIR:   $RALPH_SCRIPT_DIR"
  echo ""
  echo "── 任务源 ──"
  echo "  RALPH_SOURCE:       $RALPH_SOURCE"
  echo "  RALPH_INBOX_REPO:   ${RALPH_INBOX_REPO:-（未设置）}"
  echo "  RALPH_GIST_ID:      ${RALPH_GIST_ID:-（未设置）}"
  echo ""
  echo "── 模型 ──"
  echo "  RALPH_DEFAULT_MODEL:  $RALPH_DEFAULT_MODEL"
  echo "  RALPH_REFLECT_MODEL:  $RALPH_REFLECT_MODEL"
  echo "  RALPH_REVIEW_MODEL:   $RALPH_REVIEW_MODEL"
  echo ""
  echo "── 执行 ──"
  echo "  RALPH_MAX_CONCURRENT:       $RALPH_MAX_CONCURRENT"
  echo "  RALPH_MAX_TURNS_SIMPLE:     $RALPH_MAX_TURNS_SIMPLE"
  echo "  RALPH_MAX_TURNS_COMPLEX:    $RALPH_MAX_TURNS_COMPLEX"
  echo "  RALPH_POLL_INTERVAL:        ${RALPH_POLL_INTERVAL}s"
  echo ""
  echo "── 项目配置 (.ralph.yaml) ──"
  echo "  RALPH_MERGE_TARGET:                ${RALPH_MERGE_TARGET}"
  echo "  RALPH_SKIP_HOOKS:                  ${RALPH_SKIP_HOOKS}"
  echo "  RALPH_CHANGESET_ENABLED:           ${RALPH_CHANGESET_ENABLED}"
  echo "  RALPH_CHANGESET_PACKAGE:           ${RALPH_CHANGESET_PACKAGE:-（未设置，跳过 changeset）}"
  echo "  RALPH_VERIFY_COMMANDS:             ${RALPH_VERIFY_COMMANDS:-（未设置，跳过验证命令）}"
  echo "  RALPH_VERIFY_SYMLINK_NODE_MODULES: ${RALPH_VERIFY_SYMLINK_NODE_MODULES}"
  echo ""
  echo "── 通知 ──"
  echo "  RALPH_WEBHOOK_URL:  ${RALPH_WEBHOOK_URL:+已配置 (${RALPH_WEBHOOK_URL:0:40}...)}${RALPH_WEBHOOK_URL:-（未设置）}"
  echo ""
  echo "── 版本 ──"
  local version_file="$RALPH_HOME/.version"
  if [[ -f "$version_file" ]]; then
    echo "  已安装版本: $(cat "$version_file")"
  else
    echo "  已安装版本: 未知（未通过 install.sh 安装）"
  fi

  # 检查 .ralph.yaml
  echo ""
  if [[ -f "$RALPH_CWD/.ralph.yaml" ]]; then
    echo "── .ralph.yaml 原文 ──"
    cat "$RALPH_CWD/.ralph.yaml"
  else
    echo "  提示: 当前项目未创建 .ralph.yaml，使用默认配置"
    echo "  运行 'ralph init' 可生成配置文件"
  fi
}

cmd_clean() {
  echo "=== 清理 (项目: $RALPH_PROJECT) ==="
  local cleaned=0

  # 清理孤儿 worktree
  echo ""
  echo "── 孤儿 Worktree ──"
  for wt in /tmp/ralph-wt-$RALPH_PROJECT-*; do
    [[ -d "$wt" ]] || continue
    local task_id_part="${wt##*/tmp/ralph-wt-$RALPH_PROJECT-}"
    echo "  发现: $wt (task: $task_id_part)"
    cd "$RALPH_CWD"
    git worktree remove "$wt" --force >/dev/null 2>&1 || rm -rf "$wt"
    git branch -D "ralph/task-$task_id_part" >/dev/null 2>&1 || true
    echo "  已清理"
    cleaned=$((cleaned + 1))
  done
  [[ $cleaned -eq 0 ]] && echo "  无孤儿 worktree"

  # 清理临时文件
  echo ""
  echo "── 临时文件 ──"
  local tmp_count=0
  for f in /tmp/ralph-*; do
    [[ -e "$f" ]] || continue
    rm -rf "$f"
    tmp_count=$((tmp_count + 1))
  done
  echo "  已清理 $tmp_count 个临时文件"

  # 清理已停止的 PID 文件
  if [[ -f "$RALPH_PID_FILE" ]]; then
    local pid
    pid="$(cat "$RALPH_PID_FILE")"
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$RALPH_PID_FILE"
      echo ""
      echo "── PID 文件 ──"
      echo "  已清理过期 PID 文件 (进程 $pid 已不存在)"
      cleaned=$((cleaned + 1))
    fi
  fi

  # 日志大小提示
  if [[ -f "$RALPH_LOG" ]]; then
    local log_size
    log_size="$(du -sh "$RALPH_LOG" 2>/dev/null | cut -f1)"
    local log_lines
    log_lines="$(wc -l < "$RALPH_LOG" | tr -d ' ')"
    echo ""
    echo "── 日志 ──"
    echo "  $RALPH_LOG: $log_size ($log_lines 行)"
    if [[ "$log_lines" -gt 10000 ]]; then
      echo "  提示: 日志较大，可考虑截断: tail -5000 \"\$RALPH_LOG\" > /tmp/ralph-log-trim && mv /tmp/ralph-log-trim \"\$RALPH_LOG\""
    fi
  fi

  echo ""
  echo "清理完成"
}

# ── 主入口 ──

case "${1:-help}" in
  start)          cmd_start ;;
  stop)           cmd_stop ;;
  restart)        cmd_restart ;;
  resume)         cmd_resume ;;
  add)            shift; cmd_add "$@" ;;
  status)         cmd_status ;;
  log|logs)       shift; cmd_log "$@" ;;
  task)           shift; cmd_task "$@" ;;
  merge)          shift; cmd_merge "$@" ;;
  report)         cmd_report ;;
  config|conf)    cmd_config ;;
  clean|cleanup)  cmd_clean ;;
  init)           cmd_init ;;
  projects)       cmd_projects ;;
  help|*)         usage ;;
esac
