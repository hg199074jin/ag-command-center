# ag v2.4 — Agent Runtime & Autonomy 设计文档

> 版本：v2.4.0-r1（2026-09-07 按本机实测修订）  
> 日期：2026-09-07  
> 目标平台：macOS（Mac mini 主机）  
> 上游基线：ag v2.3.2 Session Registry / Session Center（本机实测版本）  
> 主要 Agent：OpenAI Codex CLI、Claude Code  
> 后续兼容：Gemini CLI、GLM、MiniMax、OpenCode 等

---

## 1. 文档目的

ag v2.4 的目标不是再增加一个新的 GUI、tmux 管理器或 Session Manager，而是在现有 ag v2.3 的基础上补齐两个关键能力：

1. **Agent Runtime**
   - ag 不仅知道“这个 Session 是谁”，还要知道“它现在在干什么、是否需要人、是否卡住、是否完成”。
2. **Agent Autonomy**
   - 将 Codex CLI 与 Claude Code 的审批/权限行为统一抽象成 `SAFE / AUTO / YOLO` 三档，减少频繁人工确认。

同时，v2.4 将社区中成熟项目的优秀设计吸收到 ag，但坚持：

> **ag 是唯一控制面（Control Plane）；第三方工具原则上只读、旁路或参考，不成为新的 Source of Truth。**

---

# 2. 当前环境与前置假设

本方案基于当前 Mac Agent 工作台：

```text
Windows / 手机
      │
      │ SSH / 向日葵 / 蒲公英
      ▼
Mac mini
      │
      ├── ag v2.3.2（registry 在 ~/.local/state/ag/projects/）
      ├── tmux 3.7c
      ├── Yazi
      ├── Codex CLI 0.153.4（sessions JSONL + 已有 hooks.json）
      ├── Claude Code 2.1.234（走 MiniMax 中转）
      ├── claude-worker-router（/Volumes/ORICO/Projects/）
      ├── Git / Git Worktree
      └── 通知链路：agent-notify → ntfy.sh → Windows PWA
```

本机事实注记：

```text
项目全部位于外置盘 /Volumes/ORICO/Projects/，盘未挂载时路径"消失"，
registry/policy/gate 一律 fail-safe：禁止把"路径不存在"当成"可清理"
~/.claude/settings.json 已有 4 类 hooks；~/.codex/hooks.json 已存在
两者只能合并、不能覆盖
```

ag v2.3 已经或正在解决：

```text
Project
Session Registry
tmux session
Codex/Claude session
cwd
resume
历史会话
```

v2.4 不推倒重来，而是在其上增加：

```text
Runtime State
Autonomy Policy
Provider Adapter
Usage
Stuck Detection
Trace
Notification
Worker Integration
```

---

# 3. 设计原则

## 3.1 ag 仍然是唯一控制面

以下能力只能有一个主控：

- Session Registry
- Project Registry
- tmux session 命名
- Agent launcher
- Project trust
- Autonomy mode
- Runtime state
- Worker 生命周期

因此不能让以下第三方软件直接“接管”现有 ag：

- dmux
- Agent CLI Farm
- amux
- codex-hud 的 `codex` wrapper
- 其他自动创建 tmux/worktree/session 的管理器

这些项目主要作为**参考实现**。

---

## 3.2 第三方优先只读

可以直接部署的工具应满足：

- 不修改 ag Registry；
- 不改写 `codex` / `claude` 启动入口；
- 不创建另一套 tmux 命名规则；
- 不成为 Session 生命周期管理者。

优先允许：

- abtop
- CodexBar
- codex-dash（只用 dashboard/index，不使用 launch wrapper）
- codex-trace

---

## 3.3 不全局永久 YOLO

YOLO 的价值很明确：

- 减少重复审批；
- 适合可信项目；
- 适合无人值守 Worker；
- 适合已经有 Git/worktree/evidence/review 的执行链。

但不能简单做成：

```text
所有目录
所有项目
所有 Agent
永久 bypass
```

正确做法：

