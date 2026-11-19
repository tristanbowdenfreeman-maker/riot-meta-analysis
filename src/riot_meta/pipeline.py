"""The four fetch stages. Each one writes to the local store (store.py) as it goes, so any stage
can be stopped and re-run without losing work.

1. discover:        find Emerald+ solo/duo players          -> player
2. queue:           collect their recent ranked match IDs    -> match_queue
3. fetch:           download each queued match's JSON        -> match_raw
4. fetch-timelines: download each fetched match's timeline   -> timeline_raw
"""

import json
import random
import time

from riot_meta.client import RiotApiError, RiotClient
from riot_meta.store import compress

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
    total = 0
    for tier, divisions in LADDER:
        for division in divisions:
            for page in range(1, pages_per_division + 1):
                entries = [e for e in client.league_entries(tier, division, page) if e.get("puuid")]
                if not entries:
                    break
                with conn:
                    conn.executemany(
                        """
                        INSERT INTO player (puuid, tier, division, league_points, wins, losses)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT (puuid) DO UPDATE SET tier = excluded.tier, division = excluded.division,
                            league_points = excluded.league_points, wins = excluded.wins, losses = excluded.losses
                        """,
                        [(e["puuid"], e["tier"], e["rank"], e["leaguePoints"], e["wins"], e["losses"])
                         for e in entries],
                    )
                total += len(entries)
                print(f"  {tier} {division} page {page}: {len(entries)} players")
    return total


def queue_matches(
    client: RiotClient, conn, target: int | None, since_epoch: int, per_player: int, seed: int, platform: str,
    more: int | None = None, until_epoch: int | None = None,
) -> int:
    """Visit players in a seeded random order, queueing up to `per_player` of their ranked matches
    played since `since_epoch` (and before `until_epoch`, if given), until the queue holds `target`
    matches (or `more` than it holds now).

    A player's history covers every server in the region (EUW, EUNE, TR, RU), so only match IDs
    from `platform` (e.g. EUW1_...) are queued."""
    prefix = f"{platform.upper()}_"
    queued = conn.execute(
        "SELECT COUNT(*) FROM match_queue WHERE status <> 'failed' AND substr(match_id, 1, ?) = ?",
        (len(prefix), prefix),
    ).fetchone()[0]
    if more is not None:
        target = queued + more

    players = conn.execute("SELECT puuid, tier FROM player WHERE match_ids_fetched_at IS NULL ORDER BY puuid").fetchall()
    random.Random(seed).shuffle(players)

    for visited, (puuid, tier) in enumerate(players, start=1):
        if queued >= target:
            break
        match_ids = [m for m in client.match_ids(puuid, since_epoch, per_player, end_time=until_epoch)
                     if m.startswith(prefix)]
        with conn:
            for match_id in match_ids:
                queued += conn.execute(
                    "INSERT OR IGNORE INTO match_queue (match_id, source_puuid, source_tier) VALUES (?, ?, ?)",
                    (match_id, puuid, tier),
                ).rowcount
            conn.execute("UPDATE player SET match_ids_fetched_at = CURRENT_TIMESTAMP WHERE puuid = ?", (puuid,))
        if visited % 25 == 0:
            print(f"  {visited} players visited, {queued}/{target} matches queued")

    print(f"  queue holds {queued} matches")
    if queued < target:
        print("  ran out of players: run discover with more pages to find more")
    return queued


def _print_progress(done: int, total: int, started: float, noun: str) -> None:
    if done % 50 == 0 or done == total:
        remaining = (time.monotonic() - started) / done * (total - done)
        print(f"  {done}/{total} {noun}, ~{remaining / 60:.0f} min left")


def fetch_matches(client: RiotClient, conn, limit: int | None = None) -> int:
    """Download pending matches into match_raw, GZIP-compressed."""
    pending = [row[0] for row in conn.execute(
        "SELECT match_id FROM match_queue WHERE status = 'pending' ORDER BY queued_at, match_id")]
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
            with conn:
                conn.execute(
                    """
                    UPDATE match_queue
                    SET attempts = attempts + 1,
                        status = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE 'pending' END,
                        updated_at = CURRENT_TIMESTAMP
                    WHERE match_id = ?
                    """,
                    (MAX_FETCH_ATTEMPTS, match_id),
                )
            continue

        with conn:
            if text is None:  # 404: match no longer available
                status = "skipped"
            else:
                conn.execute("INSERT OR IGNORE INTO match_raw (match_id, payload_gz) VALUES (?, ?)",
                             (match_id, compress(text)))
                status = "done"
                fetched += 1
            conn.execute("UPDATE match_queue SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE match_id = ?",
                         (status, match_id))
        _print_progress(done, len(pending), started, "matches")
    return fetched


def fetch_timelines(client: RiotClient, conn, limit: int | None = None) -> int:
    """Download the timeline of every fetched match that doesn't have one yet. The timeline holds
    the item purchase order. timeline_raw doubles as the queue: no row, or status 'pending',
    means still to fetch."""
    pending = [row[0] for row in conn.execute(
        """
        SELECT r.match_id
        FROM match_raw AS r
        LEFT JOIN timeline_raw AS t ON t.match_id = r.match_id
        WHERE t.match_id IS NULL OR t.status = 'pending'
        ORDER BY r.match_id
        """
    )]
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
            with conn:
                conn.execute(
                    """
                    INSERT INTO timeline_raw (match_id, status, attempts) VALUES (?, 'pending', 1)
                    ON CONFLICT (match_id) DO UPDATE SET attempts = attempts + 1,
                        status = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE 'pending' END,
                        updated_at = CURRENT_TIMESTAMP
                    """,
                    (match_id, MAX_FETCH_ATTEMPTS),
                )
            continue

        # None means 404: the timeline is no longer available.
        status, payload = ("skipped", None) if text is None else ("done", compress(text))
        with conn:
            conn.execute(
                """
                INSERT INTO timeline_raw (match_id, status, payload_gz) VALUES (?, ?, ?)
                ON CONFLICT (match_id) DO UPDATE SET status = excluded.status, payload_gz = excluded.payload_gz,
                    updated_at = CURRENT_TIMESTAMP
                """,
                (match_id, status, payload),
            )
        fetched += status == "done"
        _print_progress(done, len(pending), started, "timelines")
    return fetched
