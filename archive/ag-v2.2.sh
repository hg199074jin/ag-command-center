#!/usr/bin/env bash

# ============================================================
# ag v2.2 - AG Command Center
# 基于 Gum 的分层菜单 + 稳定非交互子命令
# 兼容 AG 2.1 的状态目录 / 最近项目 / tmux 会话命名
# Compatible with macOS Bash 3.2+
# ============================================================

set -u

AG2_VERSION="2.2.0"

# 保证在非交互/launchd 环境下也能找到工具
for _d in "$HOME/.local/bin" /opt/homebrew/bin; do
  [ -d "$_d" ] && case ":$PATH:" in
    *":$_d:"*) ;;
    *) PATH="$_d:$PATH" ;;
  esac
done
export PATH

# AG 2.1 兼容：可选配置文件
AG_CONFIG_FILE="$HOME/.config/ag/config"
if [ -r "$AG_CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$AG_CONFIG_FILE"
fi

: "${AG_STATE_DIR:=$HOME/.local/state/ag}"
: "${AG_LOG_FILE:=$AG_STATE_DIR/logs/ag.log}"
: "${AG_RECENT_FILE:=$AG_STATE_DIR/recent-projects}"
: "${AG_RECENT_LIMIT:=15}"
: "${AG_ORICO_VOLUME:=/Volumes/ORICO}"
: "${AG_PROJECT_ROOT:=$AG_ORICO_VOLUME/Projects}"
: "${AG_FALLBACK_ROOTS:=$AG_ORICO_VOLUME/AI $HOME/Documents/Codex}"
: "${AG_AGENTBOARD_PORT:=4040}"
: "${AG_AGENTBOARD_LABEL:=com.sandro.agentboard}"
AG_CURRENT_FILE="${AG_CURRENT_FILE:-$AG_STATE_DIR/current-project}"
AG_LOG_MAX_BYTES="${AG_LOG_MAX_BYTES:-5242880}"

# ------------------------------------------------------------
# 基础工具（与 AG 2.1 保持一致）
# ------------------------------------------------------------

have() {
  command -v "$1" >/dev/null 2>&1
}

pause() {
  printf '\n按 Enter 继续...'
  IFS= read -r _
}

sanitize_name() {
  printf '%s' "$1" \
    | sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

pretty_path() {
  # shellcheck disable=SC2088  # 这里的 ~ 是展示用的字面量，不参与展开
  case "$1" in
    "$HOME")
      printf '~'
      ;;
    "$HOME"/*)
      printf '~/%s' "${1#"$HOME"/}"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

# shellcheck disable=SC2088  # canonical_dir 中匹配的是字面量 ~ 与 ~/，属预期
canonical_dir() {
  local input="$1"

  case "$input" in
    '~')
      input="$HOME"
      ;;
    '~/'*)
      input="$HOME/${input#\~/}"
      ;;
  esac

  if [ -d "$input" ]; then
    (
      cd "$input" 2>/dev/null &&
      pwd -P
    )
  else
    return 1
  fi
}

list_sessions_raw() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null || true
}

session_exists() {
  tmux has-session -t "=$1" 2>/dev/null
}

session_path() {
  tmux display-message \
    -p \
    -t "=$1:" \
    '#{pane_current_path}' \
    2>/dev/null || true
}

session_command() {
  tmux display-message \
    -p \
    -t "=$1:" \
    '#{pane_current_command}' \
    2>/dev/null || true
}

unique_session_name() {
  local base="$1"
  local dir="$2"
  local candidate="$base"
  local n=2

  if ! session_exists "$candidate"; then
    printf '%s' "$candidate"
    return 0
  fi

  if [ "$(session_path "$candidate")" = "$dir" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  while session_exists "${base}-${n}"; do
    n=$((n + 1))
  done

  printf '%s-%s' "$base" "$n"
}

enter_session() {
  local name="$1"

  if ! have tmux; then
    echo "错误：没有找到 tmux。"
    return 1
  fi

  if ! session_exists "$name"; then
    echo "Session 不存在：$name"
    return 1
  fi

  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$name"
  else
    tmux attach-session -t "=$name"
  fi
}

ag_choose_default_root() {
  local candidate

  if [ -d "$AG_PROJECT_ROOT" ]; then
    printf '%s' "$AG_PROJECT_ROOT"
    return 0
  fi

  for candidate in $AG_FALLBACK_ROOTS; do
    [ -d "$candidate" ] || continue
    printf '%s' "$candidate"
    return 0
  done

  printf '%s' "$HOME"
}

# ------------------------------------------------------------
# 日志（带轮转）/ 当前项目 / 最近项目
# ------------------------------------------------------------

ag2_log() {
  local size

  mkdir -p "$AG_STATE_DIR/logs" 2>/dev/null || true

  if [ -f "$AG_LOG_FILE" ]; then
    size=$(wc -c < "$AG_LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$AG_LOG_MAX_BYTES" ] 2>/dev/null; then
      mv -f "$AG_LOG_FILE" "$AG_LOG_FILE.1" 2>/dev/null || true
    fi
  fi

  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$AG_LOG_FILE" 2>/dev/null || true
}

current_project() {
  [ -r "$AG_CURRENT_FILE" ] || return 1
  local p
  p=$(head -n 1 "$AG_CURRENT_FILE" 2>/dev/null || true)
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

set_current_project() {
  local dir="$1"
  local tmp

  tmp=$(mktemp "${TMPDIR:-/tmp}/ag2-current.XXXXXX") || return 1
  if printf '%s\n' "$dir" > "$tmp"; then
    if mv "$tmp" "$AG_CURRENT_FILE" 2>/dev/null; then
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

ag_add_recent_project() {
  local project="$1"
  local tmp

  [ -d "$project" ] || return 0
  project=$(canonical_dir "$project") || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/ag2-recent.XXXXXX") || return 0

  {
    printf '%s\n' "$project"
    grep -Fxv -- "$project" "$AG_RECENT_FILE" 2>/dev/null || true
  } | awk 'NF && !seen[$0]++' | head -n "$AG_RECENT_LIMIT" > "$tmp" 2>/dev/null

  mv "$tmp" "$AG_RECENT_FILE" 2>/dev/null || rm -f "$tmp"
}

# 从 recent-projects 中删除一条记录（原子写回）
ag_remove_recent_project() {
  local project="$1"
  local tmp

  tmp=$(mktemp "${TMPDIR:-/tmp}/ag2-recent-rm.XXXXXX") || return 0
  grep -Fxv -- "$project" "$AG_RECENT_FILE" 2>/dev/null > "$tmp" || true
  mv "$tmp" "$AG_RECENT_FILE" 2>/dev/null || rm -f "$tmp"
}

# ------------------------------------------------------------
# Gum 菜单辅助
# ------------------------------------------------------------

require_gum() {
  if ! have gum; then
    echo "错误：没有找到 gum（AG 2.2 交互菜单依赖它）。"
    return 1
  fi
  if [ ! -t 0 ]; then
    echo "交互菜单需要在终端中运行。"
    echo "非交互场景请使用：ag status / doctor / project current / project list / session list"
    return 1
  fi
}

banner() {
  gum style \
    --border double \
    --border-foreground 212 \
    --padding "0 2" \
    --align center \
    "AG · Agent Command Center" \
    "v${AG2_VERSION}" 2>/dev/null || true
}

# menu_pick <标题> <选项...>：输出所选选项；ESC/Ctrl+C 返回非零
menu_pick() {
  local header="$1"
  shift
  gum choose --header "$header" "$@"
}

menu_pause() {
  pause
}

# ------------------------------------------------------------
# Agent 会话创建（与 AG 2.1 相同的命名与复用规则）
# ------------------------------------------------------------

start_agent_in_session() {
  local name="$1"
  local launcher="$2"

  case "$launcher" in
    Codex)
      if ! have codex; then
        echo "错误：PATH 中没有找到 codex。"
        return 1
      fi
      tmux send-keys -t "=$name:" 'codex' C-m
      ;;

    Claude)
      if ! have claude; then
        echo "错误：PATH 中没有找到 claude。"
        return 1
      fi
      tmux send-keys -t "=$name:" 'claude' C-m
      ;;

    Shell)
      ;;
    *)
      echo "错误：未知启动方式：$launcher"
      return 1
      ;;
  esac
}

create_session_for_dir() {
  local dir="$1"
  local launcher="$2"
  local requested_name="${3:-}"

  local base
  local name
  local existing_path

  dir=$(canonical_dir "$dir") || {
    echo "目录不存在：$dir"
    pause
    return 1
  }

  if [ -n "$requested_name" ]; then
    base=$(sanitize_name "$requested_name")
  else
    base=$(sanitize_name "$(basename "$dir")")
  fi

  [ -n "$base" ] || base='agent'

  name=$(unique_session_name "$base" "$dir")

  if session_exists "$name"; then
    existing_path=$(session_path "$name")
    if [ "$existing_path" = "$dir" ]; then
      echo
      echo "Session '$name' 已存在，直接进入。"
      set_current_project "$dir" || true
      ag_add_recent_project "$dir"
      ag2_log "reuse session=$name dir=$dir"
      enter_session "$name"
      return 0
    fi
  fi

  case "$launcher" in
    Codex)
      have codex || { echo "错误：没有找到 codex。"; pause; return 1; }
      ;;
    Claude)
      have claude || { echo "错误：没有找到 claude。"; pause; return 1; }
      ;;
    Shell)
      ;;
    *)
      echo "错误：未知 launcher：$launcher"
      pause
      return 1
      ;;
  esac

  tmux new-session -d -s "$name" -c "$dir"

  if ! start_agent_in_session "$name" "$launcher"; then
    tmux kill-session -t "=$name" 2>/dev/null || true
    pause
    return 1
  fi

  set_current_project "$dir" || true
  ag_add_recent_project "$dir"
  ag2_log "start launcher=$launcher session=$name dir=$dir"

  echo
  echo "已创建："
  echo
  echo "  Session : $name"
  echo "  Agent   : $launcher"
  echo "  Path    : $(pretty_path "$dir")"
  echo

  enter_session "$name"
}

# ------------------------------------------------------------
# 项目选择（Agent 启动用）
# ------------------------------------------------------------

# 从最近项目里选一个目录（含外置盘保护与失效清理）
pick_from_recent() {
  local line
  local parent
  local warned=0
  local removed
  local -a items=()
  local -a targets=()
  local i
  local sel
  local picked

  [ -s "$AG_RECENT_FILE" ] || { echo "暂无最近项目记录。"; return 1; }

  removed=""

  while IFS= read -r line; do
    [ -n "$line" ] || continue

    if [ -d "$line" ]; then
      items+=("$(basename "$line")  —  $(pretty_path "$line")")
      targets+=("$line")
      continue
    fi

    parent=$(dirname "$line" 2>/dev/null || true)

    if [ -n "$parent" ] && [ -d "$parent" ]; then
      # 父目录可达而目录不存在 → 记录确实失效，自动清理
      ag_remove_recent_project "$line"
      removed="$removed
⚠️ 项目目录不存在，已从最近项目中移除：$(pretty_path "$line")"
      ag2_log "cleanup removed=$(pretty_path "$line")"
    else
      # 父目录不可达（外置盘未挂载）→ 保留记录，绝不清理
      if [ ! -d "$AG_ORICO_VOLUME" ] && [ "$warned" -eq 0 ]; then
        case "$line" in
          "$AG_ORICO_VOLUME"/*)
            echo "⚠️ 外置盘 $AG_ORICO_VOLUME 未挂载，相关记录已保留，本次不清理任何记录。"
            warned=1
            ;;
        esac
      fi
    fi
  done < "$AG_RECENT_FILE"

  [ -n "$removed" ] && printf '%s\n' "$removed"

  if [ "${#targets[@]}" -eq 0 ]; then
    echo "暂无当前可用的最近项目（外置盘可能未挂载）。"
    return 1
  fi

  sel=$(menu_pick "最近项目" "${items[@]}") || return 1

  picked=""
  for i in "${!items[@]}"; do
    if [ "${items[$i]}" = "$sel" ]; then
      picked="${targets[$i]}"
      break
    fi
  done

  [ -n "$picked" ] || return 1
  printf '%s' "$picked"
}

# Yazi 选目录（复用 AG 2.1 的 --cwd-file 机制）
pick_with_yazi() {
  local tmp
  local selected

  have yazi || { echo "错误：没有找到 yazi。"; return 1; }

  tmp=$(mktemp "${TMPDIR:-/tmp}/ag2-yazi.XXXXXX") || return 1

  yazi "$(ag_choose_default_root)" --cwd-file="$tmp"

  selected=""
  [ -s "$tmp" ] && selected=$(cat "$tmp")
  rm -f "$tmp"

  [ -n "$selected" ] && [ -d "$selected" ] || {
    echo "没有选择有效的项目目录。"
    return 1
  }

  selected=$(canonical_dir "$selected") || return 1
  printf '%s' "$selected"
}

# 为启动选择项目目录：当前项目 / 最近项目 / Yazi
pick_project_for_launch() {
  local cur
  local choice
  local dir

  cur=$(current_project 2>/dev/null || true)

  local -a opts=()
  local -a vals=()

  if [ -n "$cur" ] && [ -d "$cur" ]; then
    opts+=("使用当前项目  —  $(pretty_path "$cur")")
    vals+=("$cur")
  fi
  opts+=("从最近项目选择" "用 Yazi 选择目录")
  vals+=("__recent__" "__yazi__")

  choice=$(menu_pick "选择项目" "${opts[@]}") || return 1

  local i
  local v=""
  for i in "${!opts[@]}"; do
    [ "${opts[$i]}" = "$choice" ] && v="${vals[$i]}" && break
  done

  case "$v" in
    __recent__)
      pick_from_recent
      ;;
    __yazi__)
      pick_with_yazi
      ;;
    *)
      [ -n "$v" ] && printf '%s' "$v"
      ;;
  esac
}

# ------------------------------------------------------------
# 恢复 Agent 会话（按面板进程识别）
# ------------------------------------------------------------

agent_session_candidates() {
  local kind="$1"
  local s
  local cmd

  while IFS= read -r s; do
    [ -n "$s" ] || continue
    cmd=$(session_command "$s")

    case "$kind" in
      codex)
        if [ "$cmd" = "codex" ] || { [ "$cmd" = "node" ] && \
          tmux capture-pane -p -t "=$s:" 2>/dev/null | head -40 | grep -qi 'codex'; }; then
          printf '%s\t%s\t%s\n' "$s" "$cmd" "$(pretty_path "$(session_path "$s")")"
        fi
        ;;
      claude)
        if [ "$cmd" = "claude" ] || { [ "$cmd" = "node" ] && \
          tmux capture-pane -p -t "=$s:" 2>/dev/null | head -40 | grep -qi 'claude'; }; then
          printf '%s\t%s\t%s\n' "$s" "$cmd" "$(pretty_path "$(session_path "$s")")"
        fi
        ;;
    esac
  done < <(list_sessions_raw)
}

resume_agent_menu() {
  local kind="$1"
  local label="$2"
  local -a items=()
  local -a targets=()
  local name
  local i
  local sel
  local picked

  if ! have tmux; then
    echo "错误：没有找到 tmux。"
    pause
    return 0
  fi

  while IFS=$'\t' read -r name _cmd _path; do
    [ -n "$name" ] || continue
    items+=("$name  （${_cmd} · ${_path}）")
    targets+=("$name")
  done < <(agent_session_candidates "$kind")

  if [ "${#targets[@]}" -eq 0 ]; then
    echo
    echo "暂无正在运行 $label 的会话。"
    echo "可能 Agent 已退出，可通过 🤖 Agent → ${label} 新任务 重新启动，"
    echo "或在 🖥 工作台 → tmux 会话 中直接查看所有会话。"
    pause
    return 0
  fi

  sel=$(menu_pick "恢复 $label" "${items[@]}") || return 0

  picked=""
  for i in "${!items[@]}"; do
    [ "${items[$i]}" = "$sel" ] && picked="${targets[$i]}" && break
  done

  [ -n "$picked" ] || return 0

  ag2_log "resume kind=$kind session=$picked"
  enter_session "$picked"
}

# ------------------------------------------------------------
# Agent 菜单
# ------------------------------------------------------------

agent_menu() {
  while true; do
    c=$(menu_pick "🤖 Agent" \
      "Codex 新任务" "Claude 新任务" \
      "恢复 Codex" "恢复 Claude" "返回") || return 0

    case "$c" in
      "Codex 新任务")
        dir=$(pick_project_for_launch) || { pause; continue; }
        [ -n "$dir" ] || { pause; continue; }
        gum confirm "在 $(pretty_path "$dir") 启动 Codex？" &&
          create_session_for_dir "$dir" Codex
        ;;
      "Claude 新任务")
        dir=$(pick_project_for_launch) || { pause; continue; }
        [ -n "$dir" ] || { pause; continue; }
        gum confirm "在 $(pretty_path "$dir") 启动 Claude？" &&
          create_session_for_dir "$dir" Claude
        ;;
      "恢复 Codex")
        resume_agent_menu codex "Codex"
        ;;
      "恢复 Claude")
        resume_agent_menu claude "Claude"
        ;;
      *)
        return 0
        ;;
    esac
  done
}

# ------------------------------------------------------------
# 项目菜单
# ------------------------------------------------------------

project_menu() {
  while true; do
    c=$(menu_pick "📁 项目" \
      "最近项目" "Yazi 选择项目" "当前项目" "新建项目" "返回") || return 0

    case "$c" in
      "最近项目")
        dir=$(pick_from_recent) || { pause; continue; }
        launcher=$(menu_pick "启动什么" "Codex" "Claude" "Shell") || continue
        create_session_for_dir "$dir" "$launcher"
        ;;
      "Yazi 选择项目")
        dir=$(pick_with_yazi) || { pause; continue; }
        set_current_project "$dir" || true
        ag_add_recent_project "$dir"
        ag2_log "project set dir=$dir source=yazi"
        echo
        echo "✅ 当前项目已设置：$(pretty_path "$dir")"
        pause
        ;;
      "当前项目")
        cur=$(current_project 2>/dev/null || true)
        echo
        if [ -n "$cur" ]; then
          echo "当前项目：$(pretty_path "$cur")"
          [ -d "$cur" ] || echo "⚠️ 该目录当前不存在（外置盘可能未挂载）。"
        else
          echo "尚未设置当前项目。"
        fi
        pause
        ;;
      "新建项目")
        parent=$(menu_pick "选择项目父目录" "$AG_PROJECT_ROOT" "$HOME/Projects" "用 Yazi 自定义") || continue
        if [ "$parent" = "用 Yazi 自定义" ]; then
          parent=$(pick_with_yazi) || { pause; continue; }
        fi
        [ -d "$parent" ] || { echo "父目录不存在：$parent"; pause; continue; }
        name=$(gum input --placeholder "项目名称（不含路径分隔符）") || continue
        [ -n "$name" ] || continue
        case "$name" in
          */*)
            echo "无效的项目名称（不能包含 /）。"
            pause
            continue
            ;;
        esac
        target="$parent/$name"
        if [ -e "$target" ]; then
          if [ -d "$target" ]; then
            echo "目录已存在，将直接使用。"
          else
            echo "同名文件已存在：$(pretty_path "$target")"
            pause
            continue
          fi
        else
          mkdir -p "$target" || { echo "创建目录失败。"; pause; continue; }
        fi
        target=$(canonical_dir "$target") || continue
        set_current_project "$target" || true
        ag_add_recent_project "$target"
        ag2_log "project created dir=$target"
        echo
        echo "✅ 项目已就绪：$(pretty_path "$target")"
        echo "ℹ️ AG 只负责建立目录；git/npm/uv 初始化交给 Agent。"
        echo "   启动 Agent 请到 🤖 Agent 菜单。"
        pause
        ;;
      *)
        return 0
        ;;
    esac
  done
}

