import pytest

from riot_meta.client import RateLimiter, RiotApiError, RiotAuthError, RiotClient
from riot_meta.config import parse_rate_limits


class FakeClock:
    def __init__(self):
        self.now = 0.0
        self.sleeps = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


def test_parse_rate_limits():
    assert parse_rate_limits("20:1,100:120") == [(20, 1.0), (100, 120.0)]


def test_rate_limiter_allows_burst_up_to_short_window():
    clock = FakeClock()
    limiter = RateLimiter([(20, 1), (100, 120)], clock=clock, sleep=clock.sleep, margin=0)
    for _ in range(20):
        limiter.acquire()
    assert clock.sleeps == []
    limiter.acquire()  # 21st request inside one second must wait
    assert clock.sleeps == [1.0]


def test_rate_limiter_enforces_long_window():
    clock = FakeClock()
    limiter = RateLimiter([(20, 1), (100, 120)], clock=clock, sleep=clock.sleep, margin=0)
    for _ in range(101):
        limiter.acquire()
    # 100 requests fit in the long window; the 101st waits until the first one is 120s old.
    assert clock.now == pytest.approx(120.0)


class FakeResponse:
    def __init__(self, status_code, body="{}", headers=None):
        self.status_code = status_code
        self.text = body
        self.headers = headers or {}

    def json(self):
        import json

        return json.loads(self.text)


class FakeSession:
    def __init__(self, responses):
        self.responses = list(responses)
        self.headers = {}
        self.calls = []

    def get(self, url, params=None, timeout=None):
        self.calls.append((url, params))
        return self.responses.pop(0)


def make_client(responses):
    session = FakeSession(responses)
    sleeps = []
    client = RiotClient("RGAPI-test", "euw1", "europe", [(1000, 1)], session=session, sleep=sleeps.append)
    return client, session, sleeps


def test_client_sends_key_and_routes_to_correct_hosts():
    client, session, _ = make_client([FakeResponse(200, "[]"), FakeResponse(200, '["EUW1_1"]')])
    client.league_entries("EMERALD", "I", 1)
    assert client.match_ids("abc", 1700000000, 5) == ["EUW1_1"]
    assert session.headers["X-Riot-Token"] == "RGAPI-test"
    assert session.calls[0][0] == "https://euw1.api.riotgames.com/lol/league-exp/v4/entries/RANKED_SOLO_5x5/EMERALD/I"
    assert session.calls[1][0].startswith("https://europe.api.riotgames.com/lol/match/v5/matches/by-puuid/abc/ids")
    assert session.calls[1][1] == {"queue": 420, "type": "ranked", "startTime": 1700000000, "count": 5}


def test_match_ids_stops_at_end_time_when_given():
    client, session, _ = make_client([FakeResponse(200, '["EUW1_1"]')])
    client.match_ids("abc", 1700000000, 20, end_time=1700100000)
    assert session.calls[0][1] == {"queue": 420, "type": "ranked", "startTime": 1700000000, "count": 20, "endTime": 1700100000}


def test_client_fetches_timeline_from_region_host():
    client, session, _ = make_client([FakeResponse(200, '{"info": {"frames": []}}')])
    assert client.match_timeline_json("EUW1_1") == '{"info": {"frames": []}}'
    assert session.calls[0][0] == "https://europe.api.riotgames.com/lol/match/v5/matches/EUW1_1/timeline"


def test_client_waits_for_retry_after_on_429():
    client, _, sleeps = make_client([FakeResponse(429, headers={"Retry-After": "7"}), FakeResponse(200, '{"info": {}}')])
    assert client.match_json("EUW1_1") == '{"info": {}}'
    assert 7.0 in sleeps


def test_client_returns_none_on_404():
    client, _, _ = make_client([FakeResponse(404)])
    assert client.match_json("EUW1_1") is None


def test_client_raises_clear_error_on_expired_key():
    client, _, _ = make_client([FakeResponse(403)])
    with pytest.raises(RiotAuthError, match="expired"):
        client.match_json("EUW1_1")


def test_client_gives_up_after_repeated_server_errors():
    client, _, _ = make_client([FakeResponse(503)] * RiotClient.MAX_RETRIES)
    with pytest.raises(RiotApiError, match="failed after"):
        client.match_json("EUW1_1")


def test_client_requires_api_key():
    with pytest.raises(RiotAuthError):
        RiotClient("", "euw1", "europe", [(20, 1)])
