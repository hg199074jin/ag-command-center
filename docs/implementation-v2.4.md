# ag v2.4 — Agent Runtime & Autonomy 实施方案

> 版本：v2.4.0-r1（2026-09-07 按本机实测修订）  
> 日期：2026-09-07  
> 实施原则：在 ag v2.3.2（本机实测版本）上增量升级，不重写、不破坏现有 Registry/tmux/SSH/Yazi 工作流。

---

# 0. 本机已核对事实（2026-09-07 只读探测）

以下为本机实测结论，正文凡与本节冲突处，以本节为准（正文已同步修订）：

```text
ag             v2.3.2（~/.local/bin/ag，2523 行 bash；同目录另有 ag2/ag3/ags/backup）
ag registry    ~/.local/state/ag/projects/<sha256前16位>.json
               字段：id,name,path,agent,lifecycle,tmux_session,launch_mode,
                    created_at,updated_at,last_active_at
               lifecycle 落盘仅 done/active；runtime 为实时判定
               （tmux 会话存在 + 会话 identity 与 registry 的 id+path 匹配）
ag config      ~/.config/ag/config（被 ag/mac-status/mac-fix 共同 source）
tmux           3.7c（现有会话：AI、agentboard；gum 菜单必须 2>/dev/tty 渲染）
codex          0.153.4（mise/node 安装）
               存在：--approve-for-me / --dangerously-bypass-approvals-and-sandbox /
                    -a on-request|never / -s read-only|workspace-write|danger-full-access /
                    子命令 doctor、resume、exec、app-server(experimental)、agents
               不存在：--yolo / --not-so-yolo / --full-auto
               ~/.codex/hooks.json 已存在（PermissionRequest/Stop/UserPromptSubmit）
claude         2.1.234（~/.local/bin/claude）
               --permission-mode 可选值：acceptEdits, auto, bypassPermissions,
               manual, dontAsk, plan（无 default）
               --dangerously-skip-permissions 存在
               ~/.claude/settings.json 已有 4 类 hooks（cross-agent-memory +
               agent-workstation 的 done/permission/question），只能合并不能覆盖
通知链路       agent-notify → ntfy.sh → Windows PWA（不依赖 macOS 通知中心）
项目根         /Volumes/ORICO/Projects/（外置盘；未挂载时路径失效，逻辑须 fail-safe）
Python         3.12.14（uv 管理，python3 / python3.12 均可用）；jq 1.7.1
包管理         brew ✓ uv ✓ docker ✓（3 个 tdai-* 受保护容器在跑）；pipx ✗ cargo ✗
监控工具       abtop/CodexBar/codex-dash/codex-trace 均未安装；~/src 不存在
其他           Claude 走 MiniMax 中转（官方 5h/weekly quota 字段允许 null）；
               ag/ags 由 ~/.dotfiles.git 每日自动快照，改坏可回溯
```

---

# 1. 实施目标

本次部署完成以下内容：

1. 新增 `SAFE / AUTO / YOLO`；
2. Codex / Claude 统一 Provider Adapter；
3. Trusted Project；
4. Runtime 状态机；
5. STALLED / STUCK；
6. Usage Collector；
7. 通知；
8. Worker Router 默认 YOLO；
9. ag TUI 增加 Runtime/Policy；
10. 安装低侵入监控工具；
11. 保留社区项目作为参考，而不让其接管 ag。

---

# 2. 实施红线

Agent 在开始修改前必须遵守：

```text
禁止直接重写 ag
禁止删除 v2.3 Registry
禁止修改已有 tmux session 名
禁止批量 kill 现有 Agent
禁止覆盖 ~/.codex/config.toml
禁止覆盖 ~/.claude/settings.json（只能读取后合并，见 §17）
禁止覆盖 ~/.codex/hooks.json（如需合并先审查已有内容）
禁止直接执行第三方 install.sh 而不审阅
```

任何变更前：

```text
backup
diff
test
rollback
```

---

# 3. Phase 0 — 只读环境核对

先执行：

```bash
date
sw_vers
uname -m

command -v ag
type -a ag

command -v codex
codex --version
codex --help

command -v claude
claude --version
claude --help

command -v tmux
tmux -V

command -v yazi
command -v git
command -v jq
command -v python3
command -v python3.12
```

