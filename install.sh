#!/usr/bin/env bash
# ag-command-center installer (backup-aware, idempotent)
# 目标目录可用环境变量覆盖：AG_BIN_DIR / AG_LIB_DIR
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${AG_BIN_DIR:-$HOME/.local/bin}"
LIB_DIR="${AG_LIB_DIR:-$HOME/.local/share/ag}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/config-backup/ag-install-$STAMP"
BACKED_UP=0

backup_and_install() {
  local src="$1" dst="$2" rel
  if [ -e "$dst" ]; then
    rel="${dst#$HOME/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a "$dst" "$BACKUP_DIR/$rel"
    BACKED_UP=1
    echo "备份: ~/$rel"
  fi
  cp "$src" "$dst"
  chmod 700 "$dst"
}

mkdir -p "$BIN_DIR" "$LIB_DIR/runtime/providers"

echo "==> 安装命令族到 $BIN_DIR"
for f in "$HERE"/bin/*; do
  backup_and_install "$f" "$BIN_DIR/$(basename "$f")"
done

echo "==> 安装运行时包到 $LIB_DIR/runtime"
for f in "$HERE"/lib/ag-runtime/*.py; do
  backup_and_install "$f" "$LIB_DIR/runtime/$(basename "$f")"
done
for f in "$HERE"/lib/ag-runtime/providers/*.py; do
  backup_and_install "$f" "$LIB_DIR/runtime/providers/$(basename "$f")"
done

echo
echo "✅ 安装完成。先跑一次体检："
echo "   ag doctor          （ag 主诊断 + v2.4 runtime 诊断）"
echo "   ag-provider-doctor （探测 codex/claude 能力）"
echo "   ag                 （进入菜单）"
if [ "$BACKED_UP" -eq 1 ]; then
  echo "   （被覆盖的旧文件已备份到 $BACKUP_DIR）"
fi
