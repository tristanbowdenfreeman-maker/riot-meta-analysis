"""The four fetch stages. Each one writes to SQL Server as it goes, so any stage can be stopped
and re-run without losing work.

1. discover:        find Emerald+ solo/duo players          -> stg.player
2. queue:           collect their recent ranked match IDs    -> stg.match_queue
3. fetch:           download each queued match's JSON        -> stg.match_raw
4. fetch-timelines: download each fetched match's timeline   -> stg.timeline_raw
"""

import gzip
import json
import random
import time

from riot_meta.client import RiotApiError, RiotClient

# Emerald and above. Apex tiers have a single division.
LADDER = [
    ("CHALLENGER", ["I"]),
    ("GRANDMASTER", ["I"]),
    ("MASTER", ["I"]),
    ("DIAMOND", ["I", "II", "III", "IV"]),
    ("EMERALD", ["I", "II", "III", "IV"]),
]
MAX_FETCH_ATTEMPTS = 3


def discover(client: RiotClient, conn, pages_per_division: int) -> int:
    """Store up to `pages_per_division` pages (205 players each) of every division."""
    cursor = conn.cursor()
    total = 0
    for tier, divisions in LADDER:
        for division in divisions:
            for page in range(1, pages_per_division + 1):
                entries = [e for e in client.league_entries(tier, division, page) if e.get("puuid")]
                if not entries:
                    break
                cursor.executemany(
                    """
                    MERGE stg.player AS t
                    USING (SELECT %s AS puuid, %s AS tier, %s AS division, %s AS league_points,
                                  %s AS wins, %s AS losses) AS s
                       ON t.puuid = s.puuid
                    WHEN MATCHED THEN UPDATE SET tier = s.tier, division = s.division,
                         league_points = s.league_points, wins = s.wins, losses = s.losses
                    WHEN NOT MATCHED THEN INSERT (puuid, tier, division, league_points, wins, losses)
                         VALUES (s.puuid, s.tier, s.division, s.league_points, s.wins, s.losses);
                    """,
                    [(e["puuid"], e["tier"], e["rank"], e["leaguePoints"], e["wins"], e["losses"]) for e in entries],
                )
                total += len(entries)
                print(f"  {tier} {division} page {page}: {len(entries)} players")
    return total


def queue_matches(client: RiotClient, conn, target: int, since_epoch: int, per_player: int, seed: int) -> int:
    """Visit players in a seeded random order, queueing up to `per_player` of their ranked matches
    played since `since_epoch`, until the queue holds `target` matches."""
    cursor = conn.cursor()
    cursor.execute("SELECT COUNT(*) FROM stg.match_queue WHERE status <> 'failed'")
    queued = cursor.fetchone()[0]

    cursor.execute("SELECT puuid, tier FROM stg.player WHERE match_ids_fetched_at IS NULL ORDER BY puuid")
    players = cursor.fetchall()
    random.Random(seed).shuffle(players)

    for visited, (puuid, tier) in enumerate(players, start=1):
        if queued >= target:
            break
        for match_id in client.match_ids(puuid, since_epoch, per_player):
            cursor.execute(
                """
                INSERT INTO stg.match_queue (match_id, source_puuid, source_tier)
                SELECT %s, %s, %s
                WHERE NOT EXISTS (SELECT 1 FROM stg.match_queue WHERE match_id = %s)
                """,
                (match_id, puuid, tier, match_id),
            )
            queued += cursor.rowcount
        cursor.execute("UPDATE stg.player SET match_ids_fetched_at = SYSUTCDATETIME() WHERE puuid = %s", (puuid,))
        if visited % 25 == 0:
            print(f"  {visited} players visited, {queued}/{target} matches queued")

    print(f"  queue holds {queued} matches")
    return queued


def _compress(text: str) -> bytes:
    """GZIP of UTF-16 text: T-SQL's CAST(DECOMPRESS(x) AS NVARCHAR(MAX)) turns it back into text."""
    return gzip.compress(text.encode("utf-16-le"))


def _print_progress(done: int, total: int, started: float, noun: str) -> None:
    if done % 50 == 0 or done == total:
        remaining = (time.monotonic() - started) / done * (total - done)
        print(f"  {done}/{total} {noun}, ~{remaining / 60:.0f} min left")


