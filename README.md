# Player Behaviour Analysis

I built this while I was playing League of Legends, to test my data and software skills and to
make better decisions in my own games. It looks at what winning teams and players do differently,
using ranked games (Emerald+ solo/duo on EUW) from the Riot Games API, one patch at a time.

I've been working on it for about a year. This repository is the latest rebuild, with Python
collecting the games, SQL Server modelling them and a static website showing the results.

**Live:** https://tristanbowdenfreeman-maker.github.io/tiny-summit/league/ (part of my
[portfolio](https://tristanbowdenfreeman-maker.github.io/tiny-summit/))

## What it finds

From about 41,600 games on one patch:

- The team that took first tower won 68% of games. Rift Herald was next at 66%, then first
  dragon at 62% and first void grubs at 55%.
- Small gold leads don't count for much. Teams less than 1k gold ahead at 15 minutes won 54%,
  and teams 2–3k ahead won 71%.
- Across the five roles, winners died 31–41% less than the losing player in the same role, but
  farmed only 5–15% more.
- The most banned champions don't win more often. Champions banned in 10%+ of games won 50.4%,
  and those banned in under 3% won 49.7%.
- Kayle won 41% of games that ended within 25 minutes and 64% of games that went past 33.
- Ivern had the highest raw win rate (56.6%) but from only 789 games. Once small samples are
  adjusted for, Braum ranks first at 54.0% over 2,946 games.

These show what winning teams have in common. They don't prove what causes the win, because the
better team tends to get the objectives, kills and gold as well. The site's figures update as
more games come in, so they may have moved on from these.

## How the data flows

```
Riot Games API ─► Python ─► stg   raw JSON, as downloaded
                             │    stored procedures (OPENJSON)
                             ▼
                            dim + fact   star schema
                             │    views
                             ▼
                            mart ─► JSON files ─► website
```

1. **Python downloads** ranked players, their match IDs, each match and its timeline, and saves
   the raw JSON into `stg` tables. It doesn't transform anything.
2. **T-SQL stored procedures** parse the JSON into `dim` and `fact` tables.
3. **T-SQL views** in `mart` calculate the stats: win rates by objective, gold lead, ban rate
   and game length, plus builds and the tier list.
4. **Python exports** each `mart` view to a JSON file, which the website reads.

## Where to look

**SQL** (`sql/`, run in folder and file order)

| Folder | What's in it |
|---|---|
| [0_setup](sql/0_setup) | The database and its schemas |
| [1_staging](sql/1_staging) | Tables for the raw JSON and the download queue |
| [2_model](sql/2_model) | The star schema: `dim_` and `fact_` tables |
| [3_etl](sql/3_etl) | Stored procedures that load the tables from the raw JSON |
| [4_marts](sql/4_marts) | One view per stat on the site; [22_v_tier_list.sql](sql/4_marts/22_v_tier_list.sql) is the main one |
| [5_checks](sql/5_checks) | Data-quality checks, one row per check |

**Python** (`src/riot_meta/`)

| File | What it does |
|---|---|
| [\_\_main\_\_.py](src/riot_meta/__main__.py) | The commands below |
| [client.py](src/riot_meta/client.py) | Calls the Riot API within its rate limits |
| [pipeline.py](src/riot_meta/pipeline.py) | Finds players, queues matches, downloads them |
| [ddragon.py](src/riot_meta/ddragon.py) | Downloads champion, item and rune names |
| [db.py](src/riot_meta/db.py) | Connects to SQL Server and runs the `sql/` scripts |
| [export.py](src/riot_meta/export.py) | Writes the `mart` views to `site/data/*.json` |

**Other:** [site/](site) is the website (HTML, CSS, JavaScript), [tests/](tests) are the pytest
tests, and [docs/how-it-works.md](docs/how-it-works.md) has the definitions and method.

## Run it

Needs Docker Desktop and Python 3.12.

```bash
cp .env.example .env                  # add a Riot API key and a SQL Server password
docker compose up -d                  # SQL Server 2022
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt && pip install -e .

python -m riot_meta setup-db          # create the database, tables, procedures and views
python -m riot_meta patch             # names from Data Dragon, and the patch to collect
python -m riot_meta discover          # find Emerald+ players
python -m riot_meta queue --more 1000 # games of that patch, up to MATCHES_PER_PATCH in all
python -m riot_meta fetch             # download matches (safe to stop and re-run)
python -m riot_meta fetch-timelines   # download timelines (safe to stop and re-run)
python -m riot_meta transform         # run the load procedures
python -m riot_meta check             # data-quality checks
python -m riot_meta export            # mart views -> site/data/*.json
python -m riot_meta status            # row counts at every stage
```

`scripts/collect.sh` repeats patch → queue → fetch → transform → check → export in rounds of
1,000 matches and publishes the site when the checks pass. When a new patch comes out it collects
that in the background, then switches the site over and deletes the old patch once the new one
has 30,000 matches (`MATCHES_TO_GO_LIVE` in `.env`). It carries on collecting up to
`MATCHES_PER_PATCH`. Setting `HOLD_PATCH` (e.g. `16.19`) keeps it on one patch after the next is
released, taking only games played before the next patch started.

`pytest` runs the tests.
