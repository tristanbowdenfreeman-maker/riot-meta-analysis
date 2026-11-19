-- One row per match whose timeline has been parsed. Build-order stats only use these matches,
-- so a missing timeline can't be mistaken for a player who bought nothing.
CREATE TABLE IF NOT EXISTS riot_fact.match_timeline (
    match_id   STRING   NOT NULL,
    loaded_at  DATETIME NOT NULL
);
