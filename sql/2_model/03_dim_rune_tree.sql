IF OBJECT_ID(N'dim.rune_tree') IS NULL
CREATE TABLE dim.rune_tree (
    tree_id          INT           NOT NULL CONSTRAINT PK_dim_rune_tree PRIMARY KEY,
    tree_name        NVARCHAR(30)  NOT NULL,
    icon_path        VARCHAR(200)  NOT NULL,  -- relative to ddragon.leagueoflegends.com/cdn/img/
    ddragon_version  VARCHAR(20)   NOT NULL
);
GO
