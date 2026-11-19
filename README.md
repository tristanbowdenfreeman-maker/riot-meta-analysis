# Player Behaviour Analysis

I built this while I was playing League of Legends, to test my data and software skills and to
make better decisions in my own games. It looks at what winning teams and players do differently,
using ranked games (Emerald+ solo/duo on EUW) from the Riot Games API, one patch at a time.

I've been working on it for about a year. This repository is the latest rebuild, with Python
collecting the games, BigQuery modelling them and a static website showing the results.

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
Riot Games API ─► Python ─► local store (SQLite)   raw JSON, as downloaded
                             │    parsed in Python, load jobs
                             ▼
                            riot_dim + riot_fact   star schema in BigQuery
                             │    SQL, rebuilt daily
                             ▼
                            riot_mart ─► JSON files ─► website
```

1. **Python downloads** ranked players, their match IDs, each match and its timeline, and saves
   the raw JSON (gzipped) in a local SQLite store, along with the download queue.
2. **Python parses** the JSON into rows and loads them into the BigQuery `riot_dim` and
   `riot_fact` tables with load jobs.
3. **BigQuery SQL** in `riot_mart` calculates the stats: win rates by objective, gold lead, ban
   rate and game length, plus builds and the tier list.
4. **Python exports** each mart table to a JSON file, which the website reads.

It runs on the free BigQuery sandbox. That allows no `INSERT`/`UPDATE`/`DELETE`, so rows go in
with load jobs and come out by rebuilding a table without them, and every query has a cap on the
bytes it may scan.

## Where to look

**SQL** (`sql/`, run in folder and file order)

| Folder | What's in it |
|---|---|
| [0_setup](sql/0_setup) | The BigQuery datasets |
| [1_model](sql/1_model) | The star schema: `dim_` and `fact_` tables, and `etl.patch` |
| [2_marts](sql/2_marts) | One table per stat on the site; [22_tier_list.sql](sql/2_marts/22_tier_list.sql) is the main one |
| [3_checks](sql/3_checks) | Data-quality checks, one row per check |

**Python** (`src/riot_meta/`)

| File | What it does |
|---|---|
| [\_\_main\_\_.py](src/riot_meta/__main__.py) | The commands below |
| [client.py](src/riot_meta/client.py) | Calls the Riot API within its rate limits |
| [pipeline.py](src/riot_meta/pipeline.py) | Finds players, queues matches, downloads them |
| [store.py](src/riot_meta/store.py) | The local SQLite store: raw JSON, queue and patches |
| [parse.py](src/riot_meta/parse.py) | Turns the raw JSON into fact and dim rows |
| [transform.py](src/riot_meta/transform.py) | Loads new matches and timelines into BigQuery |
| [patches.py](src/riot_meta/patches.py) | Which patch is live and which is collecting |
| [warehouse.py](src/riot_meta/warehouse.py) | Connects to BigQuery and runs the `sql/` scripts |
| [ddragon.py](src/riot_meta/ddragon.py) | Downloads champion, item and rune names |
| [export.py](src/riot_meta/export.py) | Writes the mart tables to `site/data/*.json` |

**Other:** [site/](site) is the website (HTML, CSS, JavaScript), [tests/](tests) are the pytest
tests, and [docs/how-it-works.md](docs/how-it-works.md) has the definitions and method.

## Run it

Needs Python 3.12, the gcloud CLI and a Google Cloud project (the free sandbox is enough).

```bash
cp .env.example .env                  # add a Riot API key and BQ_PROJECT
gcloud auth application-default login # lets Python use BigQuery as you
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt && pip install -e .

python -m riot_meta setup             # create the local store and the BigQuery tables
python -m riot_meta patch             # names from Data Dragon, and the patch to collect
python -m riot_meta discover          # find Emerald+ players
python -m riot_meta queue --more 1000 # games of that patch, up to MATCHES_PER_PATCH in all
python -m riot_meta fetch             # download matches (safe to stop and re-run)
python -m riot_meta fetch-timelines   # download timelines (safe to stop and re-run)
python -m riot_meta transform         # parse new JSON and load it into BigQuery
python -m riot_meta build             # rebuild the mart tables
python -m riot_meta check             # data-quality checks
python -m riot_meta export            # mart tables -> site/data/*.json
python -m riot_meta status            # row counts at every stage
```

`scripts/collect.sh` repeats patch → queue → fetch → transform in rounds of 1,000 matches, and
once a day runs build → check → export and publishes the site when the checks pass. A daily build
scans a few GB, well inside BigQuery's free 1 TB a month. When a new patch comes out it collects
that in the background, then switches the site over and deletes the old patch once the new one
has 30,000 matches (`MATCHES_TO_GO_LIVE` in `.env`). It carries on collecting up to
`MATCHES_PER_PATCH`. Setting `HOLD_PATCH` (e.g. `16.19`) keeps it on one patch after the next is
released, taking only games played before the next patch started.

`pytest` runs the tests.
