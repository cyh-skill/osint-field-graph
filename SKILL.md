---
name: gh-field-graph
description: >
  Map the core people of a technical field on GitHub. Given a few seed accounts,
  it expands their forward-following network (BFS) and ranks everyone by
  cross-source count — how many independent seeds follow them — to surface the
  field's true center, which is usually NOT the highest-follower account.
  Use when: "who are the core people in <field> on GitHub", "map the <topic>
  community", "find the influential maintainers in <ecosystem>", "field
  influence graph". Public data only.
allowed-tools: Bash, Read, Write
---

# gh-field-graph

Turn "who actually matters in technical field X on GitHub" from a guess into a
sourced, ranked graph.

## Core idea

Inspired by network-analysis writeups that mapped a field's key people from
public follow graphs. Two signals, and the second is the important one:

- **in-degree (follower count)** = *fame*.
- **cross-source count** = how many **independent seed accounts** follow a
  person = *peer recognition inside the niche*.

PageRank intuition: *being followed by several important, mutually-independent
nodes* beats *being followed by many random nodes*. The highest-follower
account is often a field-adjacent celebrity, not the center.

## Pipeline

1. **Seeds** — start from a handful of high-quality, unambiguous accounts in
   the field (well-known tool authors, an awesome-list maintainer, an org).
2. **Forward BFS** — fetch each seed's `following` list (forward network).
   Forward links (who a known expert chooses to follow) are far higher-signal
   than reverse `followers` (mostly noise).
3. **Cross-source ranking** — count how many distinct seeds follow each node.
   Long-tail distribution emerges; the head is the core.
4. **Domain filter** — the critical manual step. As rounds/seeds grow, raw
   cross-source drifts toward general-infosec / general-dev celebrities that
   *everyone* follows. Keep only nodes whose own work is in the field.
5. **Enrich & report** — pull name / followers / bio for the head, label each
   by their signature project, output a ranked table.

## Usage

```bash
# one round, enrich the top 20
python3 scripts/field_graph.py "soxoj,megadose,cipher387,WebBreacher" --top 20 --enrich

# seeds from a file, 3 BFS rounds (auto-promote top emerged nodes each round)
python3 scripts/field_graph.py @seeds.txt --rounds 3 --promote 12 --top 40 --csv out.csv
```

Flags: `--cap` (max following per seed, default 100), `--rounds`,
`--promote`, `--top`, `--enrich`, `--workers`, `--csv`.

Requires the GitHub CLI (`gh`) authenticated (`gh auth status`). Uses only
public REST endpoints (`users/{u}/following`, `users/{u}`).

## Reading the output

- **Resolution scales with seeds.** ~12 seeds tops out around 3 cross-sources;
  ~45 seeds reaches ~10. More rounds = finer head, but also more drift (step 4).
- **The center is the highest-cross-source node that is still on-topic** after
  the domain filter — frequently a mid-follower specialist, not the 10k+ name.

## Scope & Red Lines

This maps **publicly-active contributors** of a field from data they chose to
make public (their GitHub profile, their public follow graph, their signed
open-source work). That is the legitimate use, and the only one.

Do **not** repurpose this to:

- build an exhaustive dossier on one **private individual**, or de-anonymize
  someone who deliberately uses a pseudonym / left their profile blank — stop at
  deliberate anonymity;
- pivot from a **private identifier** (phone number, personal email, ID) to a
  person — this tool takes public accounts as seeds, by design, and never the
  reverse;
- attach private/sensitive attributes (psychoprofiles, location inference,
  protected characteristics) to people.

If you are doing hiring/due-diligence, restrict yourself to job-relevant,
self-published professional signals and follow local consent law (PIPL / GDPR /
FCRA). Aggregating "everything about a person" is out of scope on purpose.
