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
    mssql_host: str
    mssql_port: int
    mssql_user: str
    mssql_password: str
    mssql_database: str


def parse_rate_limits(spec: str) -> list[tuple[int, float]]:
    """'20:1,100:120' -> [(20, 1.0), (100, 120.0)]: at most 20 requests per 1s and 100 per 120s."""
    limits = []
    for part in spec.split(","):
        count, seconds = part.strip().split(":")
        limits.append((int(count), float(seconds)))
    return limits


def load_settings() -> Settings:
    load_dotenv(PROJECT_ROOT / ".env")
    password = os.getenv("MSSQL_SA_PASSWORD", "")
    if not password:
        raise SystemExit("MSSQL_SA_PASSWORD is not set in .env")
    return Settings(
        riot_api_key=os.getenv("RIOT_API_KEY", ""),
        platform=os.getenv("RIOT_PLATFORM", "euw1"),
        region=os.getenv("RIOT_REGION", "europe"),
        rate_limits=parse_rate_limits(os.getenv("RIOT_RATE_LIMITS", "20:1,100:120")),
        mssql_host=os.getenv("MSSQL_HOST", "localhost"),
        mssql_port=int(os.getenv("MSSQL_PORT", "1433")),
        mssql_user=os.getenv("MSSQL_USER", "sa"),
        mssql_password=password,
        mssql_database=os.getenv("MSSQL_DATABASE", "RiotMeta"),
    )
