-- Key: match_id, team_id, pick_turn.
CREATE TABLE IF NOT EXISTS riot_fact.match_ban (
    match_id     STRING NOT NULL,
    team_id      INT64  NOT NULL,
    pick_turn    INT64  NOT NULL,
    champion_id  INT64  NOT NULL
);