```text
Project Trust
      +
Autonomy Policy
      +
Runtime Provider
      +
Worktree / Git
```

---

# 4. 总体架构

```text
                       ag v2.4
                          │
                ┌─────────┴─────────┐
                │                   │
          Project Registry     Session Registry
                │                   │
                └─────────┬─────────┘
                          │
                  Runtime Policy
                          │
             ┌────────────┼────────────┐
             │            │            │
            SAFE         AUTO         YOLO
             │            │            │
      ┌──────┴─────┐ ┌────┴─────┐ ┌────┴─────┐
      │            │ │          │ │          │
    Codex        Claude Codex Claude Codex Claude
      │            │ │          │ │          │
      └──────┬─────┘ └────┬─────┘ └────┬─────┘
             │             │            │
             └─────────────┴────────────┘
                           │
                    Provider Adapter
                           │
                    Agent Launcher
                           │
                         tmux
                           │
                   Runtime Collector
                           │
      ┌─────────┬──────────┼──────────┬──────────┐
      │         │          │          │          │
   Process    Session     Events     Usage      Trace
      │         │          │          │          │
      └─────────┴──────────┼──────────┴──────────┘
                           │
                     State Engine
                           │
             RUNNING / WAITING / STUCK / ...
                           │
                ag TUI + Notifications
```

---

# 5. SAFE / AUTO / YOLO 统一权限模型

## 5.1 ag 层统一语义

### SAFE

适用：

- 新下载的 GitHub 仓库；
- 未信任项目；
- 重要生产资料；
- 系统配置目录；
- 第一次执行复杂脚本。

语义：

```text
重要操作 → 人工确认
修改范围 → 尽可能受限
```

---

### AUTO

适用：

- 日常交互式 Codex / Claude；
- 已知项目；
- 用户通常会同意的大多数普通命令。

语义：

```text
普通行为 → 自动
明显高风险行为 → 保留 Provider 自身保护
```

这是建议的**交互式默认模式**。

---

### YOLO

适用：

- Trusted Project；
- Git 仓库；
- 独立 worktree；
- Worker；
- 已明确授权的无人值守任务。

语义：

```text
尽量不打断
不逐项请求用户确认
```

YOLO 是显式风险模式，不代表安全边界消失；安全控制转移到：

- Project trust；
- worktree；
- Git；
- policy；
- evidence；
- review；
- 外部隔离（未来增强）。

---

# 6. Provider 权限映射

## 6.1 Codex Adapter

本机 codex 0.153.4 实测已有：

```bash
codex --approve-for-me
codex --dangerously-bypass-approvals-and-sandbox
codex --ask-for-approval on-request|never
codex --sandbox read-only|workspace-write|danger-full-access
```

注意：旧资料中的 `--yolo` 与 `--not-so-yolo` 在 0.153.4 已不存在，
YOLO 必须使用完整写法 `--dangerously-bypass-approvals-and-sandbox`。

推荐映射：

| ag | Codex |
|---|---|
| SAFE | Codex 常规审批配置 |
| AUTO | `codex --approve-for-me` |
| YOLO | `codex --dangerously-bypass-approvals-and-sandbox` |

重要：

`--approve-for-me` 当前官方实现会使用自动审批审查，并维持 `workspace-write` sandbox。

`--dangerously-bypass-approvals-and-sandbox` 会跳过确认并取消 Codex 自身 sandbox，因此仅用于明确 trusted 场景。

---

## 6.2 Claude Adapter

Claude Code 的权限模式正在快速演进，因此 v2.4 **不得硬编码假设某个版本一定支持 AUTO**。

Provider Adapter 启动时先进行 capability probe：

```bash
claude --version
claude --help
```

本机 claude 2.1.234 的 `--permission-mode` 实测可选值：
`acceptEdits, auto, bypassPermissions, manual, dontAsk, plan`（没有 default）。

统一映射建议：

| ag | Claude 优先策略 |
|---|---|
| SAFE | 缺省（不传 `--permission-mode`）或 `plan` |
| AUTO | `auto`（本机已支持）；若不可用则 `acceptEdits` |
| YOLO | `bypassPermissions` / `--dangerously-skip-permissions` |