# ------------------------------------------------------------
# 开发菜单
# ------------------------------------------------------------

justfile_in() {
  local dir="$1"
  if [ -f "$dir/justfile" ]; then
    printf '%s' "$dir/justfile"
  elif [ -f "$dir/Justfile" ]; then
    printf '%s' "$dir/Justfile"
  else
    return 1
  fi
}

just_has_recipe() {
  local jf="$1"
  local recipe="$2"
  have just || return 1
  just --justfile "$jf" --summary 2>/dev/null | tr ' ' '\n' | grep -qx "$recipe"
}

require_current_project() {
  cur=$(current_project 2>/dev/null || true)
  if [ -z "$cur" ]; then
    echo "ℹ️ 尚未设置当前项目，请先到 📁 项目 菜单选择。"
    pause
    return 1
  fi
  if [ ! -d "$cur" ]; then
    echo "⚠️ 当前项目目录不存在（外置盘可能未挂载）：$(pretty_path "$cur")"
    pause
    return 1
  fi
  printf '%s' "$cur"
}

dev_menu() {
  local cur
  local jf

  while true; do
    c=$(menu_pick "🛠 开发" \
      "Git" "Docker" "测试" "完整检查" "安全扫描" \
      "GitHub Actions" "开发监听" "项目分析" "性能测试" "返回") || return 0

    case "$c" in
      "Git")
        cur=$(require_current_project) || continue
        if ! (cd "$cur" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
          echo "ℹ️ 当前项目不是 Git 仓库。"
          pause
          continue
        fi
        (cd "$cur" && lazygit)
        ;;
      "Docker")
        if ! docker info >/dev/null 2>&1; then
          echo "ℹ️ Docker 当前不可用，请检查 Docker Desktop。"
          pause
          continue
        fi
        lazydocker
        ;;
      "测试")
        cur=$(require_current_project) || continue
        if ! jf=$(justfile_in "$cur"); then
          echo "ℹ️ 当前项目尚未定义 justfile。"
          echo "   建议让 Agent 为项目建立标准 justfile（test/lint/check/security/watch）。"
          pause
          continue
        fi
        if just_has_recipe "$jf" test; then
          just --justfile "$jf" test
        else
          echo "ℹ️ 当前项目尚未定义 \`just test\`。"
        fi
        pause
        ;;
      "完整检查")
        cur=$(require_current_project) || continue
        if ! jf=$(justfile_in "$cur"); then
          echo "ℹ️ 当前项目尚未定义 justfile，无法执行 just check。"
          pause
          continue
        fi
        if just_has_recipe "$jf" check; then
          just --justfile "$jf" check
        else
          echo "ℹ️ 当前项目尚未定义 \`just check\`。"
        fi
        pause
        ;;
      "安全扫描")
        cur=$(require_current_project) || continue
        if jf=$(justfile_in "$cur") && just_has_recipe "$jf" security; then
          just --justfile "$jf" security
        else
          have trivy || { echo "错误：没有找到 trivy。"; pause; continue; }
          echo "（使用 trivy 直接扫描，只生成结果，不做任何修改）"
          trivy fs --scanners vuln,secret,misconfig "$cur"
        fi
        pause
        ;;
      "GitHub Actions")
        cur=$(require_current_project) || continue
        if [ ! -d "$cur/.github/workflows" ]; then
          echo "ℹ️ 当前项目没有 GitHub Actions。"
          pause
          continue
        fi
        gum confirm "act 首次运行可能下载较大的 Docker 镜像，继续？" &&
          (cd "$cur" && act)
        ;;
      "开发监听")
        cur=$(require_current_project) || continue
        if jf=$(justfile_in "$cur") && just_has_recipe "$jf" watch; then
          just --justfile "$jf" watch
        else
          echo "ℹ️ 当前项目尚未定义 \`just watch\`。"
        fi
        pause
        ;;
      "项目分析")
        cur=$(require_current_project) || continue
        echo "--- Git 状态 ---"
        (cd "$cur" && git status --short 2>/dev/null || echo "（非 Git 仓库）")
        echo
        echo "--- 代码规模 ---"
        scc "$cur" 2>/dev/null | head -20
        pause
        ;;
      "性能测试")
        cur=$(require_current_project) || continue
        if jf=$(justfile_in "$cur") && just_has_recipe "$jf" bench; then
          just --justfile "$jf" bench
        else
          echo "ℹ️ 当前项目未定义 benchmark。"
          echo "   如需要性能测试，可让 Agent 使用 hyperfine 配置 \`just bench\`。"
        fi
        pause
        ;;
      *)
        return 0
        ;;
    esac
  done
}

