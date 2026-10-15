#!/usr/bin/env bash
# PR body を「目的 / 実装方針 / 確認方法 / 見て欲しいポイント」の見出し構成で組み立てて stdout に出す。
# gh pr create --body は Web UI と違い PULL_REQUEST_TEMPLATE.md を通らないため、sh 経由で PR を
# 作る経路はここで骨格・順序・見出しを固定する。節の中身は呼び出し側 (エージェント) が決める。
#
# 引数: $1 = 目的, $2 = 実装方針, $3 = 確認方法, $4 = 見て欲しいポイント (任意)
# refs や Closes #<issue> の行は「目的」($1) に含めて渡す。空の節は既定文言で埋める。
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: pr-body-template.sh <purpose> <approach> <verification> [review_points]" >&2
  exit 2
fi

purpose="$1"
approach="$2"
verification="$3"
review_points="${4:-}"

cat <<MARKDOWN
## 目的

${purpose:-(記載なし)}

## 実装方針

${approach:-(記載なし)}

## 確認方法

${verification:-(記載なし)}

## 見て欲しいポイント

${review_points:-特になし}
MARKDOWN
