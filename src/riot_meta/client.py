"""Minimal Riot Games API client with client-side rate limiting.

Riot enforces its rate limits per routing host (e.g. euw1 for league data, europe for match
data), so each host gets its own limiter. If a 429 still comes back, the client waits for the
Retry-After header before trying again.
"""

import time
from collections import deque
from typing import Callable

import requests


class RiotApiError(Exception):
    pass


class RiotAuthError(RiotApiError):
    """401/403: the key is missing, wrong or expired (development keys last 24 hours)."""


class RateLimiter:
    """Sliding-window limiter over several windows, e.g. 20 per 1s and 100 per 120s."""

    def __init__(
        self,
        limits: list[tuple[int, float]],
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        margin: float = 0.05,
    ):
        self._windows = [(count, seconds, deque()) for count, seconds in limits]
        self._clock = clock
        self._sleep = sleep
        self._margin = margin

    def acquire(self) -> None:
        while True:
            now = self._clock()
            wait = 0.0
            for count, seconds, stamps in self._windows:
                while stamps and now - stamps[0] >= seconds:
                    stamps.popleft()
                if len(stamps) >= count:
                    wait = max(wait, seconds - (now - stamps[0]))
            if wait <= 0:
                for _, _, stamps in self._windows:
                    stamps.append(now)
                return
            self._sleep(wait + self._margin)


class RiotClient:
    MAX_RETRIES = 5

    def __init__(
        self,
        api_key: str,
        platform: str,
        region: str,
        rate_limits: list[tuple[int, float]],
        session: requests.Session | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ):
        if not api_key:
            raise RiotAuthError("RIOT_API_KEY is not set in .env")
        self._platform_host = f"https://{platform}.api.riotgames.com"
        self._region_host = f"https://{region}.api.riotgames.com"
        self._session = session or requests.Session()
        self._session.headers["X-Riot-Token"] = api_key
        self._sleep = sleep
        self._limiters = {
            host: RateLimiter(rate_limits, sleep=sleep) for host in (self._platform_host, self._region_host)
        }

    def _get(self, host: str, path: str, params: dict | None = None) -> requests.Response | None:
        """GET with rate limiting and retries. Returns None for 404."""
        for attempt in range(1, self.MAX_RETRIES + 1):
            self._limiters[host].acquire()
            try:
                response = self._session.get(host + path, params=params, timeout=30)
            except (requests.ConnectionError, requests.Timeout):
                self._sleep(2**attempt)
                continue

            if response.status_code == 200:
                return response
            if response.status_code == 404:
                return None
            if response.status_code in (401, 403):
                raise RiotAuthError(
                    f"Riot API returned {response.status_code}. The API key is missing or expired - "
                    "regenerate it at https://developer.riotgames.com and update RIOT_API_KEY in .env."
                )
            if response.status_code == 429:
                self._sleep(float(response.headers.get("Retry-After", 10)))
                continue
            if response.status_code >= 500:
                self._sleep(2**attempt)
                continue
            raise RiotApiError(f"GET {path} -> {response.status_code}: {response.text[:200]}")
        raise RiotApiError(f"GET {path} failed after {self.MAX_RETRIES} attempts")

    def league_entries(self, tier: str, division: str, page: int, queue: str = "RANKED_SOLO_5x5") -> list[dict]:
        """league-exp-v4: one page (up to 205 players) of a tier/division ladder."""
        response = self._get(
            self._platform_host, f"/lol/league-exp/v4/entries/{queue}/{tier}/{division}", {"page": page}
        )
        return response.json() if response else []

    def match_ids(self, puuid: str, start_time: int, count: int, queue: int = 420) -> list[str]:
        """match-v5: a player's most recent match IDs since start_time (epoch seconds), newest first."""
        response = self._get(
            self._region_host,
            f"/lol/match/v5/matches/by-puuid/{puuid}/ids",
            {"queue": queue, "type": "ranked", "startTime": start_time, "count": count},
        )
        return response.json() if response else []

    def match_json(self, match_id: str) -> str | None:
        """match-v5: the full match as raw JSON text (stored unparsed in stg.match_raw)."""
        response = self._get(self._region_host, f"/lol/match/v5/matches/{match_id}")
        return response.text if response else None

    def match_timeline_json(self, match_id: str) -> str | None:
        """match-v5: the minute-by-minute timeline (item purchases, kills, ...) as raw JSON text."""
        response = self._get(self._region_host, f"/lol/match/v5/matches/{match_id}/timeline")
        return response.text if response else None
