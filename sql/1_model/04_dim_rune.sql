CREATE TABLE IF NOT EXISTS riot_dim.rune (
    rune_id          INT64  NOT NULL,
    rune_name        STRING NOT NULL,
    tree_id          INT64  NOT NULL,
    slot_index       INT64  NOT NULL,  -- 0 = keystone row
    icon_path        STRING NOT NULL,
    ddragon_version  STRING NOT NULL
);
