"""Raw JSON -> fact and dimension rows, one dict per row, ready to load into BigQuery.

These are plain functions of the JSON, with no database, so tests can check them on small
hand-written payloads. Each table's columns are listed in sql/1_model.
"""

import json
from collections import defaultdict
from datetime import datetime, timezone

ROLES = ("TOP", "JUNGLE", "MIDDLE", "BOTTOM", "UTILITY")
SHOP_EVENTS = ("ITEM_PURCHASED", "ITEM_SOLD", "ITEM_UNDO")
FRAME_MINUTES = (10, 15, 20, 25)
REMAKE_SECONDS = 300
# Only games of 11+ minutes have a minute-10 frame worth keeping; shorter ones are remakes or
# early surrenders.
MIN_FRAME_SECONDS = 660

# Stat shards: the three small bonuses under the rune trees. They are not in Data Dragon's
# runesReforged.json, so the list is kept here. Some IDs appear in more than one row.
STAT_SHARDS = [
    (5008, "Adaptive Force", "perk-images/StatMods/StatModsAdaptiveForceIcon.png"),
    (5005, "Attack Speed", "perk-images/StatMods/StatModsAttackSpeedIcon.png"),
    (5007, "Ability Haste", "perk-images/StatMods/StatModsCDRScalingIcon.png"),
    (5010, "Move Speed", "perk-images/StatMods/StatModsMovementSpeedIcon.png"),
    (5001, "Health Scaling", "perk-images/StatMods/StatModsHealthScalingIcon.png"),
    (5011, "Health", "perk-images/StatMods/StatModsHealthPlusIcon.png"),
    (5013, "Tenacity and Slow Resist", "perk-images/StatMods/StatModsTenacityIcon.png"),
    (5002, "Armor", "perk-images/StatMods/StatModsArmorIcon.png"),
    (5003, "Magic Resist", "perk-images/StatMods/StatModsMagicResIcon.png"),
]


def patch_of(version: str) -> str:
    """'16.19.1' (a Data Dragon or game version) -> '16.19', the patch as fact.match stores it."""
    return ".".join(version.split(".")[:2])


