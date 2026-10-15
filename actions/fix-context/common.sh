#!/usr/bin/env bash
# fix-context のスクリプトが source する共通関数。

# 文字列をバイト数で切り詰め、超過したら末尾に注記を付ける (黙って欠けると、エージェントが
# 「書かれていない」と誤読するため)。${var:0:n} は UTF-8 ロケールで文字数になるため head -c で切る。
truncate_bytes() {
  local s="$1" max="$2" label="$3"
  if [ "$(printf '%s' "$s" | wc -c)" -gt "$max" ]; then
    s="$(printf '%s' "$s" | head -c "$max")" || true
    s+=$'\n... ('"${label}"' truncated: exceeded '"${max}"' bytes) ...'
  fi
  printf '%s' "$s"
}

# GITHUB_OUTPUT に key<<DELIM ... DELIM を書く。DELIM は本文と衝突しないようランダム化する。
emit_multiline() {
  local key="$1" value="$2" delim
  delim="EOF_$(openssl rand -hex 16)"
  {
    echo "${key}<<${delim}"
    printf '%s\n' "$value"
    echo "${delim}"
  } >> "$GITHUB_OUTPUT"
}
