-- Shop events from the timeline: purchases, sales and undos, in the order they happened.
-- For an undo, item_id is the item whose purchase was reverted (the event's beforeId).
IF OBJECT_ID(N'fact.item_event') IS NULL
CREATE TABLE fact.item_event (
    match_id        VARCHAR(30) NOT NULL,
    event_seq       INT         NOT NULL,   -- frame * 10000 + position in frame: unique and ordered
    participant_id  TINYINT     NOT NULL,
    timestamp_ms    INT         NOT NULL,
    event_type      VARCHAR(16) NOT NULL
                    CONSTRAINT CK_fact_item_event_type CHECK (event_type IN ('ITEM_PURCHASED', 'ITEM_SOLD', 'ITEM_UNDO')),
    item_id         INT         NOT NULL,
    CONSTRAINT PK_fact_item_event PRIMARY KEY (match_id, event_seq),
    CONSTRAINT FK_fact_item_event_timeline FOREIGN KEY (match_id) REFERENCES fact.match_timeline (match_id),
    CONSTRAINT FK_fact_item_event_participant FOREIGN KEY (match_id, participant_id)
        REFERENCES fact.match_participant (match_id, participant_id)
);
GO

-- The build-order views look up one player's events for one item at a time.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_item_event_participant_item')
    CREATE INDEX IX_fact_item_event_participant_item
        ON fact.item_event (match_id, participant_id, item_id, event_seq)
        INCLUDE (event_type, timestamp_ms);
GO
