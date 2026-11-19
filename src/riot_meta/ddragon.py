"""Data Dragon: Riot's static game data (champion, item, rune and summoner spell names).

These files are public CDN downloads and do not count against the API rate limit.
"""

import requests

from riot_meta.parse import parse_ddragon
from riot_meta.warehouse import Warehouse

BASE_URL = "https://ddragon.leagueoflegends.com"
FILES = ("champion.json", "item.json", "runesReforged.json", "summoner.json")


def latest_version() -> str:
    response = requests.get(f"{BASE_URL}/api/versions.json", timeout=30)
    response.raise_for_status()
    return response.json()[0]


def load(warehouse: Warehouse, version: str | None = None, language: str = "en_GB") -> str:
    """Download the four Data Dragon files and replace every dim table with their contents."""
    version = version or latest_version()
    texts = []
    for filename in FILES:
        response = requests.get(f"{BASE_URL}/cdn/{version}/data/{language}/{filename}", timeout=60)
        response.raise_for_status()
        texts.append(response.text)
    tables = parse_ddragon(version, *texts)
    for table, rows in tables.items():
        warehouse.load(f"riot_dim.{table}", rows, replace=True)
    print(f"Data Dragon {version}: {len(tables['champion'])} champions, {len(tables['item'])} items, "
          f"{len(tables['rune'])} runes, {len(tables['summoner_spell'])} summoner spells")
    return version
