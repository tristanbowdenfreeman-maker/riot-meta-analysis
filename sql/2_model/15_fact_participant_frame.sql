-- Each player's gold, XP and creep score at minutes 10, 15, 20 and 25, from the timeline's
-- once-a-minute frames (frame n is minute n). Games that ended earlier have no row for that minute.
IF OBJECT_ID(N'fact.participant_frame') IS NULL
CREATE TABLE fact.participant_frame (
    match_id        VARCHAR(30) NOT NULL,
    minute          TINYINT     NOT NULL,
    participant_id  TINYINT     NOT NULL,
    total_gold      INT         NOT NULL,
    xp              INT         NOT NULL,
    creep_score     SMALLINT    NOT NULL,
    CONSTRAINT PK_fact_participant_frame PRIMARY KEY (match_id, minute, participant_id),
    CONSTRAINT FK_fact_participant_frame_timeline FOREIGN KEY (match_id) REFERENCES fact.match_timeline (match_id),
    CONSTRAINT FK_fact_participant_frame_participant FOREIGN KEY (match_id, participant_id)
        REFERENCES fact.match_participant (match_id, participant_id)
);
GO
