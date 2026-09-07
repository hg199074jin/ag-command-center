"""ag v2.4 runtime：通知层。

桥接现有 agent-notify（ntfy.sh → Windows PWA），不新增第二套通知 daemon。
事件映射（实施方案 §21）：
  WAITING_USER → question；WAITING_APPROVAL → permission；
  COMPLETED → done；FAILED → failed；STALLED/STUCK → interrupted；
  LOW_QUOTA / ORPHANED → 仅记日志（agent-notify 无对应事件）。
去重：同一 runtime 同一事件只提醒一次（notification.json 记账）。
"""

import os
import shutil
import subprocess
import time

from . import config

EVENT_MAP = {
    "WAITING_USER": "question",
    "WAITING_APPROVAL": "permission",
    "COMPLETED": "done",
    "FAILED": "failed",
    "STALLED": "interrupted",
    "STUCK": "interrupted",
}

STRONG = {"FAILED", "STUCK"}
LOG_ONLY = {"LOW_QUOTA", "ORPHANED"}


def _load_dedup():
    data = config.load_json(config.NOTIFICATION_PATH) or {}
    if not isinstance(data, dict):
        return {}
    return data


def clear_for_runtime(rt_id, keep_event=None):
    """状态离开时清掉该 runtime 的旧事件去重账（保留当前状态的）。

    否则 24h 窗口会吞掉同一会话内后续真实的审批/等待请求。
    """
    dedup = _load_dedup()
    changed = False
    for key in [k for k in dedup
                if k.split(":", 1)[-1] == rt_id and k.split(":", 1)[0] != keep_event]:
        del dedup[key]
        changed = True
    if changed:
        config.save_json_atomic(config.NOTIFICATION_PATH, dedup)


def notify(event, rt_id, provider="", session="", summary="", dry_run=False, now_ts=None):
    """发一条通知。返回 (sent, skipped_reason_or_channel)。"""
    now_ts = now_ts or time.time()
    event = (event or "").upper()
    if event in LOG_ONLY:
        config.log("notify", "%s rt=%s → 仅记录日志" % (event, rt_id))
        return False, "log-only"

    dedup = _load_dedup()
    key = "%s:%s" % (event, rt_id)
    last = dedup.get(key, 0)
    if now_ts - last < 86400:  # 同一 runtime 同一事件 24h 内只提醒一次
        return False, "dedup"

    mapped = EVENT_MAP.get(event)
    if not mapped:
        return False, "unknown-event"

    if not shutil.which("agent-notify"):
        config.log("notify", "agent-notify 不在 PATH，丢弃 %s" % event)
        return False, "no-agent-notify"

    text = summary or ("[%s] %s" % (provider, event))
    argv = ["agent-notify", "emit", "--agent", provider or "codex",
            "--event", mapped, "--summary", text[:160]]
    if dry_run:
        argv.append("--no-push")

    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        ok = p.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        ok = False

    if ok:
        dedup[key] = now_ts
        # 清理 7 天前的去重记录，防膨胀
        dedup = {k: v for k, v in dedup.items() if now_ts - v < 7 * 86400}
        config.save_json_atomic(config.NOTIFICATION_PATH, dedup)
        config.log("notify", "%s rt=%s via agent-notify(%s)%s"
                   % (event, rt_id, mapped, " dry" if dry_run else ""))
        return True, "agent-notify"
    config.log("notify", "agent-notify 失败：%s（任务不受影响）" % event)
    return False, "emit-failed"
