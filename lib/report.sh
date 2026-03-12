#!/usr/bin/env bash
# Ralph Loop — 晨报生成
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/db.sh"
source "$SCRIPT_DIR/source.sh"

ralph_generate_report() {
  ralph_log_info "=== REPORT phase ==="

  local today
  today="$(date '+%Y-%m-%d')"
  local today_short
  today_short="$(date '+%m%d')"

  # 收集数据
  local completed_tasks failed_tasks
  completed_tasks="$(ralph_db_get_today_completed_tasks)"

  local done_count fail_count total_count
  done_count="$(echo "$completed_tasks" | jq '[.[] | select(.status=="done")] | length' 2>/dev/null || echo 0)"
  fail_count="$(echo "$completed_tasks" | jq '[.[] | select(.status=="failed")] | length' 2>/dev/null || echo 0)"
  total_count=$((done_count + fail_count))

  if [[ $total_count -eq 0 ]]; then
    ralph_log_info "No completed tasks today, skipping report"
    return 0
  fi

  # 收集 diff stats
  local nightly_branch="ralph/nightly-$today_short"
  local diff_stat=""
  if git rev-parse --verify "$nightly_branch" >/dev/null 2>&1; then
    diff_stat="$(cd "$RALPH_CWD" && git diff --stat HEAD..."$nightly_branch" 2>/dev/null | tail -1 || echo "")"
  fi

  # 收集 checkpoint tags
  local tags
  tags="$(cd "$RALPH_CWD" && git tag -l "ralph/cp-$today_short-*" 2>/dev/null | sort || echo "")"

  # 用 Claude 生成结构化晨报
  local report_prompt
  report_prompt="基于以下信息生成 Ralph 晨报，直接输出 Markdown 格式：

## 日期
$today

## 今日任务结果
$completed_tasks

## 代码改动统计
$diff_stat

## Checkpoint Tags
$tags

## 未消费的 Discoveries
$(ralph_db_get_unconsumed_discoveries)

---

请按以下格式生成晨报（直接输出，不要 code block）:

# Ralph 晨报 $today

## 概览
- N 个任务：M ✅ / K ⚠️
- 改动统计
- 影响模块

## 逐任务
(每个 checkpoint 一个小节，包含关键改动、风险等级、是否需要复查)

## 需关注
(高风险项、失败任务、发现的新问题)

## 快速操作
(git 命令：合并/cherry-pick/回退)"

  local report
  report="$(claude -p "$report_prompt" --model "$RALPH_REFLECT_MODEL" --max-turns 1 --dangerously-skip-permissions --output-format text 2>/dev/null </dev/null)" || {
    ralph_log_warn "Claude report generation failed, using fallback"

    # Fallback: 简单模板
    report="# Ralph 晨报 $today

## 概览
- $total_count 个任务：$done_count ✅ / $fail_count ⚠️
- $diff_stat

## Checkpoint Tags
$tags

## 任务详情
$completed_tasks
"
  }

  # 推送到 source
  echo "$report" | push_report 2>/dev/null || ralph_log_warn "Failed to push report"

  # 本地也保存一份
  local report_dir="$RALPH_PROJECT_DIR/reports"
  mkdir -p "$report_dir"
  echo "$report" > "$report_dir/report-$today.md"

  ralph_log_info "Report generated: $report_dir/report-$today.md"
}