注意：

```text
dontAsk ≠ YOLO
```

`dontAsk` 更接近：

```text
需要审批 → 不询问 → 拒绝
```

不能映射成完全自治。

另外，Claude 当前版本中 `auto`、`bypassPermissions`、Plan 退出后的模式仍可能有版本/套餐差异，因此 Adapter 必须：

1. 探测能力；
2. 记录实际生效模式；
3. 不依赖单一版本行为；
4. Provider 更新后通过 `ag doctor` 重新验证。

---

# 7. Project Trust 模型

## 7.1 项目级信任

每个项目记录：

```json
{
  "project_id": "claude-worker-router",
  "root": "/Volumes/ORICO/Projects/claude-worker-router",
  "trust": "trusted",
  "default_autonomy": "yolo"
}
```

可选值：

```text
untrusted
trusted
protected
```

---

## 7.2 默认策略

### untrusted

```text
默认 SAFE
禁止自动进入 YOLO
```

### trusted

```text
默认 AUTO
允许项目配置 YOLO
```

### protected

```text
默认 SAFE
即使过去 trusted，也禁止自动 YOLO
```

### 外置盘保护（本机特有）

```text
项目全在 /Volumes/ORICO/Projects/，外置盘未挂载时路径"看起来不存在"
policy 清理 / gate 判定前必须 test -d /Volumes/ORICO
不可达时禁止清理任何记录，gate 一律降级 SAFE
```

---

# 8. 高风险目录保护

以下路径默认不能自动进入 YOLO：

```text
/
$HOME
$HOME/.ssh
$HOME/.gnupg
$HOME/.config
$HOME/Library
$HOME/.agent-workstation
/System
/Library
/private
/etc
```

注意：

这只是 **ag launcher gate**。

Codex/Claude 真正进入 bypass 后，Provider 本身可能仍具备访问项目之外路径的能力。因此 v2.4 不应宣传为“YOLO 仍然完全安全”。

后续可以增强：

- 专用 Worker 用户；
- Container；
- 外部 filesystem sandbox；
- macOS policy/sandbox 研究；
- Path deny enforcement。

---

# 9. Runtime 状态机

统一状态：

```text
STARTING
RUNNING
WAITING_USER
WAITING_APPROVAL
IDLE
STALLED
STUCK
COMPLETED
FAILED
DETACHED
ORPHANED
STALE
```

---

## 9.1 状态定义

### STARTING

Agent 已启动，但尚未确认 Session Runtime。

### RUNNING

存在持续事件、tool call、输出或活动信号。

### WAITING_USER

Agent 明确等待用户输入。

### WAITING_APPROVAL

Agent 明确等待权限确认。

### IDLE

Session 存活，但当前无任务。

### STALLED

Session 看起来仍在运行，但一定时间没有有效进展。

### STUCK

STALLED 超过阈值，且无网络/tool/output/session 活动。

### COMPLETED

本轮任务正常结束。

### FAILED

Agent 或任务异常退出。

### DETACHED

tmux/session 存活，但当前无人 attach。

### ORPHANED

Agent process、tmux、Registry 三者出现失联。

### STALE

历史 Session 长时间未活动。

---

# 10. Runtime 状态判定优先级

不是依赖单一数据源。

推荐：

```text
Provider Native Event / App Server
        ↓
Provider Hook / Session Event
        ↓
Session JSONL / transcript
        ↓
tmux pane
        ↓
process
        ↓
mtime / heuristic
```

## Codex

优先研究：

```text
Codex app-server
```

其次：

```text
~/.codex/sessions/**/*.jsonl
```

再结合：

```text
tmux
PID
process state
```

## Claude

优先：

```text
CLI runtime + hooks
```

可利用：

- `SessionStart`
- `PreToolUse`
- `PostToolUse`
- `PermissionRequest`
- `Stop`

