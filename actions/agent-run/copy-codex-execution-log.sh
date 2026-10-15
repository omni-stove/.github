#!/usr/bin/env bash
# Codex の CODEX_HOME/sessions 配下で最も新しい rollout (.jsonl) を指定先にコピーし、
# コピー先のパスを標準出力に出す。見つからなければ何も出さない。
#   bash copy-codex-execution-log.sh <codex-home> <dest>
set -euo pipefail

codex_home="${1:?codex home is required}"
dest="${2:?destination is required}"
sessions="${codex_home}/sessions"
[ -d "$sessions" ] || exit 0

source="$(find "$sessions" -type f -name '*.jsonl' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 1 || true)"
[ -n "$source" ] || exit 0
cp "$source" "$dest"
printf '%s' "$dest"
