-- Final inventory, unpivoted from item0..item6 so items can be grouped and joined.
IF OBJECT_ID(N'fact.participant_item') IS NULL
CREATE TABLE fact.participant_item (
    match_id        VARCHAR(30) NOT NULL,
    participant_id  TINYINT     NOT NULL,
    slot            TINYINT     NOT NULL,   -- 0-5 inventory, 6 trinket
    item_id         INT         NOT NULL,
    CONSTRAINT PK_fact_participant_item PRIMARY KEY (match_id, participant_id, slot),
    CONSTRAINT FK_fact_participant_item_participant FOREIGN KEY (match_id, participant_id)
        REFERENCES fact.match_participant (match_id, participant_id)
);
GO
