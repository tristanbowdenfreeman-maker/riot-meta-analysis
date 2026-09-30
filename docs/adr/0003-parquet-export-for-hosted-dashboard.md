# 3. Export marts to Parquet for a hosted Streamlit dashboard

**Status:** superseded by [0006](0006-static-site-instead-of-streamlit.md), 2026-09-30

## Context

Interviewers should be able to open a live link. Streamlit Community Cloud hosts apps for free but
cannot reach a SQL Server running on a laptop. A cloud database (e.g. Azure SQL) would work but
adds accounts, credentials and cost.

## Decision

SQL Server stays local and does all the modelling. `python -m riot_meta export` writes each
`mart` view to `data/marts/*.parquet`, which is committed to the repo. The hosted Streamlit app
reads only those files.

## Consequences

- A live link with no database credentials anywhere online.
- The dashboard shows the data as of the last export; refreshing means re-running the pipeline
  locally and pushing the new Parquet files.
- The Parquet files hold aggregated stats only, no player IDs.
