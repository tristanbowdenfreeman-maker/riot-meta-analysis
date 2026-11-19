-- Key: match_id, participant_id.
CREATE TABLE IF NOT EXISTS riot_fact.match_participant (
    match_id             STRING NOT NULL,
    participant_id       INT64  NOT NULL,  -- 1-10
    puuid                STRING NOT NULL,
    team_id              INT64  NOT NULL,  -- 100 = blue, 200 = red
    champion_id          INT64  NOT NULL,
    team_position        STRING,           -- TOP | JUNGLE | MIDDLE | BOTTOM | UTILITY
    win                  BOOL   NOT NULL,
    kills                INT64  NOT NULL,
    deaths               INT64  NOT NULL,
    assists              INT64  NOT NULL,
    gold_earned          INT64  NOT NULL,
    creep_score          INT64  NOT NULL,  -- lane minions + jungle monsters
    vision_score         INT64  NOT NULL,
    damage_to_champions  INT64  NOT NULL,
    summoner1_id         INT64  NOT NULL,
    summoner2_id         INT64  NOT NULL,
    primary_tree_id      INT64,
    secondary_tree_id    INT64,
    keystone_id          INT64,
    shard_offense_id     INT64,            -- perks.statPerks: top, middle and bottom shard rows
    shard_flex_id        INT64,
    shard_defense_id     INT64
);
