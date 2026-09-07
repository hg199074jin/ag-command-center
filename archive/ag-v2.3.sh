#!/usr/bin/env bash

# ============================================================
# ag v2.3 - AG Command Center
# 基于 Gum 的分层菜单 + 项目 registry + 会话中心
# 兼容 AG 2.1 的状态目录 / 最近项目 / tmux 会话命名
# Compatible with macOS Bash 3.2+
# ============================================================

set -u

AG2_VERSION="2.3.0"

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
# 项目 registry（v2.3.0）：可变运行状态，归 state 目录（config/state 分离）
AG_REGISTRY_DIR="${AG_REGISTRY_DIR:-$AG_STATE_DIR/projects}"

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
  # v2.3.0：支持可选级别参数 ag2_log [INFO|WARN|ERROR] <message>
  # 旧调用（首参直接是消息）保持兼容
  local level="INFO"
  case "${1:-}" in
    INFO|WARN|ERROR)
      level="$1"
      shift
      ;;
  esac

  local size

  mkdir -p "$AG_STATE_DIR/logs" 2>/dev/null || true

  if [ -f "$AG_LOG_FILE" ]; then
    size=$(wc -c < "$AG_LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$AG_LOG_MAX_BYTES" ] 2>/dev/null; then
      mv -f "$AG_LOG_FILE" "$AG_LOG_FILE.1" 2>/dev/null || true
    fi
  fi

  printf '%s [%s] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$level" \
    "$*" >> "$AG_LOG_FILE" 2>/dev/null || true
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
# 项目 registry（v2.3.0：lifecycle 落盘；runtime 实时计算不落盘）
# ------------------------------------------------------------

ag_now() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

registry_init() {
  [ -d "$AG_REGISTRY_DIR" ] || mkdir -p "$AG_REGISTRY_DIR" 2>/dev/null || return 1
  chmod 700 "$AG_REGISTRY_DIR" 2>/dev/null || true
  return 0
}

registry_id_for_path() {
  local canon
  canon=$(canonical_dir "$1") || return 1
  printf '%s' "$canon" | shasum -a 256 | cut -c1-16
}

registry_write_atomic() {
  local target="$1"
  local content="$2"
  local tmp

  tmp="${target}.tmp.$$"
  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if ! jq empty "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    ag2_log ERROR "registry json invalid: $target"
    return 1
  fi

  mv "$tmp" "$target"
}

registry_create() {
  local name="$1"
  local path="$2"
  local id
  local now
  local json

  have jq || return 1
  registry_init || return 1
  id=$(registry_id_for_path "$path") || return 1
  [ -f "${AG_REGISTRY_DIR}/${id}.json" ] && return 0

  now=$(ag_now)
  json=$(jq -n \
    --arg id "$id" \
    --arg name "$name" \
    --arg path "$path" \
    --arg now "$now" \
    '{id:$id, name:$name, path:$path, agent:"none", lifecycle:"parked", tmux_session:null, created_at:$now, updated_at:$now, last_active_at:null}')

  registry_write_atomic "${AG_REGISTRY_DIR}/${id}.json" "$json"
}

registry_get() {
  # registry_get <id> <field>
  local f="${AG_REGISTRY_DIR}/$1.json"
  [ -r "$f" ] || return 1
  jq -r --arg k "$2" '.[$k] // empty' "$f" 2>/dev/null
}

registry_set_field() {
  local id="$1"
  local field="$2"
  local value="$3"
  local f="${AG_REGISTRY_DIR}/${id}.json"
  local out

  [ -f "$f" ] || return 1

  out=$(jq --arg k "$field" --arg v "$value" --arg now "$(ag_now)" \
    '.[$k] = $v | .updated_at = $now' "$f" 2>/dev/null) || {
    ag2_log ERROR "registry read failed: $f"
    return 1
  }

  registry_write_atomic "$f" "$out"
}

