-- Empties the fact tables so every raw match and timeline is re-parsed on the next load.
-- Use after changing etl.usp_load_matches or etl.usp_load_timelines.
CREATE OR ALTER PROCEDURE etl.usp_reset_facts
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;
    DELETE FROM fact.participant_skills;
    DELETE FROM fact.participant_frame;
    DELETE FROM fact.team_objective;
    DELETE FROM fact.item_event;
    DELETE FROM fact.match_timeline;
    DELETE FROM fact.participant_rune;
    DELETE FROM fact.participant_item;
    DELETE FROM fact.match_ban;
    DELETE FROM fact.match_participant;
    DELETE FROM fact.match;
    COMMIT TRANSACTION;
END;
GO
