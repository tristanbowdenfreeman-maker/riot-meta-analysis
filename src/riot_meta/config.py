"""Settings read from .env (see .env.example)."""

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Settings:
    riot_api_key: str
    platform: str
    region: str
    rate_limits: list[tuple[int, float]]
    store_path: Path
    bq_project: str
    bq_location: str
    bq_max_gb_billed: int
    matches_per_patch: int
    matches_to_go_live: int
    hold_patch: str | None


def parse_rate_limits(spec: str) -> list[tuple[int, float]]:
    """'20:1,100:120' -> [(20, 1.0), (100, 120.0)]: at most 20 requests per 1s and 100 per 120s."""
    limits = []
    for part in spec.split(","):
        count, seconds = part.strip().split(":")
        limits.append((int(count), float(seconds)))
    return limits


def load_settings() -> Settings:
    load_dotenv(PROJECT_ROOT / ".env")
    project = os.getenv("BQ_PROJECT", "")
    if not project:
        raise SystemExit("BQ_PROJECT is not set in .env")
    return Settings(
        riot_api_key=os.getenv("RIOT_API_KEY", ""),
        platform=os.getenv("RIOT_PLATFORM", "euw1"),
        region=os.getenv("RIOT_REGION", "europe"),
        rate_limits=parse_rate_limits(os.getenv("RIOT_RATE_LIMITS", "20:1,100:120")),
        store_path=PROJECT_ROOT / os.getenv("STORE_PATH", "data/riot.sqlite"),
        bq_project=project,
        bq_location=os.getenv("BQ_LOCATION", "EU"),
        # Any single query that would scan more than this fails instead of running. The free tier
        # is 1 TB of scanning a month; a full export scans a few GB.
        bq_max_gb_billed=int(os.getenv("BQ_MAX_GB_BILLED", "20")),
        matches_per_patch=int(os.getenv("MATCHES_PER_PATCH", "30000")),
        # A new patch replaces the live one on the site at this many matches, then keeps
        # growing up to MATCHES_PER_PATCH. Never more than the cap.
        matches_to_go_live=min(int(os.getenv("MATCHES_TO_GO_LIVE", "30000")),
                               int(os.getenv("MATCHES_PER_PATCH", "30000"))),
        # Keep collecting this patch (e.g. "16.19") and don't start new ones; unset to follow new patches.
        hold_patch=os.getenv("HOLD_PATCH") or None,
    )