定位 ag：

```bash
AG_BIN="$(command -v ag)"
echo "$AG_BIN"
file "$AG_BIN"
```

只读查看：

```bash
sed -n '1,260p' "$AG_BIN"
```

定位相关目录：

```bash
find "$HOME" -maxdepth 3 \
  \( -name '*ag*' -o -name '*registry*' -o -name '*session*' \) \
  2>/dev/null | head -200
```

检查 tmux：

```bash
tmux list-sessions 2>/dev/null || true
tmux list-panes -a -F '#S|#I|#P|#{pane_pid}|#{pane_current_path}|#{pane_current_command}' 2>/dev/null || true
```

检查 Codex Session：

```bash
find "$HOME/.codex/sessions" -type f -name '*.jsonl' 2>/dev/null | tail -20
```

Claude：

```bash
ls -la "$HOME/.claude" 2>/dev/null || true
```

输出一份：

```text
ag-v2.4-preflight.txt
```

---

# 4. Phase 1 — 完整备份

建议：

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/config-backup/ag-v2.4-$STAMP"
mkdir -p "$BACKUP"
```

备份：

```bash
cp -a "$(command -v ag)" "$BACKUP/ag" 2>/dev/null || true

cp -a "$HOME/.config/ag" "$BACKUP/ag-config" 2>/dev/null || true
cp -a "$HOME/.codex/config.toml" "$BACKUP/codex-config.toml" 2>/dev/null || true
cp -a "$HOME/.claude/settings.json" "$BACKUP/claude-settings.json" 2>/dev/null || true
cp -a "$HOME/.tmux.conf" "$BACKUP/tmux.conf" 2>/dev/null || true
cp -a "$HOME/.zshrc" "$BACKUP/zshrc" 2>/dev/null || true
```

不要备份：

```text
SSH 私钥
API Key
Token
密码
```

如果某些 Provider 配置含 Token，只备份结构或权限安全的本地副本，不上传 Git。

---

# 5. Phase 2 — 建立 v2.4 Sidecar

不直接修改 v2.3 Registry schema。

建立（按本机 config/state 分离惯例拆分：人写配置进 ~/.config/ag，机器数据进 state）：

```text
~/.config/ag/
└── runtime-policy.json          # 人写策略（trust / autonomy / protected_roots）

~/.local/state/ag/runtime/
├── runtime-state.json           # 运行时状态（机器写）
├── provider-capabilities.json   # probe 结果
├── notification.json            # 通知去重状态
└── usage-history.jsonl          # 用量历史
```

初始化：

```json
{
  "version": 1,
  "defaults": {
    "interactive": "auto",
    "worker": "yolo",
    "untrusted": "safe"
  },
  "protected_roots": [
    "/",
    "$HOME",
    "$HOME/.ssh",
    "$HOME/.gnupg",
    "$HOME/.config",
    "$HOME/Library",
    "/System",
    "/Library",
    "/private",
    "/etc"
  ],
  "projects": {}
}
```

实际写入时把 `$HOME` 展开为真实路径。

---

# 6. Phase 3 — 建立运行时模块目录

建议目录：

```text
~/.local/share/ag/runtime/
├── __init__.py
├── cli.py
├── config.py
├── registry_bridge.py
├── project_policy.py
├── state_engine.py
├── process_probe.py
├── tmux_probe.py
├── notification.py
├── usage.py
├── stuck.py
└── providers/
    ├── __init__.py
    ├── base.py
    ├── codex.py
    └── claude.py
