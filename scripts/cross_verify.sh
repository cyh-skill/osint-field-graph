#!/usr/bin/env bash
# cross_verify.sh — persona-routed cross-verification of one person.
#
# Detect what KIND of person this is, then check the source that authoritatively
# covers them: code -> GitHub/npm/PyPI, research -> arXiv, influencer/business ->
# emit a cyh-browser-skill plan (those need a logged-in browser). See ../SOURCES.md.
#
# PUBLIC, SELF-SIGNED identity only. Respects deliberate anonymity.
# Deps: gh (for code persona), curl. No Python.
set -euo pipefail

GH=""; NAME=""; PERSONA=""
die() { echo "error: $*" >&2; exit 1; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; }
usage() {
  cat >&2 <<'EOF'
Usage: cross_verify.sh --name "Full Name" [--gh <github-login>] [--persona code|research|influencer|business]
  --name      person's real/display name (used for arXiv/social search)
  --gh        a known GitHub handle (enables auto persona-detect + code checks)
  --persona   force a persona, skipping auto-detection
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --gh) need_value "$@"; GH="$2"; shift 2;;
    --name) need_value "$@"; NAME="$2"; shift 2;;
    --persona) need_value "$@"; PERSONA="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown: $1" >&2; usage; exit 1;;
  esac
done
[ -n "$NAME$GH" ] || { usage; exit 1; }
[ -z "$GH" ] || printf '%s\n' "$GH" | LC_ALL=C grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$' || die "invalid GitHub login: $GH"
case "$NAME" in *$'\n'*|*$'\r'*|*$'\t'*) die "--name must be a single line without tabs";; esac
case "$PERSONA" in ''|code|research|influencer|business) :;; *) die "--persona must be code, research, influencer, or business";; esac
[ -z "$GH" ] || command -v gh >/dev/null || die "'gh' not found"

# --- auto-detect persona from a GitHub profile, if available -----------------
BIO=""; COMPANY=""; TW="-"; BLOG="-"; REPOS=0; GHNAME=""
if [ -n "$GH" ]; then
  if ! prof=$(gh api "users/$GH" --jq '[
      (.bio//""|gsub("[\n\t]";" ")),
      (.company//""|gsub("[\n\t]";" ")),
      (.twitter_username//"-"),
      (.blog//"-"),
      (.public_repos|tostring),
      (.name//"")
    ]|join("\t")' 2>/dev/null); then
    die "could not fetch GitHub profile for $GH"
  fi
  # awk -F'\t' does NOT merge empty fields (unlike `read` with whitespace IFS)
  BIO=$(printf '%s' "$prof"     | awk -F'\t' '{print $1}')
  COMPANY=$(printf '%s' "$prof" | awk -F'\t' '{print $2}')
  TW=$(printf '%s' "$prof"      | awk -F'\t' '{print $3}')
  BLOG=$(printf '%s' "$prof"    | awk -F'\t' '{print $4}')
  REPOS=$(printf '%s' "$prof"   | awk -F'\t' '{print $5}')
  GHNAME=$(printf '%s' "$prof"  | awk -F'\t' '{print $6}')
  [ -z "${REPOS//[0-9]/}" ] || REPOS=0
  [ -z "$NAME" ] && NAME="$GHNAME"
fi

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
sig="$(lc "$BIO $COMPANY")"

if [ -z "$PERSONA" ]; then
  case "$sig" in
    *phd*|*ph.d*|*researcher*|*research\ scientist*|*professor*|*university*|*laborator*|*institute*|*deepmind*)
      PERSONA="research";;
    *founder*|*co-founder*|*ceo*|*cto*|*investor*|*partner*)
      PERSONA="business";;
    *creator*|*content*|*influencer*|*streamer*|*youtuber*)
      PERSONA="influencer";;
    *)
      if [ -n "$GH" ] && [ "${REPOS:-0}" -ge 3 ]; then PERSONA="code"; else PERSONA="unknown"; fi;;
  esac
fi

[ "$PERSONA" != code ] || [ -n "$GH" ] || die "code persona requires --gh"
[ "$PERSONA" != research ] || [ -n "$NAME" ] || die "research persona requires --name or a GitHub profile with a public name"
[ "$PERSONA" != research ] || command -v curl >/dev/null || die "'curl' not found"

echo "== subject =="
echo "name:    ${NAME:-?}"
[ -n "$GH" ] && echo "github:  https://github.com/$GH  (repos:$REPOS company:$COMPANY)"
[ -n "$TW" ] && [ "$TW" != "-" ] && echo "x:       https://x.com/$TW   (self-published on GitHub)"
[ -n "$BLOG" ] && [ "$BLOG" != "-" ] && echo "site:    $BLOG"
echo "persona: $PERSONA"
echo

case "$PERSONA" in
  code)
    echo "== [code] GitHub / package registries =="
    gh api "users/$GH/repos?per_page=100&sort=stars" \
      --jq 'sort_by(-.stargazers_count)[:8][]|"  \(.stargazers_count)star \(.name)  \(.language//"-")"' 2>/dev/null || true
    echo "  npm:   https://www.npmjs.com/~$GH    (check Author field on packages)"
    echo "  PyPI:  the GitHub-linked project on pypi.org -> Author field"
    ;;
  research)
    echo "== [research] arXiv author search =="
    if ! arxiv_response=$(curl -fsSL --get 'https://export.arxiv.org/api/query' \
      --data-urlencode "search_query=au:\"$NAME\"" --data-urlencode 'max_results=6' \
    ); then
      die "arXiv request failed"
    fi
    printf '%s\n' "$arxiv_response" \
      | grep -oE '<title>[^<]+</title>' | sed 's/<[^>]*>//g' | grep -v '^arXiv Query' | sed 's/^/  - /' || true
    echo "  also: Semantic Scholar / OpenAlex / DBLP / ORCID  (API-key or browser)"
    ;;
  influencer)
    cat <<EOF
== [influencer] browser plan (needs logged-in browser; use cyh-browser-skill) ==
  search "$NAME" on:  xiaohongshu / weibo / douyin / bilibili / X / YouTube
  confirm via: profile verification badge, bio cross-link back to GitHub/site, follower scale
EOF
    ;;
  business)
    cat <<EOF
== [business] browser / registry plan ==
  LinkedIn:   search "$NAME"  (cyh-browser-skill or Bright Data)
  Crunchbase: company + role
  CN registry: gsxt.gov.cn (official, free) / tianyancha / qcc
  confirm via: employment record, registered legal rep, official team page
EOF
    ;;
  *)
    echo "== persona unknown -- too few signals. Likely deliberately low-profile."
    echo "   Per SOURCES.md: if no signed public identity exists, stop here."
    ;;
esac
