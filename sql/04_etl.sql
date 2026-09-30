-- Transformation procedures: raw JSON in stg -> dim and fact tables.

------------------------------------------------------------------------------------------
-- Data Dragon -> dimensions. Reloads every dimension from the given (or latest) version.
------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_load_ddragon
    @ddragon_version VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ddragon_version IS NULL
        SELECT TOP (1) @ddragon_version = ddragon_version
        FROM stg.ddragon_raw
        WHERE dataset = 'champion'
        ORDER BY loaded_at DESC;

    DECLARE @champion NVARCHAR(MAX), @item NVARCHAR(MAX), @runes NVARCHAR(MAX), @spells NVARCHAR(MAX);
    SELECT @champion = MAX(CASE WHEN dataset = 'champion'      THEN payload END),
           @item     = MAX(CASE WHEN dataset = 'item'          THEN payload END),
           @runes    = MAX(CASE WHEN dataset = 'runesReforged' THEN payload END),
           @spells   = MAX(CASE WHEN dataset = 'summoner'      THEN payload END)
    FROM stg.ddragon_raw
    WHERE ddragon_version = @ddragon_version;

    IF @champion IS NULL OR @item IS NULL OR @runes IS NULL OR @spells IS NULL
        THROW 50001, 'Data Dragon version is missing one or more datasets in stg.ddragon_raw.', 1;

    BEGIN TRANSACTION;

    -- champion.json: {"data": {"Aatrox": {"id": "Aatrox", "key": "266", "name": "Aatrox", "tags": [...]}, ...}}
    DELETE FROM dim.champion;
    INSERT INTO dim.champion (champion_id, champion_key, champion_name, primary_class, ddragon_version)
    SELECT CAST(c.champion_key_num AS INT), c.id, c.name, JSON_VALUE(c.tags, '$[0]'), @ddragon_version
    FROM OPENJSON(@champion, '$.data') AS d
    CROSS APPLY OPENJSON(d.value) WITH (
        id                VARCHAR(40)   '$.id',
        champion_key_num  VARCHAR(10)   '$.key',
        name              NVARCHAR(60)  '$.name',
        tags              NVARCHAR(MAX) '$.tags' AS JSON
    ) AS c;

    -- item.json: {"data": {"3031": {"name": ..., "gold": {"total": 3400}, "tags": [...], "into": [...]}}}
    -- Items that build into something else are components. Of the rest, anything worth at least
    -- 1,000 gold is a completed item; cheaper finished items (Doran's, Dark Seal) are starters.
    DELETE FROM dim.item;
    INSERT INTO dim.item (item_id, item_name, total_gold, item_class, ddragon_version)
    SELECT CAST(d.[key] AS INT),
           i.name,
           i.total_gold,
           CASE
               WHEN t.is_trinket = 1                           THEN 'Trinket'
               WHEN t.is_consumable = 1 OR i.consumed = 1      THEN 'Consumable'
               WHEN t.is_boots = 1 AND i.total_gold > 300      THEN 'Boots'
               WHEN i.builds_into IS NOT NULL                  THEN 'Component'
               WHEN i.total_gold >= 1000                       THEN 'Completed'
               ELSE 'Starter'
           END,
           @ddragon_version
    FROM OPENJSON(@item, '$.data') AS d
    CROSS APPLY OPENJSON(d.value) WITH (
        name         NVARCHAR(100) '$.name',
        total_gold   INT           '$.gold.total',
        consumed     BIT           '$.consumed',
        tags         NVARCHAR(MAX) '$.tags' AS JSON,
        builds_into  NVARCHAR(MAX) '$.into' AS JSON
    ) AS i
    CROSS APPLY (
        SELECT MAX(CASE WHEN tg.value = 'Trinket'    THEN 1 ELSE 0 END) AS is_trinket,
               MAX(CASE WHEN tg.value = 'Consumable' THEN 1 ELSE 0 END) AS is_consumable,
               MAX(CASE WHEN tg.value = 'Boots'      THEN 1 ELSE 0 END) AS is_boots
        FROM OPENJSON(ISNULL(i.tags, N'[]')) AS tg
    ) AS t;

    -- runesReforged.json: [{"id": 8100, "name": "Domination", "icon": "perk-images/...",
    --                      "slots": [{"runes": [{"id": 8112, "name": ..., "icon": ...}]}]}]
    DELETE FROM dim.rune;
    DELETE FROM dim.rune_tree;
    INSERT INTO dim.rune_tree (tree_id, tree_name, icon_path, ddragon_version)
    SELECT tr.id, tr.name, tr.icon, @ddragon_version
    FROM OPENJSON(@runes) WITH (id INT '$.id', name NVARCHAR(30) '$.name', icon VARCHAR(200) '$.icon') AS tr;

    INSERT INTO dim.rune (rune_id, rune_name, tree_id, slot_index, icon_path, ddragon_version)
    SELECT r.id, r.name, tr.id, CAST(s.[key] AS TINYINT), r.icon, @ddragon_version
    FROM OPENJSON(@runes) WITH (id INT '$.id', slots NVARCHAR(MAX) '$.slots' AS JSON) AS tr
    CROSS APPLY OPENJSON(tr.slots) AS s
    CROSS APPLY OPENJSON(s.value, '$.runes')
        WITH (id INT '$.id', name NVARCHAR(60) '$.name', icon VARCHAR(200) '$.icon') AS r;

    -- summoner.json: {"data": {"SummonerFlash": {"id": "SummonerFlash", "key": "4", "name": "Flash"}}}
    DELETE FROM dim.summoner_spell;
    INSERT INTO dim.summoner_spell (spell_id, spell_key, spell_name, ddragon_version)
    SELECT CAST(sp.spell_num AS INT), sp.id, sp.name, @ddragon_version
    FROM OPENJSON(@spells, '$.data') AS d
    CROSS APPLY OPENJSON(d.value)
        WITH (id VARCHAR(40) '$.id', spell_num VARCHAR(10) '$.key', name NVARCHAR(40) '$.name') AS sp;

    COMMIT TRANSACTION;

    SELECT @ddragon_version AS ddragon_version,
           (SELECT COUNT(*) FROM dim.champion)       AS champions,
           (SELECT COUNT(*) FROM dim.item)           AS items,
           (SELECT COUNT(*) FROM dim.rune)           AS runes,
           (SELECT COUNT(*) FROM dim.summoner_spell) AS summoner_spells;
END;
GO

------------------------------------------------------------------------------------------
-- Raw matches -> facts. Incremental: only matches not already in fact.match are parsed.
-- Each batch commits on its own, so a failure part-way keeps the batches already loaded.
------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_load_matches
    @batch_size INT = 1000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch_rows INT, @total_rows INT = 0;

    CREATE TABLE #batch (
        match_id  VARCHAR(30)   NOT NULL PRIMARY KEY,
        payload   NVARCHAR(MAX) NOT NULL
    );

    CREATE TABLE #participant (
        match_id             VARCHAR(30)   NOT NULL,
        participant_id       TINYINT       NOT NULL,
        puuid                VARCHAR(100)  NOT NULL,
        team_id              SMALLINT      NOT NULL,
        champion_id          INT           NOT NULL,
        team_position        VARCHAR(10)   NULL,
        win                  BIT           NOT NULL,
        kills                SMALLINT      NOT NULL,
        deaths               SMALLINT      NOT NULL,
        assists              SMALLINT      NOT NULL,
        gold_earned          INT           NOT NULL,
        creep_score          INT           NOT NULL,
        vision_score         INT           NOT NULL,
        damage_to_champions  INT           NOT NULL,
        summoner1_id         INT           NOT NULL,
        summoner2_id         INT           NOT NULL,
        item0 INT, item1 INT, item2 INT, item3 INT, item4 INT, item5 INT, item6 INT,
        perks                NVARCHAR(MAX) NULL,
        PRIMARY KEY (match_id, participant_id)
    );

    WHILE 1 = 1
    BEGIN
        TRUNCATE TABLE #batch;
        TRUNCATE TABLE #participant;

        INSERT INTO #batch (match_id, payload)
        SELECT TOP (@batch_size) r.match_id, r.payload
        FROM stg.v_match_raw AS r
        WHERE NOT EXISTS (SELECT 1 FROM fact.match AS m WHERE m.match_id = r.match_id)
        ORDER BY r.match_id;

        SET @batch_rows = @@ROWCOUNT;
        IF @batch_rows = 0 BREAK;

        -- Shred participants once; the three fact inserts below read from this temp table.
        INSERT INTO #participant
        SELECT b.match_id, p.participantId, p.puuid, p.teamId, p.championId, NULLIF(p.teamPosition, ''),
               p.win, p.kills, p.deaths, p.assists, p.goldEarned,
               p.totalMinionsKilled + p.neutralMinionsKilled,
               p.visionScore, p.totalDamageDealtToChampions, p.summoner1Id, p.summoner2Id,
               p.item0, p.item1, p.item2, p.item3, p.item4, p.item5, p.item6,
               p.perks
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info.participants') WITH (
            participantId                TINYINT,
            puuid                        VARCHAR(100),
            teamId                       SMALLINT,
            championId                   INT,
            teamPosition                 VARCHAR(10),
            win                          BIT,
            kills                        SMALLINT,
            deaths                       SMALLINT,
            assists                      SMALLINT,
            goldEarned                   INT,
            totalMinionsKilled           INT,
            neutralMinionsKilled         INT,
            visionScore                  INT,
            totalDamageDealtToChampions  INT,
            summoner1Id                  INT,
            summoner2Id                  INT,
            item0 INT, item1 INT, item2 INT, item3 INT, item4 INT, item5 INT, item6 INT,
            perks                        NVARCHAR(MAX) AS JSON
        ) AS p;

        BEGIN TRANSACTION;

        INSERT INTO fact.match (match_id, patch, game_version, game_start_utc, duration_s, queue_id, sample_tier, is_remake)
        SELECT b.match_id,
               v.patch,
               i.gameVersion,
               DATEADD(SECOND, CAST(i.gameCreation / 1000 AS INT), CAST('1970-01-01' AS DATETIME2(0))),
               i.gameDuration,
               i.queueId,
               q.source_tier,
               CASE WHEN i.gameDuration < 300 THEN 1 ELSE 0 END
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info') WITH (
            gameVersion   VARCHAR(30),
            gameCreation  BIGINT,
            gameDuration  INT,
            queueId       INT
        ) AS i
        -- '15.19.712.3456' -> '15.19'
        CROSS APPLY (SELECT LEFT(i.gameVersion, CHARINDEX('.', i.gameVersion, CHARINDEX('.', i.gameVersion) + 1) - 1) AS patch) AS v
        LEFT JOIN stg.match_queue AS q ON q.match_id = b.match_id;

        INSERT INTO fact.match_participant (
            match_id, participant_id, puuid, team_id, champion_id, team_position, win, kills, deaths, assists,
            gold_earned, creep_score, vision_score, damage_to_champions, summoner1_id, summoner2_id,
            primary_tree_id, secondary_tree_id, keystone_id, shard_offense_id, shard_flex_id, shard_defense_id)
        SELECT match_id, participant_id, puuid, team_id, champion_id, team_position, win, kills, deaths, assists,
               gold_earned, creep_score, vision_score, damage_to_champions, summoner1_id, summoner2_id,
               JSON_VALUE(perks, '$.styles[0].style'),
               JSON_VALUE(perks, '$.styles[1].style'),
               JSON_VALUE(perks, '$.styles[0].selections[0].perk'),
               JSON_VALUE(perks, '$.statPerks.offense'),
               JSON_VALUE(perks, '$.statPerks.flex'),
               JSON_VALUE(perks, '$.statPerks.defense')
        FROM #participant;

        -- Unpivot the seven item columns into rows; 0 means an empty slot.
        INSERT INTO fact.participant_item (match_id, participant_id, slot, item_id)
        SELECT p.match_id, p.participant_id, s.slot, s.item_id
        FROM #participant AS p
        CROSS APPLY (VALUES (0, p.item0), (1, p.item1), (2, p.item2), (3, p.item3),
                            (4, p.item4), (5, p.item5), (6, p.item6)) AS s (slot, item_id)
        WHERE s.item_id > 0;

        -- perks.styles[0] is the primary tree, styles[1] the secondary; each has a selections array.
        INSERT INTO fact.participant_rune (match_id, participant_id, rune_id, tree_id, is_primary_tree, selection_index)
        SELECT p.match_id, p.participant_id, sel.perk, st.style,
               CASE WHEN s.[key] = '0' THEN 1 ELSE 0 END,
               CAST(sr.[key] AS TINYINT)
        FROM #participant AS p
        CROSS APPLY OPENJSON(p.perks, '$.styles') AS s
        CROSS APPLY OPENJSON(s.value) WITH (style INT, selections NVARCHAR(MAX) AS JSON) AS st
        CROSS APPLY OPENJSON(st.selections) AS sr
        CROSS APPLY OPENJSON(sr.value) WITH (perk INT) AS sel;

        -- championId -1 means the team skipped that ban.
        INSERT INTO fact.match_ban (match_id, team_id, pick_turn, champion_id)
        SELECT b.match_id, t.teamId, bn.pickTurn, bn.championId
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info.teams') WITH (teamId SMALLINT, bans NVARCHAR(MAX) AS JSON) AS t
        CROSS APPLY OPENJSON(t.bans) WITH (championId INT, pickTurn TINYINT) AS bn
        WHERE bn.championId > 0;

        COMMIT TRANSACTION;

        SET @total_rows += @batch_rows;
    END;

    SELECT @total_rows AS matches_loaded;
