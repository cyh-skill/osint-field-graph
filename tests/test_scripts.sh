#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/field-graph-tests.XXXXXX")"
cleanup() { [ -d "$TEST_TMP" ] && rm -rf -- "$TEST_TMP"; }
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
fail() { echo "not ok - $*" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); echo "ok $PASS - $*"; }

expect_failure() {
  local description="$1"
  shift
  if "$@" > "$TEST_TMP/stdout" 2> "$TEST_TMP/stderr"; then
    fail "$description (command unexpectedly succeeded)"
  fi
  pass "$description"
}

assert_contains() {
  local file="$1" expected="$2" description="$3"
  grep -F -- "$expected" "$file" >/dev/null || fail "$description (missing: $expected)"
  pass "$description"
}

for script in field_graph.sh seed_bootstrap.sh cross_verify.sh; do
  bash -n "$ROOT/scripts/$script"
  "$ROOT/scripts/$script" --help >/dev/null 2>&1
done
pass "all shell entrypoints parse and expose help"

expect_failure "field_graph rejects a missing option value" "$ROOT/scripts/field_graph.sh" seed --top
expect_failure "field_graph rejects non-positive workers" "$ROOT/scripts/field_graph.sh" seed --workers 0
expect_failure "field_graph rejects leading-zero integers" "$ROOT/scripts/field_graph.sh" seed --rounds 08
expect_failure "field_graph bounds large values" "$ROOT/scripts/field_graph.sh" seed --top 100001
expect_failure "field_graph rejects multiple seed arguments" "$ROOT/scripts/field_graph.sh" one two
expect_failure "seed_bootstrap rejects a missing option value" "$ROOT/scripts/seed_bootstrap.sh" --topic
expect_failure "seed_bootstrap rejects an excessive seed count" "$ROOT/scripts/seed_bootstrap.sh" --topic osint --n 101
expect_failure "seed_bootstrap rejects huge integers cleanly" "$ROOT/scripts/seed_bootstrap.sh" --topic osint --n 999999999999999999999999999999
expect_failure "cross_verify rejects an invalid persona" "$ROOT/scripts/cross_verify.sh" --name Person --persona other
expect_failure "cross_verify requires a GitHub handle for code persona" "$ROOT/scripts/cross_verify.sh" --name Person --persona code
expect_failure "cross_verify validates GitHub handles" "$ROOT/scripts/cross_verify.sh" --gh bad/handle

cat > "$TEST_TMP/edges.tsv" <<'EOF'
# comment
seed-1	alice
seed-2	alice
seed-1	bob
seed-1	bob
EOF
"$ROOT/scripts/field_graph.sh" ignored --edges "$TEST_TMP/edges.tsv" --top 10 > "$TEST_TMP/ranking"
assert_contains "$TEST_TMP/ranking" "# Field graph [edges]: 2 seeds, 3 edges, 2 unique nodes" "edge mode deduplicates complete edges"
grep -Eq '^[[:space:]]*2[[:space:]]+alice$' "$TEST_TMP/ranking" || fail "edge mode ranks by independent sources"
pass "edge mode ranks by independent sources"

printf 'seed\tneighbor\textra\n' > "$TEST_TMP/bad-edges.tsv"
expect_failure "edge mode rejects malformed TSV" "$ROOT/scripts/field_graph.sh" ignored --edges "$TEST_TMP/bad-edges.tsv"
printf '# comments only\n\n' > "$TEST_TMP/empty-edges.tsv"
expect_failure "edge mode rejects empty graphs" "$ROOT/scripts/field_graph.sh" ignored --edges "$TEST_TMP/empty-edges.tsv"

MARKER="$TEST_TMP/injected"
export MARKER
cat > "$TEST_TMP/cmd-seeds.txt" <<'EOF'
safe
evil$(touch "$MARKER")
a/b
a?b
EOF
"$ROOT/scripts/field_graph.sh" "@$TEST_TMP/cmd-seeds.txt" \
  --provider 'cmd:printf "shared\nnode:%s\n" {}' --workers 2 --top 20 > "$TEST_TMP/cmd-ranking"