# 输出: id<TAB>name<TAB>lifecycle<TAB>agent<TAB>tmux_session<TAB>path
registry_iter() {
  local f
  local id

  [ -d "$AG_REGISTRY_DIR" ] || return 0
  for f in "$AG_REGISTRY_DIR"/*.json; do
    [ -f "$f" ] || continue
    if ! jq empty "$f" >/dev/null 2>&1; then
      ag2_log ERROR "registry corrupt, skipped: $f"
      continue
    fi
    id=$(basename "$f" .json)
    printf '%s\t%s\n' "$id" \
      "$(jq -r '[.name, .lifecycle, (.agent // "none"), (.tmux_session // "-"), .path] | @tsv' "$f" 2>/dev/null)"
  done
}

# runtime 实时判定：registry 记了 tmux_session 且 tmux 里真的存在（v2.3.0 硬性规则）
registry_project_running() {
  local ts
  ts=$(registry_get "$1" "tmux_session") || return 1
  [ -n "$ts" ] && [ "$ts" != "null" ] && [ "$ts" != "-" ] && session_exists "$ts"
}

# 项目成功启动/复用会话后调用：更新（或补建）registry，lifecycle → active
registry_record_start() {
  local dir="$1"
  local launcher="$2"
  local session_name="$3"
  local id

  have jq || return 0
  id=$(registry_id_for_path "$dir") || return 0

  if [ ! -f "${AG_REGISTRY_DIR}/${id}.json" ]; then
    registry_create "$(basename "$dir")" "$dir" || return 0
  fi

  case "$launcher" in
    Codex|Claude)
      registry_set_field "$id" "agent" "$(printf '%s' "$launcher" | tr '[:upper:]' '[:lower:]')"
      ;;
  esac
  registry_set_field "$id" "lifecycle" "active"
  registry_set_field "$id" "tmux_session" "$session_name"
  registry_set_field "$id" "last_active_at" "$(ag_now)"
  ag2_log "registry start id=$id session=$session_name launcher=$launcher"
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

# menu_pick <标题> <选项...>：输出所选选项
# v2.3.0：safe-choose 语义的唯一正式入口
#   - gum（bubbletea）只在 stderr 为真实 tty 时渲染交互界面，必须直连 /dev/tty，
#     用 2>/dev/null 或管道都会导致菜单不可见（实测确认）
#   - 取消时 gum 会清掉自己的界面帧、在原处留一行提示（nothing selected），
#     这里上移一行清除，保证 TUI 不被污染
#   - Esc/取消静默返回非零，调用方不得再 pause；真实异常写日志
menu_pick() {
  local header="$1"
  shift
  local result
  local rc

  result=$(gum choose --header "$header" "$@" 2>/dev/tty)
  rc=$?

  if [ "$rc" -ne 0 ] || [ -z "$result" ]; then
    if [ "$rc" -eq 1 ] || [ "$rc" -ge 128 ]; then
      # 正常取消 / Ctrl+C：擦掉 gum 留下的那一行提示
      printf '\033[1A\033[2K' > /dev/tty 2>/dev/null || true
    elif [ "$rc" -ne 0 ]; then
      ag2_log ERROR "gum choose rc=$rc"
    fi
    return 1
  fi

  printf '%s\n' "$result"
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

  # 纯中文等 slug 化为空 → 用 registry id 前 6 位兜底（v2.3.0 §15）
  if [ -z "$base" ]; then
    base=$(registry_id_for_path "$dir" | cut -c1-6)
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
      registry_record_start "$dir" "$launcher" "$name"
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
  registry_record_start "$dir" "$launcher" "$name"

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

# Yazi 选目录（--cwd-file 机制；v2.3.0 加固：rc 检查 + 取消静默 + canonical 规范化）
pick_with_yazi() {
  local tmp
  local selected
  local rc

  have yazi || { echo "错误：没有找到 yazi。"; return 1; }

  tmp=$(mktemp "${TMPDIR:-/tmp}/ag3-yazi.XXXXXX") || return 1

  yazi "$(ag_choose_default_root)" --cwd-file="$tmp"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    ag2_log WARN "yazi exited rc=$rc"
    return 1
  fi

  selected=""
  [ -s "$tmp" ] && selected=$(cat "$tmp")
  rm -f "$tmp"

  # 用户取消（未选择目录）→ 静默返回，调用方不再 pause
  [ -n "$selected" ] || return 1

  if [ ! -d "$selected" ]; then
    ag2_log ERROR "invalid yazi cwd: $selected"
    return 1
  fi

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
    echo "或在 🖥 工作台 → 会话中心 → tmux 原始会话 中查看所有会话。"
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
        dir=$(pick_project_for_launch) || continue
        [ -n "$dir" ] || continue
        gum confirm "在 $(pretty_path "$dir") 启动 Codex？" &&
          create_session_for_dir "$dir" Codex
        ;;
      "Claude 新任务")
        dir=$(pick_project_for_launch) || continue
        [ -n "$dir" ] || continue
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
# 新建项目（v2.3.0：Yazi 任选父目录 + registry 落盘）
# ------------------------------------------------------------

project_validate_name() {
  local name="$1"

  [ -n "$name" ] || return 1
  [ "$name" != "." ] || return 1
  [ "$name" != ".." ] || return 1

  case "$name" in
    */*) return 1 ;;
  esac

  # 控制字符拒绝
  if printf '%s' "$name" | grep -q '[[:cntrl:]]'; then
    return 1
  fi

  return 0
}

