"""Export the mart views to Parquet so the hosted dashboard can read them without SQL Server."""

import pandas as pd

from riot_meta.config import PROJECT_ROOT, Settings
from riot_meta.db import engine

EXPORT_DIR = PROJECT_ROOT / "data" / "marts"
MART_VIEWS = [
    "v_patch_summary",
    "v_sample_by_tier",
    "v_champion_role_stats",
    "v_champion_item_stats",
    "v_champion_item_pairs",
    "v_champion_rune_stats",
    "v_champion_spell_stats",
    "v_champion_matchups",
]


def export_marts(settings: Settings) -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    db = engine(settings)
    for view in MART_VIEWS:
        frame = pd.read_sql(f"SELECT * FROM mart.{view}", db)
        path = EXPORT_DIR / f"{view.removeprefix('v_')}.parquet"
        frame.to_parquet(path, index=False)
        print(f"  {path.relative_to(PROJECT_ROOT)}: {len(frame):,} rows")
