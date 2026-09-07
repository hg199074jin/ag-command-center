# ag — Agent Command Center

**[中文文档](README.zh-CN.md)** | English

[![Platform](https://img.shields.io/badge/platform-macOS-blue)](https://github.com/hg199074jin/ag-command-center)
[![Shell](https://img.shields.io/badge/shell-bash%203.2%2B-green)](https://github.com/hg199074jin/ag-command-center)
[![Python](https://img.shields.io/badge/python-stdlib%20only-3776ab)](https://github.com/hg199074jin/ag-command-center)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow)](LICENSE)

**ag** is a single-command control plane for running AI coding agents — [OpenAI Codex CLI](https://github.com/openai/codex) and [Claude Code](https://claude.com/claude-code) — on a macOS workstation. It wraps tmux with layered menus, a project registry, a unified permission model, a runtime state machine, and read-only observability integrations.

> **Design principle:** ag is the *only* control plane. Third-party dashboards are read-only bystanders — delete any of them and ag keeps working.

```
                        Mac
                         │
                         ag
          ┌──────────────┼──────────────┐
       Registry        Policy        Runtime
          │       SAFE / AUTO / YOLO    │
          └──────────────┼──────────────┘
                 Codex  │  Claude
                        │  tmux
            ┌───────────┼───────────┐
          abtop      codex-dash   codex-trace   (read-only bystanders)
```

## Why

Running several agents across projects on one Mac quickly gets messy: Which tmux window is which agent? Why is it silent — thinking, waiting for approval, or stuck? Why does every file edit need a manual confirmation? ag answers all three:

- **Who** — project registry + session identity baked into tmux (survives restarts of the shell, not the server)
- **What state** — a runtime state machine that knows `RUNNING / WAITING_USER / WAITING_APPROVAL / STALLED / STUCK / ORPHANED`
- **How much freedom** — a three-level autonomy model with a fail-closed gate for the dangerous level

## Features

**Command Center TUI** (`ag`) — layered [gum](https://github.com/charmbracelet/gum) menus: 🤖 Agent / 📁 Projects / 🛠 Dev / 🖥 Workstation / 🧠 Assist. Launch Codex/Claude/Shell sessions in any project, resume, browse the session center, run diagnostics.

**SAFE / AUTO / YOLO autonomy** — one vocabulary across providers, mapped to real CLI flags per capability probe:

| ag level | Codex CLI (0.153.x) | Claude Code (2.1.x) |
|---|---|---|
| `SAFE` | default approvals | no `--permission-mode` |
| `AUTO` | `--approve-for-me --sandbox workspace-write` | `--permission-mode auto` |
| `YOLO` | `--dangerously-bypass-approvals-and-sandbox` | `--permission-mode bypassPermissions` |

Capability is **probed, not assumed** — `ag-provider-doctor` inspects `--help` output and writes what's actually supported; adapters only ever *downgrade* (e.g. `auto` → `acceptEdits`), never silently upgrade.

**YOLO gate (fail-closed)** — YOLO is allowed only when all of: cwd resolves outside protected roots (`/`, `$HOME`, `~/.ssh`, `~/.gnupg`, `~/.config`, `~/Library`, `/System`, `/Library`, `/private`, `/etc`), it's inside a git repo, the project is `trusted`, the provider isn't pinned lower, and the external volume (if any) is mounted. Anything ambiguous — including the gate tool itself being broken — downgrades to AUTO. Verified by code review with dedicated regression tests.

**Runtime state machine** — hooks and session-file collectors feed an event pipeline; explicit events (`question`, `permission`, `stop`) always beat heuristics. STALLED (5 min) needs multi-signal silence; STUCK (15 min) additionally requires the session file to be quiet too. State changes can fire notifications (bridged to whatever channel you already use — ntfy/Telegram/etc. via `agent-notify emit`, swappable in `notification.py`).

**Project registry** — one small atomic JSON per project (sha256-derived id), lifecycle `active/done`, tmux session identity (`@ag_project_id` / `@ag_agent` / `@ag_launch_mode` / `@ag_runtime_id`) so sessions survive ag restarts and never get mixed up.

**Doctor** — `ag doctor`: 20 read-only checks (binaries, registry JSON validity, tmux, provider versions & capabilities, hooks, protected roots, notification chain, observability tools). Exits 0/1/2 for health/warn/fail — script-friendly.

**Worker mode** — `ag-run claude --worker` requires a *linked git worktree* of a trusted project, or it refuses (exit 3). Never silently downgrades host-root YOLO.

**Read-only observability** — menu entries for [abtop](https://github.com/graykode/abtop) (agent htop), [CodexBar](https://github.com/steipete/CodexBar) (menu-bar quota; its CLI doubles as an optional usage data source), [codex-dash](https://github.com/ArnabCodes/codex-dash) and [codex-trace](https://github.com/PixelPaw-Labs/codex-trace). All optional; ag never depends on them.

## Install

Dependencies: macOS, bash 3.2+, [`tmux`](https://github.com/tmux/tmux), [`gum`](https://github.com/charmbracelet/gum), `jq`, python3 (3.9+, stdlib only). Optional: `yazi`, `fzf`, Codex CLI, Claude Code.

```bash
git clone https://github.com/hg199074jin/ag-command-center.git
cd ag-command-center
./install.sh          # backs up any existing files before overwriting
```

What it installs:

| From | To |
|---|---|
| `bin/*` | `~/.local/bin/` |
| `lib/ag-runtime/` | `~/.local/share/ag/runtime/` |

State lives in `~/.local/state/ag/` (registry, runtime, logs) and policy in `~/.config/ag/runtime-policy.json` — never in the repo.

## Quick start

```bash
ag                      # the menu
ag doctor               # full health check
ag-policy show          # what's trusted

cd ~/my-project
ag-policy trust         # one-time: mark project trusted
ag-policy set-mode yolo # optional: pin YOLO for this project
ag-run codex --mode yolo --dry-run   # see the exact command it would run
ag-run codex --mode yolo             # actually launch (foreground)
```

Uninstall / roll back: `ag-v2.4-rollback` restores the previous ag and renames sidecar files to `*.disabled` (keeps history).

## Commands

| Command | Purpose |
|---|---|
| `ag` | interactive menu (Agent / Projects / Dev / Workstation / Assist) |
| `ag status` / `ag session list` / `ag project list` | script-friendly overviews |
| `ag doctor` | read-only diagnostics, exit code 0/1/2 |
| `ag-policy show\|trust\|untrust\|protect\|set-mode` | project trust & autonomy |
| `ag-run <codex\|claude> [--mode s/a/y] [--worker] [--dry-run]` | unified launcher with gate |
| `ag-run gate <provider> --cwd DIR` | prints `ALLOW` / `DENY:<reason>` |
| `ag-run resolve <provider> --json` | full decision trace (requested vs effective) |
| `ag-run refresh` | rescan runtimes, update states, fire notifications |
| `ag-provider-doctor` | probe provider capabilities |
| `ag-runtime-event <provider> <event>` | hook entry point (always exits 0) |
| `ag-notify <EVENT> <RUNTIME_ID>` | notification bridge (deduped) |
| `ags` | quick tmux session switcher |

## Version history

| Version | Highlights |
|---|---|
| v2.1 | project launch, tmux identity, workstation menus |
| v2.2 | project registry + recent projects, external-volume fail-safe |
| v2.3.x | Command Center: session center, doctor, agentboard integration, atomic registry writes |
| **v2.4.0** | SAFE/AUTO/YOLO + capability probes, YOLO gate (fail-closed), runtime state machine, stuck detection, notification bridge, usage snapshots, worker mode, observability integrations; external code review closed 1 Critical / 4 Important findings |

Historical versions are kept under [`archive/`](archive/) for reference.

## Repository layout

```
bin/            ag + the ag-* command family (bash / python entries)
lib/ag-runtime/ the v2.4 runtime package (python stdlib only)
docs/           design & implementation docs for v2.4
archive/        historical ag versions (v2.2, v2.3)
install.sh      backup-aware installer
```

## Known limitations

- Codex usage numbers need CodexBar's CLI (no official scriptable endpoint yet); `codex app-server` integration is planned.
- Claude `Notification` hooks map to `WAITING_APPROVAL` without subtype parsing.
- Resumed sessions aren't re-registered into runtime-state (planned: re-associate via tmux `@ag_runtime_id`).

## License

[MIT](LICENSE) © hg199074jin
