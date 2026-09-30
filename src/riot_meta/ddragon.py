"""Data Dragon: Riot's static game data (champion, item, rune and summoner spell names).

These files are public CDN downloads and do not count against the API rate limit.
"""

import requests

from riot_meta.config import Settings
from riot_meta.db import connect

BASE_URL = "https://ddragon.leagueoflegends.com"
DATASETS = {
    "champion": "champion.json",
    "item": "item.json",
    "runesReforged": "runesReforged.json",
    "summoner": "summoner.json",
}


def latest_version() -> str:
    response = requests.get(f"{BASE_URL}/api/versions.json", timeout=30)
    response.raise_for_status()
    return response.json()[0]


def load(settings: Settings, version: str | None = None, language: str = "en_GB") -> str:
    """Store the four Data Dragon files in stg.ddragon_raw, then rebuild the dim tables from them."""
    version = version or latest_version()
    with connect(settings) as conn:
        cursor = conn.cursor()
        for dataset, filename in DATASETS.items():
            response = requests.get(f"{BASE_URL}/cdn/{version}/data/{language}/{filename}", timeout=60)
            response.raise_for_status()
            cursor.execute(
                """
                INSERT INTO stg.ddragon_raw (dataset, ddragon_version, payload)
                SELECT %s, %s, %s
                WHERE NOT EXISTS (SELECT 1 FROM stg.ddragon_raw WHERE dataset = %s AND ddragon_version = %s)
                """,
                (dataset, version, response.text, dataset, version),
            )
        cursor.execute("EXEC etl.usp_load_ddragon @ddragon_version = %s", (version,))
        _, champions, items, runes, spells = cursor.fetchone()
    print(f"Data Dragon {version}: {champions} champions, {items} items, {runes} runes, {spells} summoner spells")
    return version
