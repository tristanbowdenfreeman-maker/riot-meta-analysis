# League of Legends Statistics

Champion, item, rune and summoner spell stats for League of Legends, built from the Riot Games
API. Emerald+ ranked solo/duo on EUW, one patch at a time.

**Live:** https://tristanbowdenfreeman-maker.github.io/tiny-summit/league/ (part of my
[portfolio](https://tristanbowdenfreeman-maker.github.io/tiny-summit/))

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
3. **T-SQL views** in `mart` calculate the stats: win rates, pick rates, builds, the tier list.
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
python -m riot_meta queue --more 1000 # games of that patch, up to 30,000 in all
python -m riot_meta fetch             # download matches (safe to stop and re-run)
python -m riot_meta fetch-timelines   # download timelines (safe to stop and re-run)
python -m riot_meta transform         # run the load procedures
python -m riot_meta check             # data-quality checks
python -m riot_meta export            # mart views -> site/data/*.json
python -m riot_meta status            # row counts at every stage
```

`scripts/collect.sh` repeats patch → queue → fetch → transform → check → export in rounds of
1,000 matches and publishes the site when the checks pass. It stops at 30,000 matches per patch
(`MATCHES_PER_PATCH` in `.env`), and when a new patch comes out it collects that in the background,
switching the site over and deleting the old patch once the new one has 30,000.
`pytest` runs the tests.
