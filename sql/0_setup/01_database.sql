-- Runs against master. Creates the project database if it does not exist yet.
IF DB_ID(N'RiotMeta') IS NULL
    CREATE DATABASE RiotMeta;
GO
