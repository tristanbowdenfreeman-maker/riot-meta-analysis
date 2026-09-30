-- Star schema. Dimensions come from Data Dragon; facts are parsed from stg.match_raw by
-- etl.usp_load_matches. Grain of the main fact table: one row per player per match.

------------------------------------------------------------------------------------------
-- Dimensions
------------------------------------------------------------------------------------------
IF OBJECT_ID(N'dim.champion') IS NULL
CREATE TABLE dim.champion (
    champion_id      INT          NOT NULL CONSTRAINT PK_dim_champion PRIMARY KEY,  -- numeric "key" in Data Dragon
    champion_key     VARCHAR(40)  NOT NULL,                                          -- e.g. 'MonkeyKing'
    champion_name    NVARCHAR(60) NOT NULL,                                          -- e.g. 'Wukong'
    primary_class    VARCHAR(20)  NULL,                                              -- first Data Dragon tag
    ddragon_version  VARCHAR(20)  NOT NULL
);
GO

IF OBJECT_ID(N'dim.item') IS NULL
CREATE TABLE dim.item (
    item_id          INT           NOT NULL CONSTRAINT PK_dim_item PRIMARY KEY,
    item_name        NVARCHAR(100) NOT NULL,
    total_gold       INT           NOT NULL,
    -- Completed | Boots | Component | Starter | Consumable | Trinket  (see etl.usp_load_ddragon)
    item_class       VARCHAR(12)   NOT NULL,
    ddragon_version  VARCHAR(20)   NOT NULL
);
GO

IF OBJECT_ID(N'dim.rune_tree') IS NULL
CREATE TABLE dim.rune_tree (
    tree_id          INT          NOT NULL CONSTRAINT PK_dim_rune_tree PRIMARY KEY,
    tree_name        NVARCHAR(30) NOT NULL,
    ddragon_version  VARCHAR(20)  NOT NULL
);
GO

IF OBJECT_ID(N'dim.rune') IS NULL
CREATE TABLE dim.rune (
    rune_id          INT          NOT NULL CONSTRAINT PK_dim_rune PRIMARY KEY,
    rune_name        NVARCHAR(60) NOT NULL,
    tree_id          INT          NOT NULL,
    slot_index       TINYINT      NOT NULL,  -- 0 = keystone row
    ddragon_version  VARCHAR(20)  NOT NULL
);
GO

IF OBJECT_ID(N'dim.summoner_spell') IS NULL
CREATE TABLE dim.summoner_spell (
    spell_id         INT          NOT NULL CONSTRAINT PK_dim_summoner_spell PRIMARY KEY,
    spell_name       NVARCHAR(40) NOT NULL,
    ddragon_version  VARCHAR(20)  NOT NULL
);
GO

------------------------------------------------------------------------------------------
-- Facts
------------------------------------------------------------------------------------------
IF OBJECT_ID(N'fact.match') IS NULL
CREATE TABLE fact.match (
    match_id        VARCHAR(30)  NOT NULL CONSTRAINT PK_fact_match PRIMARY KEY,
    patch           VARCHAR(10)  NOT NULL,   -- major.minor of game_version, e.g. '15.19'
    game_version    VARCHAR(30)  NOT NULL,
    game_start_utc  DATETIME2(0) NOT NULL,
    duration_s      INT          NOT NULL,
    queue_id        INT          NOT NULL,   -- 420 = ranked solo/duo
    sample_tier     VARCHAR(12)  NULL,       -- tier of the player whose history the match came from
    is_remake       BIT          NOT NULL    -- games under 5 minutes
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_match_patch')
    CREATE INDEX IX_fact_match_patch ON fact.match (patch, queue_id, is_remake);
GO

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
    CONSTRAINT PK_fact_match_participant PRIMARY KEY (match_id, participant_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_match_participant_champion')
    CREATE INDEX IX_fact_match_participant_champion
        ON fact.match_participant (champion_id, team_position)
        INCLUDE (win, kills, deaths, assists, creep_score);
GO

-- Final inventory, unpivoted from item0..item6 so items can be grouped and joined.
IF OBJECT_ID(N'fact.participant_item') IS NULL
CREATE TABLE fact.participant_item (
    match_id        VARCHAR(30) NOT NULL,
    participant_id  TINYINT     NOT NULL,
    slot            TINYINT     NOT NULL,   -- 0-5 inventory, 6 trinket
    item_id         INT         NOT NULL,
    CONSTRAINT PK_fact_participant_item PRIMARY KEY (match_id, participant_id, slot),
    CONSTRAINT FK_fact_participant_item_participant FOREIGN KEY (match_id, participant_id)
        REFERENCES fact.match_participant (match_id, participant_id)
);
GO

IF OBJECT_ID(N'fact.participant_rune') IS NULL
CREATE TABLE fact.participant_rune (
    match_id         VARCHAR(30) NOT NULL,
    participant_id   TINYINT     NOT NULL,
    rune_id          INT         NOT NULL,
    tree_id          INT         NOT NULL,
    is_primary_tree  BIT         NOT NULL,
    selection_index  TINYINT     NOT NULL,   -- 0 = keystone when is_primary_tree = 1
    CONSTRAINT PK_fact_participant_rune PRIMARY KEY (match_id, participant_id, rune_id),
    CONSTRAINT FK_fact_participant_rune_participant FOREIGN KEY (match_id, participant_id)
        REFERENCES fact.match_participant (match_id, participant_id)
);
GO

IF OBJECT_ID(N'fact.match_ban') IS NULL
CREATE TABLE fact.match_ban (
    match_id     VARCHAR(30) NOT NULL CONSTRAINT FK_fact_match_ban_match REFERENCES fact.match (match_id),
    team_id      SMALLINT    NOT NULL,
    pick_turn    TINYINT     NOT NULL,
    champion_id  INT         NOT NULL,
    CONSTRAINT PK_fact_match_ban PRIMARY KEY (match_id, team_id, pick_turn)
);
GO