project_open_existing() {
  local target="$1"

  set_current_project "$target" || true
  ag_add_recent_project "$target"
  ag2_log "project opened dir=$target"
  echo
  echo "✅ 当前项目已设置：$(pretty_path "$target")"
  echo "ℹ️ 启动 Agent 请到 🤖 Agent 菜单。"
  pause
}

project_post_create_menu() {
  local name="$1"
  local target="$2"
  local sel

  set_current_project "$target" || true
  ag_add_recent_project "$target"
  ag2_log "project created dir=$target"

  sel=$(menu_pick "创建完成后的动作" \
    "Codex" "Claude" "仅创建项目" "Yazi 打开" "返回") || return 0

  case "$sel" in
    "Codex")
      create_session_for_dir "$target" Codex
      ;;
    "Claude")
      create_session_for_dir "$target" Claude
      ;;
    "Yazi 打开")
      have yazi && yazi "$target"
      ;;
    *)
      echo "ℹ️ 已按『仅创建项目』处理（registry: parked）。启动 Agent 请到 🤖 Agent 菜单。"
      pause
      ;;
  esac
}

project_create() {
  local parent=""
  local name
  local target
  local sel

  while true; do
    # ---- 外层：选择父目录 ----
    while true; do
      sel=$(menu_pick "请选择项目父目录" \
        "Yazi 选择目录" "当前目录" "返回") || return 0

      case "$sel" in
        "Yazi 选择目录")
          parent=$(pick_with_yazi) || continue
          ;;
        "当前目录")
          parent="$PWD"
          ;;
        *)
          return 0
          ;;
      esac
      break
    done

    if [ ! -d "$parent" ]; then
      echo "父目录不可用：$parent"
      pause
      continue
    fi

    # ---- 内层：输入名称 + 同名处理 ----
    while true; do
      # gum input 取消时留一行 "not submitted"，同样擦除
      name=$(gum input --header "父目录：$(pretty_path "$parent")" \
        --placeholder "新项目名称" 2>/dev/tty) || {
        printf '\033[1A\033[2K' > /dev/tty 2>/dev/null || true
        return 0
      }

      if ! project_validate_name "$name"; then
        echo "项目名称无效，请重新输入。"
        pause
        continue
      fi

      target="$parent/$name"

      if [ -d "$target" ]; then
        sel=$(menu_pick "项目已存在：$(pretty_path "$target")" \
          "打开现有项目" "换一个名称" "重新选择父目录" "返回") || return 0

        case "$sel" in
          "打开现有项目")
            project_open_existing "$target"
            return 0
            ;;
          "换一个名称")
            continue
            ;;
          "重新选择父目录")
            break
            ;;
          *)
            return 0
            ;;
        esac
      elif [ -e "$target" ]; then
        echo "同名文件已存在，无法创建：$(pretty_path "$target")"
        pause
        continue
      else
        if ! mkdir "$target" 2>/dev/null; then
          ag2_log ERROR "mkdir failed: $target"
          echo "创建失败：$(pretty_path "$target")"
          pause
          continue
        fi

        target=$(canonical_dir "$target") || return 1

        registry_create "$name" "$target"

        echo
        echo "✅ 项目创建成功：$(pretty_path "$target")"
        echo "ℹ️ AG 只负责建立目录；git/npm/uv 初始化交给 Agent。"
        echo

        project_post_create_menu "$name" "$target"
        return 0
      fi
    done
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
        dir=$(pick_from_recent) || continue
        launcher=$(menu_pick "启动什么" "Codex" "Claude" "Shell") || continue
        create_session_for_dir "$dir" "$launcher"
        ;;
      "Yazi 选择项目")
        dir=$(pick_with_yazi) || continue
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
        project_create
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
# 会话中心（v2.3.0：runtime 实时计算，不落盘）
# ------------------------------------------------------------

