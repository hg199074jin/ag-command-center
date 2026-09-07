"""ag v2.4 runtime：进程探测。"""

import os
import subprocess


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def child_pids(pid):
    if not pid:
        return []
    try:
        p = subprocess.run(["pgrep", "-P", str(int(pid))],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return []
    out = []
    for ln in (p.stdout or "").split():
        try:
            out.append(int(ln))
        except ValueError:
            continue
    return out


def process_summary(pid):
    """返回 {alive, children}。"""
    return {"alive": pid_alive(pid), "children": child_pids(pid)}
