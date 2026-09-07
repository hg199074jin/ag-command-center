"""ag-policy CLI：项目信任与档位策略（写 ~/.config/ag/runtime-policy.json）。

写操作前强制外置盘保护：目标在 /Volumes/ORICO 下而挂载点不可达时拒绝执行，
绝不把“盘未挂载”当成“项目不存在”来清理记录。
"""

import argparse
import json
import os
import sys

_SHARE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _SHARE not in sys.path:
    sys.path.insert(0, _SHARE)

from runtime import config, project_policy  # noqa: E402

VALID_MODES = ("safe", "auto", "yolo")


def _resolve_root(args):
    cwd = args.root or os.getcwd()
    root = project_policy.find_git_root(cwd)
    root = root or project_policy.canonical(cwd)
    if project_policy.orico_unmounted(root):
        print("❌ 外置盘 %s 未挂载：拒绝写入策略（fail-safe，防止误清理）" % project_policy.ORICO_VOLUME,
              file=sys.stderr)
        raise SystemExit(1)
    # 保护根（含 $HOME、~/.ssh、/System 等）禁止登记 trust：
    # 否则 git 根覆盖保护范围时 YOLO 会取得整个区间的写权限
    policy = config.load_policy()
    hit = project_policy.protected_hit(policy, root)
    if hit:
        print("❌ 拒绝：项目根 %s 命中保护根 %s，不能登记 trust" % (root, hit), file=sys.stderr)
        raise SystemExit(1)
    return root


def cmd_show(_args):
    policy = config.load_policy()
    print("defaults     : %s" % json.dumps(policy.get("defaults", {}), ensure_ascii=False))
    print("protected(%d):" % len(policy.get("protected_roots", [])))
    for r in policy.get("protected_roots", []):
        print("  - %s" % r)
    projects = policy.get("projects", {})
    print("projects(%d):" % len(projects))
    if not projects:
        print("  （空——用 ag-policy trust 登记可信项目）")
    for path in sorted(projects):
        entry = projects[path]
        unmounted = project_policy.orico_unmounted(path)
        exists = "存在" if os.path.isdir(path) else ("盘未挂载" if unmounted else "不存在")
        print("  %-52s trust=%-9s autonomy=%s [%s]" % (
            path, entry.get("trust", "untrusted"),
            json.dumps(entry.get("autonomy", {}), ensure_ascii=False), exists))
    return 0


def cmd_list(args):
    return cmd_show(args)


def _merge_entry(policy, root, **kwargs):
    projects = policy.setdefault("projects", {})
    entry = projects.get(root) or {}
    entry.update(kwargs)
    projects[root] = entry
    return entry


def cmd_trust(args):
    policy = config.load_policy()
    root = _resolve_root(args)
    _merge_entry(policy, root, trust="trusted")
    config.save_policy(policy)
    config.log("policy", "trust %s" % root)
    print("✅ trusted: %s" % root)
    return 0


def cmd_untrust(args):
    policy = config.load_policy()
    root = _resolve_root(args)
    entry = _merge_entry(policy, root, trust="untrusted")
    entry.pop("autonomy", None)  # 取消信任时同时清掉档位提升
    config.save_policy(policy)
    config.log("policy", "untrust %s" % root)
    print("✅ untrusted: %s" % root)
    return 0


def cmd_protect(args):
    policy = config.load_policy()
    root = _resolve_root(args)
    _merge_entry(policy, root, trust="protected")
    config.save_policy(policy)
    config.log("policy", "protect %s" % root)
    print("✅ protected（即使曾 trusted 也禁止自动 YOLO）: %s" % root)
    return 0


def cmd_set_mode(args):
    if args.mode not in VALID_MODES:
        print("❌ 未知档位：%s（可选 %s）" % (args.mode, "/".join(VALID_MODES)), file=sys.stderr)
        return 1
    policy = config.load_policy()
    root = _resolve_root(args)
    if args.mode == "yolo" and project_policy.trust_of(policy, root) != "trusted":
        print("❌ 项目未 trust，禁止设置 yolo。先执行：ag-policy trust", file=sys.stderr)
        return 1
    providers = [args.provider] if args.provider else ["codex", "claude"]
    entry = policy.setdefault("projects", {}).get(root) or {}
    autonomy = entry.get("autonomy") or {}
    for pv in providers:
        autonomy[pv] = args.mode
    _merge_entry(policy, root, autonomy=autonomy)
    config.save_policy(policy)
    config.log("policy", "set-mode %s providers=%s root=%s" % (args.mode, providers, root))
    print("✅ %s → %s（%s）" % (root, args.mode, ",".join(providers)))
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="ag-policy", description="ag v2.4 项目信任与档位策略")
    p.add_argument("--root", help="目标项目根（默认取 cwd 的 git root）")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("show", help="查看当前策略").set_defaults(func=cmd_show)
    sub.add_parser("list", help="同 show").set_defaults(func=cmd_list)
    sub.add_parser("trust", help="标记当前项目为 trusted").set_defaults(func=cmd_trust)
    sub.add_parser("untrust", help="取消信任（并清掉档位提升）").set_defaults(func=cmd_untrust)
    sub.add_parser("protect", help="标记 protected（禁止自动 YOLO）").set_defaults(func=cmd_protect)

    sp = sub.add_parser("set-mode", help="设置项目默认档位（codex/claude）")
    sp.add_argument("mode", help="safe | auto | yolo")
    sp.add_argument("--provider", choices=["codex", "claude"], help="缺省同时设置两者")
    sp.set_defaults(func=cmd_set_mode)
    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)
