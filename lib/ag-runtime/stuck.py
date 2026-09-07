"""ag v2.4 runtime：STALLED / STUCK 判定。

原则（设计文档 §11）：只有多个信号同时静默才标记 STUCK；
单一 mtime 静默不足以定罪。
"""

DEFAULT_STALLED = 300
DEFAULT_STUCK = 900


def thresholds(policy):
    th = (policy or {}).get("thresholds") or {}
    try:
        stalled = int(th.get("stalled_seconds", DEFAULT_STALLED))
    except (TypeError, ValueError):
        stalled = DEFAULT_STALLED
    try:
        stuck = int(th.get("stuck_seconds", DEFAULT_STUCK))
    except (TypeError, ValueError):
        stuck = DEFAULT_STUCK
    return stalled, stuck


def stuck_verdict(signals, stalled_s, stuck_s):
    """多信号综合：silence 超 stalled → STALLED candidate；
    超 stuck 且文件同样静默 → STUCK。返回 None / 'STALLED' / 'STUCK'。
    """
    s = signals.get("silence_s", 0)
    if s >= stuck_s and signals.get("file_silent", True) and signals.get("process_alive", False):
        return "STUCK"
    if s >= stalled_s:
        return "STALLED"
    return None
