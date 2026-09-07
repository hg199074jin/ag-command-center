"""ag v2.4 runtime：路径、默认策略与原子 JSON IO。"""

import contextlib
import fcntl
import json
import os
import tempfile
import time

HOME = os.path.expanduser("~")
CONFIG_DIR = os.path.join(HOME, ".config", "ag")
STATE_DIR = os.path.join(HOME, ".local", "state", "ag")
RUNTIME_DIR = os.path.join(STATE_DIR, "runtime")
LOG_DIR = os.path.join(STATE_DIR, "logs")

# 人写策略（配置）放 ~/.config/ag，机器数据放 state（对齐 v2.3 config/state 分离惯例）
POLICY_PATH = os.path.join(CONFIG_DIR, "runtime-policy.json")
STATE_PATH = os.path.join(RUNTIME_DIR, "runtime-state.json")
CAPABILITIES_PATH = os.path.join(RUNTIME_DIR, "provider-capabilities.json")
NOTIFICATION_PATH = os.path.join(RUNTIME_DIR, "notification.json")
USAGE_PATH = os.path.join(RUNTIME_DIR, "usage-history.jsonl")

PROTECTED_ROOTS = [
    "/",
    HOME,
    os.path.join(HOME, ".ssh"),
    os.path.join(HOME, ".gnupg"),
    os.path.join(HOME, ".config"),
    os.path.join(HOME, "Library"),
    os.path.join(HOME, ".agent-workstation"),
    "/System",
    "/Library",
    "/private",
    "/etc",
]

DEFAULT_POLICY = {
    "version": 1,
    "defaults": {
        "interactive": "auto",
        "worker": "yolo",
        "untrusted": "safe",
    },
    "protected_roots": PROTECTED_ROOTS,
    "thresholds": {
        "stalled_seconds": 300,
        "stuck_seconds": 900,
    },
    "projects": {},
}

# v2.3 launch_mode → v2.4 档位
MODE_ALIASES = {
    "standard": "safe",
    "assisted": "auto",
    "yolo": "yolo",
    "safe": "safe",
    "auto": "auto",
}


def ensure_dirs():
    for d in (CONFIG_DIR, RUNTIME_DIR, LOG_DIR):
        os.makedirs(d, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass


def log(source, message):
    ensure_dirs()
    line = "%s [%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), source, message)
    try:
        with open(os.path.join(LOG_DIR, "runtime.log"), "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass


def now_iso():
    lt = time.localtime()
    return time.strftime("%Y-%m-%dT%H:%M:%S", lt) + "%+03d:%02d" % (
        -time.timezone // 3600 if lt.tm_isdst == 0 else -time.altzone // 3600,
        abs(time.timezone) % 3600 // 60,
    )


def load_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json_atomic(path, data):
    """temp file + fsync + atomic rename，避免并发损坏 JSON。"""
    ensure_dirs()
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_policy(create=True):
    """读取策略。create=False 时纯只读（doctor 用），缺失/缺键只回内存默认值不落盘。"""
    policy = load_json(POLICY_PATH)
    if not isinstance(policy, dict):
        policy = json.loads(json.dumps(DEFAULT_POLICY))
        if create:
            save_json_atomic(POLICY_PATH, policy)
    changed = False
    for key, value in DEFAULT_POLICY.items():
        if key not in policy:
            policy[key] = json.loads(json.dumps(value))
            changed = True
    if changed and create:
        save_json_atomic(POLICY_PATH, policy)
    return policy


def save_policy(policy):
    save_json_atomic(POLICY_PATH, policy)


@contextlib.contextmanager
def state_lock():
    """runtime-state.json 读-改-写的进程间锁（原子 rename 防损坏，flock 防丢更新）。"""
    ensure_dirs()
    fh = open(os.path.join(RUNTIME_DIR, "state.lock"), "a+", encoding="utf-8")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fh, fcntl.LOCK_UN)
        finally:
            fh.close()
