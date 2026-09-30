# 14. Objectives and gold leads

**Status:** accepted, 2026-09-30. Adds two cards to the Insights page from
[0011](0011-dark-theme-and-insights-dashboard.md).

## Context

The Insights page described players (winners against losers, bans, sides) but not the game
itself. The questions a team lead would ask weren't answered:

- Which objectives are worth fighting for?
- How safe is a gold lead?

The raw data already held the answers:

- Each match's `info.teams[].objectives` has, per team, whether it took each objective first and
  how many it took.
- Each timeline has every player's total gold, XP and creep score once a minute.

## Decision

**Facts**

- `fact.team_objective` holds one row per match, team and objective, with `is_first` and `kills`.
  It is loaded by `etl.usp_load_objectives`.
- `fact.participant_frame` holds each player's gold, XP and creep score at 10, 15, 20 and 25
  minutes. It is loaded by `etl.usp_load_frames`.
  - Only these four minute marks are kept, not every minute, which keeps the table at about 37
    rows per match.
  - The frame load skips games under 11 minutes. Such a game can't have a 10-minute frame, so it
    would otherwise be picked up on every run.
- Both procedures are incremental, like the match and timeline loads: they take only matches with
  no rows yet, in batches. `python -m riot_meta transform` runs them after the timeline load, so
  the collector keeps them up to date and they backfilled the existing matches on the first run.

**Views**

- `mart.v_objective_win_rate`: the win rate of the team that took each objective first, and how
  often anyone took it.
- `mart.v_objective_count_win_rate`: win rate by how many of an objective a team took.
  - The top count is capped and includes everything above it: dragons 4+, void grubs 3+,
    towers 9+, inhibitors 3+, others 2+.
  - Champion kills are left out; the winners vs losers card covers them.
- `mart.v_gold_lead_win_rate`: the leading team's win rate at each minute mark, by team gold lead.
  - The bands are 0–1k, 1–2k, 2–3k, 3–4k, 4–6k and 6k+.
  - Ties are left out.
- `mart.v_lane_lead_win_rate`: the team win rate when a player is 1,000+ gold ahead of the
  opponent in the same role, per minute and role.

**Checks** (blocking)

- Every valid match has objective rows.
- No objective was taken first by both teams.
- Every timeline of an 11+ minute game has gold frames.

**Site**

- **Objectives card:** one clickable bar per objective, showing its first-taken win rate. Picking
  one charts win rate by count taken, with a ± whisker per column. First blood happens once a
  game, so it compares the team that got it with the team that gave it up.
- **Gold leads card:** a 10/15/20/25-minute slicer drives two visuals: a column per lead band,
  and a bar per role for lane leads.

## Consequences

- At 4,949 matches:

  | Taken first | Team's win rate |
  |---|---|
  | First inhibitor | 90% |
  | First Baron | 80% |
  | First tower | 68% |
  | First blood | 58% |

  - A 2–3k lead at 15 minutes wins 71%, and 6k+ wins 95%.
  - A 1k+ lane lead is worth least for top (65% at 15 minutes); the other roles are 70–71%.
- These are associations, not causes. The better team takes objectives and gold as well as
  winning, and late objectives such as inhibitors fall close to the end of a game. Both cards say so.
- Later minute marks only count games still running, so they lean to longer games. The card shows
  how many games each minute covers.
- The match JSON also lists objectives that aren't in the game this patch (`voidGator`, with 0
  kills). The site only shows objectives that someone took first, so they don't appear.
