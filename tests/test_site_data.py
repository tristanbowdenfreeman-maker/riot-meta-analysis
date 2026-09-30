"""Checks on the exported JSON in site/data: the numbers the website shows.

These run on whatever the last `python -m riot_meta export` wrote, so they catch problems in the
mart views and the export before the site is published. They skip if nothing has been exported.
"""

import json
import re
from collections import defaultdict

import pytest

from riot_meta.config import PROJECT_ROOT

DATA = PROJECT_ROOT / "site" / "data"
APP_JS = PROJECT_ROOT / "site" / "app.js"
TOLERANCE = 1e-3  # the export rounds to 4 decimal places


def load(name):
    return json.loads((DATA / f"{name}.json").read_text())


@pytest.fixture(scope="module", autouse=True)
def exported():
    if not (DATA / "patch_summary.json").exists() or not load("patch_summary"):
        pytest.skip("nothing exported yet: run python -m riot_meta export")


@pytest.fixture(scope="module")
def matches():
    (patch,) = load("patch_summary")
    return patch["matches"]


STAT_FILES = [
    "tier_list", "champion_matchups", "champion_starter_sets", "champion_boots",
    "champion_core_items", "champion_late_items", "champion_rune_stats", "champion_rune_picks",
    "champion_shard_picks", "champion_spell_stats",
]
TEAM_STAT_FILES = ["objective_win_rate", "objective_count_win_rate", "gold_lead_win_rate", "lane_lead_win_rate"]


@pytest.mark.parametrize("name", STAT_FILES + TEAM_STAT_FILES)
def test_rates_are_proportions_and_win_rate_matches_wins(name):
    for row in load(name):
        assert 0 < row["games"], row
        assert 0 <= row["wins"] <= row["games"], row
        assert row["win_rate"] == pytest.approx(row["wins"] / row["games"], abs=TOLERANCE), row
        for column in ("pick_share", "pick_rate", "ban_rate", "build_rate", "role_share"):
            if column in row:
                assert 0 <= row[column] <= 1 + TOLERANCE, (column, row)


def test_every_id_the_site_shows_has_a_lookup_row():
    champions = {c["champion_id"] for c in load("champions")}
    items = {i["item_id"] for i in load("items")}
    runes = {r["rune_id"] for r in load("runes")}
    trees = {t["tree_id"] for t in load("rune_trees")}
    shards = {s["shard_id"] for s in load("shards")}
    spells = {s["spell_id"] for s in load("spells")}

    for name in STAT_FILES:
        for row in load(name):
            assert row["champion_id"] in champions, (name, row)
    assert {m["opponent_id"] for m in load("champion_matchups")} <= champions
    for row in load("champion_starter_sets"):
        for pair in row["starter_items"].split(","):
            item_id, quantity = map(int, pair.split(":"))
            assert item_id in items and quantity > 0, row
    for name in ("champion_boots", "champion_core_items", "champion_late_items"):
        assert {r["item_id"] for r in load(name)} <= items, name
    for row in load("champion_rune_stats"):
        # The API occasionally sends secondary tree 0 (none): 1 of 39,570 records at 3,957 matches.
        assert row["keystone_id"] in runes and {row["primary_tree_id"], row["secondary_tree_id"]} <= trees | {0}, row
    assert {r["rune_id"] for r in load("champion_rune_picks")} <= runes
    assert {s["shard_id"] for s in load("champion_shard_picks")} <= shards
    for row in load("champion_spell_stats"):
        assert {row["spell_a_id"], row["spell_b_id"]} <= spells, row


def test_each_role_has_two_players_per_match(matches):
    games = defaultdict(int)
    for row in load("tier_list"):
        games[row["role"]] += row["games"]
    assert set(games) == {"TOP", "JUNGLE", "MIDDLE", "BOTTOM", "UTILITY"}
    for role, total in games.items():
        # A handful of players per thousand matches get no role from Riot, so allow a small shortfall.
        assert 2 * matches * 0.995 <= total <= 2 * matches, (role, total)


