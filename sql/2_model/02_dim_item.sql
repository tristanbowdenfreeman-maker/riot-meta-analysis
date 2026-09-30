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
