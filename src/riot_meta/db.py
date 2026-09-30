"""SQL Server connections and the script runner for sql/*.sql."""

import re
from pathlib import Path

import pymssql
from sqlalchemy import URL, Engine, create_engine

from riot_meta.config import PROJECT_ROOT, Settings

SQL_DIR = PROJECT_ROOT / "sql"
_GO_LINE = re.compile(r"^\s*GO\s*;?\s*$", re.IGNORECASE | re.MULTILINE)


def connect(settings: Settings, database: str | None = None, autocommit: bool = True) -> pymssql.Connection:
    return pymssql.connect(
        server=settings.mssql_host,
        port=settings.mssql_port,
        user=settings.mssql_user,
        password=settings.mssql_password,
        database=database or settings.mssql_database,
        autocommit=autocommit,
    )


def engine(settings: Settings) -> Engine:
    """SQLAlchemy engine, used by pandas for the Parquet export."""
    return create_engine(
        URL.create(
            "mssql+pymssql",
            username=settings.mssql_user,
            password=settings.mssql_password,
            host=settings.mssql_host,
            port=settings.mssql_port,
            database=settings.mssql_database,
        )
    )


def split_batches(script: str) -> list[str]:
    """Split a T-SQL script on GO lines, the way sqlcmd and SSMS do."""
    return [batch.strip() for batch in _GO_LINE.split(script) if batch.strip()]


def run_scripts(settings: Settings, sql_dir: Path = SQL_DIR) -> None:
    """Run every sql/NN_*.sql file in order. 00_* runs against master (it creates the database)."""
    for path in sorted(sql_dir.glob("[0-9][0-9]_*.sql")):
        database = "master" if path.name.startswith("00_") else settings.mssql_database
        with connect(settings, database=database) as conn:
            cursor = conn.cursor()
            for batch in split_batches(path.read_text()):
                cursor.execute(batch)
        print(f"  ran {path.name}")
