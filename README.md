# gh-field-graph

A Claude Code / agent **skill** that maps the core people of a technical field
on GitHub.

Give it a few seed accounts in a field; it expands their **forward-following
network** and ranks everyone by **cross-source count** — how many *independent*
seeds follow each person. The result surfaces a field's real center, which is
usually **not** the highest-follower account.

> in-degree (followers) = fame &nbsp;·&nbsp; cross-source = peer recognition inside the niche

## Quick start

```bash
gh auth status   # GitHub CLI must be authenticated

python3 scripts/field_graph.py "soxoj,megadose,cipher387,WebBreacher" --top 20 --enrich
```

Multi-round BFS from a seed file:

```bash
python3 scripts/field_graph.py @seeds.txt --rounds 3 --promote 12 --top 40 --csv out.csv
```

| flag | meaning | default |
|------|---------|---------|
| `--cap` | max `following` fetched per seed | 100 |
| `--rounds` | BFS rounds (each extra round auto-promotes top emerged nodes) | 1 |
| `--promote` | new seeds added per extra round | 10 |
| `--top` | rows printed | 30 |
| `--enrich` | fetch followers/name/bio for printed rows | off |
| `--workers` | parallel `gh` calls | 8 |
| `--csv` | dump full ranking to CSV | — |

## How it works

1. **Seeds** → 2. **Forward BFS** over `following` → 3. **Cross-source ranking**
→ 4. **Domain filter** (manual; raw ranking drifts toward field-adjacent
celebrities as it scales) → 5. **Enrich & report**.

See [`SKILL.md`](SKILL.md) for the full method and the **Scope & Red Lines**.

## Scope

Maps **publicly-active contributors** from public profiles, public follow
graphs, and signed open-source work. It is **not** a people-deanonymization
tool: it takes public accounts as seeds (never a phone number / private email),
respects deliberate anonymity, and does not attach private attributes to people.
Read [`SKILL.md`](SKILL.md#scope--red-lines) before using.

## License

MIT
