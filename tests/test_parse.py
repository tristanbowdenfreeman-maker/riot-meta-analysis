"""parse.py on small hand-written match and timeline payloads."""

import json

from riot_meta.parse import parse_match, parse_timeline, patch_of


def _player(pid, team, position, win, champion=1):
    return {
        "participantId": pid, "puuid": f"p{pid}", "teamId": team, "championId": champion,
        "teamPosition": position, "win": win, "kills": 1, "deaths": 2, "assists": 3, "goldEarned": 9000,
        "totalMinionsKilled": 100, "neutralMinionsKilled": 20, "visionScore": 15,
        "totalDamageDealtToChampions": 12000, "summoner1Id": 4, "summoner2Id": 14,
        "item0": 3031, "item1": 0, "item6": 3340,
        "perks": {"statPerks": {"offense": 5008, "flex": 5008, "defense": 5011},
                  "styles": [{"style": 8000, "selections": [{"perk": 8005}, {"perk": 9111}]},
                             {"style": 8100, "selections": [{"perk": 8139}]}]},
    }


ROLES = ["TOP", "JUNGLE", "MIDDLE", "BOTTOM", "UTILITY"]


def _match(duration=1800, blank=None):
    players = [_player(i + 1, 100, ROLES[i], True) for i in range(5)]
    players += [_player(i + 6, 200, ROLES[i], False) for i in range(5)]
    if blank:
        players[blank - 1]["teamPosition"] = ""
    return json.dumps({"info": {
        "gameVersion": "16.19.712.3456", "gameCreation": 1_758_600_000_000, "gameDuration": duration,
        "queueId": 420, "participants": players,
        "teams": [
            {"teamId": 100, "bans": [{"championId": 50, "pickTurn": 1}, {"championId": -1, "pickTurn": 2}],
             "objectives": {"dragon": {"first": True, "kills": 3}, "champion": {"first": False, "kills": 20}}},
            {"teamId": 200, "bans": [{"championId": 60, "pickTurn": 6}],
             "objectives": {"dragon": {"first": False, "kills": 1}, "champion": {"first": True, "kills": 15}}},
        ],
    }})


def test_patch_of():
    assert patch_of("16.19.1") == "16.19"


def test_parse_match_rows():
    rows = parse_match("EUW1_1", _match(), "DIAMOND")
    match = rows["match"][0]
    assert match["patch"] == "16.19" and match["sample_tier"] == "DIAMOND" and match["is_remake"] is False
    assert match["game_start_utc"] == "2025-09-23 04:00:00"
    assert len(rows["match_participant"]) == 10
    p = rows["match_participant"][0]
    assert p["creep_score"] == 120 and p["keystone_id"] == 8005 and p["secondary_tree_id"] == 8100
    assert len(rows["participant_item"]) == 20            # two non-empty slots each
    assert len(rows["participant_rune"]) == 30            # three selections each
    assert [b["champion_id"] for b in rows["match_ban"]] == [50, 60]   # -1 is a skipped ban
    assert len(rows["team_objective"]) == 4


def test_remake():
    assert parse_match("EUW1_1", _match(duration=200), None)["match"][0]["is_remake"] is True


def test_single_blank_role_is_filled():
    rows = parse_match("EUW1_1", _match(blank=3), None)
    assert rows["match_participant"][2]["team_position"] == "MIDDLE"


def _timeline(events, frames=26):
    frame_list = [{"events": [], "participantFrames": {
        str(i): {"participantId": i, "totalGold": 500 * m, "xp": 100 * m, "minionsKilled": 8 * m,
                 "jungleMinionsKilled": 0} for i in range(1, 11)}} for m in range(frames)]
    frame_list[1]["events"] = events
    return json.dumps({"info": {"frames": frame_list}})


def test_parse_timeline_shop_events_and_frames():
    events = [
        {"type": "ITEM_PURCHASED", "participantId": 1, "itemId": 1055, "timestamp": 1000},
        {"type": "ITEM_UNDO", "participantId": 1, "beforeId": 1055, "afterId": 0, "timestamp": 2000},
        {"type": "ITEM_UNDO", "participantId": 1, "beforeId": 0, "afterId": 1055, "timestamp": 2500},
        {"type": "ITEM_PURCHASED", "participantId": 0, "itemId": 3865, "timestamp": 0},
        {"type": "WARD_PLACED", "participantId": 1, "timestamp": 3000},
    ]
    rows = parse_timeline("EUW1_1", _timeline(events), 1800, "2026-10-01 00:00:00")
    assert [(e["event_type"], e["item_id"], e["event_seq"]) for e in rows["item_event"]] == [
        ("ITEM_PURCHASED", 1055, 10000), ("ITEM_UNDO", 1055, 10001)]
    assert len(rows["participant_frame"]) == 40   # minutes 10, 15, 20, 25 x 10 players
    assert rows["participant_frame"][0]["creep_score"] == 80


def test_short_games_have_no_frames():
    assert parse_timeline("EUW1_1", _timeline([]), 600, "2026-10-01 00:00:00")["participant_frame"] == []


def test_skill_order():
    # E, Q, W, then E to 5 points, Q to 5, W after: max order E, Q, W.
    slots = [3, 1, 2, 3, 3, 4, 3, 3, 1, 1, 4]
    events = [{"type": "SKILL_LEVEL_UP", "participantId": 2, "levelUpType": "NORMAL", "skillSlot": s,
               "timestamp": i} for i, s in enumerate(slots)]
    skills = parse_timeline("EUW1_1", _timeline(events), 1800, "2026-10-01 00:00:00")["participant_skills"]
    assert skills == [{"match_id": "EUW1_1", "participant_id": 2, "skill_levels": "31233433114",
                       "skill_start": "312", "max_order": "312"}]