END;
GO

------------------------------------------------------------------------------------------
-- Raw timelines -> fact.item_event. Incremental like usp_load_matches, and only for matches
-- already in fact.match. Timelines are ~0.5 MB of JSON each, hence the smaller batches.
------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_load_timelines
    @batch_size INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch_rows INT, @total_rows INT = 0;

    CREATE TABLE #batch (
        match_id  VARCHAR(30)   NOT NULL PRIMARY KEY,
        payload   NVARCHAR(MAX) NOT NULL
    );

    WHILE 1 = 1
    BEGIN
        TRUNCATE TABLE #batch;

        INSERT INTO #batch (match_id, payload)
        SELECT TOP (@batch_size) r.match_id, r.payload
        FROM stg.v_timeline_raw AS r
        WHERE EXISTS (SELECT 1 FROM fact.match AS m WHERE m.match_id = r.match_id)
          AND NOT EXISTS (SELECT 1 FROM fact.match_timeline AS t WHERE t.match_id = r.match_id)
        ORDER BY r.match_id;

        SET @batch_rows = @@ROWCOUNT;
        IF @batch_rows = 0 BREAK;

        BEGIN TRANSACTION;

        INSERT INTO fact.match_timeline (match_id)
        SELECT match_id FROM #batch;

        -- info.frames[] is one frame per minute; each frame has an events[] array in time order.
        -- participantId 0 is the game itself (e.g. items granted at the start) and is skipped.
        INSERT INTO fact.item_event (match_id, event_seq, participant_id, timestamp_ms, event_type, item_id)
        SELECT b.match_id,
               CAST(f.[key] AS INT) * 10000 + CAST(e.[key] AS INT),
               ev.participantId,
               ev.[timestamp],
               ev.[type],
               IIF(ev.[type] = 'ITEM_UNDO', ev.beforeId, ev.itemId)
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info.frames') AS f
        CROSS APPLY OPENJSON(f.value, '$.events') AS e
        CROSS APPLY OPENJSON(e.value) WITH (
            [type]         VARCHAR(40),
            participantId  TINYINT,
            [timestamp]    INT,
            itemId         INT,
            beforeId       INT
        ) AS ev
        WHERE ev.[type] IN ('ITEM_PURCHASED', 'ITEM_SOLD', 'ITEM_UNDO')
          AND ev.participantId BETWEEN 1 AND 10
          -- An undo with beforeId 0 reverts a sale rather than a purchase; purchases are what we count.
          AND IIF(ev.[type] = 'ITEM_UNDO', ev.beforeId, ev.itemId) > 0;

        COMMIT TRANSACTION;

        SET @total_rows += @batch_rows;
    END;

    SELECT @total_rows AS timelines_loaded;