```

要求：

- Python 标准库优先；
- 第一版不引入数据库；
- 第一版不引入 Redis；
- 第一版不引入额外 daemon 框架；
- JSON/JSONL 足够。

---

# 7. Phase 4 — Provider Capability Probe

建立：

```bash
ag-provider-doctor
```

Codex：

```bash
codex --version
codex --help
```

检测（本机 codex 0.153.4 实测：--yolo 与 --not-so-yolo 已不存在，不要探测）：

```text
--approve-for-me
--dangerously-bypass-approvals-and-sandbox
--ask-for-approval（on-request | never）
--sandbox（read-only | workspace-write | danger-full-access）
```

写入：

```json
{
  "codex": {
    "version": "...",
    "approve_for_me": true,
    "yolo": true,
    "checked_at": "..."
  }
}
```

Claude：

```bash
claude --version
claude --help
```

检测（本机 claude 2.1.234 实测可选值；注意没有 default，反而多了 manual）：

```text
--permission-mode
--dangerously-skip-permissions
auto
acceptEdits
bypassPermissions
manual
dontAsk
plan
```

注意：

不要只通过版本号猜能力，必须结合 `--help` 和一次无副作用 smoke test。

---

# 8. Phase 5 — Codex Adapter

核心函数：

```text
probe
build_command
resume
detect_session
runtime
usage
```

命令映射：

## SAFE

保留当前 Codex 默认审批策略。

如果需要显式：

```bash
codex
```

不要第一版擅自覆盖用户 config。

---

## AUTO

优先：

```bash
codex --approve-for-me
```

若 capability probe 发现不存在：

```text
fallback → SAFE
```

不要静默 fallback 到 YOLO。

---

## YOLO

本机 0.153.4 无 `--yolo`，canonical 命令为完整写法：

```bash
codex --dangerously-bypass-approvals-and-sandbox
```

启动前必须通过：

```text
project_policy.check_yolo(cwd)
```

---

# 9. Phase 6 — Claude Adapter

## SAFE

不传 `--permission-mode`（本机 2.1.234 的 choices 中没有 default，
传了会直接报错；缺省即保留用户默认审批行为）：

```bash
claude
```

复杂规划可以：

```bash
claude --permission-mode plan
```

---

## AUTO

优先：

```bash
claude --permission-mode auto
```

如果当前 CLI/套餐不支持：

```bash
claude --permission-mode acceptEdits
```

Adapter 必须在 Runtime record 中记录：

```json
{
  "requested_mode": "auto",
  "effective_mode": "acceptEdits"
}
```

---

## YOLO

canonical（本机 2.1.234 支持）：

```bash
claude --permission-mode bypassPermissions
```

等价备选（本机同样存在）：

```bash
claude --dangerously-skip-permissions
```

canonical 由 capability probe 决定并记录；默认取 `--permission-mode bypassPermissions`。

不要把：

```text
dontAsk
```

映射为 YOLO。

---

# 10. Phase 7 — Trusted Project

建立命令：

```bash
ag-policy
```

建议子命令：

```bash
ag-policy show
ag-policy trust
ag-policy protect
ag-policy untrust
ag-policy set-mode auto
ag-policy set-mode yolo
ag-policy set-mode safe
```

例如：

```bash
cd /Volumes/ORICO/Projects/claude-worker-router
ag-policy trust
ag-policy set-mode yolo
```

结果：

```json
{
  "/Volumes/ORICO/Projects/claude-worker-router": {
    "trust": "trusted",
    "autonomy": {
      "codex": "yolo",
      "claude": "yolo"
    }
  }
}
```

这是一次性项目策略，不要求每次启动确认。

本机补充规则（外置盘保护）：

```text
ag-policy 任何写操作/清理前必须 test -d /Volumes/ORICO
不可达（外置盘未挂载）时只提示，禁止清理任何 trust 记录
YOLO gate 遇 realpath 失败的路径一律 fail-safe 到 SAFE
```

---

# 11. YOLO Gate

函数：

```text
check_yolo(cwd)
```

检查顺序：

```text
1. cwd realpath
2. 是否命中 protected root
3. 是否存在 Git root
4. 项目 root 是否登记
5. trust 是否 trusted
6. provider 是否允许 YOLO
```

通过：

```text
ALLOW_YOLO
```

否则：

```text
fallback AUTO / SAFE
```

不建议第一版通过交互弹窗解决。

如果用户要改变行为，应通过：

```bash
ag-policy
```

提前修改项目策略。

---

# 12. Phase 8 — Launcher

不要让用户直接记：

```text
codex --approve-for-me
claude --permission-mode ...
```

统一：

```bash
ag-run
```

示例：

```bash
ag-run codex
ag-run claude
ag-run codex --mode yolo
ag-run claude --mode auto
```

运行逻辑：

```text
cwd
 ↓
