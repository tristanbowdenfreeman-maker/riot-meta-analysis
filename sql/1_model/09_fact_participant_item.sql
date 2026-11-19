-- Final inventory, unpivoted from item0..item6 so items can be grouped and joined.
-- Key: match_id, participant_id, slot.
CREATE TABLE IF NOT EXISTS riot_fact.participant_item (
    match_id        STRING NOT NULL,
    participant_id  INT64  NOT NULL,
    slot            INT64  NOT NULL,  -- 0-5 inventory, 6 trinket
    item_id         INT64  NOT NULL
);
