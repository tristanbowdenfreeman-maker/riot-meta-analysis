IF OBJECT_ID(N'dim.summoner_spell') IS NULL
CREATE TABLE dim.summoner_spell (
    spell_id         INT          NOT NULL CONSTRAINT PK_dim_summoner_spell PRIMARY KEY,
    spell_key        VARCHAR(40)  NOT NULL,   -- e.g. 'SummonerFlash', also the image file name
    spell_name       NVARCHAR(40) NOT NULL,
    ddragon_version  VARCHAR(20)  NOT NULL
);
GO
