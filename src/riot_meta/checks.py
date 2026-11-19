"""Data-quality checks: the BigQuery ones (sql/3_checks) plus the ones on the local store."""

from riot_meta.warehouse import Warehouse, sql_files

# (order, name, is_blocking, query on the local store)
LOCAL_CHECKS = [
    (5, "raw matches not yet transformed", 1,
     "SELECT COUNT(*) FROM match_raw WHERE loaded_at IS NULL"),
    (6, "queue rows marked done without raw JSON", 1,
     "SELECT COUNT(*) FROM match_queue AS q WHERE q.status = 'done' "
     "AND NOT EXISTS (SELECT 1 FROM match_raw AS r WHERE r.match_id = q.match_id)"),
    (8, "raw timelines not yet transformed", 1,
     "SELECT COUNT(*) FROM timeline_raw WHERE status = 'done' AND loaded_at IS NULL"),
    (21, "queue rows that failed to download", 0,
     "SELECT COUNT(*) FROM match_queue WHERE status = 'failed'"),
    (22, "timelines that failed to download", 0,
     "SELECT COUNT(*) FROM timeline_raw WHERE status = 'failed'"),
]


def run(conn, warehouse: Warehouse) -> list[dict]:
    """Every check as {check_name, is_blocking, failures}, in order. Needs the marts built."""
    rows = warehouse.query(sql_files("3_checks")[0].read_text())
    rows += [{"check_order": order, "check_name": name, "is_blocking": blocking,
              "failures": conn.execute(query).fetchone()[0]}
             for order, name, blocking, query in LOCAL_CHECKS]
    rows.sort(key=lambda r: r["check_order"])
    return [{k: r[k] for k in ("check_name", "is_blocking", "failures")} for r in rows]
