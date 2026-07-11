---
name: cyh-field-graph
description: >
  Find the *real* core people of ANY field by mapping its endorsement graph, not
  by follower count. Method: pick the platform where the field actually lives →
  seed with its top accounts → expand their forward network (BFS) → rank everyone
  by cross-source count (how many independent seeds endorse them). The center is
  usually NOT the biggest-follower name. Works on GitHub follows, academic
  co-authorship (OpenAlex), or any platform via a pluggable provider.
  Use when: "who are the core people in <field>", "map the <topic/community>",
  "find the influential/key people in <ecosystem>", "领域核心人物/大V是谁",
  "找出某领域真正重要的人", "field influence graph". Public, self-published data only.
allowed-tools: Bash, Read, Write
---

# field-graph

Turn "who actually matters in field X" from a guess into a sourced, ranked graph —
**for any field, on whatever platform that field actually congregates on.**

Method adapted from SimmerChan, *用 Agent 自动扒了一遍知乎推荐系统领域的大V*
(zhuanlan.zhihu.com/p/2052179994911171124) — which mapped Zhihu's rec-sys field.
This skill generalizes it: the graph algorithm is one thing, the platform it runs
on is a swappable **provider**.

## Core idea

Two signals, and the second is the important one:

- **in-degree (follower / citation count)** = *fame*.
- **cross-source count** = how many **independent seed accounts** endorse a person
  = *peer recognition inside the niche*.

PageRank intuition: *being endorsed by several important, mutually-independent
nodes* beats *being endorsed by many random nodes*. The highest-follower account
is often a field-adjacent celebrity, not the center. (In the source article: a
14万-follower name was **not** the center; a 2万-follower node endorsed by 7
independent core people was.)

And **forward beats reverse**: who an expert *chooses to follow / cite* is
high-signal (30-40% on-topic); their *followers* are mostly noise (3-10%).

## The pipeline — 5 stages

Run these in order. Stages 1–2 are reasoning; 3–5 are the scripts.

