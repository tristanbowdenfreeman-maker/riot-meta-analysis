"""Export the mart views and the name/icon lookups to JSON for the static website (site/).

The website is plain files on GitHub Pages, so it can't query SQL Server; it reads these instead.
They hold aggregated stats only, no player IDs.
"""

import json
from datetime import datetime, timezone

import pandas as pd

from riot_meta.config import PROJECT_ROOT, Settings
from riot_meta.db import engine

EXPORT_DIR = PROJECT_ROOT / "site" / "data"
MART_VIEWS = [
    "v_patch_summary",
    "v_sample_by_tier",
    "v_data_volume",
    "v_tier_list",
    "v_champion_matchups",
    "v_champion_starter_sets",
    "v_champion_boots",
    "v_champion_core_items",
    "v_champion_late_items",
    "v_champion_rune_stats",
    "v_champion_rune_picks",
    "v_champion_shard_picks",
    "v_champion_spell_stats",
    "v_role_win_gap",
    "v_ban_vs_win",
    "v_ban_band_win_rate",
    "v_side_win_rate",
    "v_objective_win_rate",
    "v_objective_count_win_rate",
    "v_gold_lead_win_rate",
    "v_lane_lead_win_rate",
    "v_champion_game_length",
]
LOOKUPS = {
    "champions": "SELECT champion_id, champion_key, champion_name, primary_class FROM dim.champion",
    "items": "SELECT item_id, item_name, total_gold, item_class FROM dim.item",
    "rune_trees": "SELECT tree_id, tree_name, icon_path FROM dim.rune_tree",
    "runes": "SELECT rune_id, rune_name, tree_id, slot_index, icon_path FROM dim.rune",
    "shards": "SELECT shard_id, shard_name, icon_path FROM dim.stat_shard",
    "spells": "SELECT spell_id, spell_key, spell_name FROM dim.summoner_spell",
    # The data checks, so the site can show them (scripts/collect.sh only exports once they pass).
    "data_checks": "SELECT check_name, is_blocking, failures FROM etl.v_data_quality_checks",
}


def _write(frame: pd.DataFrame, name: str) -> None:
    path = EXPORT_DIR / f"{name}.json"
    # Four decimal places is plenty for rates (0.5123 = 51.23%) and keeps the files small.
    frame.to_json(path, orient="records", double_precision=4, date_format="iso")
    print(f"  {path.relative_to(PROJECT_ROOT)}: {len(frame):,} rows")


def export_marts(settings: Settings) -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    db = engine(settings)
    for view in MART_VIEWS:
        _write(pd.read_sql(f"SELECT * FROM mart.{view}", db), view.removeprefix("v_"))
    for name, query in LOOKUPS.items():
        _write(pd.read_sql(query, db), name)

    ddragon_version = pd.read_sql("SELECT MAX(ddragon_version) AS v FROM dim.champion", db)["v"].iloc[0]
    meta = {"ddragon_version": ddragon_version, "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    (EXPORT_DIR / "meta.json").write_text(json.dumps(meta))
    print(f"  {(EXPORT_DIR / 'meta.json').relative_to(PROJECT_ROOT)}")

    # Remove files from views that are no longer exported, so the site never reads stale data.
    current = {v.removeprefix("v_") for v in MART_VIEWS} | set(LOOKUPS) | {"meta"}
    for path in EXPORT_DIR.glob("*.json"):
        if path.stem not in current:
            path.unlink()
            print(f"  removed stale {path.relative_to(PROJECT_ROOT)}")
