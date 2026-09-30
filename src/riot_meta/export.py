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
    "v_tier_list",
    "v_champion_matchups",
    "v_champion_item_stats",
    "v_champion_starter_sets",
    "v_champion_boots",
    "v_champion_core_builds",
    "v_champion_item_slots",
    "v_champion_rune_stats",
    "v_champion_rune_picks",
    "v_champion_shard_picks",
    "v_champion_spell_stats",
]
LOOKUPS = {
    "champions": "SELECT champion_id, champion_key, champion_name, primary_class FROM dim.champion",
    "items": "SELECT item_id, item_name, total_gold, item_class FROM dim.item",
    "rune_trees": "SELECT tree_id, tree_name, icon_path FROM dim.rune_tree",
    "runes": "SELECT rune_id, rune_name, tree_id, slot_index, icon_path FROM dim.rune",
    "shards": "SELECT shard_id, shard_name, icon_path FROM dim.stat_shard",
    "spells": "SELECT spell_id, spell_key, spell_name FROM dim.summoner_spell",
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