find project root
 ↓
load project policy
 ↓
resolve mode
 ↓
provider capability
 ↓
build command
 ↓
tmux
 ↓
write runtime-state
```

---

# 13. tmux 约束

v2.4 不重新发明 tmux naming。

本机 tmux 3.7c 注意事项：

```text
display-message 查询会话必须用 "=会话名:" 写法（"=会话名" 会静默返回空值）
set-option -p（pane 级 option）已在 3.7c 实测可用（"会话:窗口.pane" 与 pane id 两种目标写法均通过）
gum 菜单一律 2>/dev/tty 渲染（2>/dev/null 会黑屏）
```

必须：

```text
读取 v2.3 现有 session 命名
```

Provider launcher 只添加 metadata。

可选：

```bash
tmux set-option -p @ag_provider codex
tmux set-option -p @ag_mode yolo
tmux set-option -p @ag_project "$PROJECT_ID"
tmux set-option -p @ag_runtime_id "$RUNTIME_ID"
```

如果未来获得真实 Provider session ID：

```bash
tmux set-option -p @ag_provider_session_id "$SESSION_ID"
```

这正是 Agent CLI Farm 值得吸收的部分。

---

# 14. Phase 9 — Runtime State Record

`runtime-state.json` 结构：

```json
{
  "runtimes": {
    "rt-20260907-001": {
      "provider": "codex",
      "project": "AI",
      "cwd": "/Volumes/ORICO/AI",
      "tmux_session": "AI",
      "mode": "yolo",
      "state": "RUNNING",
      "pid": 12345,
      "provider_session_id": null,
      "started_at": "...",
      "last_event_at": "...",
      "last_output_at": "...",
      "updated_at": "..."
    }
  }
}
```

写文件要求：

```text
temp file
fsync
atomic rename
```

避免并发损坏 JSON。

---

# 15. Phase 10 — Codex Runtime Collector

第一版：

```text
tmux
+
process
+
~/.codex/sessions JSONL
```

映射：

```text
session file持续增长 → RUNNING
用户输入请求事件 → WAITING_USER
approval event → WAITING_APPROVAL
正常 turn end → IDLE/COMPLETED
process exit 0 → COMPLETED
process exit non-zero → FAILED
```

第二阶段：

```text
研究 codex-agents 的 app-server 实现
```

目标最终变成：

```text
app-server → primary
JSONL      → fallback
tmux       → fallback
process    → fallback
```

---

# 16. Phase 11 — Claude Runtime Collector

Claude 不照抄 Codex parser。

优先：

```text
hooks
+
process
+
session activity
```

Hook 尽量使用当前稳定事件：

```text
SessionStart
PreToolUse
PostToolUse
PermissionRequest
Stop
```

不要把：

```text
Notification:permission_prompt
```

作为唯一依据，因为不同 Claude Code 版本/surface 曾出现不触发问题。

本机现状：~/.claude/settings.json 已有 4 类 hooks（cross-agent-memory 与
agent-workstation 的 done/permission/question），因此：

```text
优先消费现有 agent-workstation 事件记录，够用就不新增 hook
不足处才增量合并 hooks（只追加，绝不覆盖/删除已有条目）
新增 hook 只调用 ag-runtime-event 写事件管线，不直接发通知
第一版稳定集合：SessionStart / Stop(追加) / PostToolUse / Notification(追加)
PermissionRequest 事件先探测本版本是否支持再决定是否挂
```

Hook 调用：

```bash
ag-runtime-event claude <event>
```

stdin JSON 原样存入临时 event pipeline。

---

# 17. Claude settings 修改要求

修改：

```text
~/.claude/settings.json
```

本机该文件已有 hooks 与 MiniMax 中转 env 配置，只能合并、不能覆盖。

前必须：

```bash
cp
jq validation
```

流程：

```text
read existing JSON
merge hooks
write temp
jq empty temp
atomic replace
```

禁止：

```bash
cat > ~/.claude/settings.json
```

因为会覆盖用户已有设置。

Hook 配置修改后再执行：

```bash
jq empty ~/.claude/settings.json
```

并做一次真实 Claude CLI smoke test。

---

# 18. Phase 12 — State Engine

输入：

```text
provider events
session mtime
tmux
PID
hooks
tool start/end
```

输出：

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

原则：

```text
explicit event > heuristic
```

例如：

```text
PermissionRequest
```

直接：

```text
WAITING_APPROVAL
```

不能被单纯的 process alive 覆盖成 RUNNING。

---

# 19. Phase 13 — STALLED / STUCK

建议配置：

```json
{
  "stalled_seconds": 300,
  "stuck_seconds": 900
}
```

不能仅看：

```text
JSONL mtime
```

至少结合：

```text
last event
tmux output
process activity
tool duration
```

长时间 build/test：

```text
RUNNING_LONG
```

内部可以作为 reason，不必成为正式状态。

---

# 20. Phase 14 — Usage Collector

先不部署额外数据库。

```text
usage-history.jsonl
```

每次 snapshot：

```json
{"time":"...","provider":"codex","short_limit":71,"weekly_limit":54}
```

本机注记：Claude 走 MiniMax 中转，官方 5h/weekly quota 拿不到，
claude 的 short_limit/weekly_limit 允许为 null，不得视为故障。

保留最近：

```text
30 天
```

低额度规则：

```text
25% → warning
10% → critical
```

通知去重：

```text
同一窗口同一阈值只提醒一次
```

---

# 21. Phase 15 — Notification

统一命令：

```bash
ag-notify EVENT RUNTIME_ID
```

本机落地方式：ag-notify 内部桥接现有 `agent-notify emit`（ntfy → Windows PWA），
不新增第二套通知通道。事件映射：

```text
WAITING_USER      → agent-notify question
WAITING_APPROVAL  → agent-notify permission
COMPLETED         → agent-notify done
FAILED            → agent-notify failed
STALLED / STUCK   → agent-notify interrupted
LOW_QUOTA         → 第一版仅记日志 + 菜单标注（agent-notify 无对应事件）
```

事件：

```text
WAITING_USER
WAITING_APPROVAL
COMPLETED
FAILED
STALLED
STUCK
LOW_QUOTA
ORPHANED
```

继续接现有 Mac → Windows 通知体系。

不要增加第二套通知 daemon。

---

# 22. Phase 16 — Worker Router

在 Worker 创建 worktree 后：

```text
provider
mode=yolo
worker=true
```

传入 ag：

```bash
ag-run codex --worker
```

或：

```bash
ag-run claude --worker
```

解析：

```text
worker
→ default = yolo
```

前提：

```text
worktree exists
git root exists
project trusted
```

如果不满足：

```text
worker launch fail closed
```

而不是偷偷改为 host root YOLO。

---

# 23. Worker Evidence

YOLO 不能替代验证。

Worker 完成必须输出：

```text
base SHA
branch
changed files
git diff --stat
test command
test result
lint result
evidence
integration readiness
```

与现有 Worker Router hardening 路线保持一致。

---

# 24. Phase 17 — ag 主菜单修改

原菜单不删除，只增量增加。

本机 ag v2.3.2 为五入口 gum 分层菜单（Agent / 项目 / 开发 / 工作台 / 辅助），
因此不重排主菜单，改为增量嵌入：

```text
Agent 子菜单   「Codex 新任务 / Claude 新任务」条目后缀显示默认模式（AUTO/SAFE）
              启动前经 resolver 取模式并过 YOLO gate
