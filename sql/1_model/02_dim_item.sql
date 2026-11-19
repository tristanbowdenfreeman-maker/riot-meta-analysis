CREATE TABLE IF NOT EXISTS riot_dim.item (
    item_id          INT64  NOT NULL,
    item_name        STRING NOT NULL,
    total_gold       INT64  NOT NULL,
    -- Completed | Boots | Component | Starter | Consumable | Trinket  (see parse._item_class)
    item_class       STRING NOT NULL,
    ddragon_version  STRING NOT NULL
);