但当前 Claude 某些 surface/version 的 Hook 存在行为差异，因此不能只依赖 Notification hook。

建议：

```text
Hook + process + session activity
```

组合判定。

---

# 11. STALLED / STUCK 判定

默认阈值建议：

```text
active event silence >= 5 min  → STALLED candidate
active event silence >= 15 min → STUCK candidate
```

但需要排除：

- 正常长时间 shell command；
- build；
- test；
- download；
- 模型长推理；
- 子 Agent 工作；
- 等待网络。

状态引擎应维护：

```text
last_output_at
last_tool_start_at
last_tool_end_at
last_session_event_at
last_process_cpu_activity_at
waiting_reason
```

只有多个信号同时静默才标记 STUCK。

---

# 12. Usage / Context / Limit

统一 Runtime record：

```json
{
  "provider": "codex",
  "model": "gpt-5.6",
  "context_used_pct": 44,
  "tokens_in": 120000,
  "tokens_out": 18000,
  "rate_limit_short": 62,
  "rate_limit_long": 81,
  "updated_at": "2026-09-07T17:00:00+08:00"
}
```

功能：

- 当前 Token；
- Context 占用；
- 5h/weekly quota；
- reset time；
- 历史；
- 消耗速度；
- 低额度提醒。

---

# 13. 通知模型

ag 统一产生事件：

```text
agent.waiting_user
agent.waiting_approval
agent.completed
agent.failed
agent.stalled
agent.stuck
quota.low
runtime.orphaned
```

通知层不感知 Codex/Claude 细节。

统一：

```text
Provider Adapter
     ↓
Runtime Event
     ↓
ag-notify（事件映射 + 去重）
     ↓
现有 agent-notify 链路（ntfy.sh push）
     ↓
Windows ntfy PWA
```

本机现状：通知链路已是 agent-notify → ntfy.sh → Windows PWA，
ag v2.4 桥接它，而不是新建 macOS 通知中心依赖或第二套推送。

建议降噪：

```text
RUNNING → 不通知
IDLE → 不通知
COMPLETED → 通知一次
WAITING_* → 通知一次
STALLED → 可选
STUCK → 强通知
FAILED → 强通知
```

---

# 14. Worker Router 集成

Worker 默认策略：

```text
Worker
  │
  ├── Git worktree
  ├── project scoped task
  ├── provider = Codex / Claude
  ├── autonomy = YOLO
  ├── test profile
  ├── evidence
  └── review before integrate
```

推荐：

```text
Interactive Agent → AUTO
Worker Agent      → YOLO
Unknown Repo      → SAFE
```

Worker 不能因为 YOLO 而跳过：

- test；
- evidence；
- diff；
- integrate review；
- cleanup；
- policy。

---

# 15. Registry 扩展模型

为了避免破坏 v2.3，建议先增加 sidecar（按本机 config/state 分离惯例）：

```text
~/.config/ag/
└── runtime-policy.json            # 人写策略

~/.local/state/ag/runtime/
├── runtime-state.json            # 运行时状态
├── provider-capabilities.json    # probe 结果
└── usage-history.jsonl           # 用量历史
```

本机 v2.3.2 Registry 现状（sidecar 必须与之桥接而不是冲突）：

```text
位置：~/.local/state/ag/projects/<sha256前16位>.json
字段：id,name,path,agent,lifecycle,tmux_session,launch_mode,
     created_at,updated_at,last_active_at
lifecycle 落盘仅 done/active；runtime 为实时判定
（tmux 会话存在 + 会话 identity 与 registry 的 id+path 匹配）
```

不要第一版就修改 v2.3 Registry schema。

`runtime-policy.json`：

```json
{
  "version": 1,
  "defaults": {
    "interactive": "auto",
    "worker": "yolo",
    "untrusted": "safe"
  },
  "projects": {
    "/Volumes/ORICO/Projects/claude-worker-router": {
      "trust": "trusted",
      "autonomy": {
        "codex": "yolo",
        "claude": "yolo"
      }
    }
  }
}
```

---

# 16. Provider Adapter 接口

