CREATE TABLE IF NOT EXISTS riot_dim.champion (
    champion_id      INT64  NOT NULL,  -- numeric "key" in Data Dragon
    champion_key     STRING NOT NULL,  -- e.g. 'MonkeyKing'
    champion_name    STRING NOT NULL,  -- e.g. 'Wukong'
    primary_class    STRING,           -- first Data Dragon tag
    ddragon_version  STRING NOT NULL
);