### 1. Define the field (定域)
State the field boundary in one sentence, and the *disqualifier* ("… but NOT
general-purpose ML celebrities"). This is the yardstick for the Stage-4 domain
filter. Without it, ranking drifts to whoever everyone follows.

### 2. Route the field to its platform (找阵地) → pick a provider
Where do this field's people actually congregate and leave a public endorsement
graph? This decides the provider. See **[`PLATFORMS.md`](PLATFORMS.md)** for the
full routing table; the short version:

| Field looks like… | Platform / graph | provider |
|---|---|---|
| open-source / dev tooling / infra | GitHub follows | `github` |
| academic / research / a paper's field | OpenAlex co-authorship | `openalex` |
| Chinese tech / 内容创作 / 知乎大V | Zhihu follows | `cmd:` or `--edges` (web-access) |
| influencer / 种草 / creator | X, 小红书, 微博, B站 | `--edges` (web-access) |
| founders / VC / business | LinkedIn, X | `--edges` (web-access) |

Rule of thumb: use `github`/`openalex` when the field lives there (open API);
otherwise collect the graph with the **web-access skill** and rank via `--edges`.

### 3. Seed with the field's top ~50 (取种子)
Don't hand-pick 4 accounts and hope. Get the field's head first:

```bash
# GitHub: a topic → owners + top contributors of its top repos
scripts/seed_bootstrap.sh --provider github --topic osint --n 40 --contributors > seeds.txt

# OpenAlex: a field → its most-cited authors
scripts/seed_bootstrap.sh --provider openalex --field "natural language processing" --n 50 --mailto you@x.com > seeds.txt
```

For API-less platforms, get the field's 榜单 / top list via the web-access skill
(a "top rec-sys 大V" list, an awards page, a leaderboard) and save as seeds.
**Eyeball the list** — bad seeds poison the whole graph.

### 4. Expand + rank (扩散 + 交叉信源排序)
Forward BFS over the seeds' endorsement lists, then rank by cross-source count.

```bash
# GitHub, 3 BFS rounds, enrich the head
scripts/field_graph.sh @seeds.txt --rounds 3 --promote 12 --top 40 --enrich --csv out.csv

# OpenAlex (co-authorship graph)
scripts/field_graph.sh @seeds.txt --provider openalex --mailto you@x.com --top 30 --enrich

# any platform you can script one hop of:
scripts/field_graph.sh @seeds.txt --provider 'cmd:<command that prints node {}\047s neighbors>'

# platform with no API: rank a graph you harvested via web-access
scripts/field_graph.sh field --edges harvested_follows.tsv --top 40
```

Then **domain-filter** (the one manual step): as rounds grow, raw cross-source
drifts toward field-adjacent celebrities *everyone* follows. Keep only nodes whose
own work is in the field (Stage-1 boundary). The center = the highest-cross-source
node **still on-topic** after this filter — often a mid-follower specialist.

### 5. Cross-verify, routed by persona (交叉验证)
A high-ranked node is a handle, not yet a person. Confirm who they are via the
source that *authoritatively* covers their kind — not "check every site":

```bash
scripts/cross_verify.sh --gh sokra                 # auto-detect persona from GitHub
scripts/cross_verify.sh --name "Tri Dao" --persona research
```

code → GitHub/npm/PyPI · research → arXiv/OpenAlex/ORCID · influencer → 小红书/微博/
B站/X (web-access) · business → LinkedIn/Crunchbase/gsxt.gov.cn. Full routing +
the self-signed-only rule: **[`SOURCES.md`](SOURCES.md)**.

## Providers (Stage 4 engine)

`field_graph.sh` is platform-agnostic; a provider answers one question — *given a
node, which nodes does it endorse?*

| provider | edge = | needs | node id |
|---|---|---|---|
| `github` (default) | who a user **follows** | `gh` (authed) | login |
| `openalex` | a researcher's **co-authors** | `curl`, `jq` | author id `A…` (or a name, auto-resolved — verify the echo) |
| `cmd:TPL` | stdout of `TPL` with `{}` = node | whatever `TPL` uses | anything |
| `--edges FILE` | pre-collected `seed<TAB>neighbor` TSV | — | anything |

Adding a field = adding a provider. If you can script "given X, list who X
endorses" for a platform, `cmd:` plugs it in with zero engine changes. If the
platform needs a logged-in browser, harvest with web-access → rank via `--edges`.

Pure shell — **no Python, no runtime**. `github` needs `gh` authenticated
(`gh auth status`); `openalex` needs `curl` + `jq`. Public REST endpoints only.

## Reading the output

- **Resolution scales with seeds.** ~12 seeds tops out ~3 cross-sources; ~45 seeds
  reaches ~10. More rounds = finer head, but more drift (Stage 4).
- **The center is the highest-cross-source node still on-topic** after the domain
  filter — frequently a mid-follower specialist, not the 10k+/14万 name.

## Scope & Red Lines

Maps **publicly-active contributors** of a field from data they chose to make
public (their profile, their public follow/citation graph, their signed work).
That is the legitimate use, and the only one.

Do **not** repurpose this to:

- build an exhaustive dossier on one **private individual**, or de-anonymize
  someone who deliberately uses a pseudonym / left their profile blank — stop at
  deliberate anonymity (in the source article: a core node with a blank GitHub was
  left un-identified, on purpose);
- pivot from a **private identifier** (phone, personal email, ID) to a person —
  this tool takes public accounts as seeds, by design, never the reverse;
- attach private/sensitive attributes (psychoprofiles, location inference,
  protected characteristics) to people.

Hiring / due-diligence: restrict to job-relevant, self-published professional
signals and follow local consent law (PIPL / GDPR / FCRA). Real names inferred
from an ID are "unconfirmed" until the person signed them publicly. Aggregating
"everything about a person" is out of scope on purpose.
