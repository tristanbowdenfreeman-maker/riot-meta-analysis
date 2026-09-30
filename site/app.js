// Rift Meta: reads the JSON exported from the SQL Server mart views (site/data) and renders
// two pages, the tier list (#/ or #/role/TOP) and a champion page (#/champion/Gangplank/TOP).

const IMG = "https://ddragon.leagueoflegends.com/cdn";
const ROLES = [
  ["ALL", "All"], ["TOP", "Top"], ["JUNGLE", "Jungle"],
  ["MIDDLE", "Middle"], ["BOTTOM", "Bottom"], ["UTILITY", "Support"],
];
const ROLE_NAME = Object.fromEntries(ROLES);
const TIER_ORDER = { OP: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5 };
// The options offered in each stat-shard row (offense, flex, defense).
const SHARD_ROWS = [[5008, 5005, 5007], [5008, 5010, 5001], [5011, 5013, 5001]];

const view = document.getElementById("view");
const files = {};
const load = (name) =>
  (files[name] ??= fetch(`data/${name}.json`)
    .then((r) => {
      if (!r.ok) throw new Error(`data/${name}.json: ${r.status}`);
      return r.json();
    })
    .catch((error) => {
      delete files[name];  // let the next visit try again
      throw error;
    }));

const db = {};          // lookups and the current patch, filled in by init()
let current = null;     // the page on screen, so role switches on the tier list don't re-render it
let navigation = 0;     // bumped on every route, so a slow champion load can't overwrite a newer page
let tierSort = { key: "tier", asc: true };

// ---------- Formatting ----------

const pct = (x, digits = 1) => (x == null ? "–" : `${(x * 100).toFixed(digits)}%`);
const num = (n) => n.toLocaleString("en-GB");
const plural = (n, one, many = `${one}s`) => `${num(n)} ${n === 1 ? one : many}`;
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const wr = (x) => `<span class="${x >= 0.5 ? "good" : "muted"}">${pct(x, 2)}</span>`;
// Data Dragon versions run 10 behind the patch names players see: game version 16.19 is patch 26.19.
const patchName = (version) => version.replace(/^(\d+)/, (major) => String(Number(major) + 10));

const champImg = (c, cls = "") =>
  `<img class="icon ${cls}" src="${IMG}/${db.version}/img/champion/${c.champion_key}.png" alt="${esc(c.champion_name)}" title="${esc(c.champion_name)}" loading="lazy" width="36" height="36">`;
const itemImg = (id) => {
  const name = db.items.get(id)?.item_name ?? `Item ${id}`;
  return `<img class="icon" src="${IMG}/${db.version}/img/item/${id}.png" alt="${esc(name)}" title="${esc(name)}" loading="lazy" width="36" height="36">`;
};
const spellImg = (id) => {
  const s = db.spells.get(id);
  return s ? `<img class="icon" src="${IMG}/${db.version}/img/spell/${s.spell_key}.png" alt="${esc(s.spell_name)}" title="${esc(s.spell_name)}" loading="lazy" width="36" height="36">` : "";
};
const perkImg = (path, name, cls = "") =>
  path ? `<img class="icon round ${cls}" src="${IMG}/img/${path}" alt="${esc(name)}" title="${esc(name)}" loading="lazy">` : "";

const figure = (share, games) => `<div class="figure"><strong>${pct(share, 2)}</strong><small>${plural(games, "game")}</small></div>`;

// ---------- Data ----------

