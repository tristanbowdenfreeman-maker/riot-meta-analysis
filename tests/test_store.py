"""The local store, transform and patch logic, with a fake BigQuery that keeps rows in memory."""

import pytest

from riot_meta import patches, store, transform
from riot_meta.warehouse import MATCH_TABLES
from tests.test_parse import _match, _timeline


class FakeWarehouse:
    def __init__(self, fail_on=None):
        self.tables = {}
        self.fail_on = fail_on

    def load(self, table, rows, replace=False):
        if table == self.fail_on:
            self.fail_on = None
            raise RuntimeError("load stopped")
        self.tables[table] = ([] if replace else self.tables.get(table, [])) + rows

    def remove_matches(self, tables, match_ids):
        for t in tables:
            key = f"riot_fact.{t}"
            self.tables[key] = [r for r in self.tables.get(key, []) if r["match_id"] not in match_ids]

    def remove_patches(self, patch_list):
        ids = {r["match_id"] for r in self.tables.get("riot_fact.match", []) if r["patch"] in patch_list}
        for key in [k for k in self.tables if k.startswith("riot_fact.")]:
            self.tables[key] = [r for r in self.tables[key] if r["match_id"] not in ids]
        return len(ids)


@pytest.fixture
def conn(tmp_path):
    c = store.connect(tmp_path / "riot.sqlite")
    with c:
        for i in range(3):
            c.execute("INSERT INTO match_queue (match_id, source_puuid, source_tier, status) VALUES (?, 'p', 'GOLD', 'done')",
                      (f"EUW1_{i}",))
            c.execute("INSERT INTO match_raw (match_id, payload_gz) VALUES (?, ?)", (f"EUW1_{i}", store.compress(_match())))
            c.execute("INSERT INTO timeline_raw (match_id, status, payload_gz) VALUES (?, 'done', ?)",
                      (f"EUW1_{i}", store.compress(_timeline([]))))
    return c


def test_transform_loads_everything_once(conn):
    wh = FakeWarehouse()
    assert transform.transform(conn, wh) == (3, 3)
    assert len(wh.tables["riot_fact.match"]) == 3
    assert len(wh.tables["riot_fact.match_participant"]) == 30
    assert transform.transform(conn, wh) == (0, 0)
    assert conn.execute("SELECT patch, queue_id FROM match_raw LIMIT 1").fetchone() == ("16.19", 420)


def test_half_loaded_batch_is_undone_and_reloaded(conn):
    wh = FakeWarehouse(fail_on="riot_fact.participant_rune")
    with pytest.raises(RuntimeError):
        transform.transform(conn, wh)
    assert len(wh.tables["riot_fact.match"]) == 3            # some tables got the batch...
    assert conn.execute("SELECT COUNT(*) FROM load_batch").fetchone()[0] == 1
    transform.transform(conn, wh)                            # ...so it's taken out and loaded again
    for table in MATCH_TABLES:
        ids = [r["match_id"] for r in wh.tables[f"riot_fact.{table}"]]
        assert len(set(ids)) == 3
    assert len(wh.tables["riot_fact.match"]) == 3
    assert conn.execute("SELECT COUNT(*) FROM load_batch").fetchone()[0] == 0


def test_patch_rollover(conn):
    wh = FakeWarehouse()
    transform.transform(conn, wh)
    assert patches.start(conn, wh, "16.19") == 0             # first patch goes live at once
    assert conn.execute("SELECT status FROM patch").fetchall() == [("live",)]
    patches.start(conn, wh, "16.20")
    assert patches.promote(conn, wh, "euw1", match_cap=1) == (None, 0)   # 16.20 has no matches yet
    with conn:  # pretend 16.20 filled up
        conn.execute("UPDATE match_raw SET patch = '16.20' WHERE match_id = 'EUW1_0'")
    wh.tables["riot_fact.match"][0]["patch"] = "16.20"
    promoted, deleted = patches.promote(conn, wh, "euw1", match_cap=1)
    assert promoted == "16.20"
    assert deleted == 2                                       # 16.19's matches left BigQuery...
    assert conn.execute("SELECT COUNT(*) FROM match_raw").fetchone()[0] == 1   # ...and the store
    assert wh.tables["riot_etl.patch"] == [
        {"patch": "16.20", "status": "live", "started_utc": wh.tables["riot_etl.patch"][0]["started_utc"],
         "live_since_utc": wh.tables["riot_etl.patch"][0]["live_since_utc"]}]
