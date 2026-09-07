"""ag v2.4 runtime：Project Trust 与 YOLO gate。"""

import os

from . import config

# 外置项目盘（可被 AG_ORICO_VOLUME 覆盖；盘未挂载时一切判定 fail-safe）
ORICO_VOLUME = os.environ.get("AG_ORICO_VOLUME", "/Volumes/ORICO")


def canonical(path):
    """存在则 realpath；不存在（如外置盘未挂载）也不抛错，fail-safe。"""
    if os.path.exists(path):
        return os.path.realpath(path)
    return os.path.normpath(os.path.abspath(path))


def _worktree_main_root(dotgit_file):
    """linked worktree 的 .git 是文件，内容 'gitdir: <主仓>/.git/worktrees/<名>'。
    返回主仓库根；解析失败返回 None。"""
    try:
        with open(dotgit_file, "r", encoding="utf-8") as f:
            first = f.readline().strip()
    except OSError:
        return None
    if not first.startswith("gitdir:"):
        return None
    gd = first[len("gitdir:"):].strip()
    marker = "/.git/worktrees/"
    idx = gd.find(marker)
    if idx <= 0:
        return None
    return gd[:idx]


def find_git_root(path):
    p = canonical(path)
    if os.path.isfile(p):
        p = os.path.dirname(p)
    while True:
        dotgit = os.path.join(p, ".git")
        if os.path.isfile(dotgit):
            # linked worktree：trust 属于项目（主仓库根），而不是每个临时 worktree
            main = _worktree_main_root(dotgit)
            return main or p
        if os.path.isdir(dotgit):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def project_root_for(cwd):
    """git root 优先，退化用 cwd 本身。"""
    return find_git_root(cwd) or canonical(cwd)


def orico_unmounted(path):
    """路径声称在 ORICO 上，但挂载点不可达 → 一律按不可信处理。"""
    return path.startswith(ORICO_VOLUME + os.sep) and not os.path.isdir(ORICO_VOLUME)


def _is_under(path, root):
    if path == root:
        return True
    return path.startswith(root.rstrip(os.sep) + os.sep)


def protected_hit(policy, path):
    # 语义："/" 与 $HOME 只保护目录本身（否则 $HOME 下的合法项目永远无法 YOLO，
    # 且文档单独列举 ~/.ssh 等子目录就失去意义）；其余保护根按子树匹配。
    exact_only = {"/", os.path.expanduser("~")}
    for root in policy.get("protected_roots", []):
        root = os.path.expanduser(root)
        if root in exact_only:
            if path == root:
                return root
            continue
        if _is_under(path, root):
            return root
    return None


def project_entry(policy, root):
    return policy.get("projects", {}).get(root) or {}


def trust_of(policy, root):
    return project_entry(policy, root).get("trust", "untrusted")


def autonomy_of(policy, root, provider):
    return (project_entry(policy, root).get("autonomy") or {}).get(provider)


def check_yolo(cwd, provider, policy=None):
    """YOLO gate。检查顺序：realpath → 保护根 → ORICO → git root → trust → provider 钉档。

    返回 {"allowed": bool, "reason": str, "root": str, ...}。
    """
    policy = policy or config.load_policy()
    path = canonical(cwd)
    root = project_root_for(path)

    if orico_unmounted(path):
        return {"allowed": False, "reason": "外置盘 %s 未挂载（fail-safe）" % ORICO_VOLUME,
                "root": root, "trust": "unmounted"}
    hit = protected_hit(policy, path)
    if hit:
        return {"allowed": False, "reason": "命中保护根 %s" % hit, "root": root}
    if not find_git_root(path):
        return {"allowed": False, "reason": "目录不在 Git 仓库内", "root": root}
    # 防御纵深：cwd 不在保护根，但其 git 根在（如 $HOME 整体被 git 化）也拒绝——
    # 否则 YOLO 的写权限范围会覆盖整个家目录
    root_hit = protected_hit(policy, root)
    if root_hit and root != path:
        return {"allowed": False,
                "reason": "git 根 %s 命中保护根 %s（整仓范围过大）" % (root, root_hit),
                "root": root}
    trust = trust_of(policy, root)
    if trust == "protected":
        return {"allowed": False, "reason": "项目标记为 protected", "root": root, "trust": trust}
    if trust != "trusted":
        return {"allowed": False, "reason": "项目未信任（untrusted）", "root": root, "trust": trust}
    pinned = autonomy_of(policy, root, provider)
    if pinned in ("safe", "auto"):
        return {"allowed": False, "reason": "项目把 %s 钉在 %s 档" % (provider, pinned),
                "root": root, "trust": trust}
    return {"allowed": True, "reason": "trusted project", "root": root, "trust": trust}


def resolve_mode(provider, requested, cwd, worker=False, policy=None):
    """把（显式请求档位 / 项目策略 / 全局默认）解析成最终档位。

    trusted    → 默认 AUTO，可 YOLO（过 gate）
    untrusted  → 强制 SAFE
    protected  → 强制 SAFE
    worker 且 gate 拒绝 → fail closed（effective=None）
    """
    policy = policy or config.load_policy()
    defaults = policy.get("defaults", {})
    path = canonical(cwd)
    root = project_root_for(path)
    trust = trust_of(policy, root)

    if worker:
        # worker 默认 yolo；显式请求 safe/auto 时尊重之（更严不会更松）
        if requested not in ("safe", "auto"):
            requested = defaults.get("worker", "yolo")
    requested = config.MODE_ALIASES.get(requested, requested)

    out = {
        "provider": provider,
        "requested": requested or "",
        "cwd": path,
        "root": root,
        "trust": trust,
        "worker": bool(worker),
        "effective": None,
        "reason": "",
        "gate": None,
    }

    if trust != "trusted":
        want0 = requested or pinned or defaults.get("interactive", "auto")
        if worker and want0 == "yolo":
            # Worker 红线：worker 需要的 YOLO 在非 trusted 项目上一律 fail closed，
            # 绝不静默降档继续跑（显式 safe/auto 的 worker 除外——风险更低）
            out["reason"] = "worker 要求 YOLO，但 trust=%s（fail closed）" % trust
            return out
        out["effective"] = "safe"
        out["reason"] = "trust=%s → SAFE" % trust
        return out

    pinned = autonomy_of(policy, root, provider)
    want = requested or pinned or defaults.get("interactive", "auto")

    if want == "yolo":
        gate = check_yolo(path, provider, policy)
        out["gate"] = {k: gate[k] for k in ("allowed", "reason", "root")}
        if gate["allowed"]:
            out["effective"] = "yolo"
            out["reason"] = gate["reason"]
            return out
        if worker:
            out["reason"] = "worker YOLO gate 拒绝：%s（fail closed）" % gate["reason"]
            return out
        out["effective"] = "auto"
        out["reason"] = "YOLO 拒绝（%s）→ AUTO" % gate["reason"]
        return out

    out["effective"] = want if want in ("safe", "auto") else "auto"
    out["reason"] = "project policy"
    return out