[ ! -e "$MARKER" ] || fail "cmd provider executed node text as shell source"
pass "cmd provider passes hostile node text as data"
assert_contains "$TEST_TMP/cmd-ranking" "# Field graph [cmd:printf \"shared\\nnode:%s\\n\" {}]: 4 seeds, 8 edges, 5 unique nodes" "parallel fetches avoid sanitized filename collisions"
grep -Eq '^[[:space:]]*4[[:space:]]+shared$' "$TEST_TMP/cmd-ranking" || fail "cmd provider output was not ranked"
pass "cmd provider output is ranked without corrupting spaces"

expect_failure "cmd provider discards partial output on failure" \
  "$ROOT/scripts/field_graph.sh" seed --provider 'cmd:: {}; printf "partial\n"; exit 9' --timeout 2
if grep -F partial "$TEST_TMP/stdout" >/dev/null; then fail "failed provider partial output entered the ranking"; fi
pass "failed provider output cannot pollute the ranking"

printf 'good\nbad\n' > "$TEST_TMP/mixed-seeds.txt"
"$ROOT/scripts/field_graph.sh" "@$TEST_TMP/mixed-seeds.txt" \
  --provider 'cmd:if [ {} = bad ]; then printf "partial\n"; exit 9; fi; printf "kept\n"' \
  --timeout 2 > "$TEST_TMP/mixed-ranking" 2> "$TEST_TMP/mixed-stderr"
assert_contains "$TEST_TMP/mixed-ranking" "kept" "successful providers survive a partial batch failure"
if grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+partial$' "$TEST_TMP/mixed-ranking"; then fail "partial failed output survived a mixed batch"
fi
pass "mixed batches discard only failed-provider output"

export PIDFILE="$TEST_TMP/timeout-provider.pid"
expect_failure "cmd provider timeout fails an all-failed run" \
  "$ROOT/scripts/field_graph.sh" seed --provider 'cmd:: {}; printf "%s\n" "$$" > "$PIDFILE"; exec sleep 30' --timeout 1
timeout_pid=$(cat "$PIDFILE")
if kill -0 "$timeout_pid" 2>/dev/null; then fail "timed-out provider remained alive"
fi
pass "provider timeout terminates the complete command group"

expect_failure "provider output limit rejects runaway output" \
  "$ROOT/scripts/field_graph.sh" seed --provider 'cmd:: {}; exec yes output' --timeout 5 --max-output-kb 1

export PIDFILE="$TEST_TMP/signal-provider.pid"
"$ROOT/scripts/field_graph.sh" seed \
  --provider 'cmd:: {}; trap "" TERM; printf "%s\n" "$$" > "$PIDFILE"; exec sleep 30' --timeout 30 \
  > "$TEST_TMP/signal-stdout" 2> "$TEST_TMP/signal-stderr" &
graph_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$PIDFILE" ] && break
  sleep 0.1
done
[ -s "$PIDFILE" ] || fail "signal test provider did not start"
signal_provider_pid=$(cat "$PIDFILE")
kill -TERM "$graph_pid"
if wait "$graph_pid"; then signal_rc=0; else signal_rc=$?; fi
[ "$signal_rc" -eq 130 ] || fail "interrupted field_graph returned $signal_rc instead of 130"
if kill -0 "$signal_provider_pid" 2>/dev/null; then fail "interrupted provider remained alive"
fi
pass "interrupting field_graph terminates provider descendants"

