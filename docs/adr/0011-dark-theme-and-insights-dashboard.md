# 11. Dark theme, headline figures and an Insights dashboard

**Status:** accepted, 2026-09-30. Objectives and gold-lead cards added by [0014](0014-objectives-and-gold-leads.md).

## Context

- The site joins the portfolio as "League of Legends Statistics". The portfolio's League card and its
  dark sections use ink (`#151713`) with paper text, and the light paper version read as flat.
- The site is for data analyst and BI hiring managers. The size of the data behind it (close to a
  million item events) is part of what it shows, but it was only visible as a match count.
- The Insights page used static SVG scatter plots and a heat table. They answered the questions
  but needed reading closely, and nothing responded to the reader.

## Decision

- **Theme:** the portfolio's tokens, fonts and nav on an ink background. Orange stays the one
  accent. Active pills and tabs invert to paper.
- **Headline figures:** `mart.v_data_volume` counts, per patch, the matches, player records,
  timelines, item events, rune choices, bans, ladder players, fact rows and mart views.
  - The tier list and Insights show three as a triangle at the top right of the hero: item events
    on top in orange, ranked matches and player records under it.
  - Insights adds rune choices, bans, champions played and days of games in one box, divided by
    thin rules rather than a card each.
  - Every figure counts up when it scrolls into view. Its width is fixed first, so the text
    beside it doesn't move.
  - Raw JSON size was dropped: storage size says little to a reader.
  - Each count is a key seek per match, so the view takes about half a second at 4,000 matches.
- **Insights as a dashboard:** one card per finding, each with a one-line takeaway, an
  interactive chart and a footnote.
  - Winners against losers: a bar per stat, with a role slicer. The bars slide between roles.
  - Bans: a column per ban band with its margin of error. Picking a column lists that band's
    champions (cross-filtering).
  - Small samples: the top ten by raw or adjusted win rate, as dots joined by a line. The
    adjusted dot slides from the raw one, and rows slide to their new rank when the slicer changes.
  - Sides as a split bar; the sample by rank as bars.
  - The pipeline as a line that draws across, with each stage's own figure (ladder players, staged
    games and timelines, fact rows, mart views, data checks) and the data checks under it.
  - Every mark has a tooltip on hover, tap or keyboard focus.
- The tier list has a champion search: `/` focuses it, Enter opens the first result, Escape
  clears it.
- Charts are plain HTML and CSS with a little JavaScript: no chart library, no build step.

## Consequences

- The scatter plots and heat table are gone. Their numbers are in the tooltips.
- With reduced motion, every chart renders in its final state with no count-up or slide.
- `tests/test_site_data.py` checks the headline figures against the other exported files.
