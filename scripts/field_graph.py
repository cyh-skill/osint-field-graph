#!/usr/bin/env python3
"""gh-field-graph — map a technical field's core people on GitHub.

Method: forward-following BFS + cross-source ranking.
A person followed by many *independent* seed accounts is more central to a
field than a person who simply has many followers (PageRank-style intuition:
in-degree = fame; cross-source = peer recognition inside the niche).

PUBLIC DATA ONLY. This reads public `following` lists and public profiles via
the authenticated `gh` CLI. It maps PUBLICLY-ACTIVE contributors in a field.
It is NOT a people-deanonymization tool. See SKILL.md "Scope & Red Lines".
"""
import argparse
import concurrent.futures
import json
import subprocess
import sys
from collections import defaultdict


def gh_following(user, cap):
    """Return (user, [followee_login, ...]) up to `cap`, using public API."""
    logins, page = [], 1
    while len(logins) < cap:
        try:
            out = subprocess.run(
                ["gh", "api", f"users/{user}/following?per_page=100&page={page}"],
                capture_output=True, text=True, timeout=30,
            )
        except subprocess.TimeoutExpired:
            break
        if out.returncode != 0:
            break
        try:
            arr = json.loads(out.stdout)
        except json.JSONDecodeError:
            break
        if not arr:
            break
        logins += [u["login"] for u in arr]
        if len(arr) < 100:
            break
        page += 1
    return user, logins[:cap]


def fetch_all(seeds, cap, workers):
    edges = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(gh_following, s, cap) for s in seeds]
        for f in concurrent.futures.as_completed(futs):
            s, logins = f.result()
            edges[s] = logins
            print(f"  {s}: {len(logins)} following", file=sys.stderr)
    return edges


def cross_source(edges):
    """node -> number of DISTINCT seeds that follow it."""
    cnt = defaultdict(set)
    for seed, logins in edges.items():
        for u in logins:
            cnt[u].add(seed)
    return {u: len(s) for u, s in cnt.items()}


def enrich(login):
    out = subprocess.run(
        ["gh", "api", f"users/{login}", "--jq",
         '[(.followers|tostring),(.name//"-"),'
         '((.bio//"")|gsub("[\\n\\t]";" ")|.[0:60])]|join("\t")'],
        capture_output=True, text=True,
    )
    return out.stdout.strip() if out.returncode == 0 else "\t\t"


def main():
    ap = argparse.ArgumentParser(
        description="Map a field's core GitHub people via following-BFS + cross-source ranking.")
    ap.add_argument("seeds", help="comma-separated seed logins, or @path/to/file (one per line)")
    ap.add_argument("--cap", type=int, default=100, help="max following fetched per seed (default 100)")
    ap.add_argument("--rounds", type=int, default=1,
                    help="BFS rounds; each extra round auto-promotes top emerged nodes as new seeds")
    ap.add_argument("--promote", type=int, default=10, help="new seeds added per extra round (default 10)")
    ap.add_argument("--top", type=int, default=30, help="rows to print (default 30)")
    ap.add_argument("--enrich", action="store_true", help="fetch profile (followers/name/bio) for printed rows")
    ap.add_argument("--workers", type=int, default=8, help="parallel gh calls (default 8)")
    ap.add_argument("--csv", help="write full ranking to this CSV path")
    args = ap.parse_args()

    if args.seeds.startswith("@"):
        with open(args.seeds[1:]) as fh:
            seeds = [l.strip() for l in fh if l.strip() and not l.startswith("#")]
    else:
        seeds = [s.strip() for s in args.seeds.split(",") if s.strip()]

    all_edges = {}
    seedset = list(dict.fromkeys(seeds))
    for r in range(1, args.rounds + 1):
        new = [s for s in seedset if s not in all_edges]
        print(f"[round {r}] fetching {len(new)} seeds...", file=sys.stderr)
        all_edges.update(fetch_all(new, args.cap, args.workers))
        if r < args.rounds:
            rank = cross_source(all_edges)
            promo = [u for u, _ in sorted(rank.items(), key=lambda x: -x[1])
                     if u not in all_edges][:args.promote]
            print(f"[round {r}] promoting -> {', '.join(promo)}", file=sys.stderr)
            print("  NOTE: auto-promotion drifts toward field-adjacent celebrities;"
                  " apply domain filtering on the final list (see SKILL.md).", file=sys.stderr)
            seedset += promo

    rank = cross_source(all_edges)
    ranked = sorted(rank.items(), key=lambda x: (-x[1], x[0]))

    n_edges = sum(len(v) for v in all_edges.values())
    print(f"\n# Field graph: {len(all_edges)} seeds, {n_edges} edges, {len(rank)} unique nodes\n")
    header = f"{'src':>3}  node"
    if args.enrich:
        header += "  | followers | name | bio"
    print(header)
    for u, c in ranked[:args.top]:
        print(f"{c:>3}  {u}" + (f"  | {enrich(u)}" if args.enrich else ""))

    if args.csv:
        with open(args.csv, "w") as f:
            f.write("login,cross_source\n")
            for u, c in ranked:
                f.write(f"{u},{c}\n")
        print(f"\nCSV -> {args.csv}", file=sys.stderr)


if __name__ == "__main__":
    main()
