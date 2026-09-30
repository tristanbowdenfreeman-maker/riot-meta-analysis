# 6. Static website instead of Streamlit

**Status:** accepted, 2026-09-30. Supersedes [0003](0003-parquet-export-for-hosted-dashboard.md).

## Context

The dashboard should read like op.gg (a tier list with role tabs, champion pages with rune grids
and build tables) and feel like a simple, animated portfolio site: one idea per screen, large
type, smooth transitions. Streamlit re-runs the whole script on every click and lays pages out
as stacked blocks, so it can't do either well.

## Decision

The frontend is a static site in `site/`: HTML, CSS and a little JavaScript, hosted free on
GitHub Pages. `python -m riot_meta export` writes every `mart` view, plus name/icon lookups
from the `dim` tables, to `site/data/*.json`, which is committed. Champion, item and rune images
load from Riot's Data Dragon CDN.

SQL Server still does all the modelling. The site only filters and displays the exported rows.

## Consequences

- Full control over layout and animation; no server, no credentials online.
- JavaScript instead of Python for the presentation layer.
- Like before, the site shows the data as of the last export: refreshing means re-running the
  pipeline locally and pushing the new JSON.
- The JSON holds aggregated stats only, no player IDs.
