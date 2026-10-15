#!/usr/bin/env bash
# Code Review に渡す PR diff と PR の文脈 (説明 / 参照 Issue / コミット / コメント /
# レビュースレッド) を取得し、レビューの意味が薄いファイルを除外して GITHUB_OUTPUT に
# `diff` / `empty` / `pr_description` / `pr_linked_issues` / `pr_commits` / `pr_comments` /
# `pr_review_threads` として出力する。actions/fetch-review-diff から呼ばれる。
#
# 除外は決定論で行いたいので LLM のプロンプトには委ねず、ここで弾く。
# gh pr diff の --exclude は信頼できないため使わず、素の diff を `diff --git a/… b/…`
# ブロック単位に分割して、各ブロックのファイルパスを should_exclude() で判定する。
#
# GitHub の diff API は 300 ファイル超の PR で HTTP 406 (diff too_large) を返すため、
# gh pr diff が失敗したらローカル git にフォールバックする (fetch_diff を参照)。
#
# diff も文脈も切り詰めない。diff は上限に収まるファイルだけをインラインに載せ、残りは
# ファイル単位で DIFF_DIR に書き出して、その一覧と Read の指示を diff の末尾に付ける。
# 文脈は上限を超えたものだけ CONTEXT_DIR に全文を書き出し、Read の指示に置き換える。
#
# 上限の実効値は GITHUB_OUTPUT の 1MB ではなく execve(2) の MAX_ARG_STRLEN (128KiB)。
# ここで出力した値はレビューの prompt に埋め込まれ、action には単一の環境変数として
# 渡るため、プロンプト全体をこの上限未満に収める。
#
# 入力 (環境変数):
#   REPO             - owner/name
#   PR               - PR 番号
#   GITHUB_OUTPUT    - 出力先
#   GH_CMD / GIT_CMD - コマンド名 (既定: gh / git。テストでモックを差し込むため)
#   EXCLUDE_PATTERNS - 追加の除外 glob (改行区切り)
#   MAX_BODY_BYTES   - 文脈 5 種それぞれをインラインに載せる最大バイト数 (既定: 8000)
#   MAX_BYTES        - diff 出力の最大バイト数 (既定: プロンプト予算から文脈 5 種分を引いた残り)
#   DIFF_DIR         - インラインに載せないファイルの diff の書き出し先 (既定: $GITHUB_WORKSPACE/.review-diff)
#   CONTEXT_DIR      - インラインに載せない文脈の書き出し先 (既定: $GITHUB_WORKSPACE/.review-context)
set -euo pipefail

: "${REPO:?REPO is required}"
: "${PR:?PR is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

GH_CMD="${GH_CMD:-gh}"
GIT_CMD="${GIT_CMD:-git}"
# execve(2) の MAX_ARG_STRLEN (128KiB) から安全マージンを引いたプロンプト予算。
PROMPT_BUDGET=$((131072 - 16384))
MAX_BODY_BYTES="${MAX_BODY_BYTES:-8000}"
[ -n "${MAX_BYTES:-}" ] || MAX_BYTES=$((PROMPT_BUDGET - 5 * MAX_BODY_BYTES))
DIFF_DIR="${DIFF_DIR:-${GITHUB_WORKSPACE:-$PWD}/.review-diff}"
CONTEXT_DIR="${CONTEXT_DIR:-${GITHUB_WORKSPACE:-$PWD}/.review-context}"
EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-}"

