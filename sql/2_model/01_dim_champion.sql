IF OBJECT_ID(N'dim.champion') IS NULL
CREATE TABLE dim.champion (
    champion_id      INT          NOT NULL CONSTRAINT PK_dim_champion PRIMARY KEY,  -- numeric "key" in Data Dragon
    champion_key     VARCHAR(40)  NOT NULL,                                          -- e.g. 'MonkeyKing'
    champion_name    NVARCHAR(60) NOT NULL,                                          -- e.g. 'Wukong'
    primary_class    VARCHAR(20)  NULL,                                              -- first Data Dragon tag
    ddragon_version  VARCHAR(20)  NOT NULL
);
GO
