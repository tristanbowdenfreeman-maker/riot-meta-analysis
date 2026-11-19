-- One dataset per layer (BigQuery's datasets play the part of SQL Server's schemas):
--   riot_dim  : lookup tables (champions, items, runes, summoner spells) from Data Dragon
--   riot_fact : match data parsed out of the raw JSON (the raw JSON itself stays local)
--   riot_mart : the stats the website shows, rebuilt as tables before each export
--   riot_etl  : the patch being shown, copied from the local store
-- In the free sandbox every table expires 60 days after it was last created or refreshed;
-- `python -m riot_meta build` refreshes them.
CREATE SCHEMA IF NOT EXISTS riot_dim  OPTIONS (location = '{location}');
CREATE SCHEMA IF NOT EXISTS riot_fact OPTIONS (location = '{location}');
CREATE SCHEMA IF NOT EXISTS riot_mart OPTIONS (location = '{location}');
CREATE SCHEMA IF NOT EXISTS riot_etl  OPTIONS (location = '{location}');