统一接口：

```text
probe()
build_launch_command()
detect_session_id()
read_runtime()
read_usage()
resume()
stop()
```

示意：

```python
class ProviderAdapter:
    name: str

    def probe(self): ...
    def launch(self, cwd, autonomy, prompt=None): ...
    def detect_session(self, process): ...
    def runtime_state(self, session): ...
    def usage(self, session): ...
```

实现：

```text
providers/
├── codex.py
├── claude.py
└── base.py
```

后续：

```text
gemini.py
glm.py
minimax.py
opencode.py
```

---

# 17. ag TUI 目标

本机 ag v2.3.2 为五入口 gum 分层菜单（Agent / 项目 / 开发 / 工作台 / 辅助）。
下图为信息布局目标，实施时以增量列/增量入口嵌入现有菜单，不重排主菜单，
gum 一律 `2>/dev/tty` 渲染。

主界面建议：

```text
╭──────────────────────────────────────────────────────────────╮
│                   Agent Workspace v2.4                       │
├────┬────────────────────┬────────┬────────┬─────────┬─────────┤
│ #  │ Project            │ Agent  │ Mode   │ State   │ Age     │
├────┼────────────────────┼────────┼────────┼─────────┼─────────┤
│ 1  │ ag                 │ Codex  │ YOLO   │ RUN     │ 12m     │
│ 2  │ docchunk           │ Codex  │ AUTO   │ INPUT   │ 3m      │
│ 3  │ worker-router      │ Claude │ YOLO   │ RUN     │ 28m     │
│ 4  │ audit-agent        │ Codex  │ AUTO   │ DONE    │ 1h      │
╰────┴────────────────────┴────────┴────────┴─────────┴─────────╯

N  New Agent
Y  Yazi
S  Sessions
A  Agent Monitor
T  Trace
U  Usage
P  Project Policy
D  Doctor
R  Resume
Enter Attach
```

---

# 18. 第三方仓库策略

## 18.1 长期情报源

### openai/codex

定位：

```text
官方 Source of Truth
```

用途：

- CLI flags；
- app-server；
- hooks；
- config；
- session format；
- status line；
- runtime changes。

---

### RoggeOhta/awesome-codex-cli

定位：

```text
Codex 生态雷达
```

定期关注：

- Session & Workflow Management
- Monitoring & Analytics
- Shell & Terminal
- Remote Access
- Hooks
- Skills
- Plugins
- Subagents

不直接因为榜单出现项目就安装。

---

# 19. 第一梯队：必读参考实现

## codex-dash

吸收：

- 多 Session 状态；
- local-first；
- stale；
- token；
- rate limit；
- SSH/tmux metadata；
- attach/resume 设计。

可直接部署为只读 Dashboard，但：

```text
第一阶段不要使用 codex-dash launch 接管启动
```

---

## codex-agents

吸收：

```text
Codex app-server
Unix socket
真实 Waiting / Working / Completed
```

这是 Runtime State 最重要的架构参考之一。

---

## codex-trace

吸收：

```text
Session event
Tool call
MCP
Patch
Token
Agent chain
```

可以直接部署，只读 `~/.codex/sessions`。

---

## agent-cli-farm

吸收：

- tmux pane ↔ provider session ID；
- exact resume；
- save；
- restore；
- reboot recovery；
- doctor；
- board；
- manifest。

不让其替代 ag Registry。

---

## abtop

直接部署优先级高。

用途：

```text
htop for Agents
```

监控：

- Claude；
- Codex；
- OpenCode；
- PID；
- child process；
- token；
- context；
- rate limit；
- ports。

只读，不抢控制权。

---

## dmux

吸收：

```text
Task
→ Worktree
→ tmux pane
→ Agent
→ merge
→ cleanup
```

主要用于审查 claude-worker-router 的 Worker 生命周期设计。

不与 ag 同时接管 worktree。

---

# 20. 第二梯队：吸收能力

## codex-hud

吸收：

- 单 Session HUD；
- context bar；
- tool activity；
- multi-session view；
- tmux UI。

