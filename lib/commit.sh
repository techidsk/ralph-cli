#!/usr/bin/env bash
# Ralph Loop — 提交与标记 (patch apply + changeset + checkpoint tag)
# 使用临时 worktree 操作 nightly 分支，不影响主仓库的 checkout 状态
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/db.sh"

# ralph_commit <worktree_path> <task_id> <task_title>
# 返回 checkpoint tag 名称到 stdout
ralph_commit() {
  local worktree="$1"
  local task_id="$2"
  local task_title="$3"
  local start_time
  start_time="$(date +%s)"

  ralph_log_info "=== COMMIT phase: $task_id ==="

  local today
  today="$(date '+%m%d')"
  local nightly_branch="ralph/nightly-$today"

  cd "$RALPH_CWD"
  ralph_log_info "COMMIT: CWD=$RALPH_CWD, nightly=$nightly_branch"

  # 确保 nightly 分支存在且与 HEAD 同步
  if ! git rev-parse --verify "$nightly_branch" >/dev/null 2>&1; then
    ralph_log_info "COMMIT: Creating nightly branch: $nightly_branch from HEAD=$(git rev-parse --short HEAD)"
    git branch "$nightly_branch" HEAD
  else
    # merge 后 nightly 落后于 HEAD，fast-forward 对齐
    if git merge-base --is-ancestor "$nightly_branch" HEAD 2>/dev/null; then
      local nightly_sha head_sha
      nightly_sha="$(git rev-parse "$nightly_branch")"
      head_sha="$(git rev-parse HEAD)"
      if [[ "$nightly_sha" != "$head_sha" ]]; then
        ralph_log_info "COMMIT: Fast-forwarding $nightly_branch (${nightly_sha:0:7} → ${head_sha:0:7})"
        git branch -f "$nightly_branch" HEAD
      else
        ralph_log_info "COMMIT: nightly branch up to date (${nightly_sha:0:7})"
      fi
    else
      ralph_log_warn "COMMIT: nightly branch diverged from HEAD, cannot fast-forward"
    fi
  fi

  # 从 task worktree 生成 patch
  local patch_dir="/tmp/ralph-patches-$$"
  mkdir -p "$patch_dir"

  local patch_count
  patch_count="$(cd "$worktree" && git format-patch -o "$patch_dir" HEAD~1 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "$patch_count" -eq 0 ]]; then
    ralph_log_warn "COMMIT: No patches generated for $task_id (worktree has no commits ahead of HEAD?)"
    ralph_log_warn "COMMIT: worktree HEAD=$(cd "$worktree" && git rev-parse --short HEAD), main HEAD=$(git rev-parse --short HEAD)"
    rm -rf "$patch_dir"
    echo ""
    return 1
  fi

  ralph_log_info "COMMIT: Generated $patch_count patch(es) from worktree"

  # ── 在临时 worktree 中操作 nightly 分支（不影响主仓库） ──
  local nightly_wt="/tmp/ralph-nightly-$$"
  ralph_log_info "COMMIT: Creating nightly worktree at $nightly_wt"
  git worktree add "$nightly_wt" "$nightly_branch" --quiet 2>/dev/null || {
    local wt_err=$?
    ralph_log_error "COMMIT: Failed to create nightly worktree (exit=$wt_err)"
    ralph_log_error "COMMIT: Existing worktrees: $(git worktree list 2>/dev/null | grep -c ralph)"
    rm -rf "$patch_dir"
    echo ""
    return 1
  }

  cd "$nightly_wt"

  # 判断 commit 类型
  local commit_type="feat"
  if echo "$task_title" | grep -qiE '(fix|修复|bug|问题|缺少|丢失|遮挡|异常|错误|失败)'; then
    commit_type="fix"
  elif echo "$task_title" | grep -qiE '(refactor|重构|优化)'; then
    commit_type="refactor"
  elif echo "$task_title" | grep -qiE '(style|样式|颜色|UI)'; then
    commit_type="style"
  fi

  # 从改动文件路径推断 scope
  local commit_scope=""
  local changed_files
  changed_files="$(cd "$worktree" && git diff --name-only HEAD~1 2>/dev/null | grep -v '^\.changeset/' || echo "")"
  if [[ -n "$changed_files" ]]; then
    local app_path
    app_path="$(echo "$changed_files" | grep -oE 'src/app/(\[lang\]/\([^)]+\)/|api/)([^/]+)' | head -1 | sed -E 's|.*/(.*)|\1|')"
    if [[ -n "$app_path" ]]; then
      commit_scope="$app_path"
    else
      local comp_path
      comp_path="$(echo "$changed_files" | grep -oE 'src/(components|features|server)/([^/]+)' | head -1 | sed -E 's|.*/(.*)|\1|')"
      if [[ -n "$comp_path" ]]; then
        commit_scope="$comp_path"
      else
        commit_scope="$(echo "$changed_files" | head -1 | xargs dirname | xargs basename)"
      fi
    fi
  fi
  [[ -z "$commit_scope" ]] && commit_scope="general"

  # 去掉 title 标签前缀
  local subject
  subject="$(echo "$task_title" | sed -E 's/^\[(BUG|需求|优化|FEAT)\] *//')"
  subject="$(echo "$subject" | cut -c1-50)"

  # hook 控制: 读 RALPH_SKIP_HOOKS
  local env_prefix=""
  local commit_flags=""
  if [[ "${RALPH_SKIP_HOOKS:-false}" == "true" ]]; then
    env_prefix="HUSKY=0"
    commit_flags="--no-verify"
  fi

  local apply_success=0
  ralph_log_info "COMMIT: Applying patches via git am --3way..."
  if git am --3way "$patch_dir"/*.patch >/dev/null 2>&1; then
    apply_success=1
    ralph_log_info "COMMIT: Patches applied successfully via git am"
  else
    ralph_log_warn "COMMIT: git am failed, attempting git apply --3way fallback..."
    git am --abort >/dev/null 2>&1 || true

    local apply_output
    apply_output="$(git apply --3way "$patch_dir"/*.patch 2>&1)" && {
      git add -A >/dev/null 2>&1
      local conflict_msg="$commit_type($commit_scope): $subject (conflict resolved)

task-id: $task_id"
      if [[ -n "$env_prefix" ]]; then
        env $env_prefix git commit -m "$conflict_msg" $commit_flags >/dev/null 2>&1
      else
        git commit -m "$conflict_msg" >/dev/null 2>&1
      fi
      apply_success=1
      ralph_log_info "COMMIT: Patches applied via git apply fallback (conflict resolved)"
    } || {
      ralph_log_error "COMMIT: Both git am and git apply failed for $task_id"
      ralph_log_error "COMMIT: apply output: $(echo "$apply_output" | tail -5)"
      ralph_log_error "COMMIT: nightly HEAD=$(git rev-parse --short HEAD), task worktree HEAD=$(cd "$worktree" && git rev-parse --short HEAD)"
      cd "$RALPH_CWD"
      git worktree remove "$nightly_wt" --force >/dev/null 2>&1 || rm -rf "$nightly_wt"
      rm -rf "$patch_dir"
      echo ""
      return 1
    }
  fi

  local checkpoint_tag=""

  if [[ $apply_success -eq 1 ]]; then
    # 创建 changeset (仅当 RALPH_CHANGESET_PACKAGE 非空时)
    if [[ -n "${RALPH_CHANGESET_PACKAGE:-}" && "${RALPH_CHANGESET_ENABLED:-true}" == "true" ]]; then
      local changeset_name="ralph-${task_id}"
      local changeset_dir="$nightly_wt/.changeset"
      mkdir -p "$changeset_dir"

      local change_type="patch"
      if echo "$task_title" | grep -qiE '(feat|feature|新增|添加)'; then
        change_type="minor"
      fi

      cat > "$changeset_dir/$changeset_name.md" <<CHANGESET
---
'$RALPH_CHANGESET_PACKAGE': $change_type
---

$subject (Ralph 自动执行)
CHANGESET

      git add "$changeset_dir/$changeset_name.md"
      if [[ -n "$env_prefix" ]]; then
        env $env_prefix git commit --amend --no-edit $commit_flags >/dev/null 2>&1 || true
      else
        git commit --amend --no-edit >/dev/null 2>&1 || true
      fi
    fi

    # 创建 checkpoint tag（在主仓库创建，对所有 worktree 可见）
    local tag_seq
    tag_seq="$(git tag -l "ralph/cp-$today-*" | wc -l | tr -d ' ')"
    tag_seq=$((tag_seq + 1))
    checkpoint_tag="$(printf 'ralph/cp-%s-%03d' "$today" "$tag_seq")"

    git tag "$checkpoint_tag"
    ralph_log_info "COMMIT: Created checkpoint tag: $checkpoint_tag on $(git rev-parse --short HEAD)"
  fi

  # ── 清理 nightly worktree ──
  cd "$RALPH_CWD"
  ralph_log_info "COMMIT: Cleaning up nightly worktree and task worktree"
  git worktree remove "$nightly_wt" --force >/dev/null 2>&1 || rm -rf "$nightly_wt"

  # 清理 task worktree
  ralph_log_info "Cleaning up worktree: $worktree"
  git worktree remove "$worktree" --force >/dev/null 2>&1 || rm -rf "$worktree"
  git branch -D "ralph/task-$task_id" >/dev/null 2>&1 || true
  # 清理重试时自动追加后缀的分支
  for _suffix_branch in $(git branch --list "ralph/task-${task_id}-*" 2>/dev/null | tr -d ' +'); do
    git branch -D "$_suffix_branch" >/dev/null 2>&1 || true
  done

  # 清理 patches
  rm -rf "$patch_dir"

  local duration=$(( $(date +%s) - start_time ))
  ralph_db_log_cycle 0 "commit" "$task_id" "" "$checkpoint_tag" 0 "$duration"

  ralph_log_info "Commit completed in ${duration}s"
  echo "$checkpoint_tag"
}

# 回滚: 清理 worktree 但不 apply
ralph_rollback_worktree() {
  local worktree="$1"
  local task_id="$2"

  ralph_log_warn "Rolling back worktree for $task_id"
  cd "$RALPH_CWD"
  git worktree remove "$worktree" --force >/dev/null 2>&1 || rm -rf "$worktree"
  git branch -D "ralph/task-$task_id" >/dev/null 2>&1 || true
  for _suffix_branch in $(git branch --list "ralph/task-${task_id}-*" 2>/dev/null | tr -d ' +'); do
    git branch -D "$_suffix_branch" >/dev/null 2>&1 || true
  done
}
