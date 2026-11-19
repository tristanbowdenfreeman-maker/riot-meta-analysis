-- Each player's skill order from the timeline, one row per player. Slots: 1-3 = Q, W, E; 4 = R.
-- skill_levels: the skill taken at each level-up, up to 18 (e.g. '312334...'). Evolutions
-- (Kai'Sa, Kha'Zix, Viktor) are left out.
-- skill_start: the first three. max_order: Q, W and E by points after 11 level-ups (most first;
-- a tie goes to the skill that got there first), NULL when the player didn't reach 11.
-- Key: match_id, participant_id.
CREATE TABLE IF NOT EXISTS riot_fact.participant_skills (
    match_id        STRING NOT NULL,
    participant_id  INT64  NOT NULL,
    skill_levels    STRING NOT NULL,
    skill_start     STRING NOT NULL,
    max_order       STRING
);
