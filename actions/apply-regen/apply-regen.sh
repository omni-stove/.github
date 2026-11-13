#!/usr/bin/env bash
# actions/regen-diff が上げた patch を作業ツリーに当てる。actions/apply-regen から呼ばれる。
# 作業ツリーは patch を作ったのと同じコミット (その run の github.sha) を checkout しておく。
#
# PR の head がすでに作り直しのコミットなのにまた差分が出たら、当てずに result=loop を返す。生成が実行のたびに
# 違う結果を出すと、作り直し → push → 再 CI が止まらなくなるため。
#
# 出力 (GITHUB_OUTPUT の result):
#   applied  - すべての patch を当てた
#   loop     - head が作り直しのコミットだった (当てていない)
#   conflict - 当たらない patch があった (patch 同士の pathspec の重なりなど)
#
# 入力 (環境変数):
#   PATCH_DIR     - download-artifact が patch を落としたディレクトリ (regen-*/regen.patch)
#   HEAD_SHA      - PR の head のコミット
#   COMMIT_PREFIX - 作り直しのコミットの件名の接頭辞
#   GIT_CMD       - git コマンド名 (既定: git)
#   GITHUB_OUTPUT - 出力先
set -euo pipefail

: "${PATCH_DIR:?PATCH_DIR is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${COMMIT_PREFIX:?COMMIT_PREFIX is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

GIT_CMD="${GIT_CMD:-git}"

finish() {
  echo "result=$1" >> "$GITHUB_OUTPUT"
  echo "$2"
  exit 0
}

subject="$("${GIT_CMD}" log -1 --format=%s "$HEAD_SHA")"
case "$subject" in
  "$COMMIT_PREFIX"*) finish loop "::error::head (${HEAD_SHA}) is already a regeneration commit, yet regenerating changed files again; the generator is not deterministic." ;;
esac

while IFS= read -r patch; do
  echo "applying ${patch#"$PATCH_DIR"/}"
  if ! "${GIT_CMD}" apply --binary "$patch"; then
    finish conflict "::error::${patch#"$PATCH_DIR"/} does not apply; check that the pathspecs of regen-diff do not overlap across jobs."
  fi
done < <(find "$PATCH_DIR" -type f -name '*.patch' -size +0 | sort)

finish applied "Applied the regenerated changes."
