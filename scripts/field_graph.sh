#!/usr/bin/env bash
# field-graph — map the core people of ANY field on a directed "endorsement" graph.
#
# Method: forward-endorsement BFS + cross-source ranking. A node endorsed by many
# *independent* seed accounts is more central to a field than one with simply many
# followers/citations.  (cross-source count = peer recognition ; in-degree = fame.)
#
# The graph algorithm is provider-agnostic. A "provider" answers ONE question:
#   given a node, which nodes does it *endorse* (follow / co-author / cite / ...)?
#
# Built-in providers:
#   github     edges = who a GitHub user *follows*      (needs: gh, authenticated)
#   openalex   edges = a researcher's *co-authors*      (needs: curl, jq)
#   cmd:TPL    edges = stdout of TPL, with {} = node    (any platform you can script)
# Or skip fetching and rank a pre-collected edge file with  --edges FILE
#   (the path for platforms with no open API: collect follow-lists via the
#    web-access skill into a  seed<TAB>neighbor  TSV, then rank it here).
#
# PUBLIC DATA ONLY. Not a deanonymization tool. See ../SKILL.md "Scope & Red Lines".
# Deps: coreutils (awk, sort, xargs) + the chosen provider's tool. No Python.
set -euo pipefail

PROVIDER="github"; CAP=100; ROUNDS=1; PROMOTE=10; TOP=30; ENRICH=0; WORKERS=8
CSV=""; EDGES=""; MAILTO="${OPENALEX_MAILTO:-}"; SEEDS_ARG=""

usage() {
  cat >&2 <<'EOF'
Usage: field_graph.sh <seeds> [options]
  <seeds>          comma-separated node ids, or @path/to/file (one per line, # = comment)
                   github  -> logins            (e.g. soxoj,megadose)
                   openalex-> author ids A...   or names (auto-resolved, verify the echo!)

Provider:
  --provider P     github (default) | openalex | cmd:'<template with {}>'
  --edges FILE     skip fetching; rank a pre-collected TSV (seed<TAB>neighbor).
                   Use for API-less platforms (X / 小红书 / LinkedIn): collect
                   follow-lists via the web-access skill, then rank here.
  --mailto EMAIL   contact email for OpenAlex's polite pool (recommended)

Graph:
  --cap N          max neighbors fetched per seed    (default 100)
  --rounds N       BFS rounds; extra rounds auto-promote top emerged nodes (default 1)
  --promote N      new seeds added per extra round   (default 10)
  --top N          rows to print                     (default 30)
  --enrich         fetch profile info for printed rows (provider-specific)
  --workers N      parallel fetches                  (default 8)
  --csv PATH       write full ranking to CSV

Examples:
  field_graph.sh "soxoj,megadose,cipher387" --top 20 --enrich
  field_graph.sh @seeds.txt --rounds 3 --promote 12 --top 40 --csv out.csv
  field_graph.sh @ml.txt --provider openalex --mailto you@x.com --top 30 --enrich
  field_graph.sh @seeds.txt --provider 'cmd:gh api users/{}/following --jq .[].login'
  field_graph.sh x --edges collected_x_follows.tsv --top 40
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2;;
    --edges) EDGES="$2"; shift 2;;
    --mailto) MAILTO="$2"; shift 2;;
    --cap) CAP="$2"; shift 2;;
    --rounds) ROUNDS="$2"; shift 2;;
    --promote) PROMOTE="$2"; shift 2;;
    --top) TOP="$2"; shift 2;;
    --enrich) ENRICH=1; shift;;
    --workers) WORKERS="$2"; shift 2;;
    --csv) CSV="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "unknown option: $1" >&2; usage; exit 1;;
    *) SEEDS_ARG="$1"; shift;;
  esac
done
[ -n "$SEEDS_ARG" ] || { usage; exit 1; }

