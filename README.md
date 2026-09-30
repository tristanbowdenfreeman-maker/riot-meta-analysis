# Riot Meta Analysis

Champion, item, rune and summoner spell stats for League of Legends, built from the Riot Games API.
Emerald+ ranked solo/duo on EUW, one patch at a time.

Python fetches matches and their timelines from the Riot Games API and stores the raw JSON in
SQL Server. T-SQL parses it into a star schema and reporting views, which are exported to JSON
for a static website: a tier list, a page per champion, and an Insights page with findings
(which objectives and gold leads win games, what separates winners from losers, whether the most
banned champions win more) and how the tier list deals with small samples.

**Live:** https://tristanbowdenfreeman-maker.github.io/tiny-summit/league/ (part of my
[portfolio](https://tristanbowdenfreeman-maker.github.io/tiny-summit/)).

```
Riot Games API ──► Python fetcher ──► stg (raw match + timeline JSON, fetch queue)
Data Dragon    ──►                     │  OPENJSON in stored procedures
                                       ▼
                                  dim + fact (star schema)
                                       │  views
                                       ▼
                                  mart ──► JSON ──► static site (GitHub Pages)
```

- Definitions and scope: [CONTEXT.md](CONTEXT.md)
- Design decisions: [docs/adr](docs/adr)

## Run it

Needs Docker Desktop and Python 3.12.

```bash
cp .env.example .env                  # add a Riot API key and a SQL Server sa password
docker compose up -d                  # SQL Server 2022
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt && pip install -e .
git config core.hooksPath .githooks   # blocks commits containing API keys

python -m riot_meta setup-db          # database, tables, procedures, views
python -m riot_meta ddragon           # champion/item/rune/spell names
python -m riot_meta discover          # Emerald+ players
python -m riot_meta queue --since 2026-09-24 --target 3000
python -m riot_meta fetch             # resumable; re-run after a stop or key expiry
python -m riot_meta fetch-timelines   # item purchase order; also resumable
python -m riot_meta transform         # raw JSON -> fact tables
python -m riot_meta check             # data-quality checks
python -m riot_meta export            # mart views -> site/data/*.json
python -m riot_meta status            # row counts at every stage
```

To keep growing the sample, `scripts/collect.sh` repeats queue, fetch, fetch-timelines,
transform, check and export in rounds of 1,000 matches until stopped, finding more players as
needed and waiting for a new key in `.env` when the old one expires:

```bash
nohup caffeinate -i scripts/collect.sh > collect.log 2>&1 &
```

`pytest` runs the unit tests.
