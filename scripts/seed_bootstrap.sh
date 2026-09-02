#!/usr/bin/env bash
# seed_bootstrap.sh — STAGE 3: get the field's top ~N accounts to seed the graph.
#
# The graph engine needs a starting set of high-quality, on-topic seeds. For the
# two providers with an open API, that top list can be generated automatically:
#   github    a topic (or a key repo) -> owners + top contributors of its top repos
#   openalex  a field name            -> the most-cited authors publishing in it
# For platforms without an open API (X / 小红书 / LinkedIn / 微博 / B站), there is
# no automated bootstrap — collect the field's ranking/榜单 via cyh-browser-skill
# instead (see ../PLATFORMS.md).
#
# Output: candidate seed ids, one per line, on stdout (names/notes go to stderr).
# Pipe into a file, eyeball it, then feed field_graph.sh:
#   seed_bootstrap.sh --provider github --topic osint --n 40 > seeds.txt
#   field_graph.sh @seeds.txt --top 30 --enrich
set -euo pipefail

PROVIDER="github"; TOPIC=""; REPO=""; FIELD=""; N=40; CONTRIB=0
MAILTO="${OPENALEX_MAILTO:-}"

die() { echo "error: $*" >&2; exit 1; }

need_value() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  seed_bootstrap.sh --provider github   --topic <topic> [--n 40] [--contributors]
  seed_bootstrap.sh --provider github   --repo <owner/name> [--n 40]
  seed_bootstrap.sh --provider openalex --field "<field name>" [--n 50] [--mailto EMAIL]

  --topic         a GitHub topic (github.com/topics/<topic>)
  --repo          a single GitHub repo; emit its top contributors
  --contributors  also pull top contributors of the top repos (github --topic)
  --field         a research field / concept name (openalex)
  --n             how many candidate seeds to emit (default 40)
  --mailto        contact email for OpenAlex's polite pool
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --provider) need_value "$@"; PROVIDER="$2"; shift 2;;
    --topic) need_value "$@"; TOPIC="$2"; shift 2;;
    --repo) need_value "$@"; REPO="$2"; shift 2;;
    --field) need_value "$@"; FIELD="$2"; shift 2;;
    --n) need_value "$@"; N="$2"; shift 2;;
    --contributors) CONTRIB=1; shift;;
    --mailto) need_value "$@"; MAILTO="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown: $1" >&2; usage; exit 1;;
  esac
done

case "$N" in ''|0|0[0-9]*|*[!0-9]*) die "--n must be a positive integer without leading zeroes";; esac
if [ "${#N}" -gt 3 ] || [ "$N" -gt 100 ]; then die "--n must be at most 100"; fi
[ -z "$MAILTO" ] || printf '%s\n' "$MAILTO" | LC_ALL=C grep -Eq '^[^[:space:]@/?#&]+@[^[:space:]@/?#&]+\.[^[:space:]@/?#&]+$' ||
  die "--mailto must be a valid email address"

TMP_BASE="${TMPDIR:-/tmp}"
[ -d "$TMP_BASE" ] || die "temporary directory does not exist: $TMP_BASE"
TMP="$(mktemp -d "$TMP_BASE/field-graph-seed.XXXXXX")" || die "could not create temporary directory"
cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

case "$PROVIDER" in
  github)
    command -v gh >/dev/null || { echo "error: 'gh' not found" >&2; exit 1; }
    [ -z "$TOPIC" ] || [ -z "$REPO" ] || die "use only one of --topic or --repo"
    if [ -n "$REPO" ]; then
      printf '%s\n' "$REPO" | LC_ALL=C grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "invalid GitHub repository: $REPO"
      echo "[github] top contributors of $REPO" >&2
      gh api "repos/$REPO/contributors?per_page=$N" --jq '.[].login' 2>/dev/null | awk '!s[$0]++' | head -n "$N"
      exit 0
    fi
    [ -n "$TOPIC" ] || { echo "error: github needs --topic or --repo" >&2; usage; exit 1; }
    printf '%s\n' "$TOPIC" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || die "invalid GitHub topic: $TOPIC"
    echo "[github] top repos for topic:$TOPIC -> owners$([ "$CONTRIB" = 1 ] && echo ' + contributors')" >&2
    reposN=$(( N > 20 ? 20 : N ))
    gh api -X GET search/repositories -f "q=topic:$TOPIC" -f sort=stars -f order=desc -f "per_page=$reposN" \
        --jq '.items[] | "\(.stargazers_count)\t\(.full_name)"' 2>/dev/null \
        | awk -F'\t' '{printf "  %8d  %s\n",$1,$2 > "/dev/stderr"; print $2}' > "$TMP/repos.tsv"
    # owners
    awk -F/ '{print $1}' "$TMP/repos.tsv" | awk '!s[$0]++' > "$TMP/seeds.txt"
    # optional: top contributors of the top 8 repos (real people, higher signal)
    if [ "$CONTRIB" = 1 ]; then
      head -n 8 "$TMP/repos.tsv" | while IFS= read -r r; do
        gh api "repos/$r/contributors?per_page=8" --jq '.[].login' 2>/dev/null || true
      done >> "$TMP/seeds.txt"
    fi
    awk '!s[$0]++' "$TMP/seeds.txt" | head -n "$N"
    echo "  NOTE: some owners are orgs (no follow graph) — harmless as seeds, but --contributors gives more real people." >&2
    ;;

  openalex)
    command -v curl >/dev/null && command -v jq >/dev/null || { echo "error: needs curl + jq" >&2; exit 1; }
    [ -n "$FIELD" ] || { echo "error: openalex needs --field \"<field name>\"" >&2; usage; exit 1; }
    enc=$(printf '%s' "$FIELD" | jq -sRr @uri)
    CID=$(curl -sL "https://api.openalex.org/concepts?search=${enc}&per_page=1${MAILTO:+&mailto=$MAILTO}" \
          | jq -r '.results[0].id // empty' | sed 's#https://openalex.org/##')
    [ -n "$CID" ] || { echo "error: could not resolve field '$FIELD' to an OpenAlex concept" >&2; exit 1; }
    echo "[openalex] field '$FIELD' -> concept $CID ; top authors on its most-cited works" >&2
    # aggregate authors from the field's most-cited works (robust across OpenAlex versions)
    pages=$(( (N / 25) + 2 ))
    for p in $(seq 1 "$pages"); do
      curl -sL "https://api.openalex.org/works?filter=concepts.id:${CID}&sort=cited_by_count:desc&per_page=200&page=${p}${MAILTO:+&mailto=$MAILTO}" \
        | jq -r '.results[].authorships[].author | select(.id!=null) | "\(.id|sub("https://openalex.org/";""))\t\(.display_name)"' 2>/dev/null
    done | awk -F'\t' '!s[$1]++{printf "  %s  %s\n",$1,$2 > "/dev/stderr"; print $1}' | head -n "$N"
    ;;

  *) echo "error: --provider must be github or openalex" >&2; usage; exit 1;;
esac
