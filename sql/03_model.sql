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
    tree_id          INT           NOT NULL CONSTRAINT PK_dim_rune_tree PRIMARY KEY,
    tree_name        NVARCHAR(30)  NOT NULL,
    icon_path        VARCHAR(200)  NOT NULL,  -- relative to ddragon.leagueoflegends.com/cdn/img/
    ddragon_version  VARCHAR(20)   NOT NULL
);
GO

IF OBJECT_ID(N'dim.rune') IS NULL
CREATE TABLE dim.rune (
    rune_id          INT           NOT NULL CONSTRAINT PK_dim_rune PRIMARY KEY,
    rune_name        NVARCHAR(60)  NOT NULL,
    tree_id          INT           NOT NULL,
    slot_index       TINYINT       NOT NULL,  -- 0 = keystone row
    icon_path        VARCHAR(200)  NOT NULL,
    ddragon_version  VARCHAR(20)   NOT NULL
);
GO

IF OBJECT_ID(N'dim.summoner_spell') IS NULL
CREATE TABLE dim.summoner_spell (
    spell_id         INT          NOT NULL CONSTRAINT PK_dim_summoner_spell PRIMARY KEY,
    spell_key        VARCHAR(40)  NOT NULL,   -- e.g. 'SummonerFlash', also the image file name
    spell_name       NVARCHAR(40) NOT NULL,
    ddragon_version  VARCHAR(20)  NOT NULL
);
GO

-- Stat shards: the three small bonuses under the rune trees. They are not in Data Dragon's
-- runesReforged.json, so the list is kept here. Some IDs appear in more than one row.
IF OBJECT_ID(N'dim.stat_shard') IS NULL
CREATE TABLE dim.stat_shard (
    shard_id    INT           NOT NULL CONSTRAINT PK_dim_stat_shard PRIMARY KEY,
    shard_name  NVARCHAR(40)  NOT NULL,
    icon_path   VARCHAR(200)  NOT NULL
);
GO

MERGE dim.stat_shard AS t
USING (VALUES
    (5008, N'Adaptive Force',             'perk-images/StatMods/StatModsAdaptiveForceIcon.png'),
    (5005, N'Attack Speed',               'perk-images/StatMods/StatModsAttackSpeedIcon.png'),
    (5007, N'Ability Haste',              'perk-images/StatMods/StatModsCDRScalingIcon.png'),
    (5010, N'Move Speed',                 'perk-images/StatMods/StatModsMovementSpeedIcon.png'),
    (5001, N'Health Scaling',             'perk-images/StatMods/StatModsHealthScalingIcon.png'),
    (5011, N'Health',                     'perk-images/StatMods/StatModsHealthPlusIcon.png'),
    (5013, N'Tenacity and Slow Resist',   'perk-images/StatMods/StatModsTenacityIcon.png'),
    (5002, N'Armor',                      'perk-images/StatMods/StatModsArmorIcon.png'),
    (5003, N'Magic Resist',               'perk-images/StatMods/StatModsMagicResIcon.png')
) AS s (shard_id, shard_name, icon_path)
ON t.shard_id = s.shard_id
WHEN MATCHED THEN UPDATE SET shard_name = s.shard_name, icon_path = s.icon_path
WHEN NOT MATCHED THEN INSERT (shard_id, shard_name, icon_path) VALUES (s.shard_id, s.shard_name, s.icon_path);
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

-- One row per match whose timeline has been parsed. Build-order stats only use these matches,
-- so a missing timeline can't be mistaken for a player who bought nothing.
IF OBJECT_ID(N'fact.match_timeline') IS NULL
CREATE TABLE fact.match_timeline (
    match_id   VARCHAR(30)  NOT NULL CONSTRAINT PK_fact_match_timeline PRIMARY KEY
               CONSTRAINT FK_fact_match_timeline_match REFERENCES fact.match (match_id),
    loaded_at  DATETIME2(0) NOT NULL CONSTRAINT DF_fact_match_timeline_loaded DEFAULT SYSUTCDATETIME()
);
GO

-- Shop events from the timeline: purchases, sales and undos, in the order they happened.
-- For an undo, item_id is the item whose purchase was reverted (the event's beforeId).
IF OBJECT_ID(N'fact.item_event') IS NULL
CREATE TABLE fact.item_event (
    match_id        VARCHAR(30) NOT NULL,
    event_seq       INT         NOT NULL,   -- frame * 10000 + position in frame: unique and ordered
    participant_id  TINYINT     NOT NULL,
    timestamp_ms    INT         NOT NULL,
    event_type      VARCHAR(16) NOT NULL
                    CONSTRAINT CK_fact_item_event_type CHECK (event_type IN ('ITEM_PURCHASED', 'ITEM_SOLD', 'ITEM_UNDO')),
    item_id         INT         NOT NULL,
    CONSTRAINT PK_fact_item_event PRIMARY KEY (match_id, event_seq),
    CONSTRAINT FK_fact_item_event_timeline FOREIGN KEY (match_id) REFERENCES fact.match_timeline (match_id),
    CONSTRAINT FK_fact_item_event_participant FOREIGN KEY (match_id, participant_id)
        REFERENCES fact.match_participant (match_id, participant_id)
);
GO

-- The build-order views look up one player's events for one item at a time.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_item_event_participant_item')
    CREATE INDEX IX_fact_item_event_participant_item
        ON fact.item_event (match_id, participant_id, item_id, event_seq)
        INCLUDE (event_type, timestamp_ms);
GO
