-- How many valid matches each patch has so far. The collector stops queueing a patch once this
-- reaches the cap (MATCHES_PER_PATCH, 30,000 by default).
CREATE OR ALTER VIEW etl.v_patch_progress
AS
SELECT p.patch,
       p.status,
       p.started_utc,
       p.live_since_utc,
       (SELECT COUNT(*)
        FROM fact.match AS m
        WHERE m.patch = p.patch
          AND m.queue_id = 420
          AND m.is_remake = 0
          AND m.match_id LIKE 'EUW1[_]%') AS matches
FROM etl.patch AS p;
GO
