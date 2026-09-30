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
  (files[name] ??= fetch(`data/${name}.json`).then((r) => {
    if (!r.ok) throw new Error(`data/${name}.json: ${r.status}`);
    return r.json();
  }));

const db = {};          // lookups and the current patch, filled in by init()
let current = null;     // the page on screen, so role switches on the tier list don't re-render it
let tierSort = { key: "tier", asc: true };

// ---------- Formatting ----------

const pct = (x, digits = 1) => (x == null ? "–" : `${(x * 100).toFixed(digits)}%`);
const num = (n) => n.toLocaleString("en-GB");
const plural = (n, one, many = `${one}s`) => `${num(n)} ${n === 1 ? one : many}`;
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const wr = (x) => `<span class="${x >= 0.5 ? "good" : "muted"}">${pct(x, 2)}</span>`;

const champImg = (c, cls = "") =>
  `<img class="icon ${cls}" src="${IMG}/${db.version}/img/champion/${c.champion_key}.png" alt="${esc(c.champion_name)}" loading="lazy" width="36" height="36">`;
const itemImg = (id, cls = "") => {
  const name = db.items.get(id)?.item_name ?? `Item ${id}`;
  return `<img class="icon ${cls}" src="${IMG}/${db.version}/img/item/${id}.png" alt="${esc(name)}" title="${esc(name)}" loading="lazy" width="36" height="36">`;
};
const spellImg = (id) => {
  const s = db.spells.get(id);
  return s ? `<img class="icon" src="${IMG}/${db.version}/img/spell/${s.spell_key}.png" alt="${esc(s.spell_name)}" title="${esc(s.spell_name)}" loading="lazy" width="36" height="36">` : "";
};
const perkImg = (path, name, cls = "") =>
  `<img class="icon round ${cls}" src="${IMG}/img/${path}" alt="${esc(name)}" title="${esc(name)}" loading="lazy">`;

const figure = (share, games) => `<div class="figure"><strong>${pct(share, 2)}</strong><small>${plural(games, "game")}</small></div>`;

// ---------- Data ----------

async function init() {
  const [meta, patches, tiers, champions, items, runes, trees, shards, spells, matchups] = await Promise.all(
    ["meta", "patch_summary", "tier_list", "champions", "items", "runes", "rune_trees", "shards", "spells", "champion_matchups"].map(load),
  );
  const byPatch = (a, b) => b.patch.localeCompare(a.patch, undefined, { numeric: true });
  const patch = [...patches].sort(byPatch)[0];

  Object.assign(db, {
    version: meta.ddragon_version,
    patch: patch.patch,
    matches: patch.matches,
    // Hide options below this many games: 50 at 3,000 matches, 500 at 30,000.
    minGames: Math.max(1, Math.round(patch.matches / 60)),
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
  document.getElementById("patch-label").textContent = `Patch ${db.patch} · ${plural(db.matches, "match", "matches")}`;
}

const forChampion = (rows, championId, role) =>
  rows.filter((r) => r.patch === db.patch && r.champion_id === championId && r.role === role);
const byGames = (a, b) => b.games - a.games;

function counters(championId, role, weakest) {
  const minGames = Math.max(1, Math.round(db.minGames / 10));
  return db.matchups
    .filter((m) => m.champion_id === championId && m.role === role && m.games >= minGames)
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
    const weak = counters(r.champion_id, r.role, true).slice(0, 3)
      .map((m) => db.champions.get(m.opponent_id)).filter(Boolean)
      .map((o) => champImg(o, "sm round")).join("");
    return `<tr class="link rise" style="--i:${Math.min(i, 20)}" data-href="#/champion/${c.champion_key}/${r.role}">
      <td class="rank left hide-sm">${i + 1}</td>
      <td class="left"><div class="champ-cell">${champImg(c)}<span>${esc(c.champion_name)}</span></div></td>
      <td><span class="tier tier-${r.tier}">${r.tier}</span></td>
      <td>${pct(r.win_rate, 2)}</td>
      <td>${pct(r.pick_rate, 2)}</td>
      <td class="hide-sm">${pct(r.ban_rate, 2)}</td>
      <td class="hide-sm">${num(r.games)}</td>
      <td class="left hide-sm role-label">${ROLE_NAME[r.role]}</td>
      <td class="hide-sm"><div class="counters">${weak}</div></td>
    </tr>`;
  }).join("");

  return `<div class="table-wrap"><table>
    <thead><tr><th class="left hide-sm">#</th><th class="left">Champion</th>${head}<th class="left hide-sm">Role</th><th class="hide-sm">Weak against</th></tr></thead>
    <tbody>${body || `<tr><td colspan="9" class="left muted">No champions reach the minimum games yet.</td></tr>`}</tbody>
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
      <h1>Who's winning<br>patch ${esc(db.patch)}</h1>
      <p>Win, pick and ban rates for every champion in Emerald+ solo/duo on EUW, from ${plural(db.matches, "ranked match", "ranked matches")}.</p>
    </div>
    ${tabs(ROLES, role, (r) => (r === "ALL" ? "#/" : `#/role/${r}`))}
    <div class="table-slot">${tierTable(role)}</div>
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
    if (row) location.hash = row.dataset.href;
  });
}

