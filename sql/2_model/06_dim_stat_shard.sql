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