def test_only_well_sampled_champions_get_a_tier():
    for row in load("tier_list"):
        if row["tier"] is None:
            continue
        assert row["tier"] in {"OP", "1", "2", "3", "4", "5"}, row
        assert row["pick_rate"] >= 0.01 - TOLERANCE and row["role_share"] >= 0.10 - TOLERANCE, row


def test_matchups_mirror_each_other():
    # Every lane result is recorded from both sides: A's wins against B are B's losses against A.
    rows = {(r["champion_id"], r["opponent_id"], r["role"]): r for r in load("champion_matchups")}
    for (champion, opponent, role), row in rows.items():
        mirror = rows[(opponent, champion, role)]
        assert mirror["games"] == row["games"], row
        assert mirror["wins"] == row["games"] - row["wins"], row


@pytest.mark.parametrize("name, group", [
    ("champion_rune_stats", ()),
    ("champion_spell_stats", ()),
    ("champion_shard_picks", ("page_rank", "shard_row")),
])
def test_pick_shares_add_up_to_one(name, group):
    totals = defaultdict(float)
    for row in load(name):
        totals[(row["champion_id"], row["role"], *(row[g] for g in group))] += row["pick_share"]
    for key, total in totals.items():
        assert total == pytest.approx(1, abs=TOLERANCE * 10), (name, key)


def test_late_item_shares_add_up_to_at_least_one():
    # Every player who reached a 4th item built at least one item 4th or later.
    totals = defaultdict(float)
    for row in load("champion_late_items"):
        totals[(row["champion_id"], row["role"])] += row["pick_share"]
    assert totals
    for key, total in totals.items():
        assert total >= 1 - TOLERANCE * 10, key


def test_rune_grid_rows_add_up_to_the_page():
    # On a rune page every player takes exactly one rune in each primary-tree row.
    slot = {r["rune_id"]: r["slot_index"] for r in load("runes")}
    page_games = {(p["champion_id"], p["role"], p["page_rank"]): p["games"] for p in load("champion_rune_stats")}
    rows = defaultdict(int)
    for pick in load("champion_rune_picks"):
        if pick["is_primary_tree"]:
            rows[(pick["champion_id"], pick["role"], pick["page_rank"], slot[pick["rune_id"]])] += pick["games"]
    assert rows
    for (champion, role, page, slot_index), games in rows.items():
        assert games == page_games[(champion, role, page)], (champion, role, page, slot_index)


def test_shards_are_in_the_rows_the_site_draws():
    shard_rows = json.loads(re.search(r"SHARD_ROWS = (\[.*?\]\]);", APP_JS.read_text()).group(1))
    for row in load("champion_shard_picks"):
        assert row["shard_id"] in shard_rows[row["shard_row"] - 1], row


def test_support_starter_sets_include_world_atlas():
    for row in load("champion_starter_sets"):
        if row["role"] == "UTILITY":
            assert "3865:1" in row["starter_items"].split(","), row


def test_data_dragon_version_matches_the_patch():
    (patch,) = load("patch_summary")
    assert load("meta")["ddragon_version"].startswith(patch["patch"] + ".")


def test_core_item_shares_add_up_to_at_most_three():
    # Each player has up to three core items (1st to 3rd), so the shares add up to 3 or less.
    totals = defaultdict(float)
    for row in load("champion_core_items"):
        assert 1 <= row["avg_slot"] <= 3, row
        totals[(row["champion_id"], row["role"])] += row["pick_share"]
    assert totals
    assert all(total <= 3 + TOLERANCE * 10 for total in totals.values())


def test_tier_list_prior_and_margin_of_error():
    rows = load("tier_list")
    (prior,) = {round(r["prior_games"], 2) for r in rows}   # one prior per patch
    assert 0 < prior <= 2500
    for row in rows:
        assert row["adjusted_win_rate"] == pytest.approx((row["wins"] + prior / 2) / (row["games"] + prior), abs=TOLERANCE), row
        # The adjustment only ever pulls a win rate towards 50%.
        assert abs(row["adjusted_win_rate"] - 0.5) <= abs(row["win_rate"] - 0.5) + TOLERANCE, row
        expected = 1.96 * (row["win_rate"] * (1 - row["win_rate"]) / row["games"]) ** 0.5
        assert row["win_rate_moe"] == pytest.approx(expected, abs=TOLERANCE), row


