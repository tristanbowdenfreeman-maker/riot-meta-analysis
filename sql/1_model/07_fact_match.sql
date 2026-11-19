-- BigQuery doesn't enforce primary or foreign keys; the data checks (sql/3_checks) test them.
-- Key: match_id.
CREATE TABLE IF NOT EXISTS riot_fact.match (
    match_id        STRING   NOT NULL,
    patch           STRING   NOT NULL,  -- major.minor of game_version, e.g. '15.19'
    game_version    STRING   NOT NULL,
    game_start_utc  DATETIME NOT NULL,
    duration_s      INT64    NOT NULL,
    queue_id        INT64    NOT NULL,  -- 420 = ranked solo/duo
    sample_tier     STRING,             -- tier of the player whose history the match came from
    is_remake       BOOL     NOT NULL   -- games under 5 minutes
);
