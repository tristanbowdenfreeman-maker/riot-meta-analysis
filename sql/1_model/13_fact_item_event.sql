-- Shop events from the timeline: purchases, sales and undos, in the order they happened.
-- For an undo, item_id is the item whose purchase was reverted (the event's beforeId).
-- Key: match_id, event_seq.
CREATE TABLE IF NOT EXISTS riot_fact.item_event (
    match_id        STRING NOT NULL,
    event_seq       INT64  NOT NULL,  -- frame * 10000 + position in frame: unique and ordered
    participant_id  INT64  NOT NULL,
    timestamp_ms    INT64  NOT NULL,
    event_type      STRING NOT NULL,  -- ITEM_PURCHASED | ITEM_SOLD | ITEM_UNDO
    item_id         INT64  NOT NULL
);