async function init() {
  const [meta, patches, tiers, champions, items, runes, trees, shards, spells, matchups] = await Promise.all(
    ["meta", "patch_summary", "tier_list", "champions", "items", "runes", "rune_trees", "shards", "spells", "champion_matchups"].map(load),
  );
  if (!patches.length) throw new Error("The export has no matches yet.");
  const byPatch = (a, b) => b.patch.localeCompare(a.patch, undefined, { numeric: true });
  const patch = [...patches].sort(byPatch)[0];

  Object.assign(db, {
    version: meta.ddragon_version,
    patch: patch.patch,
    matches: patch.matches,
    // Build, rune and matchup options need 1 game per 300 matches in the sample (at least 10),
    // so nothing on the site rests on a handful of games: 10 at 3,000 matches, 100 at 30,000.
    minGames: Math.max(10, Math.round(patch.matches / 300)),
    tiers: tiers.filter((t) => t.patch === patch.patch),
    matchups: matchups.filter((m) => m.patch === patch.patch),
    champions: new Map(champions.map((c) => [c.champion_id, c])),
    byKey: new Map(champions.map((c) => [c.champion_key.toLowerCase(), c])),
    items: new Map(items.map((i) => [i.item_id, i])),
    runes: new Map(runes.map((r) => [r.rune_id, r])),
    trees: new Map(trees.map((t) => [t.tree_id, t])),
    shards: new Map(shards.map((s) => [s.shard_id, s])),
    spells: new Map(spells.map((s) => [s.spell_id, s])),
  });
  document.getElementById("patch-label").textContent = `Patch ${patchName(db.patch)} · ${plural(db.matches, "match", "matches")}`;
}

const forChampion = (rows, championId, role) =>
  rows.filter((r) => r.patch === db.patch && r.champion_id === championId && r.role === role);
const byGames = (a, b) => b.games - a.games;
const enoughGames = (r) => r.games >= db.minGames;

// Lane opponents with enough games: weakest = the ones this champion loses to most.
function counters(championId, role, weakest) {
  return db.matchups
    .filter((m) => m.champion_id === championId && m.role === role && enoughGames(m))
    .filter((m) => (weakest ? m.win_rate < 0.5 : m.win_rate > 0.5))
    .sort((a, b) => (weakest ? a.win_rate - b.win_rate : b.win_rate - a.win_rate) || b.games - a.games);
}

// ---------- Role tabs ----------

function tabs(roles, selected, href) {
  const buttons = roles
    .map(([role, label]) => `<button role="tab" aria-selected="${role === selected}" data-role="${role}" data-href="${href(role)}">${label}</button>`)
    .join("");
  return `<div class="tabs" role="tablist"><span class="indicator"></span>${buttons}</div>`;
}

function moveIndicator(container) {
  const bar = container.querySelector(".tabs");
  const on = bar?.querySelector('[aria-selected="true"]');
  if (!on) return;
  const indicator = bar.querySelector(".indicator");
  indicator.style.width = `${on.offsetWidth}px`;
  indicator.style.transform = `translateX(${on.offsetLeft}px)`;
}

function wireTabs(container) {
  container.querySelector(".tabs")?.addEventListener("click", (e) => {
    const button = e.target.closest("button[data-href]");
    if (button) location.hash = button.dataset.href;
  });
  moveIndicator(container);
}

// ---------- Tier list ----------

const TIER_COLUMNS = [
  ["tier", "Tier"], ["win_rate", "Win rate"], ["pick_rate", "Pick rate"], ["ban_rate", "Ban rate"], ["games", "Games"],
];

function tierRows(role) {
  const rows = db.tiers.filter((t) => t.tier != null && (role === "ALL" || t.role === role));
  const { key, asc } = tierSort;
  const value = (r) => (key === "tier" ? TIER_ORDER[r.tier] * 10 - r.adjusted_win_rate : r[key]);
  return rows.sort((a, b) => (asc ? value(a) - value(b) : value(b) - value(a)));
}