# レビュー対象外にするパスの判定。読み手の解釈が入る / 定性的でレビューの意味が薄いものを
# true で返す。glob は basename ではなくパス全体に対して当てる。
should_exclude() {
  local path="$1" pat
  case "$path" in
    # ドキュメント類
    *.md | *.mdx | */docs/* | docs/*) return 0 ;;
    # 自動生成物
    */generated/* | generated/* | *.gen.* | */swagger.json | */openapi.json) return 0 ;;
    # スナップショット
    *.snap | */__snapshots__/*) return 0 ;;
    # i18n / メッセージ
    */messages/* | messages/* | */locales/* | locales/* | *.po) return 0 ;;
    # lockfile (依存解決の結果。差分が巨大でレビューの意味がない)
    pnpm-lock.yaml | */pnpm-lock.yaml | package-lock.json | */package-lock.json) return 0 ;;
    yarn.lock | */yarn.lock | *.lock) return 0 ;;
    # ビルド / 型キャッシュ・ミニファイ済み成果物
    *.tsbuildinfo | *.min.js | *.min.css) return 0 ;;
    # GitHub Actions が規約パスで読む定型データ
    .github/labeler.yml | .github/sync.yml | .github/dependabot.yml | .github/renovate.json) return 0 ;;
    */.github/ISSUE_TEMPLATE/*.yml | .github/ISSUE_TEMPLATE/*.yml) return 0 ;;
    # ツール設定 json (定型。差分レビューの意味が薄い)
    tsconfig*.json | */tsconfig*.json) return 0 ;;
    biome.json | */biome.json | turbo.json | */turbo.json) return 0 ;;
    # 画像・バイナリ・図 (diff が読めない / 巨大 1 行になる)
    *.svg | *.webp | *.png | *.jpg | *.jpeg | *.gif | *.ico | *.excalidraw) return 0 ;;
    # Prisma の自動生成マイグレーション
    */prisma/migrations/*) return 0 ;;
  esac
  while IFS= read -r pat; do
    pat="$(printf '%s' "$pat" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254 # 呼び出し側の glob をそのままパターンとして使う。
    case "$path" in
      $pat) return 0 ;;
    esac
  done <<<"$EXCLUDE_PATTERNS"
  return 1
}

# `diff --git a/<path> b/<path>` ヘッダから新側 (b/) のパスを取り出す。
path_from_header() {
  local header="$1"
  printf '%s' "${header#*" b/"}"
}

# PR の diff 全文を標準出力に返す。まず gh pr diff を試し、失敗したら merge base と head を
# --depth=1 で fetch して git diff で同等の diff を作る。
fetch_diff() {
  local raw
  if raw="$("${GH_CMD}" pr diff "$PR" --repo "$REPO" --patch)"; then
    printf '%s\n' "$raw"
    return 0
  fi
  echo "gh pr diff failed; falling back to local git diff" >&2
  local pr_info base_sha head_sha merge_base
  pr_info="$("${GH_CMD}" api "repos/${REPO}/pulls/${PR}" --jq '.base.sha + " " + .head.sha')"
  base_sha="${pr_info%% *}"
  head_sha="${pr_info##* }"
  merge_base="$("${GH_CMD}" api "repos/${REPO}/compare/${base_sha}...${head_sha}?per_page=1" \
    --jq '.merge_base_commit.sha')"
  "${GIT_CMD}" fetch --quiet --depth=1 origin "$merge_base" "$head_sha"
  "${GIT_CMD}" diff --no-color "$merge_base" "$head_sha"
}

byte_length() {
  printf '%s' "$1" | wc -c | tr -d ' '
}

fetch_pr_description() {
  "${GH_CMD}" pr view "$PR" --repo "$REPO" --json title,body --jq '"# \(.title)\n\n\(.body)"'
}

fetch_pr_comments() {
  "${GH_CMD}" issue view "$PR" --repo "$REPO" --json comments \
    --jq '.comments[] | "### @\(.author.login) (\(.createdAt))\n\(.body)\n"'
}

# PR が参照する同じリポジトリの Issue / PR のタイトルと本文を返す。参照は PR 本文の
# `#N` と URL、および Development 欄で紐づけた closing 参照から集める。
fetch_linked_issues() {
  local body="$1" refs n
  refs="$(
    {
      printf '%s\n' "$body" | grep -oE '(^|[^A-Za-z0-9_&/])#[0-9]+' | grep -oE '[0-9]+$' || true
      printf '%s\n' "$body" | grep -oE "https://github\.com/${REPO//./\\.}/(issues|pull)/[0-9]+" \
        | grep -oE '[0-9]+$' || true
      REPO_URL="https://github.com/${REPO}/" "${GH_CMD}" pr view "$PR" --repo "$REPO" \
        --json closingIssuesReferences \
        --jq '.closingIssuesReferences[] | select(.url | startswith(env.REPO_URL)) | .number' \
        2>/dev/null || true
    } | { grep -vx "$PR" || true; } | sort -nu
  )"
  for n in $refs; do
    "${GH_CMD}" api "repos/${REPO}/issues/${n}" \
      --jq '"## #\(.number) \(.title)\n\n\(.body // "")\n"' 2>/dev/null || true
  done
}

# PR のコミットメッセージを返す。Update Branch 等のマージコミットは PR の意図を含まないので落とす。
fetch_pr_commits() {
  "${GH_CMD}" api "repos/${REPO}/pulls/${PR}/commits" --paginate \
    --jq '.[] | select((.parents | length) < 2) | "### \(.sha[0:12])\n\(.commit.message)\n"'
}

# 全レビュースレッドを状態付きで返す。resolved も落とさないのは、作者が「意図的」と返信して
# resolve したスレッドこそ「対応済み・直さないと決めた指摘」の根拠で、落とすと同じ指摘が
# 蒸し返されるため。
fetch_review_threads() {
  # shellcheck disable=SC2016
  "${GH_CMD}" api graphql --paginate -f query='query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100,after:$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{
            isResolved
            isOutdated
            path
            line
            originalLine
            comments(first:100){ nodes{ author{login} createdAt body } }
          }
        }
      }
    }
  }' \
    -f owner="${REPO%%/*}" -f repo="${REPO#*/}" -F pr="${PR}" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[]
      | "### \(.path):\(.line // .originalLine // "file") [\(if .isResolved then "resolved" else "unresolved" end)\(if .isOutdated then ", outdated" else "" end)]\n"
        + ([.comments.nodes[] | "@\(.author.login // "ghost") (\(.createdAt)):\n\(.body)\n"] | join("\n"))'
}

