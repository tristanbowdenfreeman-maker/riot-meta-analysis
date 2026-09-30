-- Each player's completed items numbered in the order they were first bought (1st item, 2nd item...).
CREATE OR ALTER VIEW mart.v_completed_item_order
AS
SELECT x.match_id, x.participant_id, x.item_id,
       ROW_NUMBER() OVER (PARTITION BY x.match_id, x.participant_id ORDER BY x.first_seq) AS item_number
FROM (
    SELECT ip.match_id, ip.participant_id, ip.item_id, MIN(ip.event_seq) AS first_seq
    FROM mart.v_item_purchase AS ip
    JOIN dim.item AS d ON d.item_id = ip.item_id
    WHERE d.item_class = 'Completed'
    GROUP BY ip.match_id, ip.participant_id, ip.item_id
) AS x;
GO
