-- Each player's gold, XP and creep score at minutes 10, 15, 20 and 25, from the timeline's
-- once-a-minute frames (frame n is minute n). Games that ended earlier have no row for that minute.
-- Key: match_id, minute, participant_id.
CREATE TABLE IF NOT EXISTS riot_fact.participant_frame (
    match_id        STRING NOT NULL,
    minute          INT64  NOT NULL,
    participant_id  INT64  NOT NULL,
    total_gold      INT64  NOT NULL,
    xp              INT64  NOT NULL,
    creep_score     INT64  NOT NULL
);
