#!/usr/bin/env bash
# 作り直しの差分を push するための作業ツリーを DIR に作り、SHA を checkout する。actions/regen-diff から呼ばれる。
#
# ジョブの作業ツリーで push しないのは、apply-regen が patch を作る前のコミットに当てるのに、そこには作り直した
# ファイルと PR のコードが作った他の変更が残っているため。また checkout が残した認証情報と push のトークンが
# 二重の Authorization ヘッダーになり push が拒まれるため。
# 履歴は push-agent-fix が base とのマージに使うので全部取る。blob は要るときに取る (blob:none) ので、
# 取るのは checkout とマージに要る分だけになる。
#
# 入力 (環境変数):
#   DIR        - 作る場所 (無いか空のディレクトリ)
#   SHA        - checkout するコミット (patch を作ったジョブの HEAD)
#   PUSH_TOKEN - fetch / push のトークン
#   REMOTE_URL - 取り込み元 (既定: https://github.com/${GITHUB_REPOSITORY}.git)
#   GIT_CMD    - git コマンド名 (既定: git)
set -euo pipefail

: "${DIR:?DIR is required}"
: "${SHA:?SHA is required}"
: "${PUSH_TOKEN:?PUSH_TOKEN is required}"

GIT_CMD="${GIT_CMD:-git}"
REMOTE_URL="${REMOTE_URL:-https://github.com/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}.git}"

mkdir -p "$DIR"
cd "$DIR"
"${GIT_CMD}" init -q .
"${GIT_CMD}" remote add origin "$REMOTE_URL"
# 遅れて取る blob の fetch にもトークンが要るので、push-agent-fix が push の直前に書くのと同じキーに先に書く。
basic="$(printf 'x-access-token:%s' "$PUSH_TOKEN" | base64 | tr -d '\n')"
echo "::add-mask::${basic}"
"${GIT_CMD}" config --local http.https://github.com/.extraheader "AUTHORIZATION: basic ${basic}"
"${GIT_CMD}" config --local remote.origin.promisor true
"${GIT_CMD}" config --local remote.origin.partialclonefilter blob:none
"${GIT_CMD}" fetch -q --no-tags --filter=blob:none origin "$SHA"
"${GIT_CMD}" checkout -q --detach "$SHA"
