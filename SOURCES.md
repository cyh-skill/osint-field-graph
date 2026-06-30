# Persona-routed cross-verification

The core idea behind multi-source verification is **not** "check every site" —
it is "check the site that *authoritatively* covers this kind of person".
Route each subject to the source where their real identity is signed.

## Routing matrix

| Persona | Detect from (signals) | Authoritative sources | What confirms identity |
|---------|----------------------|----------------------|------------------------|
| **code** / engineer | many repos; bio has engineer/SWE/maintainer; company is a tech org | GitHub, npm, PyPI, crates.io | repo name + README self-intro, package `Author` field, commit email |
| **research** / academic | bio/company mentions university, lab, PhD, "researcher"; name resolves to a paper author | arXiv, Semantic Scholar, OpenAlex, DBLP, ORCID, Google Scholar | first-author papers, affiliation, ORCID ↔ name linkage |
| **influencer** / 种粉 / 内容创作 | bio says creator/博主/content; low repos; links to social with large following | 小红书, 微博, B站, 抖音/TikTok, X, YouTube | profile 认证 badge, bio cross-links, follower scale |
| **business** / 创始人 | bio says founder/CEO/CTO/investor; links to a company/LinkedIn | LinkedIn, Crunchbase, 天眼查/企查查, gsxt.gov.cn (官方) | 工商登记/任职, company team page, 官网署名 |
| **writer** / journalist | bio says writer/editor; links to Substack/Medium/blog/知乎 | personal blog, Substack, Medium, 知乎 | signed articles, RSS author, About page |

A person can span personas (a researcher who also ships code). Run the top 1–2
matched sources, not all.

## Which sources are API-reachable vs. need a browser

| Source | Access | Notes |
|--------|--------|-------|
| GitHub / npm / PyPI / crates.io | public API (`gh`, curl) | direct |
| arXiv | public API (`https://export.arxiv.org/api/query`) | author search |
| Semantic Scholar / OpenAlex / DBLP / ORCID | public API | may need an API key / be rate-limited on shared IPs |
| 小红书 / 微博 / B站 / 抖音 / X / LinkedIn | **browser + login** | use the `web-access` skill (CDP); static scraping is blocked |
| 天眼查 / 企查查 | browser; 官方 gsxt.gov.cn is free | business registry |

## The one rule that does not change

Cross-verify only on **self-published, signed** identity:

- a link the person put on their own profile (GitHub `twitter_username`, a blog
  URL, an ORCID on their site) is fair game;
- a paper/package/repo they signed with their real name is fair game;
- a person who is **deliberately anonymous** (blank profile, pseudonym, no
  signed work) → stop. Don't pivot from a private identifier to them.

Routing by persona makes verification *sharper*, not *deeper into private life*.
