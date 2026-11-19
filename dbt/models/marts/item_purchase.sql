-- Purchases that were not undone. An undo reverts the most recent purchase of
-- that item, so a purchase counts as undone when an undo of the same item follows it before the
-- item is bought again. (Two purchases of the same item followed by two undos would keep the
-- first one; that only happens with consumables and doesn't affect completed items.)
WITH purchase AS (
    SELECT match_id, participant_id, item_id, event_seq, timestamp_ms,
           LEAD(event_seq) OVER (PARTITION BY match_id, participant_id, item_id ORDER BY event_seq) AS next_purchase_seq
    FROM {{ ref('stg_fact_item_event') }}
    WHERE event_type = 'ITEM_PURCHASED'
),
undone AS (
    SELECT DISTINCT p.match_id, p.participant_id, p.event_seq
    FROM purchase AS p
    JOIN {{ ref('stg_fact_item_event') }} AS u
      ON u.match_id = p.match_id
     AND u.participant_id = p.participant_id
     AND u.item_id = p.item_id
     AND u.event_type = 'ITEM_UNDO'
     AND u.event_seq > p.event_seq
     AND (p.next_purchase_seq IS NULL OR u.event_seq < p.next_purchase_seq)
)
SELECT p.match_id, p.participant_id, p.item_id, p.event_seq, p.timestamp_ms
FROM purchase AS p
LEFT JOIN undone AS u
  ON u.match_id = p.match_id AND u.participant_id = p.participant_id AND u.event_seq = p.event_seq
WHERE u.event_seq IS NULL
