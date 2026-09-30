"""Command line: python -m riot_meta <command>. Run with no arguments for the list of commands."""

import argparse
import sys
from datetime import datetime, timezone

from riot_meta import ddragon, pipeline
from riot_meta.client import RiotClient
from riot_meta.config import load_settings
from riot_meta.db import connect, run_scripts
from riot_meta.export import export_marts


def _client(settings) -> RiotClient:
    return RiotClient(settings.riot_api_key, settings.platform, settings.region, settings.rate_limits)


def _print_rows(cursor) -> None:
    columns = [c[0] for c in cursor.description]
    rows = cursor.fetchall()
    widths = [max(len(str(v)) for v in [col, *(r[i] for r in rows)]) for i, col in enumerate(columns)]
    print("  " + "  ".join(c.ljust(w) for c, w in zip(columns, widths)))
    for row in rows:
        print("  " + "  ".join(str(v).ljust(w) for v, w in zip(row, widths)))


def cmd_setup_db(settings, args):
    run_scripts(settings)


def cmd_ddragon(settings, args):
    ddragon.load(settings, args.version)


def cmd_discover(settings, args):
    with connect(settings) as conn:
        total = pipeline.discover(_client(settings), conn, args.pages)
    print(f"Discovered {total} players")


def cmd_queue(settings, args):
    since = datetime.strptime(args.since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    with connect(settings) as conn:
        pipeline.queue_matches(_client(settings), conn, args.target, int(since.timestamp()), args.per_player, args.seed)


def cmd_fetch(settings, args):
    with connect(settings) as conn:
        fetched = pipeline.fetch_matches(_client(settings), conn, args.limit)
    print(f"Fetched {fetched} matches")


def cmd_transform(settings, args):
    with connect(settings) as conn:
        cursor = conn.cursor()
        cursor.execute("EXEC etl.usp_load_matches")
        print(f"Loaded {cursor.fetchone()[0]} new matches into the fact tables")


def cmd_check(settings, args):
    with connect(settings) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT check_name, is_blocking, failures FROM etl.v_data_quality_checks")
        rows = cursor.fetchall()
    failed = False
    for name, is_blocking, failures in rows:
        if failures == 0:
            mark = "PASS"
        elif is_blocking:
            mark, failed = "FAIL", True
        else:
            mark = "WARN"
        print(f"  {mark}  {name}: {failures}")
    if failed:
        sys.exit(1)


def cmd_export(settings, args):
    export_marts(settings)


def cmd_status(settings, args):
    with connect(settings) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT 'players discovered' AS item, COUNT(*) AS n FROM stg.player
            UNION ALL SELECT 'players with match IDs fetched', COUNT(*) FROM stg.player WHERE match_ids_fetched_at IS NOT NULL
            UNION ALL SELECT 'queue: ' + status, COUNT(*) FROM stg.match_queue GROUP BY status
            UNION ALL SELECT 'raw matches', COUNT(*) FROM stg.match_raw
            UNION ALL SELECT 'fact matches', COUNT(*) FROM fact.match
            UNION ALL SELECT 'fact player records', COUNT(*) FROM fact.match_participant
            """
        )
        _print_rows(cursor)
        cursor.execute("SELECT * FROM mart.v_patch_summary ORDER BY patch")
        _print_rows(cursor)


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m riot_meta")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("setup-db", help="create the database, tables, procedures and views").set_defaults(func=cmd_setup_db)

    p = sub.add_parser("ddragon", help="load champion/item/rune/spell names from Data Dragon")
    p.add_argument("--version", help="Data Dragon version (default: latest)")
    p.set_defaults(func=cmd_ddragon)

    p = sub.add_parser("discover", help="find Emerald+ solo/duo players")
    p.add_argument("--pages", type=int, default=2, help="pages of 205 players per division (default 2)")
    p.set_defaults(func=cmd_discover)

    p = sub.add_parser("queue", help="queue ranked match IDs from discovered players")
    p.add_argument("--since", required=True, help="only matches from this date (UTC), e.g. the patch release date")
    p.add_argument("--target", type=int, default=3000, help="stop once the queue holds this many matches")
    p.add_argument("--per-player", type=int, default=5, help="max matches taken from each player")
    p.add_argument("--seed", type=int, default=42, help="random seed for the player order")
    p.set_defaults(func=cmd_queue)

    p = sub.add_parser("fetch", help="download queued matches")
    p.add_argument("--limit", type=int, help="stop after this many matches")
    p.set_defaults(func=cmd_fetch)

    sub.add_parser("transform", help="parse new raw matches into the fact tables").set_defaults(func=cmd_transform)
    sub.add_parser("check", help="run data-quality checks").set_defaults(func=cmd_check)
    sub.add_parser("export", help="export mart views to data/marts/*.parquet").set_defaults(func=cmd_export)
    sub.add_parser("status", help="row counts for every stage").set_defaults(func=cmd_status)

    args = parser.parse_args()
    args.func(load_settings(), args)


if __name__ == "__main__":
    main()
