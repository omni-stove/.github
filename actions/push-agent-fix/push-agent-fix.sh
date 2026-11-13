#!/usr/bin/env bash
# エージェントが編集した内容を 1 つの自動修正コミットにまとめ、PR の head ブランチに積む。
# actions/push-agent-fix から呼ばれる。エージェントには編集だけさせ、commit 粒度とメッセージは
# ここで確定させる (commit し忘れや複数コミットへの分割を防ぐ)。
#
# push の前に最新の PR head に最新の base をマージし、その上に自動修正コミットを積み直す。エージェントの
# 実行中に作成者が push してリモートが進んでいても取りこぼさず、push 後の CI は最新の base に対して走る。
# push が reject されたら (さらに別の push が入った) fetch から再試行する。
# マージか積み直しがコンフリクトしたら積まずに人間に委ねる。
# ON_BASE_CONFLICT=skip なら、base のマージだけがコンフリクトしたときは base をマージせず最新の head に積む。
# actions/base-merge でエージェントが base とのコンフリクトを解消したマージコミット (RESOLVED_MERGE) があれば、
# 最新の head にそれを先にマージしてから base をマージする。その上に積む自動修正の変更が無くても push する。
#
# エージェントの実行中に緊急避難口のラベルが付くと、ラベル付与時の run キャンセルをすり抜けて
# ここに到達しうるので、commit の前にラベルを確認して何もしない。
#
# claude-code-action が PR の base から戻した設定 (RESTORED_CONFIG_PATHS) は、commit の前に HEAD の
# 内容に戻す。エージェントがこれらに加えた編集も捨てる。
#
# 出力 (GITHUB_OUTPUT の result):
#   pushed   - commit して push した
#   noop     - 作業ツリーに変更が無く、RESOLVED_MERGE も無かった
#   conflict - RESOLVED_MERGE か base のマージ (ON_BASE_CONFLICT=abort のとき) か自動修正コミットの積み直しが
#              コンフリクトした (abort 済み)
#   skipped  - 緊急避難口のラベルが付いていた
#   failed   - リトライ上限まで push できなかった (非ゼロで終了する)
#
# 入力 (環境変数):
#   REF            - push する PR の head ブランチ名
#   BASE           - マージする PR の base ブランチ名 (空なら PR / REPO から引く。引けなければマージしない)
#   RESOLVED_MERGE - base とのコンフリクトを解消したマージコミット (HEAD の祖先。空なら無し)
#   ON_BASE_CONFLICT - base のマージがコンフリクトしたとき abort (conflict で終える) か skip (base 無しで積む)。既定: abort
#   PR / REPO      - ラベルと base の確認用 (どちらか空なら確認しない)
#   PUSH_TOKEN     - push に使うトークン。push 直前に extraheader で渡す (空なら既存の認証を使う)
#   STRUCTURED     - エージェントの structured_output。.summary の 1 行目をコミット件名に使う
#   BYPASS_LABELS  - push しないラベル (カンマ区切り。既定: hotfix,revert)
#   COMMIT_PREFIX  - コミット件名の接頭辞 (既定: [agent-fix])
#   GIT_USER_NAME / GIT_USER_EMAIL - コミットの author
#   MAX_RETRIES    - push reject 時のリトライ上限 (既定: 3)
#   GIT_CMD / GH_CMD - コマンド名 (既定: git / gh)
#   GITHUB_OUTPUT  - 出力先
set -euo pipefail

: "${REF:?REF is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

GIT_CMD="${GIT_CMD:-git}"
GH_CMD="${GH_CMD:-gh}"
MAX_RETRIES="${MAX_RETRIES:-3}"
BYPASS_LABELS="${BYPASS_LABELS:-hotfix,revert}"
COMMIT_PREFIX="${COMMIT_PREFIX:-[agent-fix]}"
ON_BASE_CONFLICT="${ON_BASE_CONFLICT:-abort}"
case "$ON_BASE_CONFLICT" in
  abort | skip) ;;
  *) echo "::error::ON_BASE_CONFLICT must be abort or skip: ${ON_BASE_CONFLICT}"; exit 1 ;;
esac
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

finish() {
  echo "result=$1" >> "$GITHUB_OUTPUT"
  echo "$2"
  exit 0
}

if [ -n "${PR:-}" ] && [ -n "${REPO:-}" ]; then
  labels="$("${GH_CMD}" pr view "$PR" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  while IFS= read -r label; do
    label="$(printf '%s' "$label" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    [ -n "$label" ] || continue
    if printf '%s\n' "$labels" | grep -qxF "$label"; then
      finish skipped "'${label}' labeled; skipping push of ${COMMIT_PREFIX}."
    fi
  done <<<"$(printf '%s' "$BYPASS_LABELS" | tr ',' '\n')"
fi

# claude-code-action は PR の head を信用せず、起動時に読む設定を base の内容で作業ツリーに上書きして
# そのまま残す。add -A でそれを積むと、これらを変える PR が自動修正のたびに base へ巻き戻される。
# 一覧は claude-code-action の SENSITIVE_PATHS (src/github/operations/restore-config.ts) と揃える。
# base にだけあるファイルが残らないよう、checkout の前に消す。
RESTORED_CONFIG_PATHS=(.claude .mcp.json .claude.json .gitmodules .ripgreprc CLAUDE.md CLAUDE.local.md .husky)
for path in "${RESTORED_CONFIG_PATHS[@]}"; do
  rm -rf -- "$path"
  if "${GIT_CMD}" cat-file -e "HEAD:${path}" 2>/dev/null; then
    "${GIT_CMD}" checkout HEAD -- "$path"
  fi
