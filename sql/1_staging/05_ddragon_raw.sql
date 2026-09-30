-- Data Dragon static files (champion.json, item.json, runesReforged.json, summoner.json).
IF OBJECT_ID(N'stg.ddragon_raw') IS NULL
CREATE TABLE stg.ddragon_raw (
    dataset          VARCHAR(20)   NOT NULL,
    ddragon_version  VARCHAR(20)   NOT NULL,
    payload          NVARCHAR(MAX) NOT NULL CONSTRAINT CK_stg_ddragon_raw_json CHECK (ISJSON(payload) = 1),
    loaded_at        DATETIME2(0)  NOT NULL CONSTRAINT DF_stg_ddragon_raw_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_stg_ddragon_raw PRIMARY KEY (dataset, ddragon_version)
);
GO
