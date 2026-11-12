#!/usr/bin/env bash
# Issue Worker を待っている sub-issue のうち、ブロックしていた Issue (GitHub の issue dependencies の blocked by) が
# すべて completed で閉じたものに Worker のラベルを付けて着手させる。actions/unblock から呼ばれる。
#
# 対象は親 Issue を持つ open な sub-issue で、Worker のラベル (bug / security / prototype / implementation) が
# 付いていないもの。付けるラベルは Issue の型が Bug なら bug、それ以外は implementation。manual ラベルの
# Issue はユーザーが手でやるものなのでラベルを付けない。この規約は skill-kit の delegate / unblock と揃える。
#
# 無人で動くため、着手してよいか判断が要るものはラベルを付けずコメントで知らせるだけにする。
# 判断は手元の unblock skill か、手でラベルを付けることに残す。
#   labeled   blocker がすべて completed → ラベルを付け、親に知らせる
#   waiting   open の blocker が残る → 何もしない
#   yours     manual で open の blocker が無い → manual Issue に作成者宛てで知らせる
#   unlinked  blocker が設定されていない → 親に知らせる
#   dropped   open の blocker は無いが not planned で閉じたものがある → 親に知らせる
# 知らせるコメントは状態ごとのマーカーで重複させない。
#
# 入力 (環境変数):
#   CLOSED_ISSUE - 閉じた Issue の番号。あれば、それがブロックしていた Issue だけを見る
#   PARENTS      - 見る親 Issue の番号 (空白かカンマ区切り)。CLOSED_ISSUE も PARENTS も空なら open な sub-issue を
#                  持つすべての親
#   GH_TOKEN     - ラベルを付けるトークン。github.token で付けると labeled イベントが Issue Worker を起動しない
#   GH_REPO      - owner/name
#   GH_CMD       - テストで gh を差し替える (既定: gh)
#   GITHUB_STEP_SUMMARY - あれば結果を書く
# 出力 (stdout): sub-issue ごとに <state><TAB><number><TAB><label><TAB><title><TAB><url><TAB><blockers>
#   blockers は waiting なら open のもの、dropped / yours なら not planned で閉じたもの
set -euo pipefail

# command keeps gh from calling this function again when GH_CMD is unset
gh() { command "${GH_CMD:-gh}" "$@"; }

CLOSED_ISSUE="${CLOSED_ISSUE:-}"
PARENTS="${PARENTS:-}"
read -ra parents <<< "${PARENTS//,/ }"
for n in $CLOSED_ISSUE ${parents[@]+"${parents[@]}"}; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "unblock: not an issue number: $n" >&2; exit 2; }
done

# <number><TAB><label><TAB><author><TAB><title><TAB><url> of an open issue with no worker label
pending='select(.state == "open" and ([.labels[].name] - ["bug", "security", "prototype", "implementation"] == [.labels[].name]))
         | "\(.number)\t\(if any(.labels[]; .name == "manual") then "manual" elif .type.name == "Bug" then "bug" else "implementation" end)\t\(.user.login)\t\(.title)\t\(.html_url)"'

# Each gh list is read into a variable first, so a failed call stops the script under set -e
# instead of reading as an empty list.
candidates=
if [ -n "$CLOSED_ISSUE" ]; then
  blocked="$(gh api --paginate "repos/{owner}/{repo}/issues/$CLOSED_ISSUE/dependencies/blocking" --jq ".[] | $pending")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Only an issue split under a parent is the worker's to start; one with no parent was left unlabeled on purpose.
    # The endpoint answers 404 for an issue with no parent.
    parent="$(gh api "repos/{owner}/{repo}/issues/${line%%$'\t'*}/parent" --jq .number 2>/dev/null)" || continue
    candidates+="$parent"$'\t'"$line"$'\n'
  done <<< "$blocked"
else
  if [ ${#parents[@]} -eq 0 ]; then
    open_parents="$(gh api --paginate "repos/{owner}/{repo}/issues?state=open&per_page=100" \
      --jq '.[] | select(.pull_request == null and .sub_issues_summary.total > .sub_issues_summary.completed) | .number')"
    while read -r p; do [ -n "$p" ] && parents+=("$p"); done <<< "$open_parents"
  fi
  for p in ${parents[@]+"${parents[@]}"}; do
    subs="$(gh api --paginate "repos/{owner}/{repo}/issues/$p/sub_issues" --jq ".[] | $pending")"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      candidates+="$p"$'\t'"$line"$'\n'
    done <<< "$subs"
  done
fi

# Posts the body to the issue unless a comment carrying the marker is already there.
comment_once() {
  local issue="$1" marker="<!-- unblock:$2 -->" body="$3" existing
  existing="$(gh api --paginate "repos/{owner}/{repo}/issues/$issue/comments" --jq '.[].body')"
  grep -qF -- "$marker" <<< "$existing" && return 0
  gh issue comment "$issue" --body "$marker
$body" >/dev/null
}

results=
while IFS=$'\t' read -r parent number label author title url; do
  [ -n "$number" ] || continue
  blockers="$(gh api --paginate "repos/{owner}/{repo}/issues/$number/dependencies/blocked_by" \
    --jq '.[] | "\(.number) \(.state) \(.state_reason)"')"
  open=
  dropped=
  done_=
  while read -r n s r; do
    [ -n "$n" ] || continue
    if [ "$s" = open ]; then open="$open #$n"
    elif [ "$r" = completed ]; then done_="$done_ #$n"
    else dropped="$dropped #$n"; fi
  done <<< "$blockers"
  if [ -n "$open" ]; then state=waiting; left="${open# }"
  elif [ "$label" = manual ]; then state=yours; left="${dropped# }"
  elif [ -z "$blockers" ]; then state=unlinked; left=
  elif [ -n "$dropped" ]; then state=dropped; left="${dropped# }"
  else state=labeled; left=; fi

  case "$state" in
    labeled)
      gh issue edit "$number" --add-label "$label" >/dev/null
      comment_once "$parent" "labeled:$number" "#$number に \`$label\` を付けた。待っていた ${done_# } がすべて完了したため Issue Worker が着手する。"
      ;;
    yours)
      msg="@$author 待っていた Issue がすべて閉じたので、この作業に着手できる。終えたら completed で閉じると、これを待つ Issue が進む。"
      [ -z "$left" ] || msg="$msg
見送りで閉じた待ち: $left"
      comment_once "$number" yours "$msg"
      ;;
    unlinked)
      comment_once "$parent" "unlinked:$number" "#$number はどの Issue にもブロックされていないため、着手の時期を自動では決めない。先に要る Issue を blocked by に設定するか、着手してよければ \`$label\` ラベルを付ける。"
      ;;
    dropped)
      comment_once "$parent" "dropped:$number" "#$number が待っていた $left は見送りで閉じた。このまま着手するなら \`$label\` ラベルを付け、不要なら #$number を閉じる。"
      ;;
  esac
  results+="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$state" "$number" "$label" "$title" "$url" "$left")"$'\n'
done <<< "$candidates"

printf '%s' "$results"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "| 状態 | Issue | ラベル | 残り |"
    echo "| --- | --- | --- | --- |"
    while IFS=$'\t' read -r state number label title url left; do
      [ -n "$number" ] || continue
      echo "| $state | [#$number $title]($url) | $label | $left |"
    done <<< "$results"
  } >> "$GITHUB_STEP_SUMMARY"
fi
