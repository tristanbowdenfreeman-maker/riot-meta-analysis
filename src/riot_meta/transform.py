"""Raw JSON in the local store -> fact tables in BigQuery.

Matches are parsed in Python (parse.py) and loaded in batches with load jobs. BigQuery can't load
several tables in one transaction, so each batch is first written to load_batch in the store. Once
every table has the batch, it is marked loaded and the load_batch row goes. A load_batch row still
there at the start of a run is a load that stopped part-way: its rows are taken back out of
BigQuery and the batch is loaded again.
"""

import time
from datetime import datetime, timezone

from riot_meta.parse import parse_match, parse_timeline
from riot_meta.store import decompress
from riot_meta.warehouse import MATCH_TABLES, TIMELINE_TABLES, Warehouse

MATCH_BATCH = 2000
TIMELINE_BATCH = 500


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def recover(conn, warehouse: Warehouse) -> int:
    """Take the rows of any half-loaded batch back out of BigQuery. Returns the batches undone."""
    batches = conn.execute("SELECT batch_id, kind FROM load_batch ORDER BY batch_id").fetchall()
    for batch_id, kind in batches:
        ids = [r[0] for r in conn.execute("SELECT match_id FROM load_batch_match WHERE batch_id = ?", (batch_id,))]
        warehouse.remove_matches(MATCH_TABLES if kind == "match" else TIMELINE_TABLES, ids)
        with conn:
            conn.execute("DELETE FROM load_batch WHERE batch_id = ?", (batch_id,))
        print(f"  undid a half-loaded batch of {len(ids)} {kind}es")
    return len(batches)


def _load_batch(conn, warehouse: Warehouse, kind: str, match_ids: list[str], rows: dict[str, list[dict]]) -> None:
    with conn:
        batch_id = conn.execute("INSERT INTO load_batch (kind) VALUES (?)", (kind,)).lastrowid
        conn.executemany("INSERT INTO load_batch_match (batch_id, match_id) VALUES (?, ?)",
                         [(batch_id, m) for m in match_ids])
    for table, table_rows in rows.items():
        warehouse.load(f"riot_fact.{table}", table_rows)
    return batch_id


def load_matches(conn, warehouse: Warehouse) -> int:
    """Parse and load every downloaded match not in BigQuery yet."""
    total = 0
    started = time.monotonic()
    while True:
        batch = conn.execute(
            """
            SELECT r.match_id, r.payload_gz, q.source_tier
            FROM match_raw AS r
            LEFT JOIN match_queue AS q ON q.match_id = r.match_id
            WHERE r.loaded_at IS NULL
            ORDER BY r.match_id
            LIMIT ?
            """,
            (MATCH_BATCH,),
        ).fetchall()
        if not batch:
            return total
        rows = {table: [] for table in MATCH_TABLES}
        for match_id, payload, tier in batch:
            for table, table_rows in parse_match(match_id, decompress(payload), tier).items():
                rows[table].extend(table_rows)
        match_ids = [b[0] for b in batch]
        batch_id = _load_batch(conn, warehouse, "match", match_ids, rows)
        loaded_at = _now()
        with conn:
            conn.executemany(
                "UPDATE match_raw SET patch = ?, queue_id = ?, duration_s = ?, loaded_at = ? WHERE match_id = ?",
                [(m["patch"], m["queue_id"], m["duration_s"], loaded_at, m["match_id"]) for m in rows["match"]],
            )
            conn.execute("DELETE FROM load_batch WHERE batch_id = ?", (batch_id,))
        total += len(batch)
        print(f"  {total:,} matches loaded ({time.monotonic() - started:.0f}s)")


def load_timelines(conn, warehouse: Warehouse) -> int:
    """Parse and load every downloaded timeline whose match is already loaded."""
    total = 0
    started = time.monotonic()
    while True:
        batch = conn.execute(
            """
            SELECT t.match_id, t.payload_gz, r.duration_s
            FROM timeline_raw AS t
            JOIN match_raw AS r ON r.match_id = t.match_id
            WHERE t.status = 'done' AND t.loaded_at IS NULL AND r.loaded_at IS NOT NULL
            ORDER BY t.match_id
            LIMIT ?
            """,
            (TIMELINE_BATCH,),
        ).fetchall()
        if not batch:
            return total
        loaded_at = _now()
        rows = {table: [] for table in TIMELINE_TABLES}
        for match_id, payload, duration_s in batch:
            for table, table_rows in parse_timeline(match_id, decompress(payload), duration_s, loaded_at).items():
                rows[table].extend(table_rows)
        match_ids = [b[0] for b in batch]
        batch_id = _load_batch(conn, warehouse, "timeline", match_ids, rows)
        with conn:
            conn.executemany("UPDATE timeline_raw SET loaded_at = ? WHERE match_id = ?",
                             [(loaded_at, m) for m in match_ids])
            conn.execute("DELETE FROM load_batch WHERE batch_id = ?", (batch_id,))
        total += len(batch)
        print(f"  {total:,} timelines loaded ({time.monotonic() - started:.0f}s)")


def transform(conn, warehouse: Warehouse) -> tuple[int, int]:
    recover(conn, warehouse)
    return load_matches(conn, warehouse), load_timelines(conn, warehouse)
