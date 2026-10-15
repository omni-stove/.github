#!/usr/bin/env bash
# エージェントが編集した内容を 1 つの自動修正コミットにまとめ、PR の head ブランチに積む。
# actions/push-agent-fix から呼ばれる。エージェントには編集だけさせ、commit 粒度とメッセージは
# ここで確定させる (commit し忘れや複数コミットへの分割を防ぐ)。
#
# エージェントの実行中に作成者が push してリモートが進んでいても、fetch → rebase で上に積み直して
# 取りこぼさない。push が reject されたら (さらに別の push が入った) fetch から再試行する。
# rebase がコンフリクトしたら積まずに人間に委ねる。
#
# エージェントの実行中に緊急避難口のラベルが付くと、ラベル付与時の run キャンセルをすり抜けて
# ここに到達しうるので、commit の前にラベルを確認して何もしない。
#
# 出力 (GITHUB_OUTPUT の result):
#   pushed   - commit して push した
#   noop     - 作業ツリーに変更が無かった
#   conflict - rebase がコンフリクトした (abort 済み)
#   skipped  - 緊急避難口のラベルが付いていた
#   failed   - リトライ上限まで push できなかった (非ゼロで終了する)
#
# 入力 (環境変数):
#   REF            - push する PR の head ブランチ名
#   PR / REPO      - ラベル確認用 (どちらか空なら確認しない)
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

"${GIT_CMD}" add -A
if "${GIT_CMD}" diff --cached --quiet; then
  finish noop "No changes to commit."
fi

summary="$(printf '%s' "${STRUCTURED:-}" | jq -er '.summary // ""' 2>/dev/null | tr -d '\r' | head -n 1 || true)"
[ -n "$summary" ] || summary="address CI failures and review comments"

"${GIT_CMD}" config user.name "$GIT_USER_NAME"
"${GIT_CMD}" config user.email "$GIT_USER_EMAIL"
"${GIT_CMD}" commit --no-verify -m "${COMMIT_PREFIX} ${summary}"

# 作り直し (agent-regen) は PR のコードを実行するので、checkout ではトークンを .git/config に残していない。
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

attempt=0
while [ "$attempt" -lt "$MAX_RETRIES" ]; do
  attempt=$((attempt + 1))
  echo "push attempt ${attempt}/${MAX_RETRIES}"
  "${GIT_CMD}" fetch origin "$REF"
  if ! "${GIT_CMD}" rebase "origin/${REF}"; then
    # rebase 進行中の状態が残ると次の実行を壊しうるので、abort の失敗は警告で残す。
    "${GIT_CMD}" rebase --abort || echo "::warning::rebase --abort failed; the repository may be left mid-rebase."
    finish conflict "Rebase onto origin/${REF} conflicted; leaving the fix to a human."
  fi
  if "${GIT_CMD}" push origin "HEAD:${REF}"; then
    finish pushed "Pushed ${COMMIT_PREFIX} to ${REF}."
  fi
  echo "push rejected (remote advanced); retrying after rebase."
done

echo "result=failed" >> "$GITHUB_OUTPUT"
echo "::error::Failed to push ${COMMIT_PREFIX} after ${MAX_RETRIES} attempts."
exit 1