# --- provider dependency check (skipped in --edges mode: no fetching happens) -
[ -n "$EDGES" ] && PROVIDER="edges"
case "$PROVIDER" in
  edges) :;;
  github)   command -v gh   >/dev/null || { echo "error: 'gh' not found (github provider)"   >&2; exit 1; };;
  openalex) command -v curl >/dev/null && command -v jq >/dev/null || { echo "error: openalex provider needs curl + jq" >&2; exit 1; }
            [ -n "$MAILTO" ] || echo "note: pass --mailto EMAIL to use OpenAlex's faster polite pool" >&2;;
  cmd:*)    :;;
  *) echo "error: unknown provider '$PROVIDER' (github|openalex|cmd:...)" >&2; exit 1;;
esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMP CAP PROVIDER MAILTO

# --- OpenAlex helpers ---------------------------------------------------------
oa_resolve() {  # name-or-id -> author id (A...), logging what it resolved to
  q="$1"
  case "$q" in
    A[0-9]*)                   printf '%s\n' "$q"; return;;
    https://openalex.org/A*)   printf '%s\n' "${q##*/}"; return;;
  esac
  enc=$(printf '%s' "$q" | jq -sRr @uri)
  hit=$(curl -sL "https://api.openalex.org/authors?search=${enc}&per_page=1${MAILTO:+&mailto=$MAILTO}" \
        | jq -r '.results[0] // empty | "\(.id|sub("https://openalex.org/";""))\t\(.display_name)\t\(.last_known_institutions[0].display_name // "-")"' 2>/dev/null || true)
  id="${hit%%$'\t'*}"
  if [ -n "$id" ] && [ "$id" != "null" ]; then
    echo "  resolved '$q' -> $hit" >&2
    printf '%s\n' "$id"
  else
    echo "  WARN: could not resolve '$q' on OpenAlex; skipping" >&2
  fi
}
export -f oa_resolve

oa_following() {  # author id -> distinct co-authors (their "forward" collaborators)
  curl -sL "https://api.openalex.org/works?filter=author.id:$1&per_page=50&sort=cited_by_count:desc${MAILTO:+&mailto=$MAILTO}" \
    | jq -r --arg self "$1" '
        .results[].authorships[].author
        | select(.id != null)
        | (.id | sub("https://openalex.org/";"")) as $id
        | select($id != $self) | $id' 2>/dev/null | awk '!s[$0]++'
}
export -f oa_following

# --- one seed -> its (seed<TAB>neighbor) edges, deduped, into a per-seed file --
fetch_one() {
  u="$1"
  {
    case "$PROVIDER" in
      github)   gh api "users/$u/following?per_page=100" --jq '.[].login' 2>/dev/null | awk '!s[$0]++' ;;
      openalex) oa_following "$u" ;;
      cmd:*)    tpl="${PROVIDER#cmd:}"; bash -c "${tpl//\{\}/$u}" 2>/dev/null \
                  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | awk '!s[$0]++' ;;
    esac
  } | head -n "$CAP" | awk -v s="$u" 'NF{print s"\t"$0}' > "$TMP/e_$(printf '%s' "$u" | tr -c 'A-Za-z0-9._-' '_').tsv"
}
export -f fetch_one

rank() { cat "$TMP"/e_*.tsv 2>/dev/null | cut -f2 | sort | uniq -c | sort -rn | awk '{print $1"\t"$2}'; }

# --- build the graph ----------------------------------------------------------
if [ -n "$EDGES" ]; then
  # pre-collected edges (e.g. web-access harvest of an API-less platform)
  [ -f "$EDGES" ] || { echo "error: --edges file not found: $EDGES" >&2; exit 1; }
  sort -u "$EDGES" > "$TMP/e_precollected.tsv"
  cut -f1 "$TMP/e_precollected.tsv" | sort -u > "$TMP/done.txt"
  echo "[edges] ranking pre-collected graph: $(wc -l < "$TMP/e_precollected.tsv" | tr -d ' ') edges from $(wc -l < "$TMP/done.txt" | tr -d ' ') seeds" >&2
  PROVIDER="edges"   # nodes are opaque ids from a harvest; no live provider to enrich against
  [ "$ENRICH" = 1 ] && { echo "  note: --enrich ignored in --edges mode (no live provider)" >&2; ENRICH=0; }