pretty_time_ago() {
  local iso="$1"
  local ts_epoch
  local now_epoch
  local diff

  ts_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$iso" '+%s' 2>/dev/null) || {
    printf '%s' "$iso"
    return 0
  }

  now_epoch=$(date '+%s')
  diff=$((now_epoch - ts_epoch))

  if [ "$diff" -lt 0 ]; then
    printf '%s' "$iso"
  elif [ "$diff" -lt 60 ]; then
    echo "刚刚"
  elif [ "$diff" -lt 3600 ]; then
    echo "$((diff / 60))分钟前"
  elif [ "$diff" -lt 86400 ]; then
    echo "$((diff / 3600))小时前"
  else
    echo "$((diff / 86400))天前"
  fi
}

# 原始 tmux 视图（含非 ag 创建的会话：Work / agentboard / 手工会话等）
tmux_session_menu() {
  local -a items=()
  local -a targets=()
  local s
  local sel
  local picked
  local i

  while IFS= read -r s; do
    [ -n "$s" ] || continue
    items+=("$s  （$(session_command "$s") · $(pretty_path "$(session_path "$s")")）")
    targets+=("$s")
  done < <(list_sessions_raw)

  if [ "${#targets[@]}" -eq 0 ]; then
    echo "当前没有 tmux 会话。"
    pause
    return 0
  fi

  sel=$(menu_pick "tmux 原始会话" "${items[@]}") || return 0

  picked=""
  for i in "${!items[@]}"; do
    [ "${items[$i]}" = "$sel" ] && picked="${targets[$i]}" && break
  done

  [ -n "$picked" ] && enter_session "$picked"
}

# 实时扫描四视图（结果写入全局数组与计数）
# ● 正在运行 = tmux has-session 实测（不看 lifecycle，硬性规则）
# ↻ 待继续   = lifecycle=active 且已停止且曾启动过 Agent
# ⏸ 已搁置   = lifecycle=parked（若仍在运行会同时出现在 ●）
# ✓ 已完成   = lifecycle=done（同上）
session_center_scan() {
  local all
  local dup_list
  local id name lc agent ts path
  local short

  run_n=0; rec_n=0; park_n=0; done_n=0
  run_ids=(); run_items=()
  rec_ids=(); rec_items=()
  park_ids=(); park_items=()
  done_ids=(); done_items=()
  center_ids=()
  center_items=()

  all=$(registry_iter)

  # 重名项目在展示时补父目录后缀
  dup_list=$(printf '%s\n' "$all" | awk -F'\t' '{print $2}' | sort | uniq -d)

  while IFS=$'\t' read -r id name lc agent ts path; do
    [ -n "$id" ] || continue

    short="$name"
    if printf '%s\n' "$dup_list" | grep -qxF -- "$name"; then
      short="$name · $(basename "$(dirname "$path")")"
    fi

    if registry_project_running "$id"; then
      run_n=$((run_n + 1))
      run_ids+=("$id")
      run_items+=("● $short")
    elif [ "$lc" = "active" ] && [ -n "$agent" ] && [ "$agent" != "none" ]; then
      rec_n=$((rec_n + 1))
      rec_ids+=("$id")
      rec_items+=("↻ $short")
    fi

    case "$lc" in
      parked)
        park_n=$((park_n + 1))
        park_ids+=("$id")
        park_items+=("⏸ $short")
        ;;
      done)
        done_n=$((done_n + 1))
        done_ids+=("$id")
        done_items+=("✓ $short")
        ;;
    esac
  done <<EOF
$all
EOF
}

