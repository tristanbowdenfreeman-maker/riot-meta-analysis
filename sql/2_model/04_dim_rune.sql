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
