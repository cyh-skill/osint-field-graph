#!/usr/bin/env bash
# osint-field-graph — map a technical field's core people on GitHub.
#
# Method: forward-following BFS + cross-source ranking.
# A person followed by many *independent* seed accounts is more central to a
# field than one with simply many followers.
#
# PUBLIC DATA ONLY. Reads public `following` lists / profiles via `gh`.
# Not a deanonymization tool. See ../SKILL.md "Scope & Red Lines".
#
# Deps: gh (authenticated) + coreutils (awk, sort, xargs). No Python, no runtime.
set -euo pipefail

CAP=100; ROUNDS=1; PROMOTE=10; TOP=30; ENRICH=0; WORKERS=8; CSV=""; SEEDS_ARG=""

usage() {
  cat >&2 <<'EOF'
Usage: field_graph.sh <seeds> [options]
  <seeds>        comma-separated logins, or @path/to/file (one per line, # = comment)

Options:
  --cap N        max following fetched per seed   (default 100)
  --rounds N     BFS rounds; extra rounds auto-promote top emerged nodes (default 1)
  --promote N    new seeds added per extra round  (default 10)
  --top N        rows to print                    (default 30)
  --enrich       fetch followers/name/bio for printed rows
  --workers N    parallel gh calls                (default 8)
  --csv PATH     write full ranking to CSV
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
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

command -v gh >/dev/null || { echo "error: GitHub CLI 'gh' not found" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMP CAP

# one seed -> its (seed<TAB>followee) edges, written to a per-seed file
fetch_one() {
  u="$1"
  gh api "users/$u/following?per_page=100" --jq '.[].login' 2>/dev/null \
    | head -n "$CAP" | awk -v s="$u" 'NF{print s"\t"$0}' > "$TMP/e_$u.tsv"
}
export -f fetch_one

# load seeds
if [ "${SEEDS_ARG#@}" != "$SEEDS_ARG" ]; then
  grep -vE '^[[:space:]]*#' "${SEEDS_ARG#@}" | tr -d '[:blank:]' | sed '/^$/d'
else
  printf '%s\n' "$SEEDS_ARG" | tr ',' '\n' | tr -d '[:blank:]' | sed '/^$/d'
fi | awk '!seen[$0]++' > "$TMP/seeds.txt"

: > "$TMP/done.txt"

rank() { cat "$TMP"/e_*.tsv 2>/dev/null | cut -f2 | sort | uniq -c | sort -rn | awk '{print $1"\t"$2}'; }

r=1
while [ "$r" -le "$ROUNDS" ]; do
  grep -vxF -f "$TMP/done.txt" "$TMP/seeds.txt" 2>/dev/null | sort -u > "$TMP/new.txt" || true
  echo "[round $r] fetching $(wc -l < "$TMP/new.txt" | tr -d ' ') seeds..." >&2
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

rank > "$TMP/rank.tsv"
SEEDS_N=$(wc -l < "$TMP/done.txt" | tr -d ' ')
EDGES_N=$(cat "$TMP"/e_*.tsv 2>/dev/null | wc -l | tr -d ' ')
NODES_N=$(wc -l < "$TMP/rank.tsv" | tr -d ' ')
printf '\n# Field graph: %s seeds, %s edges, %s unique nodes\n\n' "$SEEDS_N" "$EDGES_N" "$NODES_N"

printf '%3s  node%s\n' "src" "$([ "$ENRICH" = 1 ] && echo '  | followers | name | bio')"
head -n "$TOP" "$TMP/rank.tsv" | while IFS=$'\t' read -r c u; do
  if [ "$ENRICH" = 1 ]; then
    info=$(gh api "users/$u" --jq '[(.followers|tostring),(.name//"-"),((.bio//"")|gsub("[\n\t]";" ")|.[0:60])]|join("\t")' 2>/dev/null || true)
    printf '%3s  %s  | %s\n' "$c" "$u" "$info"
  else
    printf '%3s  %s\n' "$c" "$u"
  fi
done

if [ -n "$CSV" ]; then
  { echo "login,cross_source"; awk -F'\t' '{print $2","$1}' "$TMP/rank.tsv"; } > "$CSV"
  echo "CSV -> $CSV" >&2
fi
