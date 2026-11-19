"""Which patch is collected and which one the site shows. Kept in the local store's patch table and
copied to BigQuery (riot_etl.patch) whenever it changes, so the marts know the live patch.

  live       : the patch the website shows
  collecting : a newer patch, filling up in the background until it has a full sample
  retired    : replaced; its matches are deleted, then the row goes

The website keeps showing the live patch until the new one has a full sample, so it never shows a
patch on a handful of games.
"""

from riot_meta.warehouse import Warehouse

REMAKE_SECONDS = 300


def progress(conn, platform: str) -> list[tuple[str, str, str, int]]:
    """(patch, status, started_utc, valid matches loaded so far) for every patch, oldest first.
    A valid match is ranked solo/duo (queue 420), not a remake and on our platform; the collector
    stops queueing a patch once it has MATCHES_PER_PATCH of them."""
    prefix = f"{platform.upper()}_"
    return conn.execute(
        """
        SELECT p.patch, p.status, p.started_utc,
               (SELECT COUNT(*) FROM match_raw AS r
                WHERE r.patch = p.patch AND r.loaded_at IS NOT NULL AND r.queue_id = 420
                  AND r.duration_s >= ? AND substr(r.match_id, 1, ?) = ?)
        FROM patch AS p
        ORDER BY p.started_utc
        """,
        (REMAKE_SECONDS, len(prefix), prefix),
    ).fetchall()


def sync(conn, warehouse: Warehouse) -> None:
    """Replace riot_etl.patch with the local patch table."""
    rows = conn.execute("SELECT patch, status, started_utc, live_since_utc FROM patch").fetchall()
    warehouse.load("riot_etl.patch", [
        {"patch": p, "status": s, "started_utc": started, "live_since_utc": live} for p, s, started, live in rows
    ], replace=True)


def delete_retired(conn, warehouse: Warehouse) -> int:
    """Delete every match of a retired patch: from BigQuery first, then the raw JSON and queue rows
    here, then the patch row. A stopped run leaves the patch retired, so the next run finishes it."""
    retired = [row[0] for row in conn.execute("SELECT patch FROM patch WHERE status = 'retired'")]
    if not retired:
        return 0
    deleted = warehouse.remove_patches(retired)
    marks = ", ".join("?" * len(retired))
    in_retired = f"SELECT match_id FROM match_raw WHERE patch IN ({marks})"
    with conn:
        conn.execute(f"DELETE FROM timeline_raw WHERE match_id IN ({in_retired})", retired)
        conn.execute(f"DELETE FROM match_queue WHERE match_id IN ({in_retired})", retired)
        conn.execute(f"DELETE FROM match_raw WHERE patch IN ({marks})", retired)
        conn.execute(f"DELETE FROM patch WHERE patch IN ({marks})", retired)
    sync(conn, warehouse)
    return deleted


def start(conn, warehouse: Warehouse, patch: str) -> int:
    """Start collecting a new patch (when Data Dragon lists one that isn't in the patch table).
      * The live patch stays live (and on the website) until the new one has a full sample.
      * A patch still collecting is retired and deleted: it never reached a full sample.
      * Downloads still pending are cancelled, as they are games from the old patch.
      * Every player is marked unvisited, so their games on the new patch get queued.
    With no live patch yet (a new store), the new patch goes live straight away.
    Returns the number of matches deleted."""
    if conn.execute("SELECT 1 FROM patch WHERE patch = ?", (patch,)).fetchone():
        return 0
    has_live = conn.execute("SELECT 1 FROM patch WHERE status = 'live'").fetchone() is not None
    with conn:
        conn.execute("UPDATE patch SET status = 'retired' WHERE status = 'collecting'")
        conn.execute("DELETE FROM match_queue WHERE status = 'pending'")
        conn.execute("UPDATE player SET match_ids_fetched_at = NULL")
        conn.execute(
            "INSERT INTO patch (patch, status, started_utc, live_since_utc) "
            "VALUES (?, ?, CURRENT_TIMESTAMP, CASE WHEN ? THEN NULL ELSE CURRENT_TIMESTAMP END)",
            (patch, "collecting" if has_live else "live", has_live),
        )
    sync(conn, warehouse)
    return delete_retired(conn, warehouse)


def promote(conn, warehouse: Warehouse, platform: str, match_cap: int) -> tuple[str | None, int]:
    """Put the collecting patch live once it has `match_cap` valid matches, then delete the old
    patch's data. Safe to run every round: it does nothing until the new patch is full, and it
    finishes any deletion a stopped run left. Returns (patch promoted or None, matches deleted)."""
    promoted = next((p for p, status, _, matches in progress(conn, platform)
                     if status == "collecting" and matches >= match_cap), None)
    if promoted:
        with conn:
            conn.execute("UPDATE patch SET status = 'retired' WHERE status = 'live'")
            conn.execute("UPDATE patch SET status = 'live', live_since_utc = CURRENT_TIMESTAMP WHERE patch = ?",
                         (promoted,))
        sync(conn, warehouse)
    return promoted, delete_retired(conn, warehouse)


def collection_plan(conn, platform: str, hold_patch: str | None = None):
    """The patch to collect (`hold_patch`, or else the newest not retired), the time its games
    start and end (epoch seconds: the next patch's start, or None while it's the newest), its
    matches loaded so far, and matches on their way (queued, or downloaded but not loaded).
    None if no patch is set up."""
    rows = progress(conn, platform)
    candidates = [r for r in rows if r[1] != "retired" and (hold_patch is None or r[0] == hold_patch)]
    if not candidates:
        return None
    patch, _, started, matches = candidates[-1]
    since, until = conn.execute(
        "SELECT CAST(strftime('%s', ?) AS INTEGER), "
        "(SELECT CAST(strftime('%s', MIN(started_utc)) AS INTEGER) FROM patch WHERE started_utc > ?)",
        (started, started),
    ).fetchone()
    in_progress = conn.execute(
        "SELECT (SELECT COUNT(*) FROM match_queue WHERE status = 'pending')"
        "     + (SELECT COUNT(*) FROM match_raw WHERE loaded_at IS NULL)"
    ).fetchone()[0]
    return patch, since, until, matches, in_progress
