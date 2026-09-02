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
#    cyh-browser-skill into a  seed<TAB>neighbor  TSV, then rank it here).
#
# PUBLIC DATA ONLY. Not a deanonymization tool. See ../SKILL.md "Scope & Red Lines".
# Deps: coreutils (awk, sort) + the chosen provider's tool. No Python.
set -euo pipefail

PROVIDER="github"; CAP=100; ROUNDS=1; PROMOTE=10; TOP=30; ENRICH=0; WORKERS=8
TIMEOUT=60; MAX_OUTPUT_KB=1024
CSV=""; EDGES=""; MAILTO="${OPENALEX_MAILTO:-}"; SEEDS_ARG=""
ACTIVE_FETCH_PIDS=""

die() { echo "error: $*" >&2; exit 1; }

need_value() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
}

positive_int() {
  case "$2" in
    ''|0|0[0-9]*|*[!0-9]*) die "$1 must be a positive integer without leading zeroes" ;;
  esac
}

nonnegative_int() {
  case "$2" in
    ''|0[0-9]*|*[!0-9]*) die "$1 must be a non-negative integer without leading zeroes" ;;
  esac
}

at_most() {
  if [ "${#2}" -gt "${#3}" ] || [ "$2" -gt "$3" ]; then
    die "$1 must be at most $3"
  fi
}

valid_mailto() {
  [ -z "$1" ] || printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[^[:space:]@/?#&]+@[^[:space:]@/?#&]+\.[^[:space:]@/?#&]+$'
}

usage() {
  cat >&2 <<'EOF'
Usage: field_graph.sh <seeds> [options]
  <seeds>          comma-separated node ids, or @path/to/file (one per line, # = comment)
                   github  -> logins            (e.g. soxoj,megadose)
                   openalex-> author ids A...   or names (auto-resolved, verify the echo!)

Provider:
  --provider P     github (default) | openalex | cmd:'<template with unquoted {}>'
  --edges FILE     skip fetching; rank a pre-collected TSV (seed<TAB>neighbor).
                   Use for API-less platforms (X / 小红书 / LinkedIn): collect
                   follow-lists via cyh-browser-skill, then rank here.
  --mailto EMAIL   contact email for OpenAlex's polite pool (recommended)

Graph:
  --cap N          max neighbors fetched per seed    (default 100)
  --rounds N       BFS rounds; extra rounds auto-promote top emerged nodes (default 1)
  --promote N      new seeds added per extra round   (default 10)
  --top N          rows to print                     (default 30)
  --enrich         fetch profile info for printed rows (provider-specific)
  --workers N      parallel fetches                  (default 8)
  --timeout N      timeout in seconds per provider   (default 60)
  --max-output-kb N maximum provider output per seed (default 1024)
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
    --provider) need_value "$@"; PROVIDER="$2"; shift 2;;
    --edges) need_value "$@"; EDGES="$2"; shift 2;;
    --mailto) need_value "$@"; MAILTO="$2"; shift 2;;
    --cap) need_value "$@"; CAP="$2"; shift 2;;
    --rounds) need_value "$@"; ROUNDS="$2"; shift 2;;
    --promote) need_value "$@"; PROMOTE="$2"; shift 2;;
    --top) need_value "$@"; TOP="$2"; shift 2;;
    --enrich) ENRICH=1; shift;;
    --workers) need_value "$@"; WORKERS="$2"; shift 2;;
    --timeout) need_value "$@"; TIMEOUT="$2"; shift 2;;
    --max-output-kb) need_value "$@"; MAX_OUTPUT_KB="$2"; shift 2;;
    --csv) need_value "$@"; CSV="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "unknown option: $1" >&2; usage; exit 1;;
    *) [ -z "$SEEDS_ARG" ] || die "only one seeds argument is allowed"; SEEDS_ARG="$1"; shift;;
  esac