done

RESOLVED_MERGE="${RESOLVED_MERGE:-}"
"${GIT_CMD}" config user.name "$GIT_USER_NAME"
"${GIT_CMD}" config user.email "$GIT_USER_EMAIL"

fix_sha=""
"${GIT_CMD}" add -A
if "${GIT_CMD}" diff --cached --quiet; then
  [ -n "$RESOLVED_MERGE" ] || finish noop "No changes to commit."
  echo "No changes to commit; pushing the resolved merge alone."
else
  summary="$(printf '%s' "${STRUCTURED:-}" | jq -er '.summary // ""' 2>/dev/null | tr -d '\r' | head -n 1 || true)"
  [ -n "$summary" ] || summary="address CI failures and review comments"
  "${GIT_CMD}" commit --no-verify -m "${COMMIT_PREFIX} ${summary}"
  fix_sha="$("${GIT_CMD}" rev-parse HEAD)"
fi

# 作業ツリーはエージェントが編集でき、PR のコードでもあるので、checkout ではトークンを .git/config に残していない。
# トークンを戻す前に、git が外部コマンドを起動する経路 (hook / fsmonitor 等) を潰して読まれないようにする。
if [ -n "${PUSH_TOKEN:-}" ]; then
  git_dir="$("${GIT_CMD}" rev-parse --git-dir)"
  rm -rf "${git_dir}/hooks"
  mkdir -p "${git_dir}/hooks"
  "${GIT_CMD}" config --local core.hooksPath /dev/null
  "${GIT_CMD}" config --local core.fsmonitor false
  "${GIT_CMD}" config --local --unset-all core.sshCommand || true
  "${GIT_CMD}" config --local --unset-all core.pager || true
  "${GIT_CMD}" config --local --unset-all credential.helper || true
  basic="$(printf 'x-access-token:%s' "$PUSH_TOKEN" | base64 | tr -d '\n')"
  echo "::add-mask::${basic}"
  "${GIT_CMD}" config --local http.https://github.com/.extraheader "AUTHORIZATION: basic ${basic}"
fi

BASE="${BASE:-}"
if [ -z "$BASE" ] && [ -n "${PR:-}" ] && [ -n "${REPO:-}" ]; then
  BASE="$("${GH_CMD}" pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
  [ -n "$BASE" ] || echo "::warning::could not look up the base branch of #${PR}; pushing without merging it."
fi

# rebase で積み直さないのは、base をマージしたコミットを rebase が平坦化して base のコミットを複製するため。
# base のマージを自動修正コミットの下に置くのは、CI のコードレビューが head がマージコミットの push を
# スキップするため。マージコミットは squash merge で消えるので PR の履歴には残らない。
attempt=0
while [ "$attempt" -lt "$MAX_RETRIES" ]; do
  attempt=$((attempt + 1))
  echo "push attempt ${attempt}/${MAX_RETRIES}"
  "${GIT_CMD}" fetch origin "$REF" ${BASE:+"$BASE"}
  "${GIT_CMD}" checkout -q --detach "origin/${REF}"
  # 進行中の状態が残ると次の実行を壊しうるので、abort の失敗は警告で残す。
  # base を直接マージし直すと同じコンフリクトに戻るので、先に解消済みのマージを取り込む。
  if [ -n "$RESOLVED_MERGE" ] && ! "${GIT_CMD}" merge --no-edit -m "Merge ${BASE:-base} into ${REF}" "$RESOLVED_MERGE"; then
    "${GIT_CMD}" merge --abort || echo "::warning::merge --abort failed; the repository may be left mid-merge."
    finish conflict "Merging the resolved merge into origin/${REF} conflicted; leaving the fix to a human."
  fi
  if [ -n "$BASE" ] && ! "${GIT_CMD}" merge --no-edit -m "Merge ${BASE} into ${REF}" "origin/${BASE}"; then
    "${GIT_CMD}" merge --abort || echo "::warning::merge --abort failed; the repository may be left mid-merge."
    [ "$ON_BASE_CONFLICT" = skip ] || finish conflict "Merging origin/${BASE} into origin/${REF} conflicted; leaving the fix to a human."
    echo "Merging origin/${BASE} into origin/${REF} conflicted; applying ${COMMIT_PREFIX} without the base."
  fi
  if [ -n "$fix_sha" ] && ! "${GIT_CMD}" cherry-pick "$fix_sha"; then
    "${GIT_CMD}" cherry-pick --abort || echo "::warning::cherry-pick --abort failed; the repository may be left mid-cherry-pick."
    finish conflict "Applying ${COMMIT_PREFIX} onto origin/${REF} conflicted; leaving the fix to a human."
  fi
  if "${GIT_CMD}" push origin "HEAD:${REF}"; then
    finish pushed "Pushed ${COMMIT_PREFIX} to ${REF}."
  fi
  echo "push rejected (remote advanced); retrying from fetch."
done

echo "result=failed" >> "$GITHUB_OUTPUT"
echo "::error::Failed to push ${COMMIT_PREFIX} after ${MAX_RETRIES} attempts."
exit 1
