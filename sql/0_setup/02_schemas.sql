-- One schema per layer:
--   stg  : raw API payloads and the fetch queue, exactly as received
--   dim  : lookup tables (champions, items, runes, summoner spells) from Data Dragon
--   fact : match data parsed out of the raw JSON
--   mart : reporting views the dashboard reads
--   etl  : stored procedures and data-quality checks
IF SCHEMA_ID(N'stg')  IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'dim')  IS NULL EXEC (N'CREATE SCHEMA dim');
IF SCHEMA_ID(N'fact') IS NULL EXEC (N'CREATE SCHEMA fact');
IF SCHEMA_ID(N'mart') IS NULL EXEC (N'CREATE SCHEMA mart');
IF SCHEMA_ID(N'etl')  IS NULL EXEC (N'CREATE SCHEMA etl');
GO