// ---------- Champion page ----------

function optionPanel(title, rows, icons, share = (r) => r.pick_share) {
  const body = rows.length
    ? rows.map((r, i) => `<div class="option rise" style="--i:${i}">
        <div class="icons">${icons(r)}</div>${figure(share(r), r.games)}<div class="figure">${wr(r.win_rate)}</div>
      </div>`).join("")
    : `<div class="empty">Not enough games yet.</div>`;
  return `<div class="panel"><div class="option head"><h3>${title}</h3><span>Pick rate</span><span>Win rate</span></div>${body}</div>`;
}

function starterIcons(starterItems) {
  return starterItems.split(",").map((pair) => {
    const [id, qty] = pair.split(":").map(Number);
    return qty > 1 ? `<span class="qty">${itemImg(id)}<span>${qty}</span></span>` : itemImg(id);
  }).join("");
}

function runeBoard(page, picks, shardPicks) {
  const stats = new Map(picks.map((p) => [p.rune_id, p]));
  const cell = (rune, isKeystone) => {
    const s = stats.get(rune.rune_id);
    return { rune, s, html: (on) => `<div class="rune${isKeystone ? " keystone" : ""}${on ? "" : " off"}">
      ${perkImg(rune.icon_path, rune.rune_name)}
      ${s ? `<div class="${on ? "good" : ""}">${pct(s.win_rate)}</div><div>${pct(s.pick_share)}</div><div class="games">${num(s.games)}</div>`
          : `<div class="faint">–</div>`}
    </div>` };
  };
  // In each row, the most-picked rune is lit and the rest are dimmed.
  const row = (runes, isKeystone) => {
    const cells = runes.map((r) => cell(r, isKeystone));
    const best = Math.max(0, ...cells.map((c) => c.s?.games ?? 0));
    return `<div class="rune-row">${cells.map((c) => c.html(best > 0 && c.s?.games === best)).join("")}</div>`;
  };
  const tree = (treeId, slots) => {
    const runes = [...db.runes.values()].filter((r) => r.tree_id === treeId);
    const rows = slots.map((slot) => row(runes.filter((r) => r.slot_index === slot), slot === 0)).join("");
    return `<div class="rune-tree"><h4>${esc(db.trees.get(treeId)?.tree_name ?? "")}</h4>${rows}</div>`;
  };

  const shardStats = (rowIndex, id) => shardPicks.find((s) => s.shard_row === rowIndex + 1 && s.shard_id === id);
  const shards = SHARD_ROWS.map((ids, i) => {
    const best = Math.max(0, ...ids.map((id) => shardStats(i, id)?.games ?? 0));
    return `<div class="rune-row">${ids.map((id) => {
      const s = shardStats(i, id), meta = db.shards.get(id), on = best > 0 && s?.games === best;
      return `<div class="rune${on ? "" : " off"}">${perkImg(meta.icon_path, meta.shard_name, "sm")}
        ${s ? `<div class="${on ? "good" : ""}">${pct(s.win_rate)}</div><div>${pct(s.pick_share)}</div><div class="games">${num(s.games)}</div>` : `<div class="faint">–</div>`}
      </div>`;
    }).join("")}</div>`;
  }).join("");

  return `<div class="rune-board">
    ${tree(page.primary_tree_id, [0, 1, 2, 3])}
    ${tree(page.secondary_tree_id, [1, 2, 3])}
    <div class="rune-tree"><h4>Shards</h4>${shards}</div>
  </div>`;
}

