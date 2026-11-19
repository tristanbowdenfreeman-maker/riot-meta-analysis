"""Build the marts in BigQuery and export them, with the name/icon lookups, to JSON for the static
website (site/).

The marts are tables, rebuilt from the fact tables once per export (`build`), so the website's
numbers come from one consistent snapshot and each day's export scans the fact tables only once.
The website is plain files on GitHub Pages, so it can't query BigQuery; it reads these instead.
They hold aggregated stats only, no player IDs.
"""

import json
import math
from datetime import date, datetime, timezone

from riot_meta import checks
from riot_meta.config import PROJECT_ROOT
from riot_meta.patches import REMAKE_SECONDS
from riot_meta.warehouse import Warehouse, sql_files

EXPORT_DIR = PROJECT_ROOT / "site" / "data"
MART_TABLES = [
    "patch_summary",
    "sample_by_tier",
    "data_volume",
    "tier_list",
    "champion_matchups",
    "champion_starter_sets",
    "champion_boots",
    "champion_core_items",
    "champion_late_items",
    "champion_rune_stats",
    "champion_rune_picks",
    "champion_shard_picks",
    "champion_spell_stats",
    "role_win_gap",
    "ban_vs_win",
    "ban_band_win_rate",
    "side_win_rate",
    "objective_win_rate",
    "objective_count_win_rate",
    "gold_lead_win_rate",
    "lane_lead_win_rate",
    "champion_game_length",
    "champion_rank_win_rate",
    "champion_skill_paths",
]
LOOKUPS = {
    "champions": "SELECT champion_id, champion_key, champion_name, primary_class FROM riot_dim.champion",
    "items": "SELECT item_id, item_name, total_gold, item_class FROM riot_dim.item",
    "rune_trees": "SELECT tree_id, tree_name, icon_path FROM riot_dim.rune_tree",
    "runes": "SELECT rune_id, rune_name, tree_id, slot_index, icon_path FROM riot_dim.rune",
    "shards": "SELECT shard_id, shard_name, icon_path FROM riot_dim.stat_shard",
    "spells": "SELECT spell_id, spell_key, spell_name FROM riot_dim.summoner_spell",
}


def build(warehouse: Warehouse) -> None:
    """Rebuild every mart table, then push back the sandbox's table expiry."""
    for path in sql_files("2_marts"):
        warehouse.run_file(path)
        print(f"  built riot_mart.{path.stem[3:]}")
    warehouse.refresh_expiry()


def _value(v):
    # Four decimal places is plenty for rates (0.5123 = 51.23%) and keeps the files small.
    if isinstance(v, float):
        return None if math.isnan(v) or math.isinf(v) else round(v, 4)
    if isinstance(v, datetime):
        return v.strftime("%Y-%m-%dT%H:%M:%S.000")
    if isinstance(v, date):
        return v.isoformat()
    return v


def _write(rows: list[dict], name: str) -> None:
    path = EXPORT_DIR / f"{name}.json"
    path.write_text(json.dumps([{k: _value(v) for k, v in row.items()} for row in rows], separators=(",", ":")))
    print(f"  {path.relative_to(PROJECT_ROOT)}: {len(rows):,} rows")


def _local_volume(conn, row: dict, platform: str) -> None:
    """The data_volume figures held outside BigQuery: ladder size and raw JSON stored."""
    prefix = f"{platform.upper()}_"
    row["ladder_players"] = conn.execute("SELECT COUNT(*) FROM player").fetchone()[0]
    raw_bytes = conn.execute(
        """
        SELECT SUM(length(r.payload_gz) + IFNULL(length(t.payload_gz), 0))
        FROM match_raw AS r
        LEFT JOIN timeline_raw AS t ON t.match_id = r.match_id
        WHERE r.patch = ? AND r.loaded_at IS NOT NULL AND r.queue_id = 420 AND r.duration_s >= ?
          AND substr(r.match_id, 1, ?) = ?
        """,
        (row["patch"], REMAKE_SECONDS, len(prefix), prefix),
    ).fetchone()[0] or 0
    row["raw_json_mb"] = raw_bytes / 1048576
    row["mart_views"] = len(sql_files("2_marts"))


def export_marts(conn, warehouse: Warehouse, platform: str) -> None:
    """Write site/data/*.json from the mart tables (run `build` first)."""
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    for table in MART_TABLES:
        rows = warehouse.query(f"SELECT * FROM riot_mart.{table}")
        if table == "data_volume":
            for row in rows:
                _local_volume(conn, row, platform)
        _write(rows, table)
    for name, query in LOOKUPS.items():
        _write(warehouse.query(query), name)
    # The data checks, so the site can show them (scripts/collect.sh only exports once they pass).
    _write(checks.run(conn, warehouse), "data_checks")

    ddragon_version = warehouse.query("SELECT MAX(ddragon_version) AS v FROM riot_dim.champion")[0]["v"]
    meta = {"ddragon_version": ddragon_version, "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    (EXPORT_DIR / "meta.json").write_text(json.dumps(meta))
    print(f"  {(EXPORT_DIR / 'meta.json').relative_to(PROJECT_ROOT)}")

    # Remove files from marts that are no longer exported, so the site never reads stale data.
    current = set(MART_TABLES) | set(LOOKUPS) | {"data_checks", "meta"}
    for path in EXPORT_DIR.glob("*.json"):
        if path.stem not in current:
            path.unlink()
            print(f"  removed stale {path.relative_to(PROJECT_ROOT)}")
