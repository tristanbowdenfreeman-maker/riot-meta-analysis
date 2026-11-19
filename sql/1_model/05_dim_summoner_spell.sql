CREATE TABLE IF NOT EXISTS riot_dim.summoner_spell (
    spell_id         INT64  NOT NULL,
    spell_key        STRING NOT NULL,  -- e.g. 'SummonerFlash', also the image file name
    spell_name       STRING NOT NULL,
    ddragon_version  STRING NOT NULL
);
