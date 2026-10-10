# ag — Agent 指挥中心

中文 | **[English](README.md)**

[![版本](https://img.shields.io/badge/version-2.6.0-blue)](https://github.com/hg199074jin/ag-command-center/releases)
[![平台](https://img.shields.io/badge/platform-macOS-blue)](https://github.com/hg199074jin/ag-command-center)
[![Shell](https://img.shields.io/badge/shell-bash%203.2%2B-green)](https://github.com/hg199074jin/ag-command-center)
[![tmux](https://img.shields.io/badge/tmux-3.x-1BB91F)](https://github.com/tmux/tmux)
[![界面](https://img.shields.io/badge/UI-gum%20%E8%8F%9C%E5%8D%95-FF6F61)](https://github.com/charmbracelet/gum)
[![Python](https://img.shields.io/badge/python-纯标准库-3776ab)](https://github.com/hg199074jin/ag-command-center)
[![Star](https://img.shields.io/github/stars/hg199074jin/ag-command-center?style=social&label=Star)](https://github.com/hg199074jin/ag-command-center/stargazers)
[![许可](https://img.shields.io/badge/license-MIT-yellow)](LICENSE)

**ag** 是 macOS 工作站上运行 AI 编码代理——[OpenAI Codex CLI](https://github.com/openai/codex) 与 [Claude Code](https://claude.com/claude-code)——的单命令指挥中心。它在 tmux 之上提供分层菜单、项目登记簿、统一权限模型、运行状态机和只读监控集成。

> **设计原则：ag 是唯一控制面。** 第三方面板都是只读旁观者——删掉任何一个，ag 照常工作。

```
                        Mac
                         │
                         ag
          ┌──────────────┼──────────────┐
        登记簿          策略          运行时
          │      SAFE / AUTO / YOLO    │
          └──────────────┼──────────────┘
                 Codex  │  Claude
                        │  tmux
            ┌───────────┼───────────┐
          abtop      codex-dash   codex-trace   （只读旁观者）
```

## 解决什么问题

在一台 Mac 上同时跑多个项目的多个代理，很快就会乱：哪个 tmux 窗口是哪个代理？它安静了——是在思考、在等审批、还是卡死了？为什么每改一个文件都要人工确认一次？ag 一次回答这三个问题：

- **是谁** —— 项目登记簿 + 写进 tmux 的会话身份（shell 重开不丢，server 重启才失效）
- **什么状态** —— 运行状态机，能识别 `RUNNING / WAITING_USER / WAITING_APPROVAL / STALLED / STUCK / ORPHANED`
- **多大自由度** —— 三档权限模型，最高档（YOLO）有 fail-closed 闸门

## 功能

**指挥中心 TUI**（`ag`）—— 基于 [gum](https://github.com/charmbracelet/gum) 的分层菜单：🤖 Agent / 📁 项目 / 🛠 开发 / 🖥 工作台 / 🧠 辅助。在任意项目里启动 Codex/Claude/Shell 会话、恢复会话、浏览会话中心、跑诊断。

**SAFE / AUTO / YOLO 三档权限** —— 跨 Provider 统一词汇，按能力探测映射到真实 CLI 参数：

| ag 档位 | Codex CLI（0.152.x+） | Claude Code（2.1.x） |
|---|---|---|
| `SAFE` | 默认审批 | 不传 `--permission-mode` |
| `AUTO` | `--approve-for-me` * | `--permission-mode auto` |
| `YOLO` | `--dangerously-bypass-approvals-and-sandbox` | `--permission-mode bypassPermissions` |

\* 自 v2.4.1 起 AUTO 只传 `--approve-for-me`：该参数本身就隐含 workspace-write 沙箱语义，再显式叠加 `--sandbox` 会被 codex 参数解析拒绝（`the argument '--approve-for-me' cannot be used with '--sandbox'`）。

能力是**探测出来的，不是猜的**——`ag-provider-doctor` 解析 `--help` 输出并落盘真实支持项；适配器只会**降档**（如 `auto` → `acceptEdits`），绝不静默升档。

**YOLO 闸门（fail-closed）** —— 只有同时满足才放行 YOLO：cwd 解析后不在保护根内（`/`、`$HOME`、`~/.ssh`、`~/.gnupg`、`~/.config`、`~/Library`、`/System`、`/Library`、`/private`、`/etc`）、在 git 仓库内、项目已 `trusted`、Provider 未被钉在更低档、外置盘（如有）已挂载。任何含糊情况——**包括闸门工具本身损坏**——一律降级 AUTO。经过独立代码评审并有专门回归测试覆盖。

**运行状态机** —— hooks 与会话文件采集器喂事件管线；显式事件（`question`/`permission`/`stop`）永远优先于启发式。STALLED（5 分钟）需要多信号同时静默；STUCK（15 分钟）还要求会话文件同样安静。状态变化可触发通知（桥接到你已有的通道——经 `agent-notify emit` 走 ntfy/Telegram 等，`notification.py` 里可换）。

**项目登记簿** —— 每个项目一个小 JSON（sha256 派生 id），原子写入；lifecycle `active/done`；tmux 会话身份（`@ag_project_id` / `@ag_agent` / `@ag_launch_mode` / `@ag_runtime_id`）保证 ag 重启后会话不错乱。

**Doctor** —— `ag doctor`：20 项只读检查（二进制、登记簿 JSON 有效性、tmux、Provider 版本与能力、hooks、保护根、通知链、监控工具）。退出码 0/1/2 对应 健康/警告/失败，方便脚本化。

**Worker 模式** —— `ag-run claude --worker` 要求在 *linked git worktree* 且项目 trusted，否则拒绝（exit 3）。绝不在宿主仓库根上静默跑 YOLO。

**只读监控** —— 菜单集成 [abtop](https://github.com/graykode/abtop)（agent 版 htop）、[CodexBar](https://github.com/steipete/CodexBar)（菜单栏额度；其 CLI 兼作可选用量数据源）、[codex-dash](https://github.com/ArnabCodes/codex-dash)、[codex-trace](https://github.com/PixelPaw-Labs/codex-trace)。全部可选，ag 不依赖任何一个。

## 安装

依赖：macOS、bash 3.2+、[`tmux`](https://github.com/tmux/tmux)、[`gum`](https://github.com/charmbracelet/gum)、`jq`、python3（3.9+，纯标准库）。可选：`yazi`、`fzf`、Codex CLI、Claude Code。

```bash
git clone https://github.com/hg199074jin/ag-command-center.git
cd ag-command-center
./install.sh          # 覆盖前会自动备份现有文件
```

安装内容：

| 来源 | 目标 |
|---|---|
| `bin/*` | `~/.local/bin/` |
| `lib/ag-runtime/` | `~/.local/share/ag/runtime/` |

状态数据在 `~/.local/state/ag/`（登记簿、运行时、日志），策略在 `~/.config/ag/runtime-policy.json`——都不进仓库。

## 快速开始

```bash
ag                      # 打开菜单
ag doctor               # 全面体检
ag-policy show          # 看哪些项目被信任

cd ~/my-project
ag-policy trust         # 一次性：标记项目为 trusted
ag-policy set-mode yolo # 可选：把该项目钉在 YOLO
ag-run codex --mode yolo --dry-run   # 只看它会执行的完整命令
ag-run codex --mode yolo             # 真正启动（前台）
```

卸载 / 回滚：`ag-v2.4-rollback` 还原上一个版本，并把 sidecar 文件改名为 `*.disabled`（保留历史数据）。

## 命令族

| 命令 | 用途 |
|---|---|
| `ag` | 交互菜单（Agent / 项目 / 开发 / 工作台 / 辅助） |
| `ag status` / `ag session list` / `ag project list` | 脚本友好的概览 |
| `ag doctor` | 只读诊断，退出码 0/1/2 |
| `ag-policy show\|trust\|untrust\|protect\|set-mode` | 项目信任与档位策略 |
| `ag-run <codex\|claude> [--mode s/a/y] [--worker] [--dry-run]` | 统一启动器（带闸门） |
| `ag-run gate <provider> --cwd DIR` | 输出 `ALLOW` / `DENY:<原因>` |
| `ag-run resolve <provider> --json` | 完整决策链（请求档 vs 实际生效档） |
| `ag-run refresh` | 重扫运行时、更新状态、触发通知 |
| `ag-provider-doctor` | 探测 Provider 能力 |
| `ag-runtime-event <provider> <event>` | hook 事件入口（永远 exit 0） |
| `ag-notify <EVENT> <RUNTIME_ID>` | 通知桥（带去重） |
| `ags` | tmux 会话快速切换 |

## 版本历史

| 版本 | 要点 |
|---|---|
| v2.1 | 项目启动、tmux 会话身份、工作台菜单 |
| v2.2 | 项目登记簿 + 最近项目、外置盘 fail-safe |
| v2.3.x | 指挥中心：会话中心、doctor、agentboard 集成、登记簿原子写 |
| **v2.4.0** | SAFE/AUTO/YOLO + 能力探测、YOLO 闸门（fail-closed）、运行状态机、卡死检测、通知桥、用量快照、Worker 模式、监控集成；经外部代码评审关闭 1 项 Critical / 4 项 Important |
| **v2.4.1** | 热修复：codex 0.152+ 的 AUTO 命令（`--approve-for-me` 不再叠加 `--sandbox`——参数冲突）；Yazi 选目录的输出重定向到 `/dev/tty`，误按 Enter 打开文件时 vi 等 opener 能拿到真实终端 |
| **v2.4.2** | 热修复：会话中心不再冻结——runtime `refresh` 改后台执行（同步等待实测 20s+）；`state.lock` 最多等 10 秒即降级为无锁写入，被 Ctrl+Z 挂起的持锁进程再也毒不死系统（此前表现为会话中心永久空屏） |
| **v2.5.0** | 新增 OpenCode 启动器（sst/opencode），与 Codex/Claude 并列：新任务 + 恢复 + 新建项目后动作三个菜单全部接线，SAFE/AUTO/YOLO 三档（AUTO 与 YOLO 都映射 `opencode --auto`——opencode 的最高放行档），会话身份与 tmux 持久运行照常。Python 侧 provider 注册表暂未收录 opencode：启动经本地映射回退解析，运行时登记降级为 WARN 日志（不影响启动） |
| **v2.6.0** | 恢复菜单升级为两段式：`● 运行中`照常直接进入；`○ 已退出`（如 Ctrl+C 退出了 Agent 但 tmux 会话还在）依据持久化的 `@ag_agent` 会话身份自动识别，回车即一键续聊重启——在原项目目录经 `tmux respawn-pane` 自动带上次对话（`opencode -c` / `claude --continue` / `codex resume --last`） |

历史版本保留在 [`archive/`](archive/) 供参考。

## 仓库结构

```
bin/            ag 主脚本 + ag-* 命令族（bash / python 入口）
lib/ag-runtime/ v2.4 运行时包（python 纯标准库）
docs/           v2.4 设计文档与实施方案
archive/        历史 ag 版本（v2.2、v2.3）
install.sh      带备份的安装器
```

## 已知限制

- Codex 用量数值依赖 CodexBar CLI（官方尚无脚本化端点）；`codex app-server` 集成在计划中。
- Claude `Notification` hook 未细分事件子类，统一映射为 `WAITING_APPROVAL`。
- 恢复（resume）的会话暂不重新登记进 runtime-state（计划用 tmux `@ag_runtime_id` 重关联）。

## 许可

[MIT](LICENSE) © hg199074jin
