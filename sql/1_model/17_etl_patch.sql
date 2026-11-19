-- A copy of the local store's patch table (see store.py), replaced whenever it changes. The marts
-- only count the live patch: a new patch being collected stays out of them until it goes live.
CREATE TABLE IF NOT EXISTS riot_etl.patch (
    patch           STRING   NOT NULL,  -- e.g. '16.19'
    status          STRING   NOT NULL,  -- collecting | live | retired
    started_utc     DATETIME NOT NULL,
    live_since_utc  DATETIME
);