function tierTable(role) {
  const head = TIER_COLUMNS.map(([key, label]) => {
    const sorted = tierSort.key === key ? ` aria-sort="${tierSort.asc ? "ascending" : "descending"}"` : "";
    return `<th${sorted}${["ban_rate", "games"].includes(key) ? ' class="hide-sm"' : ""}><button data-sort="${key}">${label}</button></th>`;
  }).join("");

  const body = tierRows(role).map((r, i) => {
    const c = db.champions.get(r.champion_id) ?? { champion_key: "", champion_name: r.champion_name };
    const href = `#/champion/${c.champion_key}/${r.role}`;
    const weak = counters(r.champion_id, r.role, true).slice(0, 3)
      .map((m) => db.champions.get(m.opponent_id)).filter(Boolean)
      .map((o) => champImg(o, "sm round")).join("");
    return `<tr class="link rise" style="--i:${Math.min(i, 20)}" data-href="${href}">
      <td class="rank left hide-sm">${i + 1}</td>
      <td class="left"><a class="champ-cell" href="${href}">${champImg(c)}<span>${esc(c.champion_name)}</span></a></td>
      <td><span class="tier tier-${r.tier}">${r.tier}</span></td>
      <td>${pct(r.win_rate, 2)}</td>
      <td>${pct(r.pick_rate, 2)}</td>
      <td class="hide-sm">${pct(r.ban_rate, 2)}</td>
      <td class="hide-sm">${num(r.games)}</td>
      <td class="left hide-sm role-label">${ROLE_NAME[r.role]}</td>
      <td class="hide-sm"><div class="counters">${weak || '<span class="faint">–</span>'}</div></td>
    </tr>`;
  }).join("");

  return `<div class="table-wrap"><table>
    <thead><tr><th class="left hide-sm">#</th><th class="left">Champion</th>${head}<th class="left hide-sm">Role</th><th class="hide-sm">Weak against</th></tr></thead>
    <tbody>${body || `<tr><td colspan="9" class="left muted">No champions have enough games in this role yet.</td></tr>`}</tbody>
  </table></div>`;
}