else
  # load seeds
  if [ "${SEEDS_ARG#@}" != "$SEEDS_ARG" ]; then
    grep -vE '^[[:space:]]*#' "${SEEDS_ARG#@}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
  else
    printf '%s\n' "$SEEDS_ARG" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
  fi | awk '!seen[$0]++' > "$TMP/seeds.txt"

  # openalex: resolve names/ids -> stable author ids up front (verify the echo!)
  if [ "$PROVIDER" = openalex ]; then
    echo "[openalex] resolving seeds -> author ids ..." >&2
    : > "$TMP/seeds_r.txt"
    while IFS= read -r s; do id=$(oa_resolve "$s"); [ -n "$id" ] && printf '%s\n' "$id" >> "$TMP/seeds_r.txt"; done < "$TMP/seeds.txt"
    awk '!seen[$0]++' "$TMP/seeds_r.txt" > "$TMP/seeds.txt"
  fi

  : > "$TMP/done.txt"
  r=1
  while [ "$r" -le "$ROUNDS" ]; do
    grep -vxF -f "$TMP/done.txt" "$TMP/seeds.txt" 2>/dev/null | sort -u > "$TMP/new.txt" || true
    echo "[round $r] fetching $(wc -l < "$TMP/new.txt" | tr -d ' ') seeds via '$PROVIDER'..." >&2
    xargs -P "$WORKERS" -I{} bash -c 'fetch_one "$1"' _ {} < "$TMP/new.txt"
    cat "$TMP/new.txt" >> "$TMP/done.txt"
    if [ "$r" -lt "$ROUNDS" ]; then
      rank | awk -F'\t' '{print $2}' | grep -vxF -f "$TMP/done.txt" | head -n "$PROMOTE" > "$TMP/promo.txt" || true
      echo "[round $r] promoting -> $(paste -sd, "$TMP/promo.txt")" >&2
      echo "  NOTE: auto-promotion drifts toward field-adjacent celebrities; apply domain filtering (see SKILL.md)." >&2
      cat "$TMP/promo.txt" >> "$TMP/seeds.txt"
    fi
    r=$((r + 1))
  done
fi

# --- rank & report ------------------------------------------------------------
rank > "$TMP/rank.tsv"
SEEDS_N=$(wc -l < "$TMP/done.txt" | tr -d ' ')
EDGES_N=$(cat "$TMP"/e_*.tsv 2>/dev/null | wc -l | tr -d ' ')
NODES_N=$(wc -l < "$TMP/rank.tsv" | tr -d ' ')
printf '\n# Field graph [%s]: %s seeds, %s edges, %s unique nodes\n\n' "$PROVIDER" "$SEEDS_N" "$EDGES_N" "$NODES_N"

case "$PROVIDER" in
  openalex) ENRICH_HDR='  | cited_by | name | institution | works' ;;
  *)        ENRICH_HDR='  | followers | name | bio' ;;
esac
printf '%3s  node%s\n' "src" "$([ "$ENRICH" = 1 ] && printf '%s' "$ENRICH_HDR")"

enrich_one() {
  case "$PROVIDER" in
    github)   gh api "users/$1" --jq '[(.followers|tostring),(.name//"-"),((.bio//"")|gsub("[\n\t]";" ")|.[0:60])]|join("\t")' 2>/dev/null || true ;;
    openalex) curl -sL "https://api.openalex.org/authors/$1${MAILTO:+?mailto=$MAILTO}" \
                | jq -r '[(.cited_by_count|tostring),(.display_name//"-"),(.last_known_institutions[0].display_name//"-"),(.works_count|tostring)]|join("\t")' 2>/dev/null || true ;;
    *) printf '%s' "-" ;;
  esac
}

head -n "$TOP" "$TMP/rank.tsv" | while IFS=$'\t' read -r c u; do
  if [ "$ENRICH" = 1 ]; then
    printf '%3s  %s  | %s\n' "$c" "$u" "$(enrich_one "$u")"
  else
    printf '%3s  %s\n' "$c" "$u"
  fi
done

if [ -n "$CSV" ]; then
  { echo "node,cross_source"; awk -F'\t' '{print $2","$1}' "$TMP/rank.tsv"; } > "$CSV"
  echo "CSV -> $CSV" >&2
fi