def _utc(epoch_ms: int) -> str:
    """Epoch milliseconds -> a BigQuery DATETIME (UTC, whole seconds)."""
    return datetime.fromtimestamp(epoch_ms // 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def _fill_blank_roles(players: list[dict]) -> None:
    """Riot leaves teamPosition blank for the odd player, usually one who left early. When they're
    the only blank on a team whose other four hold four different roles, they get the fifth."""
    teams = defaultdict(list)
    for p in players:
        teams[p["team_id"]].append(p)
    for team in teams.values():
        blanks = [p for p in team if p["team_position"] is None]
        taken = {p["team_position"] for p in team} - {None}
        if len(blanks) == 1 and len(taken) == 4:
            blanks[0]["team_position"] = next(r for r in ROLES if r not in taken)


def parse_match(match_id: str, text: str, sample_tier: str | None) -> dict[str, list[dict]]:
    """A match-v5 match -> rows for fact.match, match_participant, participant_item,
    participant_rune, match_ban and team_objective. sample_tier is the tier of the player whose
    history the match came from."""
    info = json.loads(text)["info"]
    match = {
        "match_id": match_id,
        "patch": patch_of(info["gameVersion"]),
        "game_version": info["gameVersion"],
        "game_start_utc": _utc(info["gameCreation"]),
        "duration_s": info["gameDuration"],
        "queue_id": info["queueId"],
        "sample_tier": sample_tier,
        "is_remake": info["gameDuration"] < REMAKE_SECONDS,
    }

    participants, items, runes = [], [], []
    for p in info["participants"]:
        perks = p.get("perks") or {}
        styles = perks.get("styles") or []
        stat_perks = perks.get("statPerks") or {}
        primary = styles[0] if styles else {}
        participants.append({
            "match_id": match_id,
            "participant_id": p["participantId"],
            "puuid": p["puuid"],
            "team_id": p["teamId"],
            "champion_id": p["championId"],
            "team_position": p.get("teamPosition") or None,
            "win": bool(p["win"]),
            "kills": p["kills"],
            "deaths": p["deaths"],
            "assists": p["assists"],
            "gold_earned": p["goldEarned"],
            "creep_score": p["totalMinionsKilled"] + p["neutralMinionsKilled"],
            "vision_score": p["visionScore"],
            "damage_to_champions": p["totalDamageDealtToChampions"],
            "summoner1_id": p["summoner1Id"],
            "summoner2_id": p["summoner2Id"],
            "primary_tree_id": primary.get("style"),
            "secondary_tree_id": styles[1].get("style") if len(styles) > 1 else None,
            "keystone_id": (primary.get("selections") or [{}])[0].get("perk"),
            "shard_offense_id": stat_perks.get("offense"),
            "shard_flex_id": stat_perks.get("flex"),
            "shard_defense_id": stat_perks.get("defense"),
        })
        # The final inventory, item0..item6 as rows; 0 means an empty slot.
        for slot in range(7):
            item_id = p.get(f"item{slot}") or 0
            if item_id > 0:
                items.append({"match_id": match_id, "participant_id": p["participantId"], "slot": slot,
                              "item_id": item_id})
        # perks.styles[0] is the primary tree, styles[1] the secondary.
        for style_index, style in enumerate(styles):
            for selection_index, selection in enumerate(style.get("selections") or []):
                runes.append({
                    "match_id": match_id,
                    "participant_id": p["participantId"],
                    "rune_id": selection["perk"],
                    "tree_id": style["style"],
                    "is_primary_tree": style_index == 0,
                    "selection_index": selection_index,
                })
    _fill_blank_roles(participants)

    bans, objectives = [], []
    for team in info["teams"]:
        for ban in team.get("bans") or []:
            if ban["championId"] > 0:  # -1 means the team skipped that ban
                bans.append({"match_id": match_id, "team_id": team["teamId"], "pick_turn": ban["pickTurn"],
                             "champion_id": ban["championId"]})
        # objectives: {"baron": {"first": true, "kills": 1}, "dragon": {...}, ...}; 'champion' is kills,
        # so its first is first blood.
        for objective, value in (team.get("objectives") or {}).items():
            objectives.append({"match_id": match_id, "team_id": team["teamId"], "objective": objective,
                               "is_first": bool(value["first"]), "kills": value["kills"]})

    return {
        "match": [match],
        "match_participant": participants,
        "participant_item": items,
        "participant_rune": runes,
        "match_ban": bans,
        "team_objective": objectives,
    }


def _skills(match_id: str, level_ups: dict[int, list[int]]) -> list[dict]:
    """Skill order rows from each player's level-ups in order. Slots: 1-3 = Q, W, E; 4 = R.
    skill_start is the first three. max_order is Q, W and E by points after 11 level-ups (most
    first; a tie goes to the skill that got there first), None when the player didn't reach 11."""
    rows = []
    for participant_id, slots in sorted(level_ups.items()):
        points, last_point = defaultdict(int), {}
        for order, slot in enumerate(slots[:11], start=1):
            if slot <= 3:
                points[slot] += 1
                last_point[slot] = order
        max_order = "".join(str(s) for s in sorted(points, key=lambda s: (-points[s], last_point[s])))
        skill_levels = "".join(str(s) for s in slots[:18])
        rows.append({
            "match_id": match_id,
            "participant_id": participant_id,
            "skill_levels": skill_levels,
            "skill_start": skill_levels[:3],
            "max_order": max_order if len(slots) >= 11 else None,
        })
    return rows


def parse_timeline(match_id: str, text: str, duration_s: int, loaded_at: str) -> dict[str, list[dict]]:
    """A match-v5 timeline -> rows for fact.match_timeline, item_event, participant_frame and
    participant_skills. duration_s is the match's length, from fact.match."""
    frames = json.loads(text)["info"]["frames"]
    item_events, frame_rows = [], []
    level_ups = defaultdict(list)

    # info.frames[] is one frame per minute; each has an events[] array in time order.
    # participantId 0 is the game itself (e.g. items granted at the start) and is skipped.
    for frame_index, frame in enumerate(frames):
        for event_index, event in enumerate(frame.get("events") or []):
            kind = event.get("type")
            participant_id = event.get("participantId") or 0
            if not 1 <= participant_id <= 10:
                continue
            if kind in SHOP_EVENTS:
                # For an undo, the item is the one whose purchase was reverted (beforeId). An undo
                # with beforeId 0 reverts a sale rather than a purchase, and is skipped.
                item_id = (event.get("beforeId") if kind == "ITEM_UNDO" else event.get("itemId")) or 0
                if item_id > 0:
                    item_events.append({
                        "match_id": match_id,
                        "event_seq": frame_index * 10000 + event_index,  # unique and in order
                        "participant_id": participant_id,
                        "timestamp_ms": event["timestamp"],
                        "event_type": kind,
                        "item_id": item_id,
                    })
            elif (kind == "SKILL_LEVEL_UP" and event.get("levelUpType") == "NORMAL"
                  and 1 <= (event.get("skillSlot") or 0) <= 4):
                level_ups[participant_id].append(event["skillSlot"])

    # Gold, XP and creep score at minutes 10, 15, 20 and 25 (frame n is minute n).
    if duration_s >= MIN_FRAME_SECONDS:
        for minute in FRAME_MINUTES:
            if minute >= len(frames):
                break
            for pf in frames[minute]["participantFrames"].values():
                if 1 <= pf["participantId"] <= 10:
                    frame_rows.append({
                        "match_id": match_id,
                        "minute": minute,
                        "participant_id": pf["participantId"],
                        "total_gold": pf["totalGold"],
                        "xp": pf["xp"],
                        "creep_score": pf["minionsKilled"] + pf["jungleMinionsKilled"],
                    })

    return {
        "match_timeline": [{"match_id": match_id, "loaded_at": loaded_at}],
        "item_event": item_events,
        "participant_frame": frame_rows,
        "participant_skills": _skills(match_id, level_ups),
    }


def _item_class(item: dict) -> str:
    """Items that build into something else are components. Of the rest, anything worth at least
    1,000 gold is a completed item; cheaper finished items (Doran's, Dark Seal) are starters."""
    tags = item.get("tags") or []
    total_gold = item["gold"]["total"]
    if "Trinket" in tags:
        return "Trinket"
    if "Consumable" in tags or item.get("consumed"):
        return "Consumable"
    if "Boots" in tags and total_gold > 300:
        return "Boots"
    if item.get("into") is not None:
        return "Component"
    return "Completed" if total_gold >= 1000 else "Starter"


def parse_ddragon(version: str, champion: str, item: str, runes: str, summoner: str) -> dict[str, list[dict]]:
    """Data Dragon's champion.json, item.json, runesReforged.json and summoner.json -> rows for
    every dim table."""
    champions = [
        {"champion_id": int(c["key"]), "champion_key": c["id"], "champion_name": c["name"],
         "primary_class": (c.get("tags") or [None])[0], "ddragon_version": version}
        for c in json.loads(champion)["data"].values()
    ]
    items = [
        {"item_id": int(key), "item_name": i["name"], "total_gold": i["gold"]["total"],
         "item_class": _item_class(i), "ddragon_version": version}
        for key, i in json.loads(item)["data"].items()
    ]
    trees = json.loads(runes)
    rune_trees = [
        {"tree_id": t["id"], "tree_name": t["name"], "icon_path": t["icon"], "ddragon_version": version}
        for t in trees
    ]
    rune_rows = [
        {"rune_id": r["id"], "rune_name": r["name"], "tree_id": t["id"], "slot_index": slot_index,
         "icon_path": r["icon"], "ddragon_version": version}
        for t in trees
        for slot_index, slot in enumerate(t["slots"])
        for r in slot["runes"]
    ]
    spells = [
        {"spell_id": int(s["key"]), "spell_key": s["id"], "spell_name": s["name"], "ddragon_version": version}
        for s in json.loads(summoner)["data"].values()
    ]
    shards = [{"shard_id": i, "shard_name": n, "icon_path": p} for i, n, p in STAT_SHARDS]
    return {
        "champion": champions,
        "item": items,
        "rune_tree": rune_trees,
        "rune": rune_rows,
        "summoner_spell": spells,
        "stat_shard": shards,
    }