session_center() {
  local sel
  local pid
  local i

  while true; do
    session_center_scan

    sel=$(menu_pick "会话中心" \
      "● 正在运行  ${run_n}" \
      "↻ 待继续    ${rec_n}" \
      "⏸ 已搁置    ${park_n}" \
      "✓ 已完成    ${done_n}" \
      "tmux 原始会话" \
      "返回") || return 0

    case "$sel" in
      "tmux 原始会话")
        tmux_session_menu
        continue
        ;;
      "●"*)
        center_ids=("${run_ids[@]}")
        center_items=("${run_items[@]}")
        ;;
      "↻"*)
        center_ids=("${rec_ids[@]}")
        center_items=("${rec_items[@]}")
        ;;
      "⏸"*)
        center_ids=("${park_ids[@]}")
        center_items=("${park_items[@]}")
        ;;
      "✓"*)
        center_ids=("${done_ids[@]}")
        center_items=("${done_items[@]}")
        ;;
      *)
        return 0
        ;;
    esac

    if [ "${#center_ids[@]}" -eq 0 ]; then
      echo "（此分类当前没有项目）"
      pause
      continue
    fi

    sel=$(menu_pick "项目列表" "${center_items[@]}") || continue

    pid=""
    for i in "${!center_items[@]}"; do
      if [ "${center_items[$i]}" = "$sel" ]; then
        pid="${center_ids[$i]}"
        break
      fi
    done

    [ -n "$pid" ] && project_detail "$pid"
  done
}