# ------------------------------------------------------------
# 工作台菜单
# ------------------------------------------------------------

agentboard_alive() {
  lsof -nP -iTCP:"$AG_AGENTBOARD_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

disk_menu() {
  local target
  local cur

  target=$(menu_pick "磁盘分析目标" "Home" "当前项目" "ORICO 盘") || return 0

  case "$target" in
    "Home")
      target="$HOME"
      ;;
    "当前项目")
      cur=$(current_project 2>/dev/null || true)
      if [ -z "$cur" ] || [ ! -d "$cur" ]; then
        echo "ℹ️ 尚未设置有效的当前项目。"
        pause
        return 0
      fi
      target="$cur"
      ;;
    "ORICO 盘")
      if [ ! -d "$AG_ORICO_VOLUME" ]; then
        echo "⚠️ 外置盘 $AG_ORICO_VOLUME 未挂载。"
        pause
        return 0
      fi
      target="$AG_ORICO_VOLUME"
      ;;
    *)
      return 0
      ;;
  esac

  have dust || { echo "错误：没有找到 dust。"; pause; return 0; }
  dust -d 1 "$target"
  pause
}

workstation_menu() {
  local cur
  local sel
  local -a items=()
  local -a targets=()
  local s
  local i
  local picked

  while true; do
    c=$(menu_pick "🖥 工作台" \
      "Agentboard" "tmux 会话" "系统监控" "磁盘分析" \
      "工作台状态" "工作台诊断" "查看日志" "返回") || return 0

    case "$c" in
      "Agentboard")
        echo
        if agentboard_alive; then
          echo "✅ Agentboard :$AG_AGENTBOARD_PORT 正常"
        else
          echo "❌ Agentboard :$AG_AGENTBOARD_PORT 离线"
          echo "ℹ️ 它由 launchd 服务 $AG_AGENTBOARD_LABEL 守护（KeepAlive）。"
          echo "   请检查该服务；AG 不会启动第二个实例。"
        fi
        pause
        ;;
      "tmux 会话")
        items=()
        targets=()
        while IFS= read -r s; do
          [ -n "$s" ] || continue
          items+=("$s  （$(session_command "$s") · $(pretty_path "$(session_path "$s")")）")
          targets+=("$s")
        done < <(list_sessions_raw)

        if [ "${#targets[@]}" -eq 0 ]; then
          echo "当前没有 tmux 会话。"
          pause
          continue
        fi

        sel=$(menu_pick "tmux 会话" "${items[@]}") || continue
        picked=""
        for i in "${!items[@]}"; do
          [ "${items[$i]}" = "$sel" ] && picked="${targets[$i]}" && break
        done
        [ -n "$picked" ] && enter_session "$picked"
        ;;
      "系统监控")
        have btop && btop
        ;;
      "磁盘分析")
        disk_menu
        ;;
      "工作台状态")
        echo
        if [ -x "$HOME/.local/bin/mac-status" ]; then
          "$HOME/.local/bin/mac-status"
        else
          show_status
        fi
        pause
        ;;
      "工作台诊断")
        echo
        cmd_doctor
        echo
        if [ -x "$HOME/.local/bin/mac-fix" ]; then
          gum confirm "是否运行 mac-fix 进行基础修复？（其内部动作均需再次确认）" &&
            "$HOME/.local/bin/mac-fix"
        else
          echo "ℹ️ mac-fix 不存在，跳过修复入口。"
        fi
        pause
        ;;
      "查看日志")
        echo
        if [ -f "$AG_LOG_FILE" ]; then
          tail -n 50 "$AG_LOG_FILE"
        else
          echo "（暂无日志：${AG_LOG_FILE}）"
        fi
        pause
        ;;
      *)
        return 0
        ;;
    esac
  done
}

