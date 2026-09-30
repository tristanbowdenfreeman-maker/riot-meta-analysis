-- Purchases that were not undone. An undo reverts the most recent purchase of that item, so a
-- purchase counts as undone when an undo of the same item follows it before the item is bought
-- again. (Two purchases of the same item followed by two undos would keep the first one; that
-- only happens with consumables and doesn't affect completed items.)
CREATE OR ALTER VIEW mart.v_item_purchase
AS
WITH purchase AS (
    SELECT e.match_id, e.participant_id, e.item_id, e.event_seq, e.timestamp_ms,
           LEAD(e.event_seq) OVER (PARTITION BY e.match_id, e.participant_id, e.item_id
                                   ORDER BY e.event_seq) AS next_purchase_seq
    FROM fact.item_event AS e
    WHERE e.event_type = 'ITEM_PURCHASED'
)
SELECT p.match_id, p.participant_id, p.item_id, p.event_seq, p.timestamp_ms
FROM purchase AS p
WHERE NOT EXISTS (
    SELECT 1
    FROM fact.item_event AS u
    WHERE u.match_id = p.match_id
      AND u.participant_id = p.participant_id
      AND u.item_id = p.item_id
      AND u.event_type = 'ITEM_UNDO'
      AND u.event_seq > p.event_seq
      AND (p.next_purchase_seq IS NULL OR u.event_seq < p.next_purchase_seq)
);
GO
