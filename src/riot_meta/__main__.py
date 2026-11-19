"""Command line: python -m riot_meta <command>. Run with no arguments for the list of commands."""

import argparse
import sys
from datetime import datetime, timezone

from riot_meta import checks, ddragon, patches, pipeline, store
from riot_meta.client import RiotClient
from riot_meta.config import load_settings
from riot_meta.export import build, export_marts
from riot_meta.parse import patch_of
from riot_meta.transform import transform
from riot_meta.warehouse import Warehouse


def _client(settings) -> RiotClient:
    return RiotClient(settings.riot_api_key, settings.platform, settings.region, settings.rate_limits)


def _print_rows(rows: list[tuple], columns: tuple[str, ...]) -> None:
    widths = [max(len(str(v)) for v in [col, *(r[i] for r in rows)]) for i, col in enumerate(columns)]
    print("  " + "  ".join(c.ljust(w) for c, w in zip(columns, widths)))
    for row in rows:
        print("  " + "  ".join(str(v).ljust(w) for v, w in zip(row, widths)))


def cmd_setup(settings, conn, wh, args):
    print(f"  local store: {settings.store_path}")
    wh.setup()


def cmd_ddragon(settings, conn, wh, args):
    ddragon.load(wh, args.version)


def cmd_discover(settings, conn, wh, args):
    total = pipeline.discover(_client(settings), conn, args.pages)
    print(f"Discovered {total} players")


def cmd_patch(settings, conn, wh, args):
    """Start collecting a new patch when Data Dragon has one, and put it live once it's full."""
    version = ddragon.latest_version()
    patch = patch_of(version)
    is_new = conn.execute("SELECT 1 FROM patch WHERE patch = ?", (patch,)).fetchone() is None
    if is_new and settings.hold_patch:
        print(f"Data Dragon has patch {patch}, but collection is held on {settings.hold_patch} (HOLD_PATCH in .env)")
    elif is_new:
        ddragon.load(wh, version)  # names and icons of any new champions and items
        deleted = patches.start(conn, wh, patch)
        print(f"New patch {patch}: collecting it; the site keeps the current patch until it's full")
        print(f"  deleted {deleted:,} matches of an unfinished patch")

    promoted, deleted = patches.promote(conn, wh, settings.platform, settings.matches_to_go_live)
    if promoted:
        print(f"Patch {promoted} has {settings.matches_to_go_live:,} matches: it is now live")
    if deleted:
        print(f"  deleted {deleted:,} matches of the old patch")
    for patch, status, _, matches in patches.progress(conn, settings.platform):
        print(f"  patch {patch}: {status}, {matches:,} of {settings.matches_per_patch:,} matches")