# ------------------------------------------------------------
# 辅助菜单
# ------------------------------------------------------------

assist_menu() {
  while true; do
    c=$(menu_pick "🧠 辅助" "历史命令" "Shell" "返回") || return 0

    case "$c" in
      "历史命令")
        if have atuin; then
          atuin search -i
        else
          echo "ℹ️ atuin 未安装。"
          pause
        fi
        ;;
      "Shell")
        "${SHELL:-/bin/zsh}"
        ;;
      *)
        return 0
        ;;
    esac
  done
}

# ------------------------------------------------------------
# 非交互子命令
# ------------------------------------------------------------

show_status() {
  local cur
  local n

  cur=$(current_project 2>/dev/null || true)
  if [ -n "$cur" ]; then
    echo "Current Project : $(basename "$cur") ($(pretty_path "$cur"))"
  else
    echo "Current Project : (未设置)"
  fi

  if agentboard_alive; then
    echo "Agentboard      : ✅ :$AG_AGENTBOARD_PORT"
  else
    echo "Agentboard      : ❌ 离线"
  fi

  if docker info >/dev/null 2>&1; then
    n=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    echo "Docker          : ✅ ($n 个容器运行中)"
  else
    echo "Docker          : ❌ 不可用"
  fi

  if have tmux; then
    echo "tmux sessions   : $(list_sessions_raw | tr '\n' ' ')"
  else
    echo "tmux sessions   : ❌ tmux 不可用"
  fi

  have codex && echo "Codex           : $(codex --version 2>/dev/null | head -1)"
  have claude && echo "Claude          : $(claude --version 2>/dev/null | head -1)"

  echo "Disk /          : $(df -h / 2>/dev/null | awk 'NR==2{print $4" 可用"}')"
  if [ -d "$AG_ORICO_VOLUME" ]; then
    echo "ORICO           : ✅ 已挂载"
  else
    echo "ORICO           : ⚠️ 未挂载"
  fi
}

