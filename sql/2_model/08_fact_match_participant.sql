IF OBJECT_ID(N'fact.match_participant') IS NULL
CREATE TABLE fact.match_participant (
    match_id             VARCHAR(30)  NOT NULL CONSTRAINT FK_fact_match_participant_match REFERENCES fact.match (match_id),
    participant_id       TINYINT      NOT NULL,   -- 1-10
    puuid                VARCHAR(100) NOT NULL,
    team_id              SMALLINT     NOT NULL,   -- 100 = blue, 200 = red
    champion_id          INT          NOT NULL,
    team_position        VARCHAR(10)  NULL,       -- TOP | JUNGLE | MIDDLE | BOTTOM | UTILITY
    win                  BIT          NOT NULL,
    kills                SMALLINT     NOT NULL,
    deaths               SMALLINT     NOT NULL,
    assists              SMALLINT     NOT NULL,
    gold_earned          INT          NOT NULL,
    creep_score          INT          NOT NULL,   -- lane minions + jungle monsters
    vision_score         INT          NOT NULL,
    damage_to_champions  INT          NOT NULL,
    summoner1_id         INT          NOT NULL,
    summoner2_id         INT          NOT NULL,
    primary_tree_id      INT          NULL,
    secondary_tree_id    INT          NULL,
    keystone_id          INT          NULL,
    shard_offense_id     INT          NULL,   -- perks.statPerks: top, middle and bottom shard rows
    shard_flex_id        INT          NULL,
    shard_defense_id     INT          NULL,
    CONSTRAINT PK_fact_match_participant PRIMARY KEY (match_id, participant_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_match_participant_champion')
    CREATE INDEX IX_fact_match_participant_champion
        ON fact.match_participant (champion_id, team_position)
        INCLUDE (win, kills, deaths, assists, creep_score);
GO
