"""ag v2.4 runtime：状态引擎。

原则：explicit event > heuristic。
PermissionRequest/permission 事件直接 WAITING_APPROVAL，
不能被 process alive 覆盖成 RUNNING。
"""

import json
import os
import time
from datetime import datetime

from . import config, stuck as _stuck, tmux_probe

STATES = (
    "STARTING", "RUNNING", "WAITING_USER", "WAITING_APPROVAL", "IDLE",
    "STALLED", "STUCK", "COMPLETED", "FAILED", "DETACHED",
    "ORPHANED", "STALE", "UNKNOWN",
)

# hook 事件 → 状态（explicit）
EVENT_STATE = {
    "question": "WAITING_USER",
    "permission": "WAITING_APPROVAL",
    "notification": "WAITING_APPROVAL",
    "stop": "IDLE",
    "session_start": "RUNNING",
    "post_tool_use": "RUNNING",
    "pre_tool_use": "RUNNING",
}

EVENTS_DIR = os.path.join(config.RUNTIME_DIR, "events")


def parse_ts(value):
    """ISO 字符串 → epoch 秒；解析失败返回 None。"""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value).timestamp()
    except (ValueError, TypeError, OSError):
        return None


def events_path(rt_id):
    return os.path.join(EVENTS_DIR, "%s.jsonl" % rt_id)


def append_event(rt_id, payload):
    """事件管线：hook/collector 追加一行 JSON，原样保留最小字段。"""
    os.makedirs(EVENTS_DIR, exist_ok=True)
    record = {
        "time": config.now_iso(),
        "ts": time.time(),
    }
    record.update(payload)
    path = events_path(rt_id)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    try:
        os.chmod(path, 0o600)  # 与其他 state 文件权限一致
    except OSError:
        pass


def latest_event(rt_id):
    path = events_path(rt_id)
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return None
    for ln in reversed(lines):
        ln = ln.strip()
        if not ln:
            continue
        try:
            return json.loads(ln)
        except ValueError:
            continue
    return None


def compute_state(entry, now_ts=None, thresholds=(300, 900), session_alive=None):
    """输入 runtime entry + 信号，输出 (state, reason)。

    优先级：tmux 失联(ORPHANED/STALE) > explicit event > 文件活动 > 静默启发。
    """
    now_ts = now_ts or time.time()
    stalled_s, stuck_s = thresholds
    provider = entry.get("provider")

    # 1) tmux 会话失联
    if session_alive is None:
        session_alive = tmux_probe.session_alive(entry.get("tmux_session") or "")
    if not session_alive:
        last = parse_ts(entry.get("last_event_at")) or parse_ts(entry.get("updated_at")) or 0
        if now_ts - last > 86400:
            return "STALE", "tmux 会话不存在且超过 24h 无活动"
        return "ORPHANED", "tmux 会话不存在"

    # 2) explicit event（在 stalled 窗口内才有效，过期回退启发式）
    ev = latest_event(entry.get("rt_id") or "")
    if ev:
        ev_ts = ev.get("ts") or parse_ts(ev.get("time")) or 0
        if now_ts - ev_ts <= stalled_s:
            state = EVENT_STATE.get(ev.get("event"))
            if state:
                return state, "event:%s" % ev.get("event")

    # 3) 会话文件活动（provider collector 提供 mtime）
    mtime = entry.get("_session_file_mtime")
    if mtime and (now_ts - mtime) < 60:
        return "RUNNING", "session file active"

    # 4) 静默启发（多信号：last_output 与文件 mtime 都静默才算卡）
    last_out = parse_ts(entry.get("last_output_at")) or parse_ts(entry.get("updated_at")) or now_ts
    silence = now_ts - last_out
    file_silent = not mtime or (now_ts - mtime) >= stalled_s
    verdict = _stuck.stuck_verdict(
        {"silence_s": silence, "file_silent": file_silent, "process_alive": True},
        stalled_s, stuck_s)
    if verdict:
        return verdict, "silent %dm%s" % (int(silence // 60), "（多信号）" if verdict == "STUCK" else "")
    if entry.get("state") in ("COMPLETED", "FAILED", "STALE"):
        return entry["state"], "保持终态"
    return "RUNNING", "近期有活动"


def apply_transition(entry, new_state, reason, now_ts=None):
    """返回 (changed, notify_event)；更新 entry 字段。"""
    now_ts = now_ts or time.time()
    old = entry.get("state")
    notify = None
    if new_state in ("WAITING_USER",):
        notify = "WAITING_USER"
    elif new_state in ("WAITING_APPROVAL",):
        notify = "WAITING_APPROVAL"
    elif new_state == "STUCK":
        notify = "STUCK"
    elif new_state == "STALLED":
        notify = "STALLED"
    elif new_state == "COMPLETED" and old not in ("COMPLETED",):
        notify = "COMPLETED"
    elif new_state == "FAILED" and old not in ("FAILED",):
        notify = "FAILED"
    entry["state"] = new_state
    entry["reason"] = reason
    entry["updated_at"] = config.now_iso()
    if new_state == "RUNNING":
        entry["last_event_at"] = entry["updated_at"]
        entry["last_output_at"] = entry["updated_at"]
    return old != new_state, notify