project_detail() {
  local id="$1"
  local name agent lc ts path last
  local running
  local -a opts=()
  local sel

  while true; do
    name=$(registry_get "$id" "name")
    agent=$(registry_get "$id" "agent")
    lc=$(registry_get "$id" "lifecycle")
    ts=$(registry_get "$id" "tmux_session")
    path=$(registry_get "$id" "path")
    last=$(registry_get "$id" "last_active_at")

    [ -n "$agent" ] || agent="none"

    running=0
    if [ -n "$ts" ] && [ "$ts" != "null" ] && [ "$ts" != "-" ] && session_exists "$ts"; then
      running=1
    fi

    echo
    echo "── $name ─────────────────────"
    echo "Agent : $agent"
    if [ "$running" -eq 1 ]; then
      echo "状态  : ● 运行中（tmux: ${ts}）"
    else
      echo "状态  : ○ 已停止"
    fi
    case "$lc" in
      active) echo "分类  : 进行中" ;;
      parked) echo "分类  : 已搁置" ;;
      done)   echo "分类  : 已完成" ;;
      *)      echo "分类  : $lc" ;;
    esac
    echo "目录  : $(pretty_path "$path")"

    if [ ! -d "$path" ]; then
      case "$path" in
        "$AG_ORICO_VOLUME"/*)
          if [ ! -d "$AG_ORICO_VOLUME" ]; then
            echo "⚠️ 外置盘 $AG_ORICO_VOLUME 未挂载，路径当前不可用（记录已保留）"
          fi
          ;;
        *)
          echo "⚠️ 路径当前不存在（记录已保留，绝不自动清理）"
          ;;
      esac
    fi

    if [ -n "$last" ] && [ "$last" != "null" ]; then
      echo "活跃  : $(pretty_time_ago "$last")"
    fi
    echo

    opts=()
    if [ "$running" -eq 1 ]; then
      opts+=("进入会话")
    else
      opts+=("用 Codex 继续" "用 Claude 继续")
    fi
    opts+=("Yazi 打开目录")
    [ "$lc" != "parked" ] && opts+=("标记搁置")
    [ "$lc" != "done" ] && opts+=("标记完成")
    [ "$running" -eq 1 ] && opts+=("关闭会话")
    opts+=("返回")

    sel=$(menu_pick "项目详情" "${opts[@]}") || return 0

    case "$sel" in
      "进入会话")
        enter_session "$ts"
        return 0
        ;;
      "用 Codex 继续")
        create_session_for_dir "$path" Codex
        return 0
        ;;
      "用 Claude 继续")
        create_session_for_dir "$path" Claude
        return 0
        ;;
      "Yazi 打开目录")
        if [ -d "$path" ]; then
          yazi "$path"
        else
          echo "目录当前不可用。"
          pause
        fi
        ;;
      "标记搁置")
        project_mark_parked "$id" || continue
        return 0
        ;;
      "标记完成")
        project_mark_done "$id" || continue
        return 0
        ;;
      "关闭会话")
        project_kill_session "$id"
        ;;
      *)
        return 0
        ;;
    esac
  done
}

project_mark_parked() {
  local id="$1"
  local ts
  local sel

  ts=$(registry_get "$id" "tmux_session")

  if [ -n "$ts" ] && [ "$ts" != "null" ] && [ "$ts" != "-" ] && session_exists "$ts"; then
    sel=$(menu_pick "当前会话仍在运行。" \
      "仅标记搁置" "同时关闭 tmux" "取消") || return 1

    case "$sel" in
      "仅标记搁置")
        registry_set_field "$id" "lifecycle" "parked"
        ag2_log "lifecycle parked id=$id"
        echo "已标记搁置。会话仍在运行，项目仍会出现在『● 正在运行』。"
        pause
        return 0
        ;;
      "同时关闭 tmux")
        tmux kill-session -t "=$ts" 2>/dev/null || true
        registry_set_field "$id" "lifecycle" "parked"
        ag2_log "lifecycle parked + tmux killed id=$id session=$ts"
        echo "已标记搁置并关闭会话：$ts"
        pause
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  fi

  registry_set_field "$id" "lifecycle" "parked"
  ag2_log "lifecycle parked id=$id"
  echo "已标记搁置。"
  pause
  return 0
}

project_mark_done() {
  local id="$1"
  local ts
  local sel

  ts=$(registry_get "$id" "tmux_session")

  if [ -n "$ts" ] && [ "$ts" != "null" ] && [ "$ts" != "-" ] && session_exists "$ts"; then
    sel=$(menu_pick "当前会话仍在运行。" \
      "标记完成并关闭 tmux" "仅标记完成" "取消") || return 1

    case "$sel" in
      "标记完成并关闭 tmux")
        tmux kill-session -t "=$ts" 2>/dev/null || true
        registry_set_field "$id" "lifecycle" "done"
        ag2_log "lifecycle done + tmux killed id=$id session=$ts"
        echo "已标记完成并关闭会话：$ts"
        pause
        return 0
        ;;
      "仅标记完成")
        registry_set_field "$id" "lifecycle" "done"
        ag2_log "lifecycle done id=$id"
        echo "已标记完成。会话仍在运行，项目仍会出现在『● 正在运行』。"
        pause
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  fi

  registry_set_field "$id" "lifecycle" "done"
  ag2_log "lifecycle done id=$id"
  echo "已标记完成。"
  pause
  return 0
}

project_kill_session() {
  local id="$1"
  local ts
  local cur=""

  ts=$(registry_get "$id" "tmux_session")
  [ -n "$ts" ] && [ "$ts" != "null" ] && [ "$ts" != "-" ] || return 0

  if ! session_exists "$ts"; then
    echo "会话已不存在：$ts"
    pause
    return 0
  fi

  if [ -n "${TMUX:-}" ]; then
    cur=$(tmux display-message -p '#S' 2>/dev/null || true)
  fi
  if [ "$cur" = "$ts" ]; then
    echo "⚠️ 注意：你当前就在该会话中，关闭后会回到外层终端。"
  fi

  gum confirm "确认关闭 tmux 会话 '$ts'？（只关会话，不改动项目分类）" || return 0

  tmux kill-session -t "=$ts" 2>/dev/null || true
  ag2_log "tmux killed id=$id session=$ts"
  echo "已关闭会话：$ts"
  pause
  return 0
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
  while true; do
    c=$(menu_pick "🖥 工作台" \
      "Agentboard" "会话中心" "系统监控" "磁盘分析" \
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
      "会话中心")
        session_center
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

  agent_ws_status_block
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

  if [ -d "$AG_REGISTRY_DIR" ]; then
    local reg_n=0
    local reg_f
    for reg_f in "$AG_REGISTRY_DIR"/*.json; do
      [ -f "$reg_f" ] && reg_n=$((reg_n + 1))
    done
    echo "✅ registry（${reg_n} 个项目，位于 ${AG_REGISTRY_DIR}）"
  else
    echo "ℹ️ registry 尚未创建（首次新建/启动项目时生成）"
  fi

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

  # ---- registry 基础能力（在临时目录验证，不碰真实数据）----
  local tmpreg
  local id1 id2
  tmpreg=$(mktemp -d "${TMPDIR:-/tmp}/ag3-regtest.XXXXXX") || tmpreg=""
  if [ -n "$tmpreg" ]; then
    AG_REGISTRY_DIR="$tmpreg"
    mkdir -p "$tmpreg/demo-a" "$tmpreg/demo-b"

    registry_create "demo-a" "$tmpreg/demo-a" || { echo "FAIL registry_create"; return 1; }

    id1=$(registry_id_for_path "$tmpreg/demo-a")
    [ -f "$tmpreg/${id1}.json" ] || { echo "FAIL registry file"; return 1; }
    jq empty "$tmpreg/${id1}.json" >/dev/null 2>&1 || { echo "FAIL registry json"; return 1; }
    [ "$(registry_get "$id1" lifecycle)" = "parked" ] || { echo "FAIL lifecycle initial"; return 1; }

    registry_set_field "$id1" lifecycle active
    [ "$(registry_get "$id1" lifecycle)" = "active" ] || { echo "FAIL registry_set_field"; return 1; }

    id2=$(registry_id_for_path "$tmpreg/demo-b")
    [ "$id1" != "$id2" ] || { echo "FAIL registry ids distinct"; return 1; }

    if project_validate_name "a/b"; then echo "FAIL validate slash"; return 1; fi
    if project_validate_name ".."; then echo "FAIL validate dotdot"; return 1; fi
    project_validate_name "ok-name" || { echo "FAIL validate ok"; return 1; }

    rm -rf "$tmpreg"
  fi

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
# Agent Workstation 集成（agent-notify 状态，V1.1 增量）
# ------------------------------------------------------------
AGENT_WS_STATE_DIR="$HOME/.agent-workstation/state"
AGENT_WS_JQ="/usr/bin/jq"
command -v jq >/dev/null 2>&1 && AGENT_WS_JQ="$(command -v jq)"

# 输出行（| 分隔）：status|agent|project|tmux_session|tmux_window|tmux_pane|id
# $1 = 过滤器：空=全部；具体状态名；BAD=FAILED+STALE
agent_ws_rows() {
  local filter="${1:-}"
  local f row st ag pr ts tw tp id
  [ -d "$AGENT_WS_STATE_DIR" ] || return 0
  [ -x "$AGENT_WS_JQ" ] || return 0
  for f in "$AGENT_WS_STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    row=$("$AGENT_WS_JQ" -r '[(.status//"?"),(.agent//"?"),(.project//"?"),(.tmux_session//""),(.tmux_window//""),(.tmux_pane//""),(.id//"-")] | join("|")' "$f" 2>/dev/null) || continue
    [ -n "$row" ] || continue
    IFS='|' read -r st ag pr ts tw tp id <<<"$row"
    # 字段守卫：状态非法或 id 缺失说明字段被 | 注入污染，跳过该行（防静默跳错会话）
    case "$st" in
      RUNNING|WAITING|DONE|FAILED|STALE|UNKNOWN) ;;
      *) continue ;;
    esac
    [ -n "$id" ] || continue
    if [ -n "$filter" ]; then
      if [ "$filter" = "BAD" ]; then
        [ "$st" = "FAILED" ] || [ "$st" = "STALE" ] || continue
      else
        [ "$st" = "$filter" ] || continue
      fi
    fi
    printf '%s\n' "$row"
  done
  return 0
}

agent_ws_print_rows() { # $1=rows [$2="n" 时每行前加编号]
  local numbered="${2:-}"
  printf '%s\n' "$1" | awk -F'|' -v numbered="$numbered" '{
    if($4=="")$4="-"; if($5=="")$5="-";
    i=$1; icon="○";
    if(i=="RUNNING")icon="●"; else if(i=="WAITING")icon="⚠"; else if(i=="DONE")icon="✓"; else if(i=="FAILED"||i=="STALE")icon="✕";
    if(numbered=="n")
      printf "  %d) %s %-8s %-7s tmux=%s:%s (%s)\n", NR, icon, $2, $3, $4, $5, $7;
    else
      printf "  %s %-8s %-7s tmux=%s:%s (%s)\n", icon, $2, $3, $4, $5, $7;
  }'
}

# $1..$7 = st ag pr ts tw tp id
agent_ws_jump() {
  local st="$1" ag="$2" pr="$3" ts="$4" tw="$5" tp="$6" id="$7"
  local TMUX_BIN="/opt/homebrew/bin/tmux"
  [ -x "$TMUX_BIN" ] || TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
  if [ -z "$TMUX_BIN" ]; then
    echo "tmux 不可用"
    return 1
  fi
  if [ -z "$ts" ]; then
    echo "Agent ${id} 无 tmux 定位信息 (project=${pr})"
    return 1
  fi
  local target="=${ts}"
  [ -n "$tw" ] && target="${target}:${tw}"
  if [ -n "${AGENT_WS_DRY_RUN:-}" ]; then
    echo "[dry-run] id=$id target=$target pane=${tp:--} mode=$( [ -n "${TMUX:-}" ] && echo switch || echo attach )"
    return 0
  fi
  if [ -n "${TMUX:-}" ]; then
    "$TMUX_BIN" switch-client -t "$target" 2>/dev/null || "$TMUX_BIN" switch-client -t "=${ts}"
    [ -n "$tp" ] && "$TMUX_BIN" select-pane -t "$tp" >/dev/null 2>&1
  else
    # 先把 session 当前 window/pane 设到 Agent 位置，再 attach（tmux 3.7c 用 = 会话名: 精确匹配）
    [ -n "$tw" ] && "$TMUX_BIN" select-window -t "$target" >/dev/null 2>&1
    [ -n "$tp" ] && "$TMUX_BIN" select-pane -t "$tp" >/dev/null 2>&1
    "$TMUX_BIN" attach-session -t "=${ts}"
  fi
}

cmd_agent_waiting() {
  local rows pick n count
  rows=$(agent_ws_rows WAITING)
  if [ -z "$rows" ]; then
    echo "当前没有 Waiting Agent"
    return 0
  fi
  count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  if [ "$count" -eq 1 ]; then
    pick="$rows"
  else
    agent_ws_print_rows "$rows" n
    printf '输入编号选择 Agent（回车取消）：'
    read -r n
    case "$n" in
      ''|*[!0-9]*) echo "已取消"; return 0 ;;
    esac
    [ "$n" -ge 1 ] || { echo "编号无效"; return 1; }
    pick=$(printf '%s\n' "$rows" | sed -n "${n}p")
    if [ -z "$pick" ]; then echo "编号无效"; return 1; fi
  fi
  IFS='|' read -r st ag pr ts tw tp id <<<"$pick"
  agent_ws_jump "$st" "$ag" "$pr" "$ts" "$tw" "$tp" "$id"
}

cmd_agent_failed() {
  local rows
  rows=$(agent_ws_rows BAD)
  if [ -z "$rows" ]; then
    echo "当前没有 Failed/Stale Agent"
    return 0
  fi
  agent_ws_print_rows "$rows"
  return 0
}

cmd_agent_open() {
  local id="${1:-}" f row
  if [ -z "$id" ]; then
    echo "用法：ag open <agent-session-id>"
    return 2
  fi
  f="$AGENT_WS_STATE_DIR/${id}.json"
  if [ ! -f "$f" ]; then
    echo "未找到 Agent session：$id"
    return 1
  fi
  row=$("$AGENT_WS_JQ" -r '[(.status//"?"),(.agent//"?"),(.project//"?"),(.tmux_session//""),(.tmux_window//""),(.tmux_pane//""),(.id//"-")] | join("|")' "$f" 2>/dev/null)
  IFS='|' read -r st ag pr ts tw tp id <<<"$row"
  case "$st" in
    RUNNING|WAITING|DONE|FAILED|STALE|UNKNOWN) ;;
    *) echo "Agent session 记录异常：$id"; return 1 ;;
  esac
  agent_ws_jump "$st" "$ag" "$pr" "$ts" "$tw" "$tp" "$id"
}

agent_ws_status_block() {
  local all
  all=$(agent_ws_rows "")
  [ -n "$all" ] || return 0
  echo ""
  echo "Agent Workstation :"
  agent_ws_print_rows "$all"
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
      工作台 → 会话中心：正在运行 / 待继续 / 已搁置 / 已完成 / tmux 原始会话

非交互子命令（适合人与 Agent 脚本调用）：
  ag status            工作台状态概览
  ag doctor            只读诊断（不做任何修改）
  ag w                 进入 WAITING 的 Agent（agent-notify）
  ag f                 列出 FAILED/STALE 的 Agent（agent-notify）
  ag open <id>         按 agent-session-id 打开对应 tmux 位置
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

  w)
    cmd_agent_waiting
    ;;

  f)
    cmd_agent_failed
    ;;

  open)
    cmd_agent_open "${2:-}"
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
