"""Provider adapter 基类与工具。"""

import shutil
import subprocess


def run_capture(argv, timeout=30):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout or "", p.stderr or ""
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


class ProviderAdapter:
    name = "base"
    binary = None

    def available(self):
        return bool(shutil.which(self.binary))

    def version(self):
        raise NotImplementedError

    def probe(self):
        raise NotImplementedError

    def build_args(self, mode, caps):
        """返回 (argv, 实际生效档位标签)。能力不足时只降档、绝不静默升档。"""
        raise NotImplementedError

    def session_activity(self, cwd, since_hours=48):
        """会话文件活动信号（mtime/size）；无实现返回 None。"""
        return None
