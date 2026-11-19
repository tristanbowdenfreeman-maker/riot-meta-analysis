"""BigQuery: the star schema (riot_dim, riot_fact), the marts (riot_mart) and the runner for the
scripts in sql/.

Written for the free sandbox, which allows no DML (INSERT, UPDATE, DELETE, MERGE). So rows go in
through load jobs, which are free and append whole batches, and rows come out by rebuilding a
table without them (CREATE OR REPLACE TABLE ... AS SELECT). Every query has a cap on the bytes it
may scan (BQ_MAX_GB_BILLED), so a mistake fails instead of using up the free 1 TB a month.
"""

from datetime import datetime, timedelta, timezone
from pathlib import Path

from google.cloud import bigquery

from riot_meta.config import PROJECT_ROOT, Settings

SQL_DIR = PROJECT_ROOT / "sql"
DATASETS = ("riot_dim", "riot_fact", "riot_mart", "riot_etl")
# Fact tables filled from each kind of raw JSON. riot_fact.match comes first and goes last: the
# others are found through it when a patch is deleted.
MATCH_TABLES = ("match", "match_participant", "participant_item", "participant_rune", "match_ban", "team_objective")
TIMELINE_TABLES = ("match_timeline", "item_event", "participant_frame", "participant_skills")
# Sandbox tables expire 60 days after they were made; each build pushes that back to this.
TABLE_LIFETIME = timedelta(days=59)
_SQL_TYPES = {"INTEGER": "INT64", "FLOAT": "FLOAT64", "BOOLEAN": "BOOL"}


def sql_files(folder: str, sql_dir: Path = SQL_DIR) -> list[Path]:
    """The scripts in one sql/ folder, in the order they run."""
    return sorted((sql_dir / folder).glob("[0-9][0-9]_*.sql"))


def _param(name: str, value) -> bigquery.ArrayQueryParameter | bigquery.ScalarQueryParameter:
    if isinstance(value, (list, tuple)):
        return bigquery.ArrayQueryParameter(name, "STRING", list(value))
    kind = "INT64" if isinstance(value, int) else "STRING"
    return bigquery.ScalarQueryParameter(name, kind, value)


class Warehouse:
    def __init__(self, settings: Settings, client: bigquery.Client | None = None):
        self.settings = settings
        self.client = client or bigquery.Client(project=settings.bq_project, location=settings.bq_location)
        self.bytes_billed = 0  # added up over this run, for the cost line at the end

    def _job_config(self, params: dict | None) -> bigquery.QueryJobConfig:
        return bigquery.QueryJobConfig(
            maximum_bytes_billed=self.settings.bq_max_gb_billed * 10**9,
            query_parameters=[_param(k, v) for k, v in (params or {}).items()],
        )

    def query(self, sql: str, params: dict | None = None) -> list[dict]:
        """Run a query (or a script of several statements) and return the last result's rows."""
        job = self.client.query(sql, job_config=self._job_config(params))
        rows = [dict(row) for row in job.result()]
        self.bytes_billed += job.total_bytes_billed or 0
        return rows

    def run_file(self, path: Path) -> None:
        self.query(path.read_text().replace("{location}", self.settings.bq_location))

    def setup(self) -> None:
        """Create the datasets and the dim, fact and etl tables. Safe to run again."""
        for path in sql_files("0_setup") + sql_files("1_model"):
            self.run_file(path)
            print(f"  ran {path.parent.name}/{path.name}")

    def load(self, table: str, rows: list[dict], replace: bool = False) -> None:
        """Append rows to a table with a load job (free, unlike streaming), or replace its contents.
        The table's own schema is used, so a row with a missing NOT NULL value fails the load."""
        if not rows and not replace:
            return
        config = bigquery.LoadJobConfig(
            schema=self.client.get_table(table).schema,
            source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
            write_disposition="WRITE_TRUNCATE" if replace else "WRITE_APPEND",
        )
        self.client.load_table_from_json(rows, table, job_config=config).result()

    def _rebuild_without(self, table: str, condition: str, params: dict) -> None:
        """Rebuild a table without the rows matching `condition`: the sandbox's DELETE. The column
        list keeps the table's types and NOT NULLs."""
        columns = ", ".join(
            f"{f.name} {_SQL_TYPES.get(f.field_type, f.field_type)}{' NOT NULL' if f.mode == 'REQUIRED' else ''}"
            for f in self.client.get_table(table).schema
        )
        self.query(f"CREATE OR REPLACE TABLE {table} ({columns}) AS SELECT * FROM {table} WHERE NOT ({condition})",
                   params)

    def remove_matches(self, tables: tuple[str, ...], match_ids: list[str]) -> None:
        """Take these matches out of the given fact tables (a load that stopped part-way)."""
        for table in tables:
            self._rebuild_without(f"riot_fact.{table}", "match_id IN UNNEST(@ids)", {"ids": match_ids})

    def remove_patches(self, patches: list[str]) -> int:
        """Take every match of these patches out of the fact tables. Returns how many there were."""
        found = self.query("SELECT COUNT(*) AS n FROM riot_fact.match WHERE patch IN UNNEST(@patches)",
                           {"patches": patches})[0]["n"]
        if found:
            in_patch = "match_id IN (SELECT match_id FROM riot_fact.match WHERE patch IN UNNEST(@patches))"
            for table in MATCH_TABLES[1:] + TIMELINE_TABLES:
                self._rebuild_without(f"riot_fact.{table}", in_patch, {"patches": patches})
            self._rebuild_without("riot_fact.match", "patch IN UNNEST(@patches)", {"patches": patches})
        return found

    def refresh_expiry(self) -> None:
        """Push back the sandbox's 60-day expiry on every table, so tables that are only appended
        to (the facts) don't disappear while the project is running."""
        expires = datetime.now(timezone.utc) + TABLE_LIFETIME
        for dataset in DATASETS:
            for item in self.client.list_tables(dataset):
                table = self.client.get_table(item.reference)
                table.expires = expires
                self.client.update_table(table, ["expires"])

    def table_names(self, dataset: str) -> list[str]:
        return [t.table_id for t in self.client.list_tables(dataset)]
