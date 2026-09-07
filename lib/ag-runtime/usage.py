"""ag v2.4 runtime：Usage Collector（v1 无数据库，JSONL + 30 天保留）。

本机实况：codex doctor / --help 无可脚本化额度端点，Claude 走 MiniMax 中转，
因此 v1 quota 字段如实记 null；额度显示由 CodexBar（菜单栏）承担，
历史记录在 ag 侧持续累积，批次 E 接 app-server 后回填真实数值。
"""

import json
import os
import time

from . import config

THROTTLE_SECONDS = 3600
RETENTION_DAYS = 30


def _codexbar_quota(provider):
    """CodexBar CLI 作为数据源之一（不是唯一 Source；app-server 属批次 E）。

    返回 {"short_limit": 0-100, "weekly_limit": 0-100}（剩余百分比）或 None。
    """
    import shutil
    import subprocess

    if not shutil.which("codexbar"):
        return None
    try:
        p = subprocess.run(
            ["codexbar", "usage", "--provider", provider, "--json"],
            capture_output=True, text=True, timeout=20)
        if p.returncode != 0:
            return None
        arr = json.loads(p.stdout or "[]")
        if not isinstance(arr, list) or not arr:
            return None
        u = arr[0].get("usage") or {}
        out = {}
        for key, win in (("short_limit", "primary"), ("weekly_limit", "secondary")):
            used = (u.get(win) or {}).get("usedPercent")
            out[key] = (100 - used) if isinstance(used, (int, float)) else None
        return out
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def snapshot(provider):
    quota = _codexbar_quota(provider) or {}
    short, weekly = quota.get("short_limit"), quota.get("weekly_limit")
    if short is not None or weekly is not None:
        note = "source=codexbar CLI"
    else:
        note = "v1 无脚本化额度源（codex CLI 无端点 / claude=MiniMax 中转）"
    return {
        "time": config.now_iso(),
        "provider": provider,
        "short_limit": short,
        "weekly_limit": weekly,
        "note": note,
    }


def snapshot_if_due(provider, now_ts=None):
    """每小时最多写一条，避免刷屏。"""
    now_ts = now_ts or time.time()
    try:
        with open(config.USAGE_PATH, "r", encoding="utf-8") as f:
            for ln in reversed(f.readlines()[-5:]):
                try:
                    rec = json.loads(ln)
                except ValueError:
                    continue
                if rec.get("provider") == provider:
                    t = rec.get("_ts") or 0
                    if now_ts - t < THROTTLE_SECONDS:
                        return None
                    break
    except OSError:
        pass
    rec = snapshot(provider)
    rec["_ts"] = now_ts
    with open(config.USAGE_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    trim()
    return rec


def trim(now_ts=None):
    """保留最近 30 天。"""
    now_ts = now_ts or time.time()
    path = config.USAGE_PATH
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return
    kept = []
    cutoff = now_ts - RETENTION_DAYS * 86400
    for ln in lines:
        try:
            rec = json.loads(ln)
        except ValueError:
            continue
        if rec.get("_ts", now_ts) >= cutoff:
            kept.append(ln if ln.endswith("\n") else ln + "\n")
    if len(kept) != len(lines):
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(kept)
        os.replace(tmp, path)


def summary():
    """供菜单/doctor 读取：每个 provider 最近一条快照。"""
    out = {}
    try:
        with open(config.USAGE_PATH, "r", encoding="utf-8") as f:
            for ln in f:
                try:
                    rec = json.loads(ln)
                except ValueError:
                    continue
                out[rec.get("provider")] = rec
    except OSError:
        pass
    return out
