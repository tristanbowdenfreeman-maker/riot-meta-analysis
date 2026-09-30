# 2. Land raw JSON, transform in T-SQL

**Status:** accepted, 2026-09-30

## Context

Match data could be flattened in Python (pandas) before loading, or stored as returned and
transformed inside SQL Server.

## Decision

Python only fetches and stores. Each match's JSON goes into `stg.match_raw` untouched; T-SQL
(`OPENJSON` in `etl.usp_load_matches`) parses it into the `fact` tables. The JSON is stored
GZIP-compressed as UTF-16, the format T-SQL's `DECOMPRESS` expects, and read through
`stg.v_match_raw`.

## Consequences

- The raw data is kept, so the model can be changed and rebuilt (`etl.usp_reset_facts`, then
  `transform`) without calling the API again.
- The loading is incremental: only matches not yet in `fact.match` are parsed, in batches that
  commit separately.
- Compression keeps 30,000 matches at a few hundred MB instead of several GB.
- More of the project's logic is in SQL, which is the skill being demonstrated.