工作台子菜单   增量追加：Runtime 监控 / Usage / Project Policy / Runtime 诊断
              （批次 C 再追加 Agent Monitor / Trace）
```

所有 gum 菜单一律 `2>/dev/tty` 渲染。

---

# 25. Session 列表

增加列：

```text
Provider
Mode
State
Reason
Last Activity
```

例如：

```text
ag               Codex   YOLO  RUNNING          tool:exec     14s
docchunk         Codex   AUTO  WAITING_USER     question      2m
worker-router    Claude  YOLO  RUNNING          Bash          8s
audit            Codex   AUTO  STUCK            silent 18m    18m
```

---

# 26. Phase 18 — Doctor

新增：

```bash
ag doctor
```

检查：

```text
ag binary
registry
runtime-policy
runtime-state
tmux
Codex version
Codex capability
Claude version
Claude capability
hooks
JSON validity
protected roots
project trust
notification
abtop
codex-dash
codex-trace
CodexBar
```

输出：

```text
PASS
WARN
FAIL
```

不要自动修复危险问题。

可以提供：

```text
ag doctor --fix-safe
```

仅修：

- 缺目录；
- 文件权限；
- JSON 格式化；
- 缺少空状态文件。

---

# 27. Phase 19 — 安装 abtop

abtop 是第一优先级第三方实际部署工具。

本机注记：cargo 不存在，必须走预编译 release 安装方式；
`~/src` 不存在，先 `mkdir -p ~/src`。

推荐先查看 release/install 内容，再安装。

官方 README 当前提供：

```bash
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/graykode/abtop/releases/latest/download/abtop-installer.sh | sh
```

更审慎的部署方式：

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/graykode/abtop.git
cd abtop
```

