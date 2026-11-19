-- Stat shards: the three small bonuses under the rune trees. They are not in Data Dragon's
-- runesReforged.json, so the list is kept in parse.STAT_SHARDS.
CREATE TABLE IF NOT EXISTS riot_dim.stat_shard (
    shard_id    INT64  NOT NULL,
    shard_name  STRING NOT NULL,
    icon_path   STRING NOT NULL
);
