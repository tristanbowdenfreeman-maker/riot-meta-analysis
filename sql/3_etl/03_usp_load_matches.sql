-- Raw matches -> facts. Incremental: only matches not already in fact.match are parsed.
-- Each batch commits on its own, so a failure part-way keeps the batches already loaded.
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
