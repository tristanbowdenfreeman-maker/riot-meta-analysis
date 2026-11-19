-- Each player's completed items numbered in the order they were first bought (1st item, 2nd item...).
CREATE OR REPLACE TABLE riot_mart.completed_item_order AS
SELECT x.match_id, x.participant_id, x.item_id,
       ROW_NUMBER() OVER (PARTITION BY x.match_id, x.participant_id ORDER BY x.first_seq) AS item_number
FROM (
    SELECT ip.match_id, ip.participant_id, ip.item_id, MIN(ip.event_seq) AS first_seq
    FROM riot_mart.item_purchase AS ip
    JOIN riot_dim.item AS d ON d.item_id = ip.item_id
    WHERE d.item_class = 'Completed'
    GROUP BY ip.match_id, ip.participant_id, ip.item_id
) AS x;
