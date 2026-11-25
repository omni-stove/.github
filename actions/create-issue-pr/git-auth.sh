#!/usr/bin/env bash
# PUSH_TOKEN があれば、このプロセスとその子の git が github.com へそのトークンで認証するようにする (source 専用)。
# create-pr.sh と adopt-issue-branch.sh が共有する。PUSH_TOKEN が空なら既存の認証のまま。
#
# リポジトリの設定に書かず環境変数で渡すのは、checkout が認証情報を残さない (persist-credentials: false)
# ジョブで、後のステップのエージェントが作業ツリーから書き込みトークンを読めないままにするため。
# 既に extraheader がある (認証情報を残した checkout) ときに足すと Authorization が二重になり GitHub が拒否する。
if [ -n "${PUSH_TOKEN:-}" ] && [ -z "$(git config --get-all http.https://github.com/.extraheader 2>/dev/null || true)" ]; then
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
  GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$PUSH_TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_VALUE_0
fi