done
[ -n "$SEEDS_ARG" ] || { usage; exit 1; }

positive_int --cap "$CAP"
positive_int --rounds "$ROUNDS"
nonnegative_int --promote "$PROMOTE"
positive_int --top "$TOP"
positive_int --workers "$WORKERS"
positive_int --timeout "$TIMEOUT"
positive_int --max-output-kb "$MAX_OUTPUT_KB"
at_most --cap "$CAP" 100000
at_most --rounds "$ROUNDS" 20
at_most --promote "$PROMOTE" 100000
at_most --top "$TOP" 100000
at_most --workers "$WORKERS" 128
at_most --timeout "$TIMEOUT" 3600
at_most --max-output-kb "$MAX_OUTPUT_KB" 102400
valid_mailto "$MAILTO" || die "--mailto must be a valid email address"

# --- provider dependency check (skipped in --edges mode: no fetching happens) -
[ -n "$EDGES" ] && PROVIDER="edges"
case "$PROVIDER" in
  edges) :;;
  github)   command -v gh   >/dev/null || { echo "error: 'gh' not found (github provider)"   >&2; exit 1; };;
  openalex) command -v curl >/dev/null && command -v jq >/dev/null || { echo "error: openalex provider needs curl + jq" >&2; exit 1; }
            [ -n "$MAILTO" ] || echo "note: pass --mailto EMAIL to use OpenAlex's faster polite pool" >&2;;
  cmd:*)    [ -n "${PROVIDER#cmd:}" ] || die "cmd provider template must not be empty"
            case "${PROVIDER#cmd:}" in *'{}'*) :;; *) die "cmd provider template must contain {}";; esac;;
  *) echo "error: unknown provider '$PROVIDER' (github|openalex|cmd:...)" >&2; exit 1;;
esac

TMP_BASE="${TMPDIR:-/tmp}"
[ -d "$TMP_BASE" ] || die "temporary directory does not exist: $TMP_BASE"
TMP="$(mktemp -d "$TMP_BASE/field-graph.XXXXXX")" || die "could not create temporary directory"
cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"; }
terminate_all() {
  local pid
  trap - HUP INT TERM
  for pid in $ACTIVE_FETCH_PIDS; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit 130
}
trap cleanup EXIT
trap terminate_all HUP INT TERM
: > "$TMP/e_empty.tsv"
export TMP CAP PROVIDER MAILTO TIMEOUT MAX_OUTPUT_KB

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

oa_following() {  # author id -> distinct co-authors (their "forward" collaborators)
  curl -sL "https://api.openalex.org/works?filter=author.id:$1&per_page=50&sort=cited_by_count:desc${MAILTO:+&mailto=$MAILTO}" \
    | jq -r --arg self "$1" '
        .results[].authorships[].author
        | select(.id != null)
        | (.id | sub("https://openalex.org/";"")) as $id
        | select($id != $self) | $id' 2>/dev/null | awk '!s[$0]++'
}