def cmd_queue(settings, conn, wh, args):
    until = None
    if args.since:
        since = int(datetime.strptime(args.since, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp())
        more = args.more
    else:
        # No date given: queue games of the patch being collected, up to its cap.
        plan = patches.collection_plan(conn, settings.platform, settings.hold_patch)
        if plan is None:
            raise SystemExit("No patch set up yet: run `python -m riot_meta patch` first, or pass --since")
        patch, since, until, matches, in_progress = plan
        if matches >= settings.matches_per_patch:
            print(f"  patch {patch} is full ({matches:,} matches): nothing to queue")
            return
        needed = settings.matches_per_patch - matches - in_progress
        if needed <= 0:
            print(f"  patch {patch}: the {in_progress:,} matches already queued will fill it")
            return
        more = needed if args.more is None else min(args.more, needed)
    pipeline.queue_matches(
        _client(settings), conn, args.target, since, args.per_player, args.seed, settings.platform, more, until
    )


def cmd_fetch(settings, conn, wh, args):
    fetched = pipeline.fetch_matches(_client(settings), conn, args.limit)
    print(f"Fetched {fetched} matches")


def cmd_fetch_timelines(settings, conn, wh, args):
    fetched = pipeline.fetch_timelines(_client(settings), conn, args.limit)
    print(f"Fetched {fetched} timelines")


def cmd_transform(settings, conn, wh, args):
    matches, timelines = transform(conn, wh)
    print(f"Loaded {matches:,} new matches and {timelines:,} new timelines into BigQuery")


def cmd_build(settings, conn, wh, args):
    patches.sync(conn, wh)  # the marts read the live patch from riot_etl.patch
    build(wh)


def cmd_check(settings, conn, wh, args):
    failed = False
    for row in checks.run(conn, wh):
        if row["failures"] == 0:
            mark = "PASS"
        elif row["is_blocking"]:
            mark, failed = "FAIL", True
        else:
            mark = "WARN"
        print(f"  {mark}  {row['check_name']}: {row['failures']}")
    if failed:
        sys.exit(1)


def cmd_export(settings, conn, wh, args):
    export_marts(conn, wh, settings.platform)


def cmd_status(settings, conn, wh, args):
    rows = conn.execute(
        """
        SELECT 'players discovered', COUNT(*) FROM player
        UNION ALL SELECT 'players with match IDs fetched', COUNT(*) FROM player WHERE match_ids_fetched_at IS NOT NULL
        UNION ALL SELECT * FROM (SELECT 'queue: ' || status, COUNT(*) FROM match_queue GROUP BY status)
        UNION ALL SELECT 'raw matches', COUNT(*) FROM match_raw
        UNION ALL SELECT 'raw matches not in BigQuery yet', COUNT(*) FROM match_raw WHERE loaded_at IS NULL
        UNION ALL SELECT * FROM (SELECT 'timelines: ' || status, COUNT(*) FROM timeline_raw GROUP BY status)
        """
    ).fetchall()
    # Row counts from table metadata: free, unlike a COUNT(*) query.
    rows += [(f"riot_fact.{r['table_id']}", r["row_count"])
             for r in wh.query("SELECT table_id, row_count FROM riot_fact.__TABLES__ ORDER BY table_id")]
    _print_rows(rows, ("item", "n"))
    print()
    _print_rows(patches.progress(conn, settings.platform), ("patch", "status", "started_utc", "matches"))


def cmd_migrate_mssql(settings, conn, wh, args):
    from riot_meta.migrate_mssql import migrate
    migrate(conn)
    patches.sync(conn, wh)


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m riot_meta")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("setup", help="create the local store and the BigQuery datasets and tables").set_defaults(
        func=cmd_setup)
    sub.add_parser(
        "patch", help="start collecting a new patch, and put it live once it has MATCHES_TO_GO_LIVE matches"
    ).set_defaults(func=cmd_patch)

    p = sub.add_parser("ddragon", help="load champion/item/rune/spell names from Data Dragon")
    p.add_argument("--version", help="Data Dragon version (default: latest)")
    p.set_defaults(func=cmd_ddragon)

    p = sub.add_parser("discover", help="find Emerald+ solo/duo players")
    p.add_argument("--pages", type=int, default=2, help="pages of 205 players per division (default 2)")
    p.set_defaults(func=cmd_discover)

    p = sub.add_parser("queue", help="queue ranked match IDs from discovered players")
    p.add_argument("--since", help="only matches from this date (UTC); default: the patch being collected, up to its cap")
    p.add_argument("--target", type=int, default=3000, help="stop once the queue holds this many matches")
    p.add_argument("--more", type=int, help="queue this many more matches than the queue holds now")
    p.add_argument("--per-player", type=int, default=5, help="max matches taken from each player")
    p.add_argument("--seed", type=int, default=42, help="random seed for the player order")
    p.set_defaults(func=cmd_queue)

    p = sub.add_parser("fetch", help="download queued matches")
    p.add_argument("--limit", type=int, help="stop after this many matches")
    p.set_defaults(func=cmd_fetch)

    p = sub.add_parser("fetch-timelines", help="download the timeline of every fetched match")
    p.add_argument("--limit", type=int, help="stop after this many timelines")
    p.set_defaults(func=cmd_fetch_timelines)

    sub.add_parser("transform", help="parse new raw matches and timelines and load them into BigQuery").set_defaults(
        func=cmd_transform)
    sub.add_parser("build", help="sync the live patch, rebuild and test the marts (dbt build), refresh expiry").set_defaults(func=cmd_build)
    sub.add_parser("check", help="run data-quality checks (after build)").set_defaults(func=cmd_check)
    sub.add_parser("export", help="export the mart tables to site/data/*.json (after build)").set_defaults(
        func=cmd_export)
    sub.add_parser("status", help="row counts for every stage").set_defaults(func=cmd_status)
    sub.add_parser("migrate-mssql", help="one-off: copy the old SQL Server database into the local store "
                   "(then run transform)").set_defaults(func=cmd_migrate_mssql)

    args = parser.parse_args()
    settings = load_settings()
    conn = store.connect(settings.store_path)
    wh = Warehouse(settings)
    try:
        args.func(settings, conn, wh, args)
    finally:
        conn.close()
        if wh.bytes_billed:
            print(f"  BigQuery: {wh.bytes_billed / 10**9:.2f} GB scanned")


if __name__ == "__main__":
    main()
