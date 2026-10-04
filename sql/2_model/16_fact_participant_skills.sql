-- Each player's skill order from the timeline, one row per player. Slots: 1-3 = Q, W, E; 4 = R.
-- skill_levels: the skill taken at each level-up, up to 18 (e.g. '312334...'). Evolutions
-- (Kai'Sa, Kha'Zix, Viktor) are left out.
-- skill_start: the first three. max_order: Q, W and E by points after 11 level-ups (most first;
-- a tie goes to the skill that got there first), NULL when the player didn't reach 11.
IF OBJECT_ID(N'fact.participant_skills') IS NULL
CREATE TABLE fact.participant_skills (
    match_id        VARCHAR(30) NOT NULL,
    participant_id  TINYINT     NOT NULL,
    skill_levels    VARCHAR(18) NOT NULL,
    skill_start     VARCHAR(3)  NOT NULL,
    max_order       VARCHAR(3)  NULL,
    CONSTRAINT PK_fact_participant_skills PRIMARY KEY (match_id, participant_id),
    CONSTRAINT FK_fact_participant_skills_timeline FOREIGN KEY (match_id) REFERENCES fact.match_timeline (match_id),
    CONSTRAINT FK_fact_participant_skills_participant FOREIGN KEY (match_id, participant_id)
        REFERENCES fact.match_participant (match_id, participant_id)
);
GO