async function renderChampion(key, role) {
  const champ = db.byKey.get(key.toLowerCase());
  if (!champ) return renderNotFound();

  const roles = db.tiers.filter((t) => t.champion_id === champ.champion_id).sort(byGames);
  if (!roles.length) return renderNotFound(`${champ.champion_name} hasn't been played in the sample yet.`);
  const stats = roles.find((r) => r.role === role) ?? roles[0];
  role = stats.role;

  view.innerHTML = `<div class="loading">Loading ${esc(champ.champion_name)}…</div>`;
  const [starters, boots, cores, slots, pages, runePicks, shardPicks, spells] = await Promise.all(
    ["champion_starter_sets", "champion_boots", "champion_core_builds", "champion_item_slots",
     "champion_rune_stats", "champion_rune_picks", "champion_shard_picks", "champion_spell_stats"].map(load),
  );
  const mine = (rows) => forChampion(rows, champ.champion_id, role).sort(byGames);
  const runePages = mine(pages).slice(0, 2);
  const minOption = Math.max(1, Math.round(db.minGames / 10));
  const top = (rows, n) => rows.filter((r) => r.games >= minOption).slice(0, n);

  const slotPanels = [4, 5, 6].map((n) => optionPanel(
    `${["", "", "", "", "Fourth", "Fifth", "Sixth"][n]} item`,
    top(mine(slots).filter((s) => s.item_number === n), 5),
    (r) => itemImg(r.item_id),
  )).join("");

  const matchup = (weakest) => counters(champ.champion_id, role, weakest).slice(0, 5)
    .map((m) => ({ ...m, pick_share: m.games / stats.games }));

  view.innerHTML = `<div class="page">
    <a class="back" href="${role ? `#/role/${role}` : "#/"}">← Tier list</a>
    <div class="champ-head">
      <img src="${IMG}/${db.version}/img/champion/${champ.champion_key}.png" alt="">
      <div>
        <h1>${esc(champ.champion_name)}</h1>
        <p class="sub">${ROLE_NAME[role]} · ${esc(champ.primary_class ?? "")}</p>
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

    <section>
      <h2>Runes</h2>
      <div class="rune-pages">${runePages.map((p, i) => `<button class="rune-page" aria-pressed="${i === 0}" data-page="${i}">
        <div class="icons">${perkImg(db.runes.get(p.keystone_id)?.icon_path ?? "", p.keystone_name ?? "", "lg")}
          ${perkImg(db.trees.get(p.secondary_tree_id)?.icon_path ?? "", p.secondary_tree_name ?? "", "sm")}
          <div class="page-name"><strong>${esc(p.keystone_name)}</strong><small>${esc(p.primary_tree_name)} + ${esc(p.secondary_tree_name)}</small></div></div>
        ${figure(p.pick_share, p.games)}<div class="figure">${wr(p.win_rate)}</div>
      </button>`).join("")}</div>
      <div class="rune-slot">${runePages.length ? runeBoard(runePages[0], mine(runePicks), mine(shardPicks)) : `<div class="panel"><div class="empty">Not enough games yet.</div></div>`}</div>
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
        (r) => [r.item1_id, r.item2_id, r.item3_id].map((id) => itemImg(id)).join('<span class="arrow">›</span>'))}
    </section>

    <section>
      <h2>Late items</h2>
      <div class="grid-3">${slotPanels}</div>
    </section>

    <section>
      <h2>Matchups</h2>
      <div class="grid-2">
        ${optionPanel("Weak against", matchup(true), (r) => { const o = db.champions.get(r.opponent_id); return o ? `${champImg(o, "round")}<span>${esc(o.champion_name)}</span>` : ""; }, (r) => r.pick_share)}
        ${optionPanel("Strong against", matchup(false), (r) => { const o = db.champions.get(r.opponent_id); return o ? `${champImg(o, "round")}<span>${esc(o.champion_name)}</span>` : ""; }, (r) => r.pick_share)}
      </div>
    </section>
  </div>`;

  const el = view.firstElementChild;
  current = { page: "champion", el };
  reveal(el.querySelectorAll("section"));
  wireTabs(el);
  el.querySelector(".rune-pages")?.addEventListener("click", (e) => {
    const button = e.target.closest(".rune-page");
    if (!button) return;
    el.querySelectorAll(".rune-page").forEach((b) => b.setAttribute("aria-pressed", b === button));
    el.querySelector(".rune-slot").innerHTML = runeBoard(runePages[button.dataset.page], mine(runePicks), mine(shardPicks));
  });
  window.scrollTo({ top: 0 });
}

function renderNotFound(message = "That page doesn't exist.") {
  current = null;
  view.innerHTML = `<div class="page hero"><h1>Not found</h1><p>${esc(message)}</p><p><a class="good" href="#/">Back to the tier list</a></p></div>`;
}

const observer = "IntersectionObserver" in window && new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (entry.isIntersecting) {
      entry.target.classList.add("in");
      observer.unobserve(entry.target);
    }
  }
}, { rootMargin: "0px 0px -10% 0px" });

function reveal(elements) {
  if (!observer) return;
  elements.forEach((e) => { e.classList.add("reveal"); observer.observe(e); });
}

// ---------- Router ----------

function route() {
  const [, page, a, b] = location.hash.replace(/^#\/?/, "#/").split("/");
  if (!page) return renderTierList("ALL");
  if (page === "role" && ROLE_NAME[a]) return renderTierList(a);
  if (page === "champion" && a) return renderChampion(decodeURIComponent(a), b);
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
