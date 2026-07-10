# field-graph

A Claude Code / agent **skill** that finds the *real* core people of **any** field
— by mapping its endorsement graph, not by follower count.

Generalized from a GitHub-only tool (`osint-field-graph`) into a **five-stage,
multi-platform method**. The graph algorithm is one thing; the platform it runs on
is a swappable **provider**.

> in-degree (followers/citations) = fame  ·  cross-source = peer recognition in the niche

Method adapted from SimmerChan, *用 Agent 自动扒了一遍知乎推荐系统领域的大V*
([zhuanlan.zhihu.com/p/2052179994911171124](https://zhuanlan.zhihu.com/p/2052179994911171124)).

## The method (see [`SKILL.md`](SKILL.md))

1. **Define the field** — and its disqualifier (the domain-filter yardstick).
2. **Route to a platform** — where does this field leave a public endorsement
   graph? → picks the provider. See [`PLATFORMS.md`](PLATFORMS.md).
3. **Seed the top ~50** — `seed_bootstrap.sh` (GitHub topic / OpenAlex field), or a
   platform 榜单 via the web-access skill.
4. **Expand + rank** — `field_graph.sh`: forward BFS + cross-source ranking, then
   the manual domain filter.
5. **Cross-verify by persona** — `cross_verify.sh` + [`SOURCES.md`](SOURCES.md).

## Quick start

```bash
# GitHub (code fields) — bootstrap seeds, then rank
scripts/seed_bootstrap.sh --provider github --topic osint --n 40 --contributors > seeds.txt
scripts/field_graph.sh @seeds.txt --rounds 3 --promote 12 --top 40 --enrich

# OpenAlex (research fields)
scripts/seed_bootstrap.sh --provider openalex --field "natural language processing" --mailto you@x.com > seeds.txt
scripts/field_graph.sh @seeds.txt --provider openalex --mailto you@x.com --top 30 --enrich

# Any other platform: script one hop with cmd:, or harvest via web-access then --edges
scripts/field_graph.sh @seeds.txt --provider 'cmd:<command printing node {}\047s neighbors>'
scripts/field_graph.sh myfield --edges harvested_follows.tsv --top 40
```

## Providers

| provider | edge = | needs |
|---|---|---|
| `github` (default) | who a user **follows** | `gh` (authenticated) |
| `openalex` | a researcher's **co-authors** | `curl`, `jq` |
| `cmd:TPL` | stdout of `TPL` with `{}` = node | anything scriptable |
| `--edges FILE` | pre-collected `seed<TAB>neighbor` TSV | web-access harvest |

> **No Python, no runtime.** Pure shell — coreutils + the chosen provider's tool.

## How it differs from existing "find people" tools

Most tools rank by **fame/volume** (followers, engagement, contributions — 千瓜,
蝉妈妈, OSS Insight) or **match a profile to a keyword/description** (Juicebox /
PeopleGPT, Exa Websets, Clay). This ranks by **cross-source endorsement** to surface
the *peer-recognized* core — who is often **not** the most famous. The only
method-cousins are academic citation-graph tools (ResearchRabbit, Connected
Papers), and those only cover academia; this runs the same idea on **any** field.

## Scope

Maps publicly-active contributors from public profiles, public follow/citation
graphs, and signed work. **Not** a deanonymization tool: public accounts as seeds
(never a phone/private email), respects deliberate anonymity, attaches no private
attributes. Read [`SKILL.md`](SKILL.md#scope--red-lines) before using.

## License

MIT