第一阶段不直接安装，因为其 installer 会包装 `codex` 命令和 tmux 行为，可能与 ag launcher 冲突。

---

## codex_stuck

吸收：

```text
STALLED / STUCK 检测
terminal title state
silent duration
```

不必单独长期运行。

---

## Codex Usage Monitor

吸收：

- usage history；
- quota threshold；
- alert；
- history.json 思路。

不再单独部署另一套 Dashboard。

---

## CodexBar

适合直接安装。

定位：

```text
macOS menu bar glance
```

只负责：

- Codex quota；
- Claude quota；
- reset time；
- provider usage。

不参与 Runtime Control。

---

## oh-my-codex

吸收：

- hooks；
- agent team；
- workflow；
- persistent state；
- HUD。

不作为 ag 主控。

---

## amux

吸收：

- watchdog；
- fleet；
- stuck；
- auto-continue；
- mobile/dashboard 思路。

YOLO 思路允许进入 ag，但不采用“全局默认无限制”。

---

## codex-1up

吸收：

```text
config wizard
doctor
permission preset
dependency check
```

用户现有环境已经远超一键安装包目标，不建议直接部署。

---

## cc-clip

后续远程增强候选。

目标：

```text
Windows clipboard/image
        ↓ SSH
      Mac Agent
```

适合未来解决 SSH 场景下图片剪贴板体验。

---

# 21. 明确暂不作为核心的项目

以下类型不要进入 Source of Truth：

```text
Community Codex Fork
大一统 GUI
第二套 tmux manager
第二套 Worktree manager
第二套 Session Registry
```

原则：

```text
Official CLI
   +
ag Control Plane
   +
read-only observability
```

优先于：

```text
Community Fork
   +
GUI Manager
   +
Another Registry
   +
Another tmux Wrapper
```

---

# 22. 可直接部署 / 暂不部署清单

## v2.4 建议实际部署

```text
abtop
CodexBar
codex-dash（只读使用）
codex-trace（只读使用）
```

## v2.4 只研究，不接管

```text
codex-agents
agent-cli-farm
dmux
amux
codex-hud
codex_stuck
Codex Usage Monitor
oh-my-codex
codex-1up
cc-clip
```

---

# 23. 兼容性要求

v2.4 必须做到：

1. 原 `ag` 命令仍然能启动；
2. 原 v2.3 Session Registry 不丢；
3. 现有 tmux session 不改名；
4. 现有 Codex/Claude session 可继续 resume；
5. Yazi 入口保持；
6. 向日葵/蒲公英 SSH 工作方式不变；
7. Runtime 功能失败时可以自动降级到 v2.3；
8. 第三方 Dashboard 删除后 ag 不受影响。

---

# 24. 失败降级

Runtime Collector 失败：

```text
state = UNKNOWN
```

而不是：

```text
阻止 Agent 启动
```

Provider capability probe 失败：

```text
AUTO → SAFE
YOLO → 仅 trusted project 允许手工显式调用
```

Notification 失败：

```text
任务继续
记录日志
```

Usage 失败：

```text
不影响 Runtime
```

---

# 25. 安全边界

YOLO 风险必须在 UI 中用模式标记，而不是每次弹确认：

```text
SAFE  = S
AUTO  = A
YOLO  = Y
```

例如：

```text
[Codex][YOLO][trusted][worker-router]
```

这样用户随时知道权限模式，但不被每一个 tool call 打断。

---

# 26. v2.4 最终能力矩阵

```text
                    ag v2.4

Registry              ✓
Project Trust         ✓
SAFE/AUTO/YOLO        ✓
Codex Adapter         ✓
Claude Adapter        ✓
Runtime State         ✓
Stuck Detection       ✓
Usage                 ✓
Notification          ✓
Trace Entry           ✓
Worker Integration    ✓
Doctor                ✓
Third-party Radar     ✓
```

---

# 27. 后续路线

## v2.4.1

```text
Runtime 稳定性
Codex App Server 深化
Claude Hook 稳定性
Usage history
```

