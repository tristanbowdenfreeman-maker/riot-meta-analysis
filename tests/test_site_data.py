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
    "tier_list", "champion_matchups", "champion_item_stats", "champion_starter_sets", "champion_boots",
    "champion_core_builds", "champion_late_items", "champion_rune_stats", "champion_rune_picks",
    "champion_shard_picks", "champion_spell_stats",
]


@pytest.mark.parametrize("name", STAT_FILES)
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
    for row in load("champion_core_builds"):
        assert {row["item1_id"], row["item2_id"], row["item3_id"]} <= items, row
    for name in ("champion_boots", "champion_late_items", "champion_item_stats"):
        assert {r["item_id"] for r in load(name)} <= items, name
    for row in load("champion_rune_stats"):
        assert row["keystone_id"] in runes and {row["primary_tree_id"], row["secondary_tree_id"]} <= trees, row
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


def test_late_item_shares_add_up_to_one_to_three_items():
    # Every player who reached a 4th item built one to three items 4th to 6th.
    totals = defaultdict(float)
    for row in load("champion_late_items"):
        totals[(row["champion_id"], row["role"])] += row["pick_share"]
    assert totals
    for key, total in totals.items():
        assert 1 - TOLERANCE * 10 <= total <= 3 + TOLERANCE * 10, key


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
