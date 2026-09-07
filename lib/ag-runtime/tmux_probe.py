"""ag v2.4 runtime：tmux 探测（会话存活 + @ag_* 元数据）。"""

import subprocess

from . import config


def _run(argv):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=10)
        return p.returncode, (p.stdout or "").strip()
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def server_alive():
    code, _ = _run(["tmux", "list-sessions"])
    return code <= 1  # 0=有会话, 1=server 在但无会话, 127=无 tmux


def list_sessions():
    code, out = _run(["tmux", "list-sessions", "-F", "#{session_name}"])
    if code != 0:
        return []
    return [ln for ln in out.splitlines() if ln]


def session_option(session, option):
    # 注意 "-t" 与 "=%s:" 必须是两个 argv 元素（拼成一个会导致 tmux 按会话名查找
    # 带前导空格的目标而永远失败——tmux 3.7c 实测）
    code, out = _run(["tmux", "show-options", "-qv", "-t", "=%s:" % session, option])
    return out if code == 0 and out else None


def session_metadata(session):
    """返回 @ag_runtime_id/@ag_agent/@ag_launch_mode/@ag_project_path（可能为 None）。"""
    return {
        "runtime_id": session_option(session, "@ag_runtime_id"),
        "agent": session_option(session, "@ag_agent"),
        "launch_mode": session_option(session, "@ag_launch_mode"),
        "project_path": session_option(session, "@ag_project_path"),
    }


def session_alive(session):
    return session in list_sessions()


def pane_info(session):
    code, out = _run([
        "tmux", "list-panes", "-t", "=%s:0" % session,
        "-F", "#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}",
    ])
    if code != 0 or not out:
        return None
    parts = out.splitlines()[0].split("\t")
    try:
        pid = int(parts[0])
    except (IndexError, ValueError):
        pid = None
    return {
        "pid": pid,
        "command": parts[1] if len(parts) > 1 else "",
        "cwd": parts[2] if len(parts) > 2 else "",
    }


def set_session_option(session, option, value):
    _run(["tmux", "set-option", "-q", "-t", "=%s:" % session, option, value])


def state_home():
    return config.STATE_DIR