## v2.5

```text
External sandbox
Worker isolation
Policy enforcement
automatic recovery
```

## v2.6

```text
Multi-machine Agent Board
Mac + Windows compute node
Unified fleet status
```

---

# 28. 验收标准

部署完成后应达到：

### 场景一

```text
ag
→ 选择 trusted project
→ Codex
→ 自动 AUTO 或 YOLO
→ 不再重复弹出普通确认
```

### 场景二

```text
Worker
→ worktree
→ Claude
→ YOLO
→ 连续完成
→ evidence
→ 等待 review
```

### 场景三

```text
ag
→ Session Center
→ 能看到：
RUNNING / INPUT / APPROVAL / STUCK / DONE
```

### 场景四

```text
Codex/Claude 完成
→ ag-notify 桥接 agent-notify
→ ntfy.sh 推送
→ Windows PWA 可收到通知
```

### 场景五

```text
abtop
→ 能看到 Agent、PID、Context、Token、端口
```

### 场景六

```text
CodexBar
→ 菜单栏可查看 Codex / Claude quota
```

### 场景七

删除：

```text
abtop
CodexBar
codex-dash
codex-trace
```

后：

```text
ag 仍完全可用
```

---

# 29. 参考仓库

- https://github.com/openai/codex
- https://github.com/RoggeOhta/awesome-codex-cli
- https://github.com/ArnabCodes/codex-dash
- https://github.com/morgadoronan/codex-agents
- https://github.com/PixelPaw-Labs/codex-trace
- https://github.com/waskosky/agent-cli-farm
- https://github.com/graykode/abtop
- https://github.com/standardagents/dmux
- https://github.com/fwyc0573/codex-hud
- https://github.com/SeemSeam/codex_stuck
- https://github.com/en4ble1337/codex-usage-monitor
- https://github.com/steipete/CodexBar
- https://github.com/HyunjunJeon/oh-my-codex
- https://github.com/mixpeek/amux
- https://github.com/regenrek/codex-1up
- https://github.com/ShunmeiCho/cc-clip

---

# 30. 最终结论

ag v2.4 不应变成另一个“大而全 Agent GUI”。

其正确定位是：

> **以 v2.3 Registry 为基础，将 ag 升级成统一的 Agent Runtime Manager。**

核心路线：

```text
官方 Codex / Claude
        ↓
Provider Adapter
        ↓
SAFE / AUTO / YOLO
        ↓
ag Runtime State
        ↓
tmux / Registry / Worker
        ↓
只读 Monitoring
```

其中：

```text
交互任务 → AUTO
可信项目 → 可记忆 YOLO
Worker → 默认 YOLO
未知项目 → SAFE
```

这样既减少无意义的人工确认，也保留清晰的项目权限边界，并为未来的多 Agent、远程 Worker、外部 sandbox 和自动恢复留下扩展空间。

---

# 修订记录

## 2026-09-07 本机实测修订（v2.4.0-r1）

按 2026-09-07 对本机（macOS / ag v2.3.2 / codex 0.153.4 / claude 2.1.234 / tmux 3.7c）的只读探测修订：

1. §2 环境拓扑更新为本机实测，新增外置盘 fail-safe 与 hooks 只能合并的注记
2. §6.1 Codex 映射修正：--yolo / --not-so-yolo 在 0.153.4 已不存在，YOLO 用 --dangerously-bypass-approvals-and-sandbox
3. §6.2 Claude 映射修正：choices 无 default，SAFE 改缺省；auto 本机已支持
4. §7 示例路径改 /Volumes/ORICO/Projects/，新增「外置盘保护」小节
5. §8 保护根补 $HOME/.agent-workstation
6. §13 通知模型落地为桥接 agent-notify（ntfy.sh → Windows PWA）
7. §15 sidecar 路径按 config/state 分离，附 v2.3.2 registry schema
8. §17 TUI 对齐 gum 分层菜单（增量嵌入，不重排）
9. §28 场景四改为 ntfy 链路