printf 'seed\tcomma,node\nseed\tquote"node\n' > "$TEST_TMP/csv-edges.tsv"
"$ROOT/scripts/field_graph.sh" ignored --edges "$TEST_TMP/csv-edges.tsv" --csv "$TEST_TMP/output.csv" >/dev/null
assert_contains "$TEST_TMP/output.csv" '"comma,node",1' "CSV output quotes commas"
assert_contains "$TEST_TMP/output.csv" '"quote""node",1' "CSV output escapes quotes"

mkdir "$TEST_TMP/seed-tmp"
expect_failure "seed_bootstrap reports unknown providers" env TMPDIR="$TEST_TMP/seed-tmp" "$ROOT/scripts/seed_bootstrap.sh" --provider invalid
[ -z "$(find "$TEST_TMP/seed-tmp" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "seed_bootstrap left temporary files after failure"
pass "seed_bootstrap removes its private temporary directory on failure"
if grep -F '/tmp/.fg_' "$ROOT/scripts/seed_bootstrap.sh" >/dev/null; then
  fail "seed_bootstrap still uses predictable /tmp files"
fi
pass "seed_bootstrap has no predictable /tmp filenames"

mkdir "$TEST_TMP/mock-bin" "$TEST_TMP/seed-success-tmp"
cat > "$TEST_TMP/mock-bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *contributors*) printf 'alice\nbob\nalice\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TEST_TMP/mock-bin/gh"
PATH="$TEST_TMP/mock-bin:$PATH" TMPDIR="$TEST_TMP/seed-success-tmp" \
  "$ROOT/scripts/seed_bootstrap.sh" --provider github --repo owner/repo --n 2 > "$TEST_TMP/seeds"
printf 'alice\nbob\n' > "$TEST_TMP/expected-seeds"
cmp "$TEST_TMP/expected-seeds" "$TEST_TMP/seeds" >/dev/null || fail "seed_bootstrap output changed"
[ -z "$(find "$TEST_TMP/seed-success-tmp" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "seed_bootstrap left temporary files after success"
pass "seed_bootstrap keeps output compatibility and cleans up on success"

mkdir "$TEST_TMP/graph-tmp"
expect_failure "field_graph reports malformed edge data" env TMPDIR="$TEST_TMP/graph-tmp" "$ROOT/scripts/field_graph.sh" ignored --edges "$TEST_TMP/bad-edges.tsv"
[ -z "$(find "$TEST_TMP/graph-tmp" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "field_graph left temporary files after failure"
pass "field_graph removes its private temporary directory on failure"

mkdir "$TEST_TMP/verify-bin"
cat > "$TEST_TMP/verify-bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'users/researcher '*) printf 'Researcher at Example Lab\tExample University\t-\t-\t5\tResearch Name\n' ;;
  *) exit 3 ;;
esac
EOF
cat > "$TEST_TMP/verify-bin/curl" <<'EOF'
#!/usr/bin/env bash
: "${CURL_ARGS:?}"
printf '%s\n' "$@" > "$CURL_ARGS"
printf '<title>arXiv Query</title><title>Verified Paper</title>\n'
EOF
chmod +x "$TEST_TMP/verify-bin/gh" "$TEST_TMP/verify-bin/curl"
export CURL_ARGS="$TEST_TMP/curl-args"
PATH="$TEST_TMP/verify-bin:$PATH" "$ROOT/scripts/cross_verify.sh" --gh researcher \
  > "$TEST_TMP/verify-output"
assert_contains "$TEST_TMP/verify-output" "persona: research" "cross_verify auto-detects research personas"
assert_contains "$TEST_TMP/verify-output" "Verified Paper" "cross_verify research success path uses arXiv"
assert_contains "$CURL_ARGS" 'search_query=au:"Research Name"' "cross_verify URL-encodes the complete author query argument"

cat > "$TEST_TMP/verify-bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$TEST_TMP/verify-bin/gh"
expect_failure "cross_verify reports GitHub API failure" env PATH="$TEST_TMP/verify-bin:$PATH" "$ROOT/scripts/cross_verify.sh" --gh unavailable

echo "1..$PASS"
