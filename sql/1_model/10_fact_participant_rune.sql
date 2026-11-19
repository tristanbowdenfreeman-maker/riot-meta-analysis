-- Key: match_id, participant_id, rune_id.
CREATE TABLE IF NOT EXISTS riot_fact.participant_rune (
    match_id         STRING NOT NULL,
    participant_id   INT64  NOT NULL,
    rune_id          INT64  NOT NULL,
    tree_id          INT64  NOT NULL,
    is_primary_tree  BOOL   NOT NULL,
    selection_index  INT64  NOT NULL   -- 0 = keystone when is_primary_tree
);