# --- one seed -> its (seed<TAB>neighbor) edges, deduped, into a per-seed file --
fetch_one() {
  local u="$1" out="$2" raw="${2}.raw" tpl script provider_pid="" status=0 wait_status=0 ticks
  terminate_fetch() {
    trap - HUP INT TERM
    if [ -n "$provider_pid" ]; then
      kill -TERM -- "-$provider_pid" 2>/dev/null || true
      sleep 0.1
      kill -KILL -- "-$provider_pid" 2>/dev/null || true
      wait "$provider_pid" 2>/dev/null || true
    fi
    exit 130
  }
  provider_command() {
    ulimit -f "$MAX_OUTPUT_KB"
    case "$PROVIDER" in
      github) gh api "users/$u/following?per_page=100" --jq '.[].login' ;;
      openalex) oa_following "$u" ;;
      cmd:*) bash -c "$script" field-graph-provider "$u" ;;
    esac
  }

  : > "$raw"
  tpl="${PROVIDER#cmd:}"
  # Keep the node out of shell source: every placeholder becomes quoted $1,
  # while the user-supplied command template remains the script itself.
  script="${tpl//\{\}/\"\$1\"}"

  # Give each provider its own process group so interruption and timeout can
  # terminate the complete command tree rather than orphaning grandchildren.
  set -m
  trap terminate_fetch HUP INT TERM
  provider_command > "$raw" 2>/dev/null &
  provider_pid=$!
  ticks=$((TIMEOUT * 10))
  while kill -0 "$provider_pid" 2>/dev/null; do
    if [ "$ticks" -le 0 ]; then
      status=124
      kill -TERM -- "-$provider_pid" 2>/dev/null || true
      sleep 0.1
      kill -KILL -- "-$provider_pid" 2>/dev/null || true
      break
    fi
    sleep 0.1
    ticks=$((ticks - 1))
  done
  if wait "$provider_pid" 2>/dev/null; then
    wait_status=0
  else
    wait_status=$?
  fi
  [ "$status" -ne 0 ] || status="$wait_status"
  provider_pid=""
  trap - HUP INT TERM
  set +m

  if [ "$status" -ne 0 ]; then
    : > "$raw"
    printf '%s\n' "$status" > "${out}.failed"
    if [ "$status" -eq 124 ]; then
      echo "  WARN: provider timed out after ${TIMEOUT}s for '$u'; discarding its output" >&2
    else
      echo "  WARN: provider failed with status $status for '$u'; discarding its output" >&2
    fi
  fi
  awk -v s="$u" -v cap="$CAP" '
    {
      sub(/\r$/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 == "") next
      if (index($0, "\t")) {
        printf "  WARN: ignoring neighbor containing a tab for %s\n", s > "/dev/stderr"
        next
      }
      if (!seen[$0]++ && emitted < cap) {
        print s "\t" $0
        emitted++
      }
    }
  ' "$raw" > "$out"
  rm -f -- "$raw"
}
edge_stream() { find "$TMP" -type f -name 'e_*.tsv' -exec cat {} +; }

rank() {
  edge_stream | awk -F'\t' 'NF == 2 { count[$2]++ } END { for (node in count) print count[node] "\t" node }' |
    LC_ALL=C sort -t $'\t' -k1,1nr -k2,2
}

validate_seed_file() {
  local file="$1" node
  [ -s "$file" ] || die "seed list is empty"
  while IFS= read -r node; do
    case "$node" in *$'\t'*|*$'\r'*) die "seed nodes must not contain tabs or carriage returns";; esac
    case "$PROVIDER" in
      github)
        printf '%s\n' "$node" | LC_ALL=C grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$' ||
          die "invalid GitHub login in seeds: $node"
        ;;
    esac
  done < "$file"
}

validate_openalex_ids() {
  local file="$1" node
  [ -s "$file" ] || die "no OpenAlex seed names could be resolved"
  while IFS= read -r node; do
    printf '%s\n' "$node" | LC_ALL=C grep -Eq '^A[0-9]+$' || die "invalid OpenAlex author id: $node"
  done < "$file"
}

fetch_batch() {
  local file="$1" round="$2" node index=0 active=0 pid
  ACTIVE_FETCH_PIDS=""
  while IFS= read -r node; do
    index=$((index + 1))
    fetch_one "$node" "$TMP/e_r${round}_${index}.tsv" &
    pid=$!
    ACTIVE_FETCH_PIDS="$ACTIVE_FETCH_PIDS $pid"
    active=$((active + 1))
    if [ "$active" -ge "$WORKERS" ]; then
      wait
      ACTIVE_FETCH_PIDS=""
      active=0
    fi
  done < "$file"
  wait
  ACTIVE_FETCH_PIDS=""
}