先审查：

```text
README
Cargo.toml
installer
release
```

再执行安装。

验收：

```bash
abtop
```

必须：

- 能看到 Codex；
- 能看到 Claude；
- 不修改 ag；
- 不修改 tmux；
- 退出后 Agent 不受影响。

ag 增加：

```text
[A] Agent Monitor → abtop
```

---

# 28. Phase 20 — 安装 CodexBar

macOS 当前可：

```bash
brew install --cask codexbar
```

如 Homebrew formula 变化，按上游 README 为准。

本机注记：先 `brew search codexbar` 确认 cask 存在再安装；
Claude 走 MiniMax 中转，CodexBar 的 Claude 官方额度可能显示 N/A，属预期。

安装后：

```text
Settings
→ Providers
→ 启用 Codex
→ 启用 Claude
```

目标：

```text
Mac 菜单栏长期显示额度
```

不允许 CodexBar 成为 ag usage 的唯一 Source。

---

# 29. Phase 21 — 安装 codex-dash

安装：

```bash
pipx install git+https://github.com/ArnabCodes/codex-dash.git
```

本机实测：pipx 未安装、uv 已装，直接确定用 uv tool，不新增 pipx：

```bash
uv tool install git+https://github.com/ArnabCodes/codex-dash.git
```

安装后：

```bash
codex-dash refresh
codex-dash
```

第一阶段禁止使用：

```bash
codex-dash launch ...
```

因为 ag 仍然是 launcher。

只使用：

```text
refresh
dashboard
list
open
```

等只读/导航能力。

---

# 30. Phase 22 — 安装 codex-trace

推荐优先 Docker 只读验证：

```bash
git clone https://github.com/PixelPaw-Labs/codex-trace.git ~/src/codex-trace
cd ~/src/codex-trace

docker build -t codex-trace .

docker run --rm \
  -p 127.0.0.1:1422:1422 \
  -v "$HOME/.codex/sessions:/home/app/.codex/sessions:ro" \
  codex-trace
```

注意：

上游近期 README 中 Web 默认端口描述存在版本变化，因此启动后以实际日志为准，不硬编码假定。

如果长期使用，再考虑：

```text
Tauri macOS App
```

ag：

```text
[T] Trace
```

第一版可简单：

```text
open local trace app / URL
```

---

# 31. 暂不安装 codex-hud

原因：

当前 codex-hud installer 会包装：

```text
codex
cx
tmux
```

与你已有：

```text
ag
tmux
launcher
```

存在明显重叠。

因此：

```text
只 clone/read
不执行 installer
```

重点吸收：

- HUD layout；
- context；
- tool activity；
- multi-session overview。

未来如果试验：

```text
isolated shell
临时 PATH
单独 tmux socket
```

不能直接污染主环境。

---

# 32. 暂不安装 Agent CLI Farm

只研究：

```text
session ID
pane metadata
save/restore
doctor
board
reboot recovery
```

不要让它创建生产 tmux session。

将其思想吸收到：

```text
ag Registry
```

---

