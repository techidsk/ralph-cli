# Ralph CLI

自动化任务执行系统 — 开发者睡觉时 Claude Code 自主完成低优先级任务，第二天通过晨报快速审查。

**v2 核心改进：多项目支持、Python 数据层（消灭 SQL 注入）、项目逻辑可配置。**

> 从 [techidsk/molook](https://github.com/techidsk/molook) 的 `scripts/ralph/` 提取为独立仓库（commit: 37c493ca1）。

## 前置条件

- macOS（使用 `caffeinate` 阻止休眠）
- Python 3（macOS 自带，用于 `ralph-db` 数据层）
- [Claude Code CLI](https://claude.ai/code)（`claude` 命令可用）
- [GitHub CLI](https://cli.github.com/)（`gh` 命令可用，使用 Gist 源时需要）
- `jq`（macOS 自带）

## 安装

```bash
# Clone 仓库
git clone git@github.com:techidsk/ralph-cli.git
cd ralph-cli

# 安装到 ~/.ralph/
bash install.sh

# 验证
ralph help
ralph-db --help
```

安装脚本会：
- 复制文件到 `~/.ralph/bin/`、`~/.ralph/lib/`
- 创建 symlink `~/.local/bin/ralph` → `~/.ralph/bin/ralph`
- 创建 symlink `~/.local/bin/ralph-db` → `~/.ralph/bin/ralph-db`

> 确保 `~/.local/bin` 在 PATH 中。

### 升级

```bash
cd /path/to/ralph-cli
git pull
bash install.sh
```

## 快速开始

```bash
# 1. 进入项目目录
cd /path/to/my-project

# 2. 初始化项目（生成 .ralph.yaml + 创建数据目录）
ralph init

# 3. 编辑 .ralph.yaml，配置验证命令等
vim .ralph.yaml

# 4. 添加任务
ralph add --title "修复拖拽偏移" --prompt "修复 clientX/Y 偏移" --priority 0

# 5. 启动
ralph start

# 6. 跟踪日志
tail -f ~/.ralph/projects/<project>/ralph.log

# 7. 查看状态
ralph status

# 8. 停止
ralph stop
```

## 项目配置 `.ralph.yaml`

每个仓库根目录放一个 `.ralph.yaml`：

```yaml
project: my-project            # 项目标识（不填则从 git remote 推导）

verify:
  symlink_node_modules: true   # 自动 ln -s 主项目 node_modules
  commands:
    - pnpm type-check          # 阻断性验证命令（可配多个）
    # - pnpm test:priority

changeset:
  enabled: false               # 是否创建 changeset
  # package: my-package        # changeset 包名

merge_target: main             # ralph merge 的目标分支
skip_hooks: true               # HUSKY=0 + --no-verify

# 可覆盖全局配置
# source: repo
# inbox_repo: git@github.com:user/inbox.git
# webhook_url: https://...
# default_model: claude-sonnet-4-6
```

## CLI 命令

```
ralph <command>
```

| 命令 | 说明 |
|------|------|
| `init` | 初始化当前项目（生成 `.ralph.yaml`，创建数据目录和数据库） |
| `start` | 后台启动主循环 |
| `stop` | 标记暂停，当前 cycle 完成后退出 |
| `resume` | 恢复执行（移除暂停标记，进程已退出则重新启动） |
| `add [opts]` | 添加任务 |
| `status` | 查看进程状态和任务列表 |
| `merge [branch]` | 将 nightly 分支合并到目标分支（从 `.ralph.yaml` 读取） |
| `report` | 手动触发生成晨报 |
| `projects` | 列出所有已注册项目及状态 |
| `migrate-legacy` | 将旧版 `~/.ralph/` 扁平数据迁移到多项目结构 |
| `help` | 显示帮助 |

### add 参数

| 参数 | 说明 | 必填 | 默认值 |
|------|------|------|--------|
| `--title` | 任务标题 | 是 | — |
| `--prompt` | 任务指令 | 是 | — |
| `--priority` | 优先级 P0-P3（P0 最高） | 否 | 3 |
| `--model` | 使用的模型 | 否 | claude-sonnet-4-6 |
| `--complexity` | `simple` 或 `complex` | 否 | simple |
| `--files` | 相关文件路径（逗号分隔） | 否 | — |

示例：

```bash
# 简单任务
ralph add \
  --title "修复拖拽坐标偏移" \
  --prompt "修复 useMouseHandler.tsx 中拖拽结束时 clientX/clientY 没有减去 canvas offset" \
  --priority 0 \
  --files "src/components/canvas-board/hooks/useMouseHandler.tsx"

# 复杂任务（会先规划再执行）
ralph add \
  --title "颜色选择器无障碍改造" \
  --prompt "为颜色选择器添加 aria-label 和键盘导航支持" \
  --priority 2 \
  --model claude-opus-4-6 \
  --complexity complex
```

## 架构：Hybrid Bash + Python

| 层 | 语言 | 职责 |
|----|------|------|
| 编排层 | Bash | git worktree、claude CLI、caffeinate、进程管理、nohup/trap |
| 数据层 | Python | SQLite（parameterized query）、JSON 序列化、项目识别 |

### 目录结构

```
ralph-cli/                     # 源码仓库
├── ralph.sh                   # CLI 入口
├── loop.sh                    # 主循环
├── install.sh                 # 安装脚本
├── config.yaml.example        # 全局配置模板
├── bin/
│   └── ralph-db               # 数据层 (Python)
├── lib/                       # Bash 模块
│   ├── config.sh              # 配置加载
│   ├── log.sh / db.sh         # 日志 / DB shim
│   ├── source*.sh             # 任务源适配器
│   ├── reflect.sh / execute.sh / verify.sh / commit.sh
│   ├── report.sh / webhook.sh
└── templates/
    ├── changeset.tpl
    ├── ralph.yaml.sample
    └── inbox-sample.jsonl

~/.ralph/                      # 安装目录（运行时）
├── bin/ralph, bin/ralph-db
├── lib/
├── config.yaml                # 全局配置（从 config.yaml.example 复制）
├── projects/                  # 每项目独立数据
│   └── <project>/
│       ├── ralph.db / ralph.log / ralph.pid
│       ├── context-brief.md / lessons.md
│       └── reports/
└── templates/
```

### 配置加载顺序

1. **环境变量**（最高优先级）
2. **`~/.ralph/config.yaml`**（全局，不提交 git）
3. **`$CWD/.ralph.yaml`**（项目端覆盖）

## 任务源

支持三种任务源：

| 源 | 说明 | 适用场景 |
|----|------|---------|
| `repo` | Git 仓库（inbox-repo） | 生产环境，飞书 bot 集成 |
| `gist` | GitHub Gist | 个人使用 |
| `local` | 本地文件 | 开发调试 |

## 单 Cycle 流程

```
Ralph Runner (本地 Mac)
┌─────────────────────────┐
│ 0. CHECK  暂停检测       │
│ 1. INBOX  消费新任务     │
│ 2. REFLECT 反思+分诊    │ ← sonnet
│ 3. EXECUTE worktree ×N  │ ← 并行，按任务选模型
│ 4. VERIFY 验证命令+review│ ← 从 .ralph.yaml 读取
│ 5. COMMIT 提交+打标     │ ← nightly 分支
│ 6. UPDATE 同步状态      │
└─────────────────────────┘
```

## 多项目管理

```bash
# 项目 A
cd /path/to/project-a && ralph init && ralph start

# 项目 B（同时运行）
cd /path/to/project-b && ralph init && ralph start

# 查看所有项目
ralph projects
```

每个项目完全独立：数据库、日志、PID 文件、worktree 路径互不干扰。

## Git 分支策略

- 每天首个任务自动创建 `ralph/nightly-MMDD` 分支
- 每个任务完成后打 `ralph/cp-MMDD-NNN` tag

```bash
# 接受全部改动
ralph merge

# 只 cherry-pick 某几个
git cherry-pick ralph/cp-0310-001..ralph/cp-0310-003

# 回退某个任务
git revert ralph/cp-0310-002
```

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `RALPH_HOME` | 数据根目录 | `~/.ralph` |
| `RALPH_PROJECT` | 强制指定项目标识 | （从 `.ralph.yaml` 或 git remote 推导） |
| `RALPH_SOURCE` | 任务源 `repo`/`gist`/`local` | `repo` |
| `RALPH_CWD` | 项目根目录 | `git rev-parse --show-toplevel` |
| `RALPH_POLL_INTERVAL` | 无任务时轮询间隔（秒） | `300` |
| `RALPH_DEFAULT_MODEL` | 默认执行模型 | `claude-sonnet-4-6` |
| `RALPH_WEBHOOK_URL` | 飞书/钉钉 webhook 地址 | （留空不发送） |

## License

MIT