# 文脈を MAX_BODY_BYTES 以内ならそのまま返し、超えたら CONTEXT_DIR に全文を書き出して
# その場所と Read の指示を返す。
inline_or_save() {
  local key="$1" label="$2" content="$3" size dest
  size="$(byte_length "$content")"
  if [ "$size" -le "$MAX_BODY_BYTES" ]; then
    printf '%s' "$content"
    return 0
  fi
  mkdir -p "$CONTEXT_DIR"
  dest="${CONTEXT_DIR}/${key}.md"
  printf '%s\n' "$content" > "$dest"
  printf '%s' "<not_inlined>
${label} (${size} bytes) does not fit in the prompt size limit. The full text
is saved in ${dest}. Read the whole file before reviewing: it is part of the
context of this review.
</not_inlined>"
}

# 1 ファイル分の diff ブロックの追加 / 削除行数を "+N -M" で返す。
count_changes() {
  local block="$1" added=0 removed=0 in_hunk=false line
  while IFS= read -r line; do
    case "$line" in
      "@@"*) in_hunk=true ;;
      "+"*) [ "$in_hunk" = true ] && added=$((added + 1)) ;;
      "-"*) [ "$in_hunk" = true ] && removed=$((removed + 1)) ;;
    esac
  done <<< "$block"
  printf '+%s -%s' "$added" "$removed"
}

# GITHUB_OUTPUT に key<<DELIM ... DELIM の heredoc を書く。DELIM は本文と衝突しないようランダム化する。
emit_multiline() {
  local key="$1" value="$2" delim
  delim="EOF_$(openssl rand -hex 16)"
  {
    echo "${key}<<${delim}"
    printf '%s\n' "$value"
    echo "${delim}"
  } >> "$GITHUB_OUTPUT"
}