# --- build the graph ----------------------------------------------------------
if [ -n "$EDGES" ]; then
  # pre-collected edges (e.g. cyh-browser-skill harvest of an API-less platform)
  [ -f "$EDGES" ] || { echo "error: --edges file not found: $EDGES" >&2; exit 1; }
  awk -F'\t' '
    { sub(/\r$/, "") }
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    NF != 2 || $1 == "" || $2 == "" {
      printf "error: malformed edge TSV at line %d; expected exactly seed<TAB>neighbor\n", NR > "/dev/stderr"
      bad=1
      next
    }
    { print $1 "\t" $2 }
    END { if (bad) exit 1 }
  ' "$EDGES" | LC_ALL=C sort -u > "$TMP/e_precollected.tsv" || exit 1
  [ -s "$TMP/e_precollected.tsv" ] || die "--edges file contains no valid edges"
  cut -f1 "$TMP/e_precollected.tsv" | sort -u > "$TMP/done.txt"
  echo "[edges] ranking pre-collected graph: $(wc -l < "$TMP/e_precollected.tsv" | tr -d ' ') edges from $(wc -l < "$TMP/done.txt" | tr -d ' ') seeds" >&2
  PROVIDER="edges"   # nodes are opaque ids from a harvest; no live provider to enrich against
  [ "$ENRICH" = 1 ] && { echo "  note: --enrich ignored in --edges mode (no live provider)" >&2; ENRICH=0; }
else
  # load seeds
  if [ "${SEEDS_ARG#@}" != "$SEEDS_ARG" ]; then
    seed_path="${SEEDS_ARG#@}"
    [ -f "$seed_path" ] || die "seed file not found: $seed_path"
    awk '!/^[[:space:]]*#/ { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); if ($0 != "") print }' "$seed_path"
  else
    printf '%s\n' "$SEEDS_ARG" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
  fi | awk '!seen[$0]++' > "$TMP/seeds.txt"

  validate_seed_file "$TMP/seeds.txt"

  # openalex: resolve names/ids -> stable author ids up front (verify the echo!)
  if [ "$PROVIDER" = openalex ]; then
    echo "[openalex] resolving seeds -> author ids ..." >&2
    : > "$TMP/seeds_r.txt"
    while IFS= read -r s; do id=$(oa_resolve "$s"); [ -n "$id" ] && printf '%s\n' "$id" >> "$TMP/seeds_r.txt"; done < "$TMP/seeds.txt"
    awk '!seen[$0]++' "$TMP/seeds_r.txt" > "$TMP/seeds.txt"
    validate_openalex_ids "$TMP/seeds.txt"
  fi

  : > "$TMP/done.txt"
  r=1
  while [ "$r" -le "$ROUNDS" ]; do
    grep -vxF -f "$TMP/done.txt" "$TMP/seeds.txt" 2>/dev/null | sort -u > "$TMP/new.txt" || true
    echo "[round $r] fetching $(wc -l < "$TMP/new.txt" | tr -d ' ') seeds via '$PROVIDER'..." >&2
    fetch_batch "$TMP/new.txt" "$r"
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
EDGES_N=$(edge_stream | wc -l | tr -d ' ')
NODES_N=$(wc -l < "$TMP/rank.tsv" | tr -d ' ')
FAILURES_N=$(find "$TMP" -type f -name 'e_*.tsv.failed' | wc -l | tr -d ' ')
if [ "$FAILURES_N" -gt 0 ]; then
  echo "  WARN: $FAILURES_N of $SEEDS_N provider fetches failed; failed output was discarded" >&2
  [ "$FAILURES_N" -lt "$SEEDS_N" ] || die "all provider fetches failed"
fi
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
  { echo "node,cross_source"; awk -F'\t' '
      function csv(value) { gsub(/"/, "\"\"", value); return "\"" value "\"" }
      { print csv($2) "," $1 }
    ' "$TMP/rank.tsv"; } > "$CSV"
  echo "CSV -> $CSV" >&2
fi
