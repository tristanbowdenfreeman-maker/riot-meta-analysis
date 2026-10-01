-- Keep SQL Server light enough to run on a laptop next to everything else.

-- Simple recovery: the log is reused after every load instead of growing until it is backed up.
-- Everything here can be rebuilt from the raw JSON, so point-in-time restores aren't needed.
ALTER DATABASE RiotMeta SET RECOVERY SIMPLE;
GO

-- By default SQL Server keeps as much memory as it can for its cache. 2 GB is plenty for one
-- patch of 30,000 matches; anything not in memory is read from disk.
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'max server memory (MB)', 2048;
RECONFIGURE;
GO