END;
GO

------------------------------------------------------------------------------------------
-- Raw matches -> fact.team_objective, for matches already in fact.match. Separate from
-- usp_load_matches so matches loaded before this table existed are filled in too.
------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_load_objectives
    @batch_size INT = 1000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch_rows INT, @total_rows INT = 0;

    CREATE TABLE #batch (
        match_id  VARCHAR(30)   NOT NULL PRIMARY KEY,
        payload   NVARCHAR(MAX) NOT NULL
    );

    WHILE 1 = 1
    BEGIN
        TRUNCATE TABLE #batch;

        INSERT INTO #batch (match_id, payload)
        SELECT TOP (@batch_size) r.match_id, r.payload
        FROM stg.v_match_raw AS r
        WHERE EXISTS (SELECT 1 FROM fact.match AS m WHERE m.match_id = r.match_id)
          AND NOT EXISTS (SELECT 1 FROM fact.team_objective AS o WHERE o.match_id = r.match_id)
        ORDER BY r.match_id;

        SET @batch_rows = @@ROWCOUNT;
        IF @batch_rows = 0 BREAK;

        -- info.teams[].objectives: {"baron": {"first": true, "kills": 1}, "dragon": {...}, ...}
        INSERT INTO fact.team_objective (match_id, team_id, objective, is_first, kills)
        SELECT b.match_id, t.teamId, o.[key], ob.[first], ob.kills
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info.teams') WITH (teamId SMALLINT, objectives NVARCHAR(MAX) AS JSON) AS t
        CROSS APPLY OPENJSON(t.objectives) AS o
        CROSS APPLY OPENJSON(o.value) WITH ([first] BIT, kills SMALLINT) AS ob;

        -- A batch with no objectives at all would be picked again forever, so stop.
        IF @@ROWCOUNT = 0 BREAK;
        SET @total_rows += @batch_rows;
    END;

    SELECT @total_rows AS matches_loaded;
