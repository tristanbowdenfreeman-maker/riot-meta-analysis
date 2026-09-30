# 1. SQL Server 2022 in Docker for the database

**Status:** accepted, 2026-09-30

## Context

The project exists to show T-SQL skills for analyst and BI roles, where SQL Server is the most
common database in job adverts. It is developed on an Apple Silicon Mac. SQL Server has no macOS
version and no ARM build, and Azure SQL Edge (the old ARM option) was retired in September 2025.

## Decision

Run SQL Server 2022 Developer edition in Docker Desktop, emulated with Rosetta
(`platform: linux/amd64` in `docker-compose.yml`). Python connects with `pymssql`, which needs no
separate ODBC driver install.

## Consequences

- All modelling is real T-SQL: `OPENJSON`, stored procedures, window functions.
- Rosetta emulation is slower than native, which is fine at 30,000 matches.
- Developer edition is licensed for development and testing only, which matches this use.
- SQLite, PostgreSQL and DuckDB were rejected because none of them is T-SQL.