function renderTierList(role) {
  if (current?.page === "tiers") {
    // Same page, new role: slide the tab indicator and swap only the table.
    current.el.querySelectorAll(".tabs button").forEach((b) => b.setAttribute("aria-selected", b.dataset.role === role));
    moveIndicator(current.el);
    current.el.querySelector(".table-slot").innerHTML = tierTable(role);
    current.role = role;
    return;
  }

  view.innerHTML = `<div class="page">
    <div class="hero">
      <h1>Who's winning<br>patch ${esc(patchName(db.patch))}</h1>
      <p>Win, pick and ban rates for every champion in Emerald+ solo/duo on EUW, from ${plural(db.matches, "ranked match", "ranked matches")}.</p>
    </div>
    ${tabs(ROLES, role, (r) => (r === "ALL" ? "#/" : `#/role/${r}`))}
    <div class="table-slot">${tierTable(role)}</div>
    <p class="method">Tiers rank champions within each role by win rate, adjusted towards 50% for small
      samples. A champion needs a 1% pick rate in a role to be ranked. Matchups need ${num(db.minGames)}+ games.</p>
  </div>`;
  const el = view.firstElementChild;
  current = { page: "tiers", el, role };
  wireTabs(el);

  el.querySelector(".table-slot").addEventListener("click", (e) => {
    const sort = e.target.closest("button[data-sort]");
    if (sort) {
      const key = sort.dataset.sort;
      tierSort = { key, asc: tierSort.key === key ? !tierSort.asc : key === "tier" };
      el.querySelector(".table-slot").innerHTML = tierTable(current.role);
      return;
    }
    const row = e.target.closest("tr[data-href]");
    if (row && !e.target.closest("a")) location.hash = row.dataset.href;
  });
}

// ---------- Champion page ----------

function optionPanel(title, rows, icons, labels = ["Pick rate", "Win rate"]) {
  const body = rows.length
    ? rows.map((r, i) => `<div class="option rise" style="--i:${i}">
        <div class="icons">${icons(r)}</div>${figure(r.pick_share, r.games)}<div class="figure">${wr(r.win_rate)}</div>
      </div>`).join("")
    : `<div class="empty">No option has ${num(db.minGames)}+ games yet.</div>`;
  return `<div class="panel"><div class="option head"><h3>${title}</h3><span>${labels[0]}</span><span>${labels[1]}</span></div>${body}</div>`;
}

function starterIcons(starterItems) {
  return starterItems.split(",").map((pair) => {
    const [id, qty] = pair.split(":").map(Number);
    return qty > 1 ? `<span class="qty">${itemImg(id)}<span>${qty}</span></span>` : itemImg(id);
  }).join("");
}

// One grid cell: icon plus win rate, pick share and games, dimmed unless `on`.
function runeCell(icon, stats, on, extraClass = "") {
  const figures = stats
    ? `<div class="${on ? "good" : ""}">${pct(stats.win_rate)}</div><div>${pct(stats.pick_share)}</div><div class="games">${num(stats.games)}</div>`
    : `<div class="faint">–</div>`;
  return `<div class="rune${extraClass}${on ? "" : " off"}">${icon}${figures}</div>`;
}

// The rune grid for one rune page. picks and shardPicks are already limited to that page.
function runeBoard(page, picks, shardPicks) {
  const runesIn = (treeId) => [...db.runes.values()].filter((r) => r.tree_id === treeId);
  const statsFor = (isPrimary) => new Map(picks.filter((p) => p.is_primary_tree === isPrimary).map((p) => [p.rune_id, p]));
  const primary = statsFor(true);
  const secondary = statsFor(false);

  // Primary tree: the most picked rune in each row is lit.
  const primaryRows = [0, 1, 2, 3].map((slot) => {
    const runes = runesIn(page.primary_tree_id).filter((r) => r.slot_index === slot);
    const best = Math.max(0, ...runes.map((r) => primary.get(r.rune_id)?.games ?? 0));
    return `<div class="rune-row">${runes.map((r) => {
      const s = primary.get(r.rune_id);
      return runeCell(perkImg(r.icon_path, r.rune_name), s, best > 0 && s?.games === best, slot === 0 ? " keystone" : "");
    }).join("")}</div>`;
  }).join("");

  // Secondary tree: players take two runes from different rows, so light the two most picked
  // runes that sit in different rows.
  const secondaryRunes = runesIn(page.secondary_tree_id).filter((r) => r.slot_index > 0);
  const lit = new Set();
  const litRows = new Set();
  for (const r of [...secondaryRunes].sort((a, b) => (secondary.get(b.rune_id)?.games ?? 0) - (secondary.get(a.rune_id)?.games ?? 0))) {
    if (lit.size === 2 || !secondary.get(r.rune_id)) break;
    if (litRows.has(r.slot_index)) continue;
    lit.add(r.rune_id);
    litRows.add(r.slot_index);
  }
  const secondaryRows = [1, 2, 3].map((slot) => `<div class="rune-row">${secondaryRunes
    .filter((r) => r.slot_index === slot)
    .map((r) => runeCell(perkImg(r.icon_path, r.rune_name), secondary.get(r.rune_id), lit.has(r.rune_id)))
    .join("")}</div>`).join("");

  const shardRows = SHARD_ROWS.map((ids, i) => {
    const statsOf = (id) => shardPicks.find((s) => s.shard_row === i + 1 && s.shard_id === id);
    const best = Math.max(0, ...ids.map((id) => statsOf(id)?.games ?? 0));
    return `<div class="rune-row">${ids.map((id) => {
      const s = statsOf(id);
      const shard = db.shards.get(id);
      return runeCell(perkImg(shard?.icon_path, shard?.shard_name, "sm"), s, best > 0 && s?.games === best);
    }).join("")}</div>`;
  }).join("");

  const title = (treeId) => `<h4>${esc(db.trees.get(treeId)?.tree_name)}</h4>`;
  return `<div class="rune-board">
    <div class="rune-tree">${title(page.primary_tree_id)}${primaryRows}</div>
    <div class="rune-tree">${title(page.secondary_tree_id)}${secondaryRows}</div>
    <div class="rune-tree"><h4>Shards</h4>${shardRows}</div>
    <p class="legend">Under each rune: win rate, share of this page's players who take it, games.</p>
  </div>`;
}

async function renderChampion(key, role, ticket) {
  const champ = db.byKey.get(key.toLowerCase());
  if (!champ) return renderNotFound();

  const allRoles = db.tiers.filter((t) => t.champion_id === champ.champion_id).sort(byGames);
  if (!allRoles.length) return renderNotFound(`${champ.champion_name} hasn't been played in the sample yet.`);
  const stats = allRoles.find((r) => r.role === role) ?? allRoles.find((r) => r.tier != null) ?? allRoles[0];
  role = stats.role;
  // Role tabs: the roles this champion is ranked in, plus the one on screen.
  const roles = allRoles.filter((r) => r.tier != null || r.role === role);

  view.innerHTML = `<div class="loading">Loading ${esc(champ.champion_name)}…</div>`;
  const [starters, boots, cores, late, pages, runePicks, shardPicks, spells] = await Promise.all(
    ["champion_starter_sets", "champion_boots", "champion_core_builds", "champion_late_items",
     "champion_rune_stats", "champion_rune_picks", "champion_shard_picks", "champion_spell_stats"].map(load),
  );
  if (ticket !== navigation) return;  // the reader has already moved on

  const mine = (rows) => forChampion(rows, champ.champion_id, role).sort(byGames);
  const top = (rows, n) => rows.filter(enoughGames).slice(0, n);
  const runePages = mine(pages).filter((p) => p.page_rank <= 2 && enoughGames(p)).sort((a, b) => a.page_rank - b.page_rank);
  const board = (page) => runeBoard(page,
    mine(runePicks).filter((p) => p.page_rank === page.page_rank),
    mine(shardPicks).filter((s) => s.page_rank === page.page_rank));

  const opponent = (r) => {
    const o = db.champions.get(r.opponent_id);
    return o ? `${champImg(o, "round")}<span>${esc(o.champion_name)}</span>` : "";
  };
  const matchup = (weakest) => counters(champ.champion_id, role, weakest).slice(0, 5)
    .map((m) => ({ ...m, pick_share: m.games / stats.games }));

  const sample = stats.tier == null
    ? `Only ${plural(stats.games, "game")} as ${ROLE_NAME[role]}, too few to rank. Treat these numbers as rough.`
    : `Based on ${plural(stats.games, "game")} as ${ROLE_NAME[role]}. Options with fewer than ${num(db.minGames)} games are hidden.`;

  view.innerHTML = `<div class="page">
    <a class="back" href="#/role/${role}">← Tier list</a>
    <div class="champ-head">
      <img src="${IMG}/${db.version}/img/champion/${champ.champion_key}.png" alt="">
      <div>
        <h1>${esc(champ.champion_name)}</h1>
        <p class="sub">${ROLE_NAME[role]} · ${esc(champ.primary_class)}</p>
      </div>
    </div>
    ${roles.length > 1 ? tabs(roles.map((r) => [r.role, ROLE_NAME[r.role]]), role, (r) => `#/champion/${champ.champion_key}/${r}`) : ""}

    <div class="stats">
      <div class="stat"><div class="label">Tier</div><div class="value">${stats.tier ? `<span class="tier tier-${stats.tier}">${stats.tier}</span>` : "–"}</div></div>
      <div class="stat"><div class="label">Win rate</div><div class="value">${pct(stats.win_rate, 2)}</div></div>
      <div class="stat"><div class="label">Pick rate</div><div class="value">${pct(stats.pick_rate, 2)}</div></div>
      <div class="stat"><div class="label">Ban rate</div><div class="value">${pct(stats.ban_rate, 2)}</div></div>
      <div class="stat"><div class="label">Games</div><div class="value">${num(stats.games)}</div></div>
    </div>
    <p class="method sample">${sample}</p>

    <section>
      <h2>Runes</h2>
      ${runePages.length ? `<div class="rune-panel"><div class="rune-pages">${runePages.map((p, i) => `<${runePages.length > 1 ? `button aria-pressed="${i === 0}"` : "div"} class="rune-page" data-page="${i}">
        <div class="icons">${perkImg(db.runes.get(p.keystone_id)?.icon_path, p.keystone_name, "lg")}
          ${perkImg(db.trees.get(p.secondary_tree_id)?.icon_path, p.secondary_tree_name, "sm")}
          <div class="page-name"><strong>${esc(p.keystone_name)}</strong><small>${esc(p.primary_tree_name)} + ${esc(p.secondary_tree_name)}</small></div></div>
        ${figure(p.pick_share, p.games)}<div class="figure">${wr(p.win_rate)}</div>
      </${runePages.length > 1 ? "button" : "div"}>`).join("")}</div>
      <div class="rune-slot">${board(runePages[0])}</div></div>`
      : `<div class="panel"><div class="empty">No rune page has ${num(db.minGames)}+ games yet.</div></div>`}
    </section>

    <section>
      <h2>Summoner spells</h2>
      <div class="grid-2">${optionPanel("Most picked", top(mine(spells), 2), (r) => spellImg(r.spell_a_id) + spellImg(r.spell_b_id))}</div>
    </section>

    <section>
      <h2>Items</h2>
      <div class="grid-2">
        ${optionPanel("Starter items", top(mine(starters), 2), (r) => starterIcons(r.starter_items))}
        ${optionPanel("Boots", top(mine(boots), 3), (r) => itemImg(r.item_id))}
      </div>
    </section>

    <section>
      <h2>Core builds</h2>
      ${optionPanel("First three completed items", top(mine(cores), 5),
        (r) => [r.item1_id, r.item2_id, r.item3_id].map(itemImg).join('<span class="arrow">›</span>'))}
    </section>

    <section>
      <h2>Late items</h2>
      ${optionPanel("Built 4th to 6th", top(mine(late), 5), (r) => itemImg(r.item_id), ["Built by", "Win rate"])}
      <p class="method">Built by: share of players who reached a 4th item that built it 4th, 5th or 6th.</p>
    </section>

    <section>
      <h2>Matchups</h2>
      <div class="grid-2">
        ${optionPanel("Weak against", matchup(true), opponent, ["Faced", "Win rate"])}
        ${optionPanel("Strong against", matchup(false), opponent, ["Faced", "Win rate"])}
      </div>
    </section>
  </div>`;

  const el = view.firstElementChild;
  current = { page: "champion", el };
  wireTabs(el);
  el.querySelector(".rune-pages")?.addEventListener("click", (e) => {
    const button = e.target.closest("button.rune-page");
    if (!button) return;
    el.querySelectorAll("button.rune-page").forEach((b) => b.setAttribute("aria-pressed", b === button));
    el.querySelector(".rune-slot").innerHTML = board(runePages[button.dataset.page]);
  });
  window.scrollTo({ top: 0 });
}

function renderNotFound(message = "That page doesn't exist.") {
  current = null;
  view.innerHTML = `<div class="page hero"><h1>Not found</h1><p>${esc(message)}</p><p><a class="good" href="#/">Back to the tier list</a></p></div>`;
}

// ---------- Router ----------

function route() {
  const ticket = ++navigation;
  const [, page, a, b] = (location.hash || "#/").split("/");
  if (!page) return renderTierList("ALL");
  if (page === "role" && ROLE_NAME[a] && a !== "ALL") return renderTierList(a);
  if (page === "champion" && a) {
    return renderChampion(decodeURIComponent(a), b, ticket).catch((error) => {
      if (ticket === navigation) renderNotFound(`Couldn't load the champion data (${error.message}).`);
    });
  }
  renderNotFound();
}

window.addEventListener("hashchange", () => {
  if (!(current?.page === "tiers" && /^#\/(role\/\w+)?$/.test(location.hash || "#/"))) current = null;
  route();
});
window.addEventListener("resize", () => current && moveIndicator(current.el));

init()
  .then(route)
  .catch((error) => {
    view.innerHTML = `<div class="page hero"><h1>No data</h1><p>${esc(error.message)}</p></div>`;
  });