END;
GO

------------------------------------------------------------------------------------------
-- Raw timelines -> fact.participant_frame, for timelines already in fact.match_timeline.
-- Only games of 11+ minutes have a minute-10 frame; shorter ones are remakes or early
-- surrenders and are skipped, so every match picked up here gets rows.
------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_load_frames
    @batch_size INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch_rows INT, @total_rows INT = 0;

    CREATE TABLE #batch (
        match_id  VARCHAR(30)   NOT NULL PRIMARY KEY,
        payload   NVARCHAR(MAX) NOT NULL
    );

    WHILE 1 = 1
    BEGIN
        TRUNCATE TABLE #batch;

        INSERT INTO #batch (match_id, payload)
        SELECT TOP (@batch_size) r.match_id, r.payload
        FROM stg.v_timeline_raw AS r
        JOIN fact.match_timeline AS t ON t.match_id = r.match_id
        JOIN fact.match AS m ON m.match_id = r.match_id
        WHERE m.duration_s >= 660
          AND NOT EXISTS (SELECT 1 FROM fact.participant_frame AS f WHERE f.match_id = r.match_id)
        ORDER BY r.match_id;

        SET @batch_rows = @@ROWCOUNT;
        IF @batch_rows = 0 BREAK;

        -- info.frames[n].participantFrames: {"1": {"totalGold": 7397, "xp": 9690, ...}, "2": ...}
        INSERT INTO fact.participant_frame (match_id, minute, participant_id, total_gold, xp, creep_score)
        SELECT b.match_id, CAST(f.[key] AS TINYINT), pf.participantId, pf.totalGold, pf.xp,
               pf.minionsKilled + pf.jungleMinionsKilled
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info.frames') AS f
        CROSS APPLY OPENJSON(f.value, '$.participantFrames') AS p
        CROSS APPLY OPENJSON(p.value) WITH (
            participantId        TINYINT,
            totalGold            INT,
            xp                   INT,
            minionsKilled        INT,
            jungleMinionsKilled  INT
        ) AS pf
        WHERE f.[key] IN ('10', '15', '20', '25')
          AND pf.participantId BETWEEN 1 AND 10;

        IF @@ROWCOUNT = 0 BREAK;
        SET @total_rows += @batch_rows;
    END;

    SELECT @total_rows AS timelines_loaded;
END;
GO

------------------------------------------------------------------------------------------
-- Empties the fact tables so every raw match and timeline is re-parsed on the next load.
-- Use after changing etl.usp_load_matches or etl.usp_load_timelines.
------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_reset_facts
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;
    DELETE FROM fact.participant_frame;
    DELETE FROM fact.team_objective;
    DELETE FROM fact.item_event;
    DELETE FROM fact.match_timeline;
    DELETE FROM fact.participant_rune;
    DELETE FROM fact.participant_item;
    DELETE FROM fact.match_ban;
    DELETE FROM fact.match_participant;
    DELETE FROM fact.match;
    COMMIT TRANSACTION;
END;
GO