# 33. 暂不安装 dmux

只研究：

```text
worktree lifecycle
pane model
merge
cleanup
hooks
```

对照：

```text
claude-worker-router
```

不同时运行两套 worktree orchestrator。

---

# 34. 暂不安装 amux

只研究：

```text
watchdog
stuck detector
fleet
auto continue
notification
```

YOLO 能力由 ag 自己实现。

---

# 35. 暂不安装 codex_stuck

将其状态检测思想吸收到：

```text
stuck.py
```

避免额外后台 monitor。

---

# 36. 暂不安装 Codex Usage Monitor

将：

```text
history
threshold
alert
```

吸收到：

```text
usage.py
usage-history.jsonl
```

避免额外 Web Dashboard。

---

# 37. Awesome Codex CLI 作为生态雷达

不需要安装。

建议增加：

```text
docs/upstream-radar.md
```

记录：

```text
Repository
Category
Last Reviewed
Potential Capability
Install?
Absorb?
Conflict?
```

每次升级 ag 前检查：

```text
Monitoring & Analytics
Session & Workflow Management
Shell & Terminal
Remote Access
Hooks
Skills
```

---

# 38. 测试矩阵

## T01 — 旧 ag

```text
ag
```

必须正常。

---

## T02 — Codex AUTO

Trusted 普通项目：

```text
ag → Codex
```

验证实际命令：

```text
--approve-for-me
```

普通文件编辑不再频繁要求人工确认。

---

## T03 — Codex YOLO

Trusted repo：

```text
mode=yolo
```

验证：

```text
codex --dangerously-bypass-approvals-and-sandbox
```

---

## T04 — YOLO 保护

在：

```text
$HOME
~/.ssh
/System
```

尝试 YOLO。

预期：

```text
禁止或降级
```

---

## T05 — Claude AUTO

验证：

```text
auto
```

支持则使用。

不支持：

```text
acceptEdits
```

并记录 effective mode。

---

## T06 — Claude YOLO

Trusted repo。

验证：

```text
bypassPermissions
```

实际生效。

---

## T07 — Worker

```text
worktree
→ provider
→ yolo
→ test
→ evidence
```

全过程不反复等待 approval。

---

## T08 — Runtime State

人为触发：

```text
RUNNING
WAITING_USER
WAITING_APPROVAL
COMPLETED
FAILED
```

状态正确。

---

## T09 — STUCK

创建测试 Session：

```text
模拟 silent
```

验证：

```text
STALLED
→ STUCK
```

---

## T10 — Notification

触发：

```text
WAITING
DONE
FAILED
STUCK
```

Mac 通知正常。

---

## T11 — reboot

由用户择机手动重启 Mac（v2.4 事先把运行态落盘，重启后正确打 STALE/ORPHANED 标记）。

验证：

```text
v2.3 session 不损坏
v2.4 runtime 可重新扫描
```

不要求第一版自动恢复所有 Agent，但必须正确标记：

```text
STALE / ORPHANED
```

---

# 39. 回滚

必须生成：

```bash
ag-v2.4-rollback
```

最低能力：

```text
1. 停止 v2.4 runtime monitor
2. 恢复原 ag
3. 恢复原 ~/.claude/settings.json
4. 不删除历史 Session
5. 不删除 tmux session
6. runtime sidecar 改名保留
```

例如：

```text
~/.config/ag/runtime-policy.json
→ runtime-policy.json.disabled
```

而不是删除。

---

# 40. 日志

建议：

```text
~/.local/state/ag/
├── runtime.log
├── provider.log
├── notification.log
└── doctor.log
```

限制：

```text
不记录 prompt 全文
不记录 API Key
不记录 auth token
不记录敏感环境变量
```

---

# 41. 运行方式

第一版不急于引入 launchd daemon。

优先：

```text
ag 启动时 refresh
Session Center 打开时 refresh
5~10 秒轻量刷新
```

如果稳定后再考虑：

```text
launchd
```

常驻 Runtime collector。

避免 v2.4 第一阶段同时引入：

```text
新状态机
新 daemon
新数据库
新 GUI
```

过多变量。

---

# 42. 建议实施批次