cmd_status() {
  show_status
}

cmd_doctor() {
  local t
  local ok=0
  local bad=0

  echo "=== ag doctor（只读诊断，不做任何修改） ==="
  echo

  echo "--- 依赖工具 ---"
  for t in gum atuin lazydocker watchexec trivy act lefthook dust hyperfine scc \
           tmux yazi lazygit btop just git gh codex claude; do
    if have "$t"; then
      printf '✅ %s\n' "$t"
      ok=$((ok + 1))
    else
      printf '❌ %s 未安装\n' "$t"
      bad=$((bad + 1))
    fi
  done

  echo
  echo "--- 服务与环境 ---"

  if docker info >/dev/null 2>&1; then
    echo "✅ Docker 可用"
  else
    echo "❌ Docker 不可用"
    bad=$((bad + 1))
  fi

  if agentboard_alive; then
    echo "✅ Agentboard :$AG_AGENTBOARD_PORT 在线"
  else
    echo "❌ Agentboard :${AG_AGENTBOARD_PORT} 离线（launchd: ${AG_AGENTBOARD_LABEL}）"
    bad=$((bad + 1))
  fi

  if have tmux && tmux info >/dev/null 2>&1; then
    echo "✅ tmux 服务可达（$(list_sessions_raw | grep -c . || true) 个会话）"
  else
    echo "⚠️ tmux 服务不可达"
  fi

  if [ -d "$AG_ORICO_VOLUME" ]; then
    echo "✅ 外置盘 $AG_ORICO_VOLUME 已挂载"
  else
    echo "⚠️ 外置盘 $AG_ORICO_VOLUME 未挂载（项目记录将被保留，不会清理）"
  fi

  echo
  echo "--- 状态文件 ---"

  if [ -d "$AG_STATE_DIR" ]; then
    echo "✅ 状态目录 $AG_STATE_DIR"
  else
    echo "❌ 状态目录缺失 $AG_STATE_DIR"
    bad=$((bad + 1))
  fi

  [ -f "$AG_RECENT_FILE" ] && echo "✅ recent-projects（$(grep -c . "$AG_RECENT_FILE" 2>/dev/null || echo 0) 条）" \
    || echo "ℹ️ recent-projects 尚无记录"

  local cur
  cur=$(current_project 2>/dev/null || true)
  if [ -n "$cur" ]; then
    if [ -d "$cur" ]; then
      echo "✅ current-project：$(pretty_path "$cur")"
    else
      echo "⚠️ current-project 指向不存在的目录：$(pretty_path "$cur")"
    fi
  else
    echo "ℹ️ current-project 未设置"
  fi

  echo
  if [ "$bad" -eq 0 ]; then
    echo "结论：无异常（$ok 项工具就绪）。"
  else
    echo "结论：$bad 项异常 / 缺失，详见上方 ❌ 行。"
  fi
  return 0
}