main() {
  local raw
  raw="$(fetch_diff)"

  # 除外対象のブロックを落とした diff を組み立てる。最初の `diff --git` を見るまでの行は
  # 空 path のブロックとしてレビュー対象から破棄する。
  local filtered="" block="" path="" kept=0 dropped=0
  local -a kept_paths=() kept_blocks=()
  flush() {
    [ -z "$block" ] && return 0
    if [ -z "$path" ]; then
      block=""
      return 0
    fi
    if should_exclude "$path"; then
      dropped=$((dropped + 1))
    else
      filtered+="$block"
      kept_paths+=("$path")
      kept_blocks+=("$block")
      kept=$((kept + 1))
    fi
    block=""
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "diff --git "*)
        flush
        path="$(path_from_header "$line")"
        ;;
    esac
    block+="${line}"$'\n'
  done <<< "$raw"
  flush

  local diff_out inlined=0 externalized=0
  if [ "$(byte_length "$filtered")" -le "$MAX_BYTES" ]; then
    diff_out="$filtered"
    inlined=$kept
  else
    # 一覧の注記ぶんを残して、収まるファイルからインラインに詰める。収まらないファイルを
    # 飛ばして後続を詰め続けるのは、大きい 1 ファイルのせいで後ろの小さいファイルまで
    # インラインから外さないため。
    local note_budget=$((MAX_BYTES / 4 < 8000 ? MAX_BYTES / 4 : 8000))
    local remaining=$((MAX_BYTES - note_budget)) list="" i size dest note
    diff_out=""
    mkdir -p "$DIFF_DIR"
    for i in "${!kept_blocks[@]}"; do
      size="$(byte_length "${kept_blocks[i]}")"
      if [ "$size" -le "$remaining" ]; then
        diff_out+="${kept_blocks[i]}"
        remaining=$((remaining - size))
        inlined=$((inlined + 1))
      else
        dest="${DIFF_DIR}/$(printf '%04d' "$i").diff"
        printf '%s' "${kept_blocks[i]}" > "$dest"
        list+="- ${kept_paths[i]} ($(count_changes "${kept_blocks[i]}")): ${dest}"$'\n'
        externalized=$((externalized + 1))
      fi
    done
    printf '%s' "$list" > "${DIFF_DIR}/index.md"

    note="<not_inlined_files>
The diffs of the following ${externalized} changed files are not inlined in \`pr_diff\`
because of the prompt size limit. Each full diff is saved in the listed file.
They are part of this review: read every one of them and review them with the
same criteria as the inlined diff.

${list}</not_inlined_files>"
    if [ "$(byte_length "$note")" -gt "$note_budget" ]; then
      note="<not_inlined_files>
The diffs of ${externalized} changed files are not inlined in \`pr_diff\` because
of the prompt size limit. Their list (changed file, line counts, saved diff file)
is in ${DIFF_DIR}/index.md. They are part of this review: read the list, then
read every diff file in it and review them with the same criteria as the
inlined diff.
</not_inlined_files>"
    fi
    diff_out+=$'\n'"$note"
  fi
  local byte_len
  byte_len="$(byte_length "$diff_out")"

  # 取得失敗は空にする。文脈は精度を上げる補助で、引けないことを理由にレビュー自体を止めない。
  local pr_description pr_linked_issues pr_commits pr_comments pr_review_threads
  pr_description="$(fetch_pr_description)" || pr_description=""
  pr_linked_issues="$(fetch_linked_issues "$pr_description")" || pr_linked_issues=""
  pr_commits="$(fetch_pr_commits)" || pr_commits=""
  pr_comments="$(fetch_pr_comments)" || pr_comments=""
  pr_review_threads="$(fetch_review_threads)" || pr_review_threads=""
  pr_description="$(inline_or_save pr_description "PR description" "$pr_description")"
  pr_linked_issues="$(inline_or_save pr_linked_issues "linked issues" "$pr_linked_issues")"
  pr_commits="$(inline_or_save pr_commits "commit messages" "$pr_commits")"
  pr_comments="$(inline_or_save pr_comments "PR comments" "$pr_comments")"
  pr_review_threads="$(inline_or_save pr_review_threads "review threads" "$pr_review_threads")"

  # 除外後にレビュー対象ファイルが 1 つも残らなかったら empty=true を出す。
  # 呼び出し側はこれを見て Code Review ステップ自体をスキップする。
  local emit_empty=false
  [ "$kept" -eq 0 ] && emit_empty=true
  echo "empty=${emit_empty}" >> "$GITHUB_OUTPUT"

  emit_multiline pr_description "$pr_description"
  emit_multiline pr_linked_issues "$pr_linked_issues"
  emit_multiline pr_commits "$pr_commits"
  emit_multiline pr_comments "$pr_comments"
  emit_multiline pr_review_threads "$pr_review_threads"
  emit_multiline diff "$diff_out"

  echo "diff emitted (kept=${kept} files, dropped=${dropped} files, inlined=${inlined} files, externalized=${externalized} files, bytes=${byte_len}, empty=${emit_empty})"
}

main
