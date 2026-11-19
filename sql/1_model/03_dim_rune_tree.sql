CREATE TABLE IF NOT EXISTS riot_dim.rune_tree (
    tree_id          INT64  NOT NULL,
    tree_name        STRING NOT NULL,
    icon_path        STRING NOT NULL,  -- relative to ddragon.leagueoflegends.com/cdn/img/
    ddragon_version  STRING NOT NULL
);