cmd_project_current() {
  local cur
  cur=$(current_project 2>/dev/null || true)
  if [ -z "$cur" ]; then
    echo "未设置当前项目" >&2
    return 1
  fi
  printf '%s\n' "$cur"
}

cmd_project_list() {
  local line
  [ -s "$AG_RECENT_FILE" ] || return 0
  if [ ! -d "$AG_ORICO_VOLUME" ]; then
    echo "⚠️ 外置盘 $AG_ORICO_VOLUME 未挂载" >&2
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\t%s\n' "$(basename "$line")" "$line"
  done < "$AG_RECENT_FILE"
}

cmd_session_list() {
  local s
  local cmd
  local kind

  have tmux || { echo "tmux 不可用" >&2; return 1; }

  while IFS= read -r s; do
    [ -n "$s" ] || continue
    cmd=$(session_command "$s")
    kind="-"
    case "$cmd" in
      codex) kind="codex" ;;
      claude) kind="claude" ;;
      node)
        if tmux capture-pane -p -t "=$s:" 2>/dev/null | head -40 | grep -qi 'codex'; then
          kind="codex"
        elif tmux capture-pane -p -t "=$s:" 2>/dev/null | head -40 | grep -qi 'claude'; then
          kind="claude"
        fi
        ;;
    esac
    printf '%s\t%s\t%s\n' "$s" "$kind" "$(session_path "$s")"
  done < <(list_sessions_raw)
}