## 批次 A — 最小可用

```text
Sidecar
Policy
Codex Adapter
Claude Adapter
SAFE/AUTO/YOLO
ag launcher
Doctor
```

完成后先使用 2~3 天。

（修订注记：本次按用户指示连续推进批次 A→B→C→D，批次 E 延后；
风险由逐批次报告 + ag-v2.4-rollback 回滚脚本兜底。）

---

## 批次 B — Runtime

```text
Runtime state
Codex JSONL
Claude hooks
WAITING
DONE
STALLED/STUCK
Notification
```

---

## 批次 C — Observability

```text
abtop
CodexBar
codex-dash
codex-trace
```

---

## 批次 D — Worker

```text
worker-router
YOLO
worktree
evidence
review
```

---

## 批次 E — 深化

```text
Codex app-server
reboot recovery
usage forecast
external sandbox
```

---

# 43. Agent 实施要求

实施 Agent 每完成一个批次必须输出：

```text
Changed Files
Commands Executed
Config Diff
Tests
Observed Result
Known Issues
Rollback Command
```

不要只回复：

```text
部署完成
```

---

# 44. 最终验收命令

预期存在：

```bash
ag
ag doctor
ag-policy
ag-run codex
ag-run claude
ag-provider-doctor
ag-runtime-event
ag-notify
abtop
codex-dash
```

CodexBar：

```text
macOS menu bar
```

Trace：

```text
codex-trace App / local Web
```

---

# 45. 最终目标形态

```text
                       Mac mini
                          │
                         ag
                          │
             ┌────────────┼────────────┐
             │            │            │
          Registry       Policy      Runtime
             │            │            │
             │     SAFE/AUTO/YOLO      │
             │            │            │
             └────────────┼────────────┘
                          │
              ┌───────────┴───────────┐
              │                       │
           Codex                    Claude
              │                       │
              └───────────┬───────────┘
                          │
                        tmux
                          │
                 ┌────────┼─────────┐
                 │        │         │
               abtop  codex-dash  trace
                 │
              CodexBar
```

控制面只有：

```text
ag
```

监控面可以有多个，但都是旁路。

---

# 46. 参考仓库

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

# 47. 一句话实施原则

> **先把 Codex/Claude 的权限和运行状态统一收进 ag，再增加只读监控；不要为了一个新功能引入第二套 Session、tmux 或 Worktree 控制面。**

---

# 修订记录

## 2026-09-07 本机实测修订（v2.4.0-r1）

按 2026-09-07 对本机（macOS / ag v2.3.2 / codex 0.153.4 / claude 2.1.234 / tmux 3.7c）的只读探测修订：

1. 新增 §0「本机已核对事实」，全文冲突处以该节为准
2. §2 红线追加：禁止覆盖 ~/.codex/hooks.json
3. §5 sidecar 按本机 config/state 分离惯例拆分路径
4. §7 能力探测列表改为实测 flag（--yolo / --not-so-yolo 在 0.153.4 不存在）
5. §8 Codex YOLO canonical 改为 --dangerously-bypass-approvals-and-sandbox
6. §9 Claude SAFE 改为不传 --permission-mode（choices 无 default）；YOLO canonical 定为 bypassPermissions
7. §10 示例路径改 /Volumes/ORICO/Projects/，新增外置盘未挂载保护规则
8. §13 补 tmux 3.7c（display-message 用 "=名:" 写法）与 gum 2>/dev/tty 注意事项
9. §14 runtime-state 示例对齐本机项目/会话命名
10. §16/§17 hooks 合并策略明确（settings.json 已有 4 类 hooks）
11. §20 补 Claude quota 为 MiniMax 中转时允许 null 的注记
12. §21 ag-notify 落地为桥接现有 agent-notify（ntfy → Windows PWA），附事件映射表
13. §24 菜单修订对齐 v2.3.2 五入口 gum 分层菜单，不重排主菜单
14. §27/§28/§29 安装方式按本机包管理实况修订（pipx/cargo 不存在，用 uv/release）
15. §38 T03 验证命令同步修正；T11 改为用户择机重启；§42 批次 A 加推进注记；§44 验收命令补全
