IF OBJECT_ID(N'fact.participant_rune') IS NULL
CREATE TABLE fact.participant_rune (
    match_id         VARCHAR(30) NOT NULL,
    participant_id   TINYINT     NOT NULL,
    rune_id          INT         NOT NULL,
    tree_id          INT         NOT NULL,
    is_primary_tree  BIT         NOT NULL,
    selection_index  TINYINT     NOT NULL,   -- 0 = keystone when is_primary_tree = 1
    CONSTRAINT PK_fact_participant_rune PRIMARY KEY (match_id, participant_id, rune_id),
    CONSTRAINT FK_fact_participant_rune_participant FOREIGN KEY (match_id, participant_id)
        REFERENCES fact.match_participant (match_id, participant_id)
);
GO