# ------------------------------------------------------------
# Self-test
# ------------------------------------------------------------

self_test() {
  local got

  got=$(sanitize_name 'my project:abc/test')
  [ "$got" = 'my-project-abc-test' ] || { echo "FAIL sanitize_name: $got"; return 1; }

  got=$(pretty_path "$HOME/test/path")
  # shellcheck disable=SC2088  # 期望输出就是字面量 ~/
  [ "$got" = '~/test/path' ] || { echo "FAIL pretty_path: $got"; return 1; }

  got=$(canonical_dir "$HOME")
  [ -n "$got" ] || { echo "FAIL canonical_dir"; return 1; }

  got=$(printf 'a b  c\n' | tr ' ' '\n' | grep -c .)
  [ "$got" = '3' ] || { echo "FAIL recipe-parse"; return 1; }

  echo "ag self-test: PASS"
}

# ------------------------------------------------------------
# 交互主菜单
# ------------------------------------------------------------

main_menu() {
  require_gum || exit 1

  banner

  while true; do
    c=$(menu_pick "主菜单" \
      "🤖 Agent" "📁 项目" "🛠 开发" "🖥 工作台" "🧠 辅助" "退出") || return 0

    case "$c" in
      "🤖 Agent") agent_menu ;;
      "📁 项目") project_menu ;;
      "🛠 开发") dev_menu ;;
      "🖥 工作台") workstation_menu ;;
      "🧠 辅助") assist_menu ;;
      *) return 0 ;;
    esac
  done
}

# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------

trap 'printf "\n"; exit 0' INT TERM

case "${1:-}" in

  --version|-v)
    echo "ag $AG2_VERSION"
    ;;

  --help|-h)
    cat <<EOF_HELP
ag $AG2_VERSION - AG Command Center

交互菜单：
  ag
      打开分层菜单（Agent / 项目 / 开发 / 工作台 / 辅助）

非交互子命令（适合人与 Agent 脚本调用）：
  ag status            工作台状态概览
  ag doctor            只读诊断（不做任何修改）
  ag project current   输出当前项目完整路径
  ag project list      最近项目（名称<TAB>路径）
  ag session list      tmux 会话（名称<TAB>Agent类型<TAB>路径）
  ag --version / --self-test / --help
EOF_HELP
    ;;

  --self-test)
    self_test
    ;;

  status)
    cmd_status
    ;;

  doctor)
    cmd_doctor
    ;;

  project)
    case "${2:-}" in
      current) cmd_project_current ;;
      list) cmd_project_list ;;
      *)
        echo "用法：ag project current | ag project list"
        exit 2
        ;;
    esac
    ;;

  session)
    case "${2:-}" in
      list) cmd_session_list ;;
      *)
        echo "用法：ag session list"
        exit 2
        ;;
    esac
    ;;

  '')
    main_menu
    ;;

  *)
    echo "未知参数：$1"
    echo "执行 ag --help 查看帮助。"
    exit 2
    ;;

esac