def fetch_matches(client: RiotClient, conn, limit: int | None = None) -> int:
    """Download pending matches into stg.match_raw, GZIP-compressed (see _compress)."""
    cursor = conn.cursor()
    cursor.execute("SELECT match_id FROM stg.match_queue WHERE status = 'pending' ORDER BY queued_at, match_id")
    pending = [row[0] for row in cursor.fetchall()]
    if limit is not None:
        pending = pending[:limit]

    started = time.monotonic()
    fetched = 0
    for done, match_id in enumerate(pending, start=1):
        try:
            text = client.match_json(match_id)
            if text is not None and "info" not in json.loads(text):
                raise RiotApiError(f"{match_id}: response has no 'info' block")
        except RiotApiError as error:
            print(f"  {error}")
            cursor.execute(
                """
                UPDATE stg.match_queue
                SET attempts = attempts + 1,
                    status = CASE WHEN attempts + 1 >= %s THEN 'failed' ELSE 'pending' END,
                    updated_at = SYSUTCDATETIME()
                WHERE match_id = %s
                """,
                (MAX_FETCH_ATTEMPTS, match_id),
            )
            continue

        if text is None:  # 404: match no longer available
            status = "skipped"
        else:
            cursor.execute(
                """
                INSERT INTO stg.match_raw (match_id, payload_gz)
                SELECT %s, %s
                WHERE NOT EXISTS (SELECT 1 FROM stg.match_raw WHERE match_id = %s)
                """,
                (match_id, _compress(text), match_id),
            )
            status = "done"
            fetched += 1
        cursor.execute(
            "UPDATE stg.match_queue SET status = %s, updated_at = SYSUTCDATETIME() WHERE match_id = %s",
            (status, match_id),
        )
        _print_progress(done, len(pending), started, "matches")
    return fetched


def fetch_timelines(client: RiotClient, conn, limit: int | None = None) -> int:
    """Download the timeline of every fetched match that doesn't have one yet. The timeline holds
    the item purchase order (docs/adr/0007). stg.timeline_raw doubles as the queue: no row, or
    status 'pending', means still to fetch."""
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT r.match_id
        FROM stg.match_raw AS r
        LEFT JOIN stg.timeline_raw AS t ON t.match_id = r.match_id
        WHERE t.match_id IS NULL OR t.status = 'pending'
        ORDER BY r.match_id
        """
    )
    pending = [row[0] for row in cursor.fetchall()]
    if limit is not None:
        pending = pending[:limit]

    started = time.monotonic()
    fetched = 0
    for done, match_id in enumerate(pending, start=1):
        try:
            text = client.match_timeline_json(match_id)
            if text is not None and "frames" not in json.loads(text).get("info", {}):
                raise RiotApiError(f"{match_id}: timeline has no 'frames' block")
        except RiotApiError as error:
            print(f"  {error}")
            cursor.execute(
                """
                MERGE stg.timeline_raw AS t
                USING (SELECT %s AS match_id) AS s ON t.match_id = s.match_id
                WHEN MATCHED THEN UPDATE SET attempts = t.attempts + 1,
                     status = CASE WHEN t.attempts + 1 >= %s THEN 'failed' ELSE 'pending' END,
                     updated_at = SYSUTCDATETIME()
                WHEN NOT MATCHED THEN INSERT (match_id, status, attempts) VALUES (s.match_id, 'pending', 1);
                """,
                (match_id, MAX_FETCH_ATTEMPTS),
            )
            continue

        # None means 404: the timeline is no longer available.
        status, payload = ("skipped", None) if text is None else ("done", _compress(text))
        cursor.execute(
            """
            MERGE stg.timeline_raw AS t
            USING (SELECT %s AS match_id, %s AS status, %s AS payload_gz) AS s ON t.match_id = s.match_id
            WHEN MATCHED THEN UPDATE SET status = s.status, payload_gz = s.payload_gz, updated_at = SYSUTCDATETIME()
            WHEN NOT MATCHED THEN INSERT (match_id, status, payload_gz) VALUES (s.match_id, s.status, s.payload_gz);
            """,
            (match_id, status, payload),
        )
        fetched += status == "done"
        _print_progress(done, len(pending), started, "timelines")
    return fetched
