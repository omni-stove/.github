#!/usr/bin/env bash
# CI run から「どのジョブが、どう落ちたか」を抽出して GITHUB_OUTPUT に body として出す。
# 自動修正のエージェントは依存を入れず CI も再実行しないので、原因の特定に要る失敗ログだけを
# 切り出して渡す。actions/fix-context から呼ばれる。
#
# 入力 (環境変数):
#   RUN_ID         - CI run の ID
#   REPO           - owner/name
#   GH_TOKEN       - actions: read を持つトークン
#   CONTEXT_LINES  - 1 ジョブあたりに渡す最大行数 (既定: 400)
#   CONTEXT_BEFORE / CONTEXT_AFTER - 失敗マーカー行の前後に含める行数 (既定: 6 / 12)
#   MAX_BYTES      - body 全体の最大バイト数 (既定: 48000。プロンプトは execve の 128KiB 未満に収める)
#   GH_CMD         - gh コマンド名 (既定: gh)
#   GITHUB_OUTPUT  - 出力先 (body / has_failure_context)
set -euo pipefail

: "${RUN_ID:?RUN_ID is required}"
: "${REPO:?REPO is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# shellcheck source=actions/fix-context/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GH_CMD="${GH_CMD:-gh}"
CONTEXT_LINES="${CONTEXT_LINES:-400}"
# マーカー行だけを拾うと assertion の diff やスタックトレースが欠け、エージェントがコードだけ見て
# 推測修正するため、前後の文脈ごとブロックで残す。
CONTEXT_BEFORE="${CONTEXT_BEFORE:-6}"
CONTEXT_AFTER="${CONTEXT_AFTER:-12}"
MAX_BYTES="${MAX_BYTES:-48000}"

MARKER_RE='FAIL |✗|✕|×|❯|⎯|AssertionError|Hook timed out|expected .* (to|but)|exited \(|ELIFECYCLE|run failed|shutdown signal|operation was canceled|Test Files|Tests .*(passed|failed|skipped)|TS[0-9]{3,}|Cannot find|is not assignable|##\[error\]|exit code [0-9]|failed to download|failed to fetch|ECONNRESET|ENOTFOUND|EAI_AGAIN|ERR_PNPM_OUTDATED_LOCKFILE|^diff --git a/'
# 本命の失敗理由まで巻き添えで消さないよう、明らかなノイズだけに絞る。
NOISE_RE='DeprecationWarning|node:.*\[DEP|Use .node --trace'

if ! jobs_json="$("${GH_CMD}" api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" --paginate \
  --jq '.jobs[] | {name, id, status, conclusion}' | jq -s '.')"; then
  echo "::warning::run ${RUN_ID} のジョブ一覧を取得できない。呼び出し側の permissions に actions: read を渡す。"
  emit_multiline body "(CI run ${RUN_ID} のジョブ一覧を取得できなかった)"
  echo "has_failure_context=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
failed_jobs="$(jq -r '.[] | select(.conclusion == "failure" or .conclusion == "cancelled") | [.name, .id] | @tsv' <<<"$jobs_json")"

# 新しい gh は ANSI エスケープを含む生レスポンスを拒否し、色付きの job ログが取れない。古い gh は
# 未知フラグでエラーになるため、対応している gh にだけ付ける。grep -q は早期終了で gh が SIGPIPE になり、
# pipefail 下で未対応と誤判定するので使わない。
GH_LOG_FLAGS=()
if "${GH_CMD}" api --help 2>/dev/null | grep -- '--allow-escape-sequences' >/dev/null; then
  GH_LOG_FLAGS=(--allow-escape-sequences)
fi

LOG_ERR_FILE="$(mktemp)"
trap 'rm -f "${LOG_ERR_FILE}"' EXIT

HAS_FAILURE_CONTEXT=false

report() {
  echo "## CI failure log (extracted from run ${RUN_ID})"
  echo ""
  echo "### ジョブ一覧"
  echo ""
  jq -r '.[] | "- [\(.conclusion // .status)] \(.name)"' <<<"$jobs_json"
  echo ""
  if [ -z "$failed_jobs" ]; then
    echo "失敗・キャンセルしたジョブは見つかりませんでした (flaky / インフラ起因の可能性)。"
    return
  fi

  local job_name job_id log log_error markers extracted
  while IFS=$'\t' read -r job_name job_id; do
    echo ""
    echo "## 失敗ジョブ: ${job_name} (job ${job_id})"
    echo ""
    echo '```'
    # 修正ジョブは同じ run の中で走り run 全体は in_progress なので、`gh run view --log` はログを返さない。
    # 完了済みの個別ジョブなら REST の job-logs API が返す。取得失敗を「エラー行なし」と区別できないと
    # エージェントが CI 失敗を直さずに終わるため、失敗は理由ごと出す。
    log_error=""
    if ! log="$("${GH_CMD}" api ${GH_LOG_FLAGS[@]+"${GH_LOG_FLAGS[@]}"} "repos/${REPO}/actions/jobs/${job_id}/logs" 2>"${LOG_ERR_FILE}")"; then
      log=""
      log_error="$(head -c 500 "${LOG_ERR_FILE}" | tr '\n' ' ')"
      echo "::warning::failed to fetch logs of job ${job_id} (${job_name}): ${log_error}" >&2
    fi
    # マーカー判定は grep -iE に任せ (awk は正規表現方言が違い \( や大小無視で崩れる)、行番号だけを awk に
    # 渡して [n-before, n+after] に広げる。head が打ち切ると上流が SIGPIPE で死ぬので全体を || true で受ける。
    extracted="$(
      {
        markers="$(printf '%s\n' "${log}" | grep -niE "${MARKER_RE}" | cut -d: -f1 | tr '\n' ' ' || true)"
        if [ -n "${markers// /}" ]; then
          printf '%s\n' "${log}" \
            | awk -v before="${CONTEXT_BEFORE}" -v after="${CONTEXT_AFTER}" -v marks="${markers}" '
                BEGIN {
                  n = split(marks, m, " ")
                  for (k = 1; k <= n; k++) {
                    if (m[k] == "") continue
                    lo = m[k] - before; if (lo < 1) lo = 1
                    hi = m[k] + after
                    for (i = lo; i <= hi; i++) want[i] = 1
                  }
                }
                { if (want[NR]) { if (prev && NR > prev + 1) print "⋯"; print; prev = NR } }
              ' \
            | { grep -ivE "${NOISE_RE}" || true; } \
            | head -n "${CONTEXT_LINES}"
        fi
      } || true
    )"
    if [ -n "${extracted}" ]; then
      HAS_FAILURE_CONTEXT=true
      echo "${extracted}"
    elif [ -n "${log_error}" ]; then
      echo "(ログ取得に失敗: ${log_error})"
    else
      echo "(抽出対象のエラー行なし)"
    fi
    echo '```'
  done <<<"$failed_jobs"
}

# report はサブシェルで走らせると HAS_FAILURE_CONTEXT が親に戻らないため、ファイル経由で受ける。
REPORT_FILE="$(mktemp)"
trap 'rm -f "${LOG_ERR_FILE}" "${REPORT_FILE}"' EXIT
report > "$REPORT_FILE"

emit_multiline body "$(truncate_bytes "$(cat "$REPORT_FILE")" "$MAX_BYTES" "CI failure log")"
echo "has_failure_context=${HAS_FAILURE_CONTEXT}" >> "$GITHUB_OUTPUT"
