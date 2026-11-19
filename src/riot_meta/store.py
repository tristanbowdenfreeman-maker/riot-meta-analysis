"""The local store: a SQLite file (data/riot.sqlite) holding everything that changes one row at a
time, which BigQuery is poor at: the players, the download queue, the raw JSON and the patch
being collected.

The raw match and timeline JSON stays here, GZIP-compressed, and never goes to BigQuery. Only the
parsed fact rows do (see transform.py), which keeps BigQuery well inside its 10 GB free storage.
Because the raw JSON is kept, every BigQuery table can be rebuilt from this file.
"""

import gzip
import sqlite3
from pathlib import Path

SCHEMA = """
-- Ranked players found through the league-exp-v4 endpoint.
CREATE TABLE IF NOT EXISTS player (
    puuid                 TEXT    PRIMARY KEY,
    tier                  TEXT    NOT NULL,
    division              TEXT    NOT NULL,
    league_points         INTEGER NOT NULL,
    wins                  INTEGER NOT NULL,
    losses                INTEGER NOT NULL,
    discovered_at         TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    match_ids_fetched_at  TEXT
);

-- Match IDs to download. A stopped run picks up the remaining 'pending' rows next time.
CREATE TABLE IF NOT EXISTS match_queue (
    match_id      TEXT    PRIMARY KEY,
    source_puuid  TEXT    NOT NULL,
    source_tier   TEXT    NOT NULL,
    status        TEXT    NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'done', 'skipped', 'failed')),
    attempts      INTEGER NOT NULL DEFAULT 0,
    queued_at     TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    TEXT
);
CREATE INDEX IF NOT EXISTS ix_match_queue_status ON match_queue (status, queued_at);

-- Raw match-v5 JSON, GZIP-compressed UTF-8. patch, queue_id and duration_s are filled in when the
-- match is parsed, so the collector can count a patch's matches without BigQuery. loaded_at is
-- set once its fact rows are in BigQuery.
CREATE TABLE IF NOT EXISTS match_raw (
    match_id    TEXT    PRIMARY KEY,
    payload_gz  BLOB    NOT NULL,
    fetched_at  TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    patch       TEXT,
    queue_id    INTEGER,
    duration_s  INTEGER,
    loaded_at   TEXT
);
CREATE INDEX IF NOT EXISTS ix_match_raw_patch ON match_raw (patch);

-- Raw match-v5 timelines, stored the same way. Also the timeline download queue: a match in
-- match_raw with no row here, or a 'pending' row, still needs its timeline.
CREATE TABLE IF NOT EXISTS timeline_raw (
    match_id    TEXT    PRIMARY KEY,
    status      TEXT    NOT NULL CHECK (status IN ('pending', 'done', 'skipped', 'failed')),
    attempts    INTEGER NOT NULL DEFAULT 0,
    payload_gz  BLOB,
    fetched_at  TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TEXT,
    loaded_at   TEXT,
    CHECK ((status = 'done') = (payload_gz IS NOT NULL))
);

-- The patches being collected, at most one of each status:
--   live       : the patch the website shows
--   collecting : a newer patch, filling up in the background until it has a full sample
--   retired    : replaced; its data is being deleted
-- A copy goes to BigQuery (etl.patch) so the marts know which patch is live.
CREATE TABLE IF NOT EXISTS patch (
    patch           TEXT PRIMARY KEY,
    status          TEXT NOT NULL CHECK (status IN ('collecting', 'live', 'retired')),
    started_utc     TEXT NOT NULL,
    live_since_utc  TEXT
);

-- A batch of matches or timelines being loaded into BigQuery. BigQuery can't load several tables
-- in one transaction, so a batch is written here first and removed once every table has it. A row
-- still here at the next transform means a load stopped part-way, and its rows are taken back out.
CREATE TABLE IF NOT EXISTS load_batch (
    batch_id    INTEGER PRIMARY KEY,
    kind        TEXT    NOT NULL CHECK (kind IN ('match', 'timeline')),
    started_at  TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS load_batch_match (
    batch_id  INTEGER NOT NULL REFERENCES load_batch (batch_id) ON DELETE CASCADE,
    match_id  TEXT    NOT NULL,
    PRIMARY KEY (batch_id, match_id)
);
"""


def connect(path: Path) -> sqlite3.Connection:
    """Open the store, creating it and its tables on first use. Writes commit at the end of a
    `with conn:` block, together or not at all."""
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=60)
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    return conn


def compress(text: str) -> bytes:
    return gzip.compress(text.encode("utf-8"), compresslevel=6)


def decompress(payload: bytes) -> str:
    return gzip.decompress(payload).decode("utf-8")
