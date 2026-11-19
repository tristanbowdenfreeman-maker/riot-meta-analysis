"""One-off: copy the old SQL Server database (the T-SQL version of this project) into the local
store. The raw JSON was stored as GZIP of UTF-16 there; here it is GZIP of UTF-8. Nothing goes to
BigQuery: run `transform` afterwards to load it, as for newly downloaded matches.

Needs pymssql and the MSSQL_* settings the old version used in .env.
"""

import gzip
import os
from concurrent.futures import ProcessPoolExecutor

from riot_meta.store import compress

BATCH = 500


def _utf8(payload: bytes | None) -> bytes | None:
    return None if payload is None else compress(gzip.decompress(payload).decode("utf-16-le"))


def _text(value) -> str | None:
    return None if value is None else value.strftime("%Y-%m-%d %H:%M:%S")


def _copy(source, conn, select: str, insert: str, convert, label: str, pool=None) -> None:
    cursor = source.cursor()
    cursor.execute(select)
    copied = 0
    while rows := cursor.fetchmany(BATCH):
        rows = list(pool.map(convert, rows)) if pool else [convert(r) for r in rows]
        with conn:
            conn.executemany(insert, rows)
        copied += len(rows)
        if copied % 5000 < BATCH:
            print(f"  {label}: {copied:,}")
    print(f"  {label}: {copied:,} copied")


def _raw_row(row):
    match_id, payload, *rest = row
    return (match_id, _utf8(payload), *rest)


def migrate(conn) -> None:
    import pymssql

    source = pymssql.connect(
        server=os.getenv("MSSQL_HOST", "localhost"),
        port=int(os.getenv("MSSQL_PORT", "1433")),
        user=os.getenv("MSSQL_USER", "sa"),
        password=os.getenv("MSSQL_SA_PASSWORD", ""),
        database=os.getenv("MSSQL_DATABASE", "RiotMeta"),
    )
    if conn.execute("SELECT COUNT(*) FROM match_raw").fetchone()[0]:
        raise SystemExit("The local store already holds matches: migrate into an empty store")

    _copy(source, conn,
          "SELECT puuid, tier, division, league_points, wins, losses, discovered_at, match_ids_fetched_at FROM stg.player",
          "INSERT INTO player VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          lambda r: (*r[:6], _text(r[6]), _text(r[7])), "players")
    _copy(source, conn,
          "SELECT match_id, source_puuid, source_tier, status, attempts, queued_at, updated_at FROM stg.match_queue",
          "INSERT INTO match_queue VALUES (?, ?, ?, ?, ?, ?, ?)",
          lambda r: (*r[:5], _text(r[5]), _text(r[6])), "queue rows")
    _copy(source, conn,
          "SELECT patch, status, started_utc, live_since_utc FROM etl.patch",
          "INSERT INTO patch VALUES (?, ?, ?, ?)",
          lambda r: (r[0], r[1], _text(r[2]), _text(r[3])), "patches")
    # Recompressing ~5 GB of JSON is the slow part, so it's spread over every core.
    with ProcessPoolExecutor() as pool:
        _copy(source, conn,
              "SELECT match_id, payload_gz, CONVERT(VARCHAR(19), fetched_at, 120) FROM stg.match_raw",
              "INSERT INTO match_raw (match_id, payload_gz, fetched_at) VALUES (?, ?, ?)",
              _raw_row, "raw matches", pool)
        _copy(source, conn,
              "SELECT match_id, payload_gz, status, attempts, CONVERT(VARCHAR(19), fetched_at, 120), "
              "CONVERT(VARCHAR(19), updated_at, 120) FROM stg.timeline_raw",
              "INSERT INTO timeline_raw (match_id, payload_gz, status, attempts, fetched_at, updated_at) "
              "VALUES (?, ?, ?, ?, ?, ?)",
              _raw_row, "raw timelines", pool)
    source.close()
