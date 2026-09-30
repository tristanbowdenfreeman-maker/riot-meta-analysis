-- Data Dragon -> dimensions. Reloads every dimension from the given (or latest) version.
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
