"""ag v2.4 runtime CLI。

入口包装：ag-run / ag-provider-doctor（见 ~/.local/bin）。
子命令：run / resolve / gate / record-launch / doctor / probe。
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

_SHARE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _SHARE not in sys.path:
    sys.path.insert(0, _SHARE)

from runtime import config, project_policy  # noqa: E402
from runtime import notification, state_engine, stuck, tmux_probe, usage  # noqa: E402
from runtime.providers import get_adapter  # noqa: E402


def resolve_full(provider, requested, cwd, worker=False):
    """策略解析 + provider 能力 → 最终 argv。provider 缺失时 error=provider-missing。"""
    decision = project_policy.resolve_mode(provider, requested, cwd, worker)
    adapter = get_adapter(provider)
    if adapter is None or not adapter.available():
        decision["args"] = []
        decision["effective"] = None
        decision["reason"] = (decision.get("reason", "") + "；%s 不可用" % provider).strip("；")
        decision["error"] = "provider-missing"
        return decision

    caps_all = config.load_json(config.CAPABILITIES_PATH, {}) or {}
    caps = caps_all.get(provider) or {}
    decision["capabilities_stale"] = not caps  # 未探测过 → 用 adapter 兜底并提示
    mode = decision.get("effective")
    if mode in ("safe", "auto", "yolo"):
        argv, effective = adapter.build_args(mode, caps)
        decision["args"] = argv
        decision["effective_mode_by_caps"] = effective
    else:
        decision["args"] = []
    return decision


def _fmt_decision(d):
    lines = [
        "provider    : %s" % d["provider"],
        "cwd         : %s" % d["cwd"],
        "project root: %s" % d["root"],
        "trust       : %s" % d["trust"],
        "requested   : %s" % (d["requested"] or "(默认)"),
        "effective   : %s" % (d.get("effective_mode_by_caps") or d.get("effective") or "-"),
        "args        : %s" % (" ".join(d.get("args") or []) or "(无)"),
        "reason      : %s" % (d.get("reason") or "-"),
    ]
    if d.get("worker"):
        lines.append("worker      : yes (fail-closed)")
    return "\n".join(lines)


def cmd_resolve(args):
    d = resolve_full(args.provider, args.mode, args.cwd or os.getcwd(), args.worker)
    if args.json:
        print(json.dumps(d, ensure_ascii=False, indent=2))
    else:
        print(_fmt_decision(d))
    return 0 if not d.get("error") else 2


def cmd_gate(args):
    """stdout: ALLOW 或 DENY:<原因>；永远 exit 0，方便 shell $( ) 捕获。"""
    g = project_policy.check_yolo(args.cwd, args.provider)
    if g["allowed"]:
        print("ALLOW")
    else:
        print("DENY:%s" % g["reason"])
    return 0


def cmd_record_launch(args):
    policy = config.load_policy(create=False)  # 只读默认值参考，不落盘
    provider = args.provider
    mode = config.MODE_ALIASES.get(args.mode or "", args.mode or "safe")
    cwd = args.cwd or os.getcwd()
    root = project_policy.project_root_for(cwd)
    now = config.now_iso()

    with config.state_lock():  # 与 refresh 互斥
        state = config.load_json(config.STATE_PATH) or {}
        state.setdefault("version", 1)
        state.setdefault("runtimes", {})

        rt_id = "rt-%s-%04x" % (time.strftime("%Y%m%d-%H%M%S"), os.getpid() & 0xFFFF)
        entry = {
            "provider": provider,
            "project": os.path.basename(root) or root,
            "cwd": cwd,
            "tmux_session": args.session or "foreground",
            "mode": mode,
            "state": "RUNNING",
            "worker": bool(args.worker),
            "pid": args.pid,
            "provider_session_id": None,
            "started_at": now,
            "last_event_at": now,
            "last_output_at": now,
            "updated_at": now,
        }
        # 同 tmux 会话只保留最新记录，历史走 runtime.log
        state["runtimes"] = {
            k: v for k, v in state["runtimes"].items()
            if v.get("tmux_session") != entry["tmux_session"]
        }
        state["runtimes"][rt_id] = entry
        config.save_json_atomic(config.STATE_PATH, state)
    config.log("record", "launch provider=%s mode=%s session=%s root=%s"
               % (provider, mode, entry["tmux_session"], root))
    print(rt_id)
    return 0


def _is_git_worktree(path):
    """linked worktree 判定：.git 是文件，或 git-dir 位于 .../worktrees/ 下。"""
    dotgit = os.path.join(path, ".git")
    if os.path.isfile(dotgit):
        return True
    if not os.path.isdir(dotgit):
        return False
    try:
        p = subprocess.run(["git", "-C", path, "rev-parse", "--git-dir"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    gitdir = (p.stdout or "").strip()
    return bool(gitdir) and os.sep + "worktrees" + os.sep in os.path.realpath(gitdir)


def cmd_run(args):
    d = resolve_full(args.provider, args.mode, args.cwd or os.getcwd(), args.worker)
    if d.get("error") == "provider-missing":
        print("ag-run：%s" % d["reason"], file=sys.stderr)
        return 2
    if d.get("effective") is None:
        print("ag-run（fail closed）：%s" % d["reason"], file=sys.stderr)
        return 3
    cwd = d["cwd"]
    if args.worker:
        # Worker 红线（实施方案 §22）：必须在 linked git worktree 内，否则 fail closed，
        # 绝不在 host 仓库/host root 上跑 YOLO
        if not _is_git_worktree(cwd):
            print("ag-run（fail closed）：--worker 要求在 linked git worktree 内运行；"
                  "%s 不是 worktree" % cwd, file=sys.stderr)
            return 3

    argv = [d["provider"]] + (d.get("args") or []) + list(args.pass_through)
    if args.dry_run:
        print(" ".join(argv))
        return 0
    # 策略按 --cwd 评估，执行目录必须与评估目录一致（否则 YOLO 作用在未评估的目录上）
    try:
        os.chdir(cwd)
    except OSError as exc:
        print("ag-run：无法进入 %s（%s）" % (cwd, exc), file=sys.stderr)
        return 2
    config.log("run", "%sexec %s (effective=%s cwd=%s)"
               % ("worker " if args.worker else "", " ".join(argv),
                  d.get("effective_mode_by_caps"), cwd))
    os.execvp(argv[0], argv)
    return 0  # pragma: no cover


def _check(name, status, detail=""):
    return {"name": name, "status": status, "detail": detail}


def cmd_doctor(args):
    checks = []
    json_paths = [
        ("runtime-policy", config.POLICY_PATH),
        ("runtime-state", config.STATE_PATH),
        ("provider-capabilities", config.CAPABILITIES_PATH),
        ("notification", config.NOTIFICATION_PATH),
    ]
    for label, path in json_paths:
        if not os.path.exists(path):
            checks.append(_check(label, "WARN", "缺少 %s（--fix-safe 可补空文件）" % path))
            continue
        if config.load_json(path) is None:
            checks.append(_check(label, "FAIL", "JSON 无法解析：%s" % path))
        else:
            checks.append(_check(label, "PASS", path))

    # registry（v2.3）
    reg_dir = os.path.join(config.STATE_DIR, "projects")
    if os.path.isdir(reg_dir):
        bad = []
        for fn in os.listdir(reg_dir):
            if fn.endswith(".json") and config.load_json(os.path.join(reg_dir, fn)) is None:
                bad.append(fn)
        checks.append(_check("ag registry", "FAIL" if bad else "PASS",
                             "损坏: %s" % ",".join(bad) if bad else reg_dir))
    else:
        checks.append(_check("ag registry", "WARN", "目录不存在：%s" % reg_dir))

    # tmux（0=有会话；1=server 在但无会话；其他=不可达）
    tmux_bin = shutil.which("tmux")
    if not tmux_bin:
        checks.append(_check("tmux", "FAIL", "找不到 tmux"))
    else:
        try:
            p = subprocess.run(["tmux", "list-sessions"],
                               capture_output=True, text=True, timeout=10)
            if p.returncode in (0, 1):
                n = len([ln for ln in (p.stdout or "").splitlines() if ln.strip()])
                detail = "server 可达（%d 会话）" % n if p.returncode == 0 else "server 可达（无会话）"
                checks.append(_check("tmux", "PASS", detail))
            else:
                checks.append(_check("tmux", "FAIL", "tmux server 不可达（rc=%d）" % p.returncode))
        except (OSError, subprocess.TimeoutExpired):
            checks.append(_check("tmux", "FAIL", "tmux 探测超时"))

    # providers
    caps_all = config.load_json(config.CAPABILITIES_PATH, {}) or {}
    for name in ("codex", "claude"):
        adapter = get_adapter(name)
        if not adapter or not adapter.available():
            checks.append(_check(name, "FAIL", "%s 不在 PATH" % name))
            continue
        caps = caps_all.get(name) or {}
        if not caps:
            checks.append(_check(name, "WARN", "未探测能力，建议运行 ag-provider-doctor"))
        else:
            modes = caps.get("modes") or {}
            checks.append(_check(name, "PASS", "%s 支持: %s" % (
                caps.get("version") or "?",
                ",".join(m for m, ok in sorted(modes.items()) if ok))))

    # claude settings hooks（只读检查，不修改）
    settings = config.load_json(os.path.join(config.HOME, ".claude", "settings.json"))
    if settings is None:
        checks.append(_check("claude settings.json", "WARN", "不存在或非 JSON"))
    elif isinstance(settings, dict) and settings.get("hooks"):
        checks.append(_check("claude settings.json", "PASS",
                             "已有 %d 类 hooks（合并时不可覆盖）" % len(settings["hooks"])))
    else:
        checks.append(_check("claude settings.json", "WARN", "没有 hooks 配置"))

    # 通知链
    checks.append(_check("agent-notify", "PASS" if shutil.which("agent-notify") else "WARN",
                         "ntfy 通知桥" if shutil.which("agent-notify") else "不在 PATH"))

    # v2.4 命令
    for binname in ("ag-run", "ag-policy", "ag-provider-doctor"):
        checks.append(_check(binname, "PASS" if shutil.which(binname) else "FAIL",
                             shutil.which(binname) or "不在 PATH"))

    # 项目 trust 概览（doctor 只读：不创建/回填策略文件）
    policy = config.load_policy(create=False)
    projects = policy.get("projects", {})
    trusted = [p for p, v in projects.items() if v.get("trust") == "trusted"]
    checks.append(_check("protected roots", "PASS" if policy.get("protected_roots") else "FAIL",
                         "%d 条" % len(policy.get("protected_roots", []))))
    checks.append(_check("project trust", "PASS", "trusted: %s" % (", ".join(trusted) or "（无）")))

    # worker-router 与 ag 策略一致性（轻集成：只读检查，不改 router；路径可用
    # AG_WORKER_ROUTER_DIR 覆盖，未配置/不存在则跳过）
    router_cfg = os.environ.get(
        "AG_WORKER_ROUTER_DIR",
        "/Volumes/ORICO/Projects/claude-worker-router")
    router_cfg = os.path.join(router_cfg, "config.toml")
    if os.path.isfile(router_cfg):
        try:
            with open(router_cfg, "r", encoding="utf-8") as f:
                txt = f.read().lower()
        except OSError:
            txt = ""
        if "permissionmode" in txt.replace("_", "") or "permission-mode" in txt:
            checks.append(_check("worker-router", "WARN",
                                 "router 自带 permission-mode 配置——请确认仅对 trusted 项目启用 bypass"))
        else:
            checks.append(_check("worker-router", "PASS", "router 配置未发现 bypass 级权限"))
    else:
        checks.append(_check("worker-router", "PASS", "未配置 router（config.toml 不存在，跳过）"))

    # 第三方可观测工具（缺失只 WARN）
    for tool in ("abtop", "codex-dash", "codexbar"):
        found = shutil.which(tool)
        if not found:
            app = os.path.join("/Applications", "CodexBar.app")
            found = app if tool == "codexbar" and os.path.isdir(app) else None
        checks.append(_check(tool, "PASS" if found else "WARN", found or "未安装（旁路工具，可后补）"))
    try:
        p = subprocess.run(["docker", "images", "-q", "codex-trace"],
                           capture_output=True, text=True, timeout=15)
        trace_ok = bool((p.stdout or "").strip())
    except (OSError, subprocess.TimeoutExpired):
        trace_ok = False
    checks.append(_check("codex-trace", "PASS" if trace_ok else "WARN",
                         "docker 镜像就绪" if trace_ok else "未构建（Docker 旁路，可后补）"))

    for c in checks:
        mark = {"PASS": "✅", "WARN": "⚠️ ", "FAIL": "❌"}[c["status"]]
        print("%s %-22s %-4s %s" % (mark, c["name"], c["status"], c["detail"]))

    fails = sum(1 for c in checks if c["status"] == "FAIL")
    warns = sum(1 for c in checks if c["status"] == "WARN")
    print()
    print("小结：%d PASS / %d WARN / %d FAIL" % (len(checks) - fails - warns, warns, fails))
    if args.fix_safe:
        config.ensure_dirs()
        for _, path in json_paths:
            if not os.path.exists(path):
                if path.endswith(".jsonl"):
                    open(path, "a", encoding="utf-8").close()
                else:
                    config.save_json_atomic(path, {"runtimes": {}} if "state" in path else {})
                print("已补空文件：%s" % path)
        return 0
    return 2 if fails else (1 if warns else 0)


def cmd_probe(args):
    caps = {"version": 1}
    overall = 0
    for name in ("codex", "claude"):
        adapter = get_adapter(name)
        entry = {"available": adapter.available() if adapter else False}
        if entry["available"]:
            entry.update(adapter.probe())
        entry["checked_at"] = config.now_iso()
        caps[name] = entry
        modes = entry.get("modes") or {}
        ok = ",".join(m for m, v in sorted(modes.items()) if v) or "无"
        mark = "✅" if entry["available"] else "❌"
        print("%s %-6s %-20s 支持档位: %s" % (mark, name, entry.get("version") or "?", ok))
        if not entry["available"]:
            overall = 1
    config.save_json_atomic(config.CAPABILITIES_PATH, caps)
    config.log("probe", "capabilities refreshed")
    return overall


def cmd_refresh(args):
    """扫描 runtime-state + tmux + provider 会话文件 → 刷新状态，按需通知。"""
    policy = config.load_policy()
    th = stuck.thresholds(policy)
    with config.state_lock():  # 与 record-launch 互斥，防读-改-写丢更新
        state = config.load_json(config.STATE_PATH) or {"version": 1, "runtimes": {}}
        runtimes = state.setdefault("runtimes", {})
        alive_sessions = set(tmux_probe.list_sessions())
        now_ts = time.time()
        scanned = 0
        dropped = []
        lines = []

        for rt_id in list(runtimes.keys()):
            entry = runtimes[rt_id]
            entry.setdefault("rt_id", rt_id)
            scanned += 1
            alive = entry.get("tmux_session") in alive_sessions
            adapter = get_adapter(entry.get("provider") or "")
            act = None
            if adapter and entry.get("cwd") and alive:
                try:
                    act = adapter.session_activity(entry["cwd"])
                except Exception as exc:  # collector 失败不影响状态机
                    config.log("refresh", "session_activity 失败 %s: %s" % (rt_id, exc))
            prev_size = entry.get("_session_file_size") or 0
            if act and act.get("size", 0) > prev_size:
                entry["last_output_at"] = config.now_iso()
            entry["_session_file_mtime"] = act.get("mtime") if act else None
            entry["_session_file_size"] = act.get("size") if act else prev_size

            new_state, reason = state_engine.compute_state(entry, now_ts, th, session_alive=alive)
            prev_state = entry.get("state")
            changed, notify_event = state_engine.apply_transition(entry, new_state, reason, now_ts)
            # 状态已离开 → 清掉旧事件的去重账，后续同类事件（如再次 WAITING）可重新提醒
            if changed and prev_state and prev_state != new_state:
                notification.clear_for_runtime(rt_id, keep_event=notify_event)
            usage.snapshot_if_due(entry.get("provider") or "codex", now_ts)
            if changed:
                config.log("state", "%s %s → %s（%s）" % (rt_id, prev_state, new_state, reason))
            if notify_event:
                notified, _why = notification.notify(
                    notify_event, rt_id,
                    provider=entry.get("provider") or "", session=entry.get("tmux_session") or "",
                    summary="%s %s（%s）" % (entry.get("tmux_session"), new_state, reason),
                    dry_run=args.dry_run)
                if notified and not args.quiet:
                    lines.append("🔔 %s → %s（已通知）" % (entry.get("tmux_session"), new_state))
            elif changed and not args.quiet:
                lines.append("%s → %s（%s）" % (entry.get("tmux_session"), new_state, reason))

            # GC：失联且 7 天未更新的记录不无限累积
            if entry.get("state") in ("ORPHANED", "STALE"):
                ts = state_engine.parse_ts(entry.get("updated_at")) or now_ts
                if now_ts - ts > 7 * 86400:
                    dropped.append("%s(%s)" % (entry.get("tmux_session"), rt_id))
                    del runtimes[rt_id]

        config.save_json_atomic(config.STATE_PATH, state)
    if not args.quiet:
        for ln in lines:
            print(ln)
        if dropped:
            print("GC：%d 条失联超 7 天的记录已清理（%s）" % (len(dropped), ", ".join(dropped)))
        print("refresh：扫描 %d 个 runtime" % scanned)
    return 0


def old_of(entry, new_state):
    # apply_transition 已把 state 覆盖为新值；这里只为日志语义兜底
    return entry.get("_prev_state") or "?"


def cmd_state_summary(args):
    """TSV：cwd → provider/mode/state（会话中心徽标用，state 为短标签）。"""
    state = config.load_json(config.STATE_PATH) or {}
    now = time.time()
    for entry in (state.get("runtimes") or {}).values():
        cwd = entry.get("cwd") or ""
        provider = entry.get("provider") or ""
        mode = MODE_LABEL.get(entry.get("mode") or "", (entry.get("mode") or "").upper())
        st = entry.get("state") or "UNKNOWN"
        # 会话失联且记录陈旧 → 直接以 STALE 展示，等 refresh 正式落盘
        if st in ("RUNNING", "WAITING_USER", "WAITING_APPROVAL"):
            ts = state_engine.parse_ts(entry.get("updated_at")) or 0
            if now - ts > 86400:
                st = "STALE"
        print("%s\t%s\t%s\t%s" % (cwd, provider, mode, STATE_SHORT.get(st, st)))
    return 0


STATE_SHORT = {
    "RUNNING": "RUN", "WAITING_USER": "INPUT", "WAITING_APPROVAL": "APPR",
    "IDLE": "IDLE", "STALLED": "STALL", "STUCK": "STUCK",
    "COMPLETED": "DONE", "FAILED": "FAIL", "ORPHANED": "ORPH",
    "STALE": "STALE", "STARTING": "START", "DETACHED": "DET", "UNKNOWN": "?",
}
PROVIDER_LABEL = {"codex": "Codex", "claude": "Claude"}
MODE_LABEL = {"safe": "SAFE", "auto": "AUTO", "yolo": "YOLO"}


def cmd_state_badge(args):
    """输出 'Codex·AUTO·RUN' 形式的徽标（cwd 最长前缀匹配）。"""
    state = config.load_json(config.STATE_PATH) or {}
    target = project_policy.canonical(args.cwd).rstrip("/")
    best, best_len = None, -1
    for entry in (state.get("runtimes") or {}).values():
        c = (entry.get("cwd") or "").rstrip("/")
        if c and (target == c or target.startswith(c + "/")) and len(c) > best_len:
            best, best_len = entry, len(c)
    if not best:
        return 0
    label = "%s·%s·%s" % (
        PROVIDER_LABEL.get(best.get("provider"), best.get("provider") or "?"),
        MODE_LABEL.get(best.get("mode"), (best.get("mode") or "?").upper()),
        STATE_SHORT.get(best.get("state"), "?"))
    print(label)
    return 0


def cmd_usage(_args):
    data = usage.summary()
    if not data:
        print("（暂无用量快照——refresh 时按小时自动采集）")
        return 0
    for provider in sorted(data):
        rec = data[provider]
        print("%-6s short=%s weekly=%s  @%s" % (
            provider, rec.get("short_limit"), rec.get("weekly_limit"), rec.get("time")))
    return 0


def cmd_notify(args):
    sent, why = notification.notify(
        args.event, args.runtime_id, provider=args.provider, session=args.session,
        summary=args.summary, dry_run=args.dry_run)
    print("sent=%s via=%s" % (sent, why))
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="ag-run", description="ag v2.4 runtime launcher")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("run", help="解析策略并启动 provider（前台）")
    sp.add_argument("provider", choices=["codex", "claude"])
    sp.add_argument("--mode", choices=["safe", "auto", "yolo", "standard", "assisted"])
    sp.add_argument("--cwd")
    sp.add_argument("--worker", action="store_true", help="worker 模式（默认 yolo，fail closed）")
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("pass_through", nargs="*", help="透传给 provider 的参数（放在 -- 之后）")
    sp.set_defaults(func=cmd_run)

    sp = sub.add_parser("resolve", help="只解析不启动")
    sp.add_argument("provider", choices=["codex", "claude"])
    sp.add_argument("--mode", choices=["safe", "auto", "yolo", "standard", "assisted"])
    sp.add_argument("--cwd")
    sp.add_argument("--worker", action="store_true")
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=cmd_resolve)

    sp = sub.add_parser("gate", help="YOLO gate（stdout: ALLOW / DENY:<原因>）")
    sp.add_argument("provider", choices=["codex", "claude"])
    sp.add_argument("--cwd")
    sp.add_argument("--mode", default="yolo")
    sp.set_defaults(func=cmd_gate)

    sp = sub.add_parser("record-launch", help="记录一次启动到 runtime-state.json")
    sp.add_argument("--provider", required=True, choices=["codex", "claude"])
    sp.add_argument("--mode", default="safe")
    sp.add_argument("--session", required=True)
    sp.add_argument("--cwd", required=True)
    sp.add_argument("--pid", type=int, default=None)
    sp.add_argument("--worker", action="store_true")
    sp.set_defaults(func=cmd_record_launch)

    sp = sub.add_parser("doctor", help="v2.4 只读诊断")
    sp.add_argument("--fix-safe", action="store_true", help="仅补缺目录/空状态文件")
    sp.set_defaults(func=cmd_doctor)

    sp = sub.add_parser("probe", help="探测 codex/claude 能力并写 provider-capabilities.json")
    sp.set_defaults(func=cmd_probe)

    sp = sub.add_parser("refresh", help="刷新 runtime 状态（tmux+JSONL+事件），按需通知")
    sp.add_argument("--quiet", action="store_true")
    sp.add_argument("--dry-run", action="store_true", help="通知只走 --no-push")
    sp.set_defaults(func=cmd_refresh)

    sp = sub.add_parser("state-summary", help="TSV：cwd/provider/mode/state")
    sp.set_defaults(func=cmd_state_summary)

    sp = sub.add_parser("state-badge", help="单项目徽标（cwd 最长前缀匹配）")
    sp.add_argument("--cwd", required=True)
    sp.set_defaults(func=cmd_state_badge)

    sp = sub.add_parser("usage", help="查看最近用量快照")
    sp.set_defaults(func=cmd_usage)

    sp = sub.add_parser("notify", help="发通知（桥接 agent-notify）")
    sp.add_argument("event")
    sp.add_argument("runtime_id")
    sp.add_argument("--provider", default="")
    sp.add_argument("--session", default="")
    sp.add_argument("--summary", default="")
    sp.add_argument("--dry-run", action="store_true")
    sp.set_defaults(func=cmd_notify)
    return p


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    # 文档用法：ag-run codex / ag-run claude --mode yolo（provider 直接跟在命令后）
    if argv and argv[0] in ("codex", "claude"):
        argv.insert(0, "run")
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


def main_probe(argv=None):
    return main(["probe"] + list(argv or []))
