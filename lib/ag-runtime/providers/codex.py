"""Codex adapter。本机 0.153.4 实测：
存在 --approve-for-me / --dangerously-bypass-approvals-and-sandbox /
-a on-request|never / -s read-only|workspace-write|danger-full-access；
--yolo 与 --not-so-yolo 已不存在。
"""

import json
import os
import time

from .base import ProviderAdapter, run_capture

SESSIONS_HOME = os.path.expanduser("~/.codex/sessions")

# safe: 保留默认审批策略；auto: 自动审批 + workspace-write；
# yolo: 跳过确认并取消 sandbox（必须过 ag gate）
MODE_ARGS = {
    "safe": [],
    "auto": ["--approve-for-me", "--sandbox", "workspace-write"],
    "yolo": ["--dangerously-bypass-approvals-and-sandbox"],
}


class CodexAdapter(ProviderAdapter):
    name = "codex"
    binary = "codex"

    def version(self):
        code, out, err = run_capture([self.binary, "--version"])
        return (out or err).strip().splitlines()[0] if code == 0 else None

    def probe(self):
        code, out, _ = run_capture([self.binary, "--help"])
        help_text = out if code == 0 else ""
        caps = {
            "version": self.version(),
            "approve_for_me": "--approve-for-me" in help_text,
            "bypass": "--dangerously-bypass-approvals-and-sandbox" in help_text,
            "ask_for_approval": "--ask-for-approval" in help_text,
            "sandbox_flag": "--sandbox" in help_text,
            "resume_subcommand": "resume" in help_text,
            "app_server_subcommand": "app-server" in help_text,
        }
        caps["modes"] = {
            "safe": True,
            "auto": caps["approve_for_me"],
            "yolo": caps["bypass"],
        }
        return caps

    def build_args(self, mode, caps):
        if mode == "auto":
            if caps.get("approve_for_me"):
                return MODE_ARGS["auto"], "auto"
            return MODE_ARGS["safe"], "safe"        # 降级 SAFE，不静默升档
        if mode == "yolo":
            if caps.get("bypass"):
                return MODE_ARGS["yolo"], "yolo"
            if caps.get("approve_for_me"):
                return MODE_ARGS["auto"], "auto(capability fallback)"
            return MODE_ARGS["safe"], "safe(capability fallback)"
        return MODE_ARGS.get(mode, MODE_ARGS["safe"]), mode

    def session_activity(self, cwd, since_hours=48):
        """Runtime collector（第一版 fallback 链：JSONL）。

        扫描近 N 小时的 rollout JSONL，按首行 session_meta.cwd 匹配项目，
        返回最新文件 {path, mtime, size}；无匹配返回 None。
        """
        now = time.time()
        best = None
        for root, _dirs, files in os.walk(SESSIONS_HOME):
            for fn in files:
                if not fn.endswith(".jsonl"):
                    continue
                path = os.path.join(root, fn)
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                if now - st.st_mtime > since_hours * 3600:
                    continue
                try:
                    with open(path, "r", encoding="utf-8") as f:
                        # session_meta 首行含完整 base_instructions，可能远超 4KB；
                        # 256KB 上限内截断只导致跳过该文件（不误判），不会崩溃
                        meta = json.loads(f.readline(262144)).get("payload", {})
                except (OSError, ValueError):
                    continue
                fcwd = (meta.get("cwd") or "").rstrip("/")
                target = (cwd or "").rstrip("/")
                if not target:
                    continue
                if fcwd == target or fcwd.startswith(target + "/") or target.startswith(fcwd + "/"):
                    if best is None or st.st_mtime > best["mtime"]:
                        best = {"path": path, "mtime": st.st_mtime, "size": st.st_size}
        return best