def test_sides_split_every_match(matches):
    sides = {s["side"]: s for s in load("side_win_rate")}
    assert set(sides) == {"Blue", "Red"}
    assert sides["Blue"]["games"] == sides["Red"]["games"] == matches
    assert sides["Blue"]["wins"] + sides["Red"]["wins"] == matches


def test_ban_bands_cover_every_champion():
    bans = load("ban_vs_win")
    bands = load("ban_band_win_rate")
    assert sum(b["champions"] for b in bands) == len(bans)
    assert sum(b["games"] for b in bands) == sum(b["games"] for b in bans)


def test_winner_gaps_cover_every_role_and_stat():
    gaps = load("role_win_gap")
    assert {(g["role"], g["metric_order"]) for g in gaps} == {
        (role, metric) for role in ("TOP", "JUNGLE", "MIDDLE", "BOTTOM", "UTILITY") for metric in range(1, 7)
    }
    for g in gaps:
        assert g["gap"] == pytest.approx(g["winners"] / g["losers"] - 1, abs=TOLERANCE), g


def test_data_volume_agrees_with_the_other_files(matches):
    (volume,) = load("data_volume")
    (patch,) = load("patch_summary")
    assert volume["patch"] == patch["patch"]
    assert volume["matches"] == matches
    assert volume["player_records"] == patch["player_records"]
    assert volume["timelines"] <= matches
    # At most ten bans per match, and six runes (four primary, two secondary) per player.
    assert volume["bans"] <= matches * 10
    assert volume["rune_choices"] == volume["player_records"] * 6
    assert volume["item_events"] > volume["timelines"] and volume["raw_json_mb"] > 0
    # Objective rows: a few per team per match. Gold frames: ten players at up to four minute marks.
    assert 0 < volume["objective_rows"] <= matches * 2 * 10
    assert 0 < volume["gold_frames"] <= volume["timelines"] * 10 * 4


def test_objectives_are_taken_first_once_a_match(matches):
    firsts = load("objective_win_rate")
    names = set(re.findall(r"^  (\w+): \[", re.search(r"const OBJECTIVES = \{(.*?)\n\};", APP_JS.read_text(), re.S).group(0), re.M))
    for row in firsts:
        assert row["games"] <= matches, row
        assert row["taken_share"] == pytest.approx(row["games"] / matches, abs=TOLERANCE), row
        assert row["objective"] in names, f"app.js has no name for {row['objective']}"


def test_objective_counts_cover_both_teams_of_every_match(matches):
    games = defaultdict(int)
    for row in load("objective_count_win_rate"):
        games[row["objective"]] += row["games"]
    assert games and all(total == 2 * matches for total in games.values()), games


def test_gold_lead_bands_are_contiguous_and_count_each_match_once(matches):
    by_minute = defaultdict(list)
    for row in load("gold_lead_win_rate"):
        by_minute[row["minute"]].append(row)
    assert set(by_minute) <= {10, 15, 20, 25}
    for minute, rows in by_minute.items():
        rows.sort(key=lambda r: r["band_min"])
        assert rows[0]["band_min"] == 0 and rows[-1]["band_max"] is None, minute
        assert all(a["band_max"] == b["band_min"] for a, b in zip(rows, rows[1:])), minute
        assert sum(r["games"] for r in rows) <= matches, minute
    # Fewer games are still running at each later minute.
    totals = [sum(r["games"] for r in by_minute[m]) for m in sorted(by_minute)]
    assert totals == sorted(totals, reverse=True)


def test_lane_leads_count_each_match_once_per_role(matches):
    for row in load("lane_lead_win_rate"):
        assert row["role"] in {"TOP", "JUNGLE", "MIDDLE", "BOTTOM", "UTILITY"}, row
        assert row["games"] <= matches, row
