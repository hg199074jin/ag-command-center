"""Claude adapter。本机 2.1.234 实测 --permission-mode choices：
acceptEdits, auto, bypassPermissions, manual, dontAsk, plan（无 default）。
"""

import os
import re
import time

from .base import ProviderAdapter, run_capture

PROJECTS_HOME = os.path.expanduser("~/.claude/projects")

# help 文本形如：(choices: "acceptEdits", "auto", ... "plan")——括号在 choices: 之前
CHOICES_RE = re.compile(
    r"--permission-mode\s*<mode>.*?choices:\s*([^)]*)\)", re.S
)


def _parse_choices(help_text):
    m = CHOICES_RE.search(help_text)
    if not m:
        return []
    return [c.strip().strip("\"'") for c in m.group(1).split(",") if c.strip()]


class ClaudeAdapter(ProviderAdapter):
    name = "claude"
    binary = "claude"

    def version(self):
        code, out, err = run_capture([self.binary, "--version"])
        return (out or err).strip().splitlines()[0] if code == 0 else None

    def probe(self):
        code, out, _ = run_capture([self.binary, "--help"])
        help_text = out if code == 0 else ""
        choices = _parse_choices(help_text)
        caps = {
            "version": self.version(),
            "permission_mode_flag": "--permission-mode" in help_text,
            "permission_mode_choices": choices,
            "dangerously_skip_permissions": "--dangerously-skip-permissions" in help_text,
        }
        caps["modes"] = {
            "safe": True,
            "auto": "auto" in choices or "acceptEdits" in choices,
            "yolo": "bypassPermissions" in choices or caps["dangerously_skip_permissions"],
        }
        return caps

    def build_args(self, mode, caps):
        choices = caps.get("permission_mode_choices") or []
        if mode == "safe":
            return [], "safe"
        if mode == "auto":
            # requested auto → effective 记录实际生效（可能降为 acceptEdits）
            if "auto" in choices:
                return ["--permission-mode", "auto"], "auto"
            if "acceptEdits" in choices:
                return ["--permission-mode", "acceptEdits"], "auto(acceptEdits)"
            return [], "safe(capability fallback)"
        if mode == "yolo":
            if "bypassPermissions" in choices:
                return ["--permission-mode", "bypassPermissions"], "yolo"
            if caps.get("dangerously_skip_permissions"):
                return ["--dangerously-skip-permissions"], "yolo(--dangerously-skip-permissions)"
            return self.build_args("auto", caps)
        return [], "safe"

    def session_activity(self, cwd, since_hours=48):
        """Claude 采集（v1：projects 目录下会话 JSONL 的 mtime）。"""
        slug = (cwd or "").rstrip("/").replace("/", "-")
        d = os.path.join(PROJECTS_HOME, slug)
        now = time.time()
        best = None
        try:
            names = os.listdir(d)
        except OSError:
            return None
        for fn in names:
            if not fn.endswith(".jsonl"):
                continue
            path = os.path.join(d, fn)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if now - st.st_mtime > since_hours * 3600:
                continue
            if best is None or st.st_mtime > best["mtime"]:
                best = {"path": path, "mtime": st.st_mtime, "size": st.st_size}
        return best
