#!/usr/bin/env bash
# agent-run のツールポリシー判定 (source 専用)。prepare.sh と tool-policy-hook.sh が共有する。
#
# - split_shell_words      コマンドをシェルの単語に分割する (メタ文字・未閉のクォートは拒否)
# - is_safe_read_command   read-only プロファイルで許可できる読み取り専用コマンドか
# - matches_rule           ツール呼び出しが Claude 形式の rule (Tool / Bash(pattern)) に一致するか
#
# bash 3.2 (macOS 標準) でも動くよう、mapfile / 連想配列 / ${var,,} は使わない。
# 要素が無いかもしれない配列は ${arr[@]+"${arr[@]}"} で展開する (set -u 対策)。

# rule の base ツール名 ("Bash(git diff:*)" → "Bash")。
base_tool() {
  local rule="$1"
  rule="${rule%%(*}"
  rule="${rule#"${rule%%[![:space:]]*}"}"
  rule="${rule%"${rule##*[![:space:]]}"}"
  printf '%s' "$rule"
}

# コマンドをシェルの単語に分割して配列 WORDS に入れる。
# 空 / シェルのメタ文字 (; & | > < ` $ \ 改行) を含む / クォートが閉じていない場合は 1 を返す。
split_shell_words() {
  local command="$1" word="" quote="" ch i
  WORDS=()
  [ -n "${command//[[:space:]]/}" ] || return 1
  for ((i = 0; i < ${#command}; i++)); do
    ch="${command:i:1}"
    # shellcheck disable=SC1003 # バックスラッシュそのものをメタ文字として弾く。
    case "$ch" in
      ';' | '&' | '|' | '>' | '<' | '`' | '$' | '\' | $'\n' | $'\r') return 1 ;;
    esac
    if [ -n "$quote" ]; then
      if [ "$ch" = "$quote" ]; then quote=""; else word+="$ch"; fi
    elif [ "$ch" = '"' ] || [ "$ch" = "'" ]; then
      quote="$ch"
    elif [[ "$ch" =~ [[:space:]] ]]; then
      if [ -n "$word" ]; then
        WORDS+=("$word")
        word=""
      fi
    else
      word+="$ch"
    fi
  done
  [ -z "$quote" ] || return 1
  [ -n "$word" ] && WORDS+=("$word")
  return 0
}

# value が rule のコマンドパターンに一致するか。
# "git diff:*" は "git diff" と "git diff <args>" に、"git diff" は完全一致か空白区切りの前方一致に当てる。
matches_pattern() {
  local value="$1" pattern="$2" wildcard=false escaped="" ch i
  if [[ "$pattern" == *":*" ]]; then
    wildcard=true
    pattern="${pattern%:\*}"
  fi
  for ((i = 0; i < ${#pattern}; i++)); do
    ch="${pattern:i:1}"
    # shellcheck disable=SC1003 # バックスラッシュも ERE のメタ文字としてエスケープする。
    case "$ch" in
      '.' | '+' | '?' | '^' | '$' | '{' | '}' | '(' | ')' | '|' | '[' | ']' | '\') escaped+="\\$ch" ;;
      '*') escaped+=".*" ;;
      *) escaped+="$ch" ;;
    esac
  done
  local regex
  if $wildcard; then
    regex="^${escaped}([[:space:]].*)?\$"
    [[ "$value" =~ $regex ]]
    return
  fi
  regex="^${escaped}\$"
  [[ "$value" =~ $regex ]] && return 0
  regex="^${escaped}([[:space:]]|\$)"
  [[ "$value" =~ $regex ]]
}

# 絶対パスを字句的に正規化する (. / .. / 連続スラッシュを畳む)。
normalize_path() {
  local rest="$1" seg out=""
  rest="${rest#/}"
  while :; do
    seg="${rest%%/*}"
    case "$seg" in
      '' | '.') ;;
      '..') out="${out%/*}" ;;
      *) out="${out}/${seg}" ;;
    esac
    [[ "$rest" == */* ]] || break
    rest="${rest#*/}"
  done
  printf '%s' "${out:-/}"
}

# workspace からの相対パス (または絶対パス) を正規化した絶対パスにする。
resolve_path() {
  local workspace="$1" value="$2"
  if [[ "$value" == /* ]]; then
    normalize_path "$value"
  else
    normalize_path "${workspace}/${value}"
  fi
}

# path が workspace 配下か (字句比較)。
is_within_workspace() {
  local path="$1" workspace="$2"
  [ "$path" = "$workspace" ] || [[ "$path" == "${workspace}/"* ]]
}

# 単語列に workspace 外を指すパスがあれば 0 を返す。
#   - .. / proc / sys / dev を含むパス、~ で始まる値は無条件に危険
#   - 絶対パスは workspace 配下でなければ危険
#   - 存在する相対パスは、シンボリックリンクの実体 (realpath) が workspace 外なら危険
has_unsafe_path() {
  local workspace="$1"
  shift
  local ws word value candidate static_prefix static_candidate glob_index i ch real
  ws="$(realpath "$workspace" 2>/dev/null)" || return 0
  for word in "$@"; do
    if [[ "$word" =~ (^|/)(\.\.|proc|sys|dev)(/|$) ]] || [[ "$word" == "~"* ]]; then
      return 0
    fi
    value="$word"
    [[ "$word" == *=* ]] && value="${word#*=}"
    if [[ "$value" == /* ]] && ! is_within_workspace "$(normalize_path "$value")" "$ws"; then
      return 0
    fi
    [[ "$value" == -* ]] && continue
    if [[ "$value" != */* ]] && [ ! -e "$(resolve_path "$ws" "$value")" ]; then
      continue
    fi
    candidate="$(resolve_path "$ws" "$value")"
    is_within_workspace "$candidate" "$ws" || return 0
    glob_index=-1
    for ((i = 0; i < ${#value}; i++)); do
      ch="${value:i:1}"
      case "$ch" in
        '*' | '?' | '[' | ']')
          glob_index=$i
          break
          ;;
      esac
    done
    if [ "$glob_index" -eq -1 ]; then
      static_candidate="$candidate"
    else
      static_prefix="${value:0:glob_index}"
      if [[ "$static_prefix" == */ ]]; then
        static_prefix="$(printf '%s' "$static_prefix" | sed 's#/*$##')"
        static_candidate="$(resolve_path "$ws" "$static_prefix")"
      else
        static_candidate="$(resolve_path "$ws" "$(dirname "$static_prefix")")"
      fi
    fi
    if [ -e "$static_candidate" ]; then
      real="$(realpath "$static_candidate" 2>/dev/null)" || return 0
      is_within_workspace "$real" "$ws" || return 0
    fi
  done
  return 1
}

is_safe_git_branch_option() {
  case "$1" in
    --list | --show-current | --all | -a | --remotes | -r | --verbose | -v | -vv | --no-abbrev | --omit-empty) return 0 ;;
  esac
  [[ "$1" =~ ^(--format|--sort|--color|--contains|--no-contains|--merged|--no-merged|--column)= ]]
}

# git の引数列が読み取り専用か。
is_safe_git() {
  local -a args=("$@") git_args=()
  local no_locks=false sub a
  if [ "${1-}" = "--no-optional-locks" ]; then
    no_locks=true
    git_args=(${args[@]+"${args[@]:1}"})
  else
    git_args=("$@")
  fi
  sub="${git_args[0]-}"
  case "$sub" in
    status | diff | log | show | rev-parse | branch) ;;
    *) return 1 ;;
  esac
  if [ "$sub" = status ] && ! $no_locks; then
    return 1
  fi
  if [ "$sub" = branch ]; then
    for a in ${git_args[@]+"${git_args[@]:1}"}; do
      is_safe_git_branch_option "$a" || return 1
    done
  fi
  for a in ${git_args[@]+"${git_args[@]}"}; do
    case "$a" in
      --ext-diff | --textconv | --show-signature | --verify-signatures | --output | --output=*) return 1 ;;
    esac
  done
  return 0
}

# sed の引数列が読み取り専用 (-n 付きで p / d スクリプト 1 つだけ) か。
is_safe_sed() {
  local -a args=("$@")
  local has_quiet=false a i script="" script_count=0
  for a in "$@"; do
    case "$a" in -n | --quiet | --silent) has_quiet=true ;; esac
  done
  $has_quiet || return 1
  for a in "$@"; do
    case "$a" in -i* | -f | --file | --in-place* | --file=*) return 1 ;; esac
  done
  for ((i = 0; i < $#; i++)); do
    a="${args[i]}"
    if [ "$a" = "-e" ] || [ "$a" = "--expression" ]; then
      script="${args[i + 1]-}"
      script_count=$((script_count + 1))
      i=$((i + 1))
    elif [[ "$a" != -* ]]; then
      script="$a"
      script_count=$((script_count + 1))
      break
    fi
  done
  [ "$script_count" -eq 1 ] || return 1
  [[ "$script" =~ ^(([0-9]+|\$)(,([0-9]+|\$))?)?[pd]$ ]]
}

# コマンドが read-only プロファイルで許可できる読み取り専用コマンドか。
is_safe_read_command() {
  local command="$1" workspace="$2" program a
  split_shell_words "$command" || return 1
  has_unsafe_path "$workspace" ${WORDS[@]+"${WORDS[@]}"} && return 1
  program="${WORDS[0]}"
  local -a args=(${WORDS[@]+"${WORDS[@]:1}"})
  case "$program" in
    pwd | ls | cat | head | tail | grep | wc | stat | file) return 0 ;;
    rg)
      for a in ${args[@]+"${args[@]}"}; do
        if [ "$a" = "--pre" ] || [[ "$a" == "--pre="* ]]; then return 1; fi
      done
      return 0
      ;;
    find)
      for a in ${args[@]+"${args[@]}"}; do
        if [[ "$a" =~ ^-(delete|exec(dir)?|ok(dir)?|fprint(f)?|fls)$ ]]; then return 1; fi
      done
      return 0
      ;;
    sed) is_safe_sed ${args[@]+"${args[@]}"} ;;
    git) is_safe_git ${args[@]+"${args[@]}"} ;;
    *) return 1 ;;
  esac
}

# Codex のツール名を Claude 形式に寄せる。
normalize_tool_name() {
  case "$1" in
    exec_command | write_stdin) printf 'Bash' ;;
    view_image) printf 'Read' ;;
    web_search) printf 'WebSearch' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ツール呼び出し (tool, command) が rule に一致するか。
matches_rule() {
  local tool="$1" command="$2" rule="$3" base pattern
  base="$(base_tool "$rule")"
  if [ "$tool" = apply_patch ]; then
    case "$base" in Edit | Write | NotebookEdit | apply_patch) return 0 ;; *) return 1 ;; esac
  fi
  if [ "$tool" = WebSearch ] && { [ "$base" = WebFetch ] || [ "$base" = WebSearch ]; }; then
    return 0
  fi
  if [ "$tool" = Bash ]; then
    if [ "$base" = Bash ] && [[ "$rule" != *"("* ]]; then return 0; fi
    if [[ "$rule" =~ ^Bash\((.*)\)$ ]]; then
      pattern="${BASH_REMATCH[1]}"
      split_shell_words "$command" || return 1
      matches_pattern "$command" "$pattern"
      return
    fi
    return 1
  fi
  [ "$tool" = "$base" ] || [[ "$tool" == *"__${base}" ]]
}
