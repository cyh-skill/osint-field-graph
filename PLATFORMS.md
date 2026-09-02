# Field → platform routing (Stage 2 + 3)

The graph method is universal; **where you run it is not**. Before seeding, route
the field to the platform where its people actually leave a public *endorsement*
graph (who-follows/cites/co-authors-whom). Pick the wrong platform and you map the
wrong crowd. This is the field-level analog of `SOURCES.md`'s person-level routing.

## Routing matrix

| Field looks like… | Platform (endorsement graph) | provider | How to get the top ~50 seeds (Stage 3) |
|---|---|---|---|
| open-source / dev tooling / infra / a language ecosystem | **GitHub** follows | `github` | `seed_bootstrap.sh --provider github --topic <t> --contributors`; or owners+contributors of the field's top repos / awesome-list |
| academic / research / "who leads <subfield>" | **OpenAlex** co-authorship (or citations) | `openalex` | `seed_bootstrap.sh --provider openalex --field "<name>"` (most-cited authors) |
| Chinese tech / 算法 / 内容型技术大V | **知乎** follows (+ GitHub/PyPI to verify) | `cmd:` or `--edges` | cyh-browser-skill: a 垂类榜单 / your own 关注 + doc authors as seeds |
| ML/AI research-that-lives-on-X, crypto, indie hackers | **X / Twitter** follows | `--edges` | cyh-browser-skill: a curated List, or top accounts of the niche |
| 种草 / 美妆 / 时尚 / 生活方式 creator | **小红书 / 微博 / 抖音 / B站** follows | `--edges` | cyh-browser-skill + 千瓜/蝉妈妈/新榜 垂类榜单 as seeds |
| founders / VC / operators / a business vertical | **LinkedIn / X** | `--edges` | cyh-browser-skill: Crunchbase list, a "top N founders" list, portfolio pages |
| writers / journalists / newsletter | **Substack** recommendations / X / 知乎 | `cmd:`/`--edges` | cyh-browser-skill: Substack leaderboard, masthead, a topic's top writers |

A field can span platforms (an ML researcher lives on both OpenAlex *and* X). Run
the 1–2 platforms where the endorsement signal is densest; you can even merge two
runs' CSVs and re-rank.

## The one distinction that decides the provider

**Does the platform expose the follow/endorsement graph over an open API?**

- **Yes → run it directly.** Only GitHub (`gh`) and OpenAlex (`curl`) do, cleanly.
  Those are the two built-in providers.
- **Scriptable but not built-in → `cmd:`.** If you can write one command that, given
  a node, prints who it endorses (e.g. an authenticated API you have a token for),
  drop it in as `--provider 'cmd:<cmd with unquoted {}>'` — no engine change.
- **No → harvest with cyh-browser-skill, then `--edges`.** X, 小红书, 微博, B站,
  LinkedIn, 知乎 all block static scraping and need a logged-in browser. Use the
  **cyh-browser-skill** to walk each seed's follow list into a `seed<TAB>neighbor`
  TSV, then rank it: `field_graph.sh <field> --edges harvested.tsv`.

## Harvesting an API-less graph (the `--edges` path)

For platforms in the "No" row, the collection is browser work, the ranking is this
tool. Pattern:

1. Get the field's top ~50 seeds — a platform 榜单 (千瓜/蝉妈妈/新榜/Substack
   leaderboard), a curated X List, or a hand-picked expert set. Save `seeds.txt`.
2. With **cyh-browser-skill**, for each seed open its *following* page and
   collect the accounts it follows. Append `seed<TAB>followee` lines to a TSV.
   (Forward following only — reverse followers are 3-10% signal; skip them.)
3. Rank: `field_graph.sh <field> --edges collected.tsv --top 40`.
4. Cross-verify the head with `cross_verify.sh` / `SOURCES.md` routing.

Keep the same red lines as `SKILL.md`: self-published follow graphs and signed
work only; stop at deliberate anonymity; never pivot from a private identifier.

## Notes per platform

- **GitHub** — cleanest case. Following is a deliberate, public choice. Orgs have
  empty following (harmless as seeds). Use topics + awesome-lists to seed.
- **OpenAlex** — free, no key (add `--mailto` for the faster pool). Built-in edge
  is **co-authorship** (collaboration hubs); it skews toward big-lab PIs — apply
  the domain filter, or swap to a citation-based `cmd:` for a directed signal.
- **知乎** — the source article's platform. `/api/v4/members/{id}` (with login)
  returns structured employments/education/badge; follows drive the graph. Needs
  cyh-browser-skill. Verify real names via GitHub/PyPI/arXiv (`SOURCES.md`).
- **X / 小红书 / 微博 / B站 / LinkedIn** — logged-in browser only; `--edges` path.
  Chinese KOL 榜单 tools (千瓜/蝉妈妈/新榜) are good *seed* sources but rank by
  reach, not by cross-source — use them to seed, then let this tool find the core.
