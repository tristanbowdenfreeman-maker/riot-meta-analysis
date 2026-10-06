// League of Legends Statistics: reads the JSON exported from the SQL Server mart views (site/data) and renders
// three pages: the insights (#/ or #/insights), the tier list (#/tiers or #/role/TOP) and a champion
// page (#/champion/Gangplank/TOP). Insights opens first: it's the analysis the project exists for.

const IMG = "https://ddragon.leagueoflegends.com/cdn";
const ROLES = [
  ["ALL", "All"], ["TOP", "Top"], ["JUNGLE", "Jungle"],
  ["MIDDLE", "Mid"], ["BOTTOM", "Bot"], ["UTILITY", "Support"],
];
const ROLE_NAME = Object.fromEntries(ROLES);
// "the average mid laner", "played as a jungler"
const ROLE_PLAYER = { TOP: "top laner", JUNGLE: "jungler", MIDDLE: "mid laner", BOTTOM: "bot laner", UTILITY: "support" };
const TIER_ORDER = { OP: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5 };
// The options offered in each stat-shard row (offense, flex, defense).
const SHARD_ROWS = [[5008, 5005, 5007], [5008, 5010, 5001], [5011, 5013, 5001]];

const view = document.getElementById("view");
const files = {};
const load = (name) =>
  (files[name] ??= fetch(`data/${name}.json`, { cache: "no-cache" })
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
let tierQuery = "";     // the tier list's champion search

// ---------- Formatting ----------

const pct = (x, digits = 1) => (x == null ? "–" : `${(x * 100).toFixed(digits)}%`);
const num = (n) => n.toLocaleString("en-GB");
const plural = (n, one, many = `${one}s`) => `${num(n)} ${n === 1 ? one : many}`;
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const wr = (x) => `<span class="${x >= 0.5 ? "good" : "muted"}">${pct(x, 2)}</span>`;
// A 95% margin of error in percentage points, e.g. "±5.1".
const moe = (x) => `±${(x * 100).toFixed(1)}`;
const signed = (x) => { const r = Math.round(x * 100); return `${r > 0 ? "+" : r < 0 ? "−" : ""}${Math.abs(r)}%`; };
// Data Dragon versions run 10 behind the patch names players see: game version 16.19 is patch 26.19.
const patchName = (version) => version.replace(/^(\d+)/, (major) => String(Number(major) + 10));

const champImg = (c, cls = "") =>
  `<img class="icon ${cls}" src="${IMG}/${db.version}/img/champion/${c.champion_key}.png" alt="${esc(c.champion_name)}" title="${esc(c.champion_name)}" loading="lazy" width="36" height="36">`;
const itemImg = (id) => {
  const name = db.items.get(id)?.item_name ?? `Item ${id}`;
  return `<img class="icon" src="${IMG}/${db.version}/img/item/${id}.png" alt="${esc(name)}" data-item="${id}" loading="lazy" width="36" height="36">`;
};
const spellImg = (id) => {
  const s = db.spells.get(id);
  return s ? `<img class="icon" src="${IMG}/${db.version}/img/spell/${s.spell_key}.png" alt="${esc(s.spell_name)}" data-spell="${esc(s.spell_key)}" loading="lazy" width="36" height="36">` : "";
};
const perkImg = (path, name, cls = "") =>
  path ? `<img class="icon round ${cls}" src="${IMG}/img/${path}" alt="${esc(name)}" data-perk="${esc(path)}" loading="lazy">` : "";


// ---------- Data ----------

async function init() {
  const [meta, patches, tiers, champions, items, runes, trees, shards, spells, matchups, volumes] = await Promise.all(
    ["meta", "patch_summary", "tier_list", "champions", "items", "runes", "rune_trees", "shards", "spells", "champion_matchups", "data_volume"].map(load),
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
    volume: volumes.find((v) => v.patch === patch.patch),
    avgMinutes: patch.avg_duration_min,
    firstGame: patch.first_game_utc,
    lastGame: patch.last_game_utc,
    matchups: matchups.filter((m) => m.patch === patch.patch),
    champions: new Map(champions.map((c) => [c.champion_id, c])),
    byKey: new Map(champions.map((c) => [c.champion_key.toLowerCase(), c])),
    items: new Map(items.map((i) => [i.item_id, i])),
    runes: new Map(runes.map((r) => [r.rune_id, r])),
    trees: new Map(trees.map((t) => [t.tree_id, t])),
    shards: new Map(shards.map((s) => [s.shard_id, s])),
    spells: new Map(spells.map((s) => [s.spell_id, s])),
  });
  document.getElementById("patch-label").textContent = `Patch ${patchName(db.patch)}`;
}

const forChampion = (rows, championId, role) =>
  rows.filter((r) => r.patch === db.patch && r.champion_id === championId && r.role === role);
const byGames = (a, b) => b.games - a.games;
const MATCHUP_MIN_GAMES = 5;   // counter picks, on the tier list and champion pages
const MATCHUP_PRIOR = 10;
const enoughGames = (r) => r.games >= db.minGames;

// Counter picks: lane opponents with 5+ games, ranked by win rate pulled towards the champion's
// own (winRate), as if each had 10 more games at that rate. A 5-0 then can't outrank a 30-10.
// Best first; best vs = score above winRate, worst vs = below.
function counterPicks(championId, role, winRate) {
  const laneGames = db.matchups.filter((m) => m.champion_id === championId && m.role === role);
  const laneTotal = laneGames.reduce((sum, m) => sum + m.games, 0);
  return laneGames.filter((m) => m.games >= MATCHUP_MIN_GAMES)
    .map((m) => ({ ...m, pick_share: m.games / laneTotal, score: (m.wins + MATCHUP_PRIOR * winRate) / (m.games + MATCHUP_PRIOR) }))
    .sort((a, b) => b.score - a.score);
}
const worstVs = (championId, role, winRate) =>
  counterPicks(championId, role, winRate).filter((m) => m.score < winRate).reverse();

// ---------- Role tabs ----------

function tabs(roles, selected, href) {
  const buttons = roles
    .map(([role, label]) => `<button role="tab" aria-selected="${role === selected}" data-role="${role}" data-href="${href(role)}">${label}</button>`)
    .join("");
  return `<div class="tabs" role="tablist"><span class="indicator"></span>${buttons}</div>`;
}

function moveIndicator(container) {
  container.querySelectorAll(".tabs").forEach((bar) => {
    const on = bar.querySelector('[aria-selected="true"]');
    if (!on) return;
    const indicator = bar.querySelector(".indicator");
    indicator.style.width = `${on.offsetWidth}px`;
    indicator.style.transform = `translateX(${on.offsetLeft}px)`;
  });
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

// Letters only, so "velkoz" finds Vel'Koz and "nunu" finds Nunu & Willump.
const searchable = (s) => s.toLowerCase().normalize("NFD").replace(/[^a-z]/g, "");

function tierRows(role) {
  const query = searchable(tierQuery);
  const rows = db.tiers.filter((t) => t.tier != null && (role === "ALL" || t.role === role)
    && (!query || searchable(t.champion_name).includes(query)));
  const { key, asc } = tierSort;
  const value = (r) => (key === "tier" ? TIER_ORDER[r.tier] * 10 - r.adjusted_win_rate : r[key]);
  return rows.sort((a, b) => (asc ? value(a) - value(b) : value(b) - value(a)));
}

function tierTable(role, animate = true) {
  const head = TIER_COLUMNS.map(([key, label]) => {
    const sorted = tierSort.key === key ? ` aria-sort="${tierSort.asc ? "ascending" : "descending"}"` : "";
    return `<th${sorted}${["ban_rate", "games"].includes(key) ? ' class="hide-sm"' : ""}><button data-sort="${key}">${label}</button></th>`;
  }).join("");

  const body = tierRows(role).map((r, i) => {
    const c = db.champions.get(r.champion_id) ?? { champion_key: "", champion_name: r.champion_name };
    const href = `#/champion/${c.champion_key}/${r.role}`;
    const weak = worstVs(r.champion_id, r.role, r.win_rate).slice(0, 3)
      .map((m) => db.champions.get(m.opponent_id)).filter(Boolean)
      .map((o) => champImg(o, "sm round")).join("");
    return `<tr class="link${animate ? " rise" : ""}" style="--i:${Math.min(i, 20)}" data-href="${href}">
      <td class="rank left hide-sm">${i + 1}</td>
      <td class="left"><a class="champ-cell" href="${href}">${champImg(c)}<span>${esc(c.champion_name)}</span></a></td>
      <td><span class="tier tier-${r.tier}">${r.tier}</span></td>
      <td>${pct(r.win_rate, 2)}<small class="moe hide-sm">${moe(r.win_rate_moe)}</small></td>
      <td>${pct(r.pick_rate, 2)}</td>
      <td class="hide-sm">${pct(r.ban_rate, 2)}</td>
      <td class="hide-sm">${num(r.games)}</td>
      <td class="left hide-sm role-label">${ROLE_NAME[r.role]}</td>
      <td class="hide-sm"><div class="counters">${weak || '<span class="faint">–</span>'}</div></td>
    </tr>`;
  }).join("");

  return `<div class="table-wrap"><table>
    <thead><tr><th class="left hide-sm">#</th><th class="left">Champion</th>${head}<th class="left hide-sm">Role</th><th class="hide-sm">Weak against</th></tr></thead>
    <tbody>${body || `<tr><td colspan="9" class="left muted">${tierQuery
      ? `No ranked champion matches “${esc(tierQuery)}”${role === "ALL" ? "" : ` in ${ROLE_NAME[role]}`}.`
      : "No champions have enough games in this role yet."}</td></tr>`}</tbody>
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
    <div class="hero hero--split">
      <div>
        <h1>Champion<br>performance</h1>
        <p>Win, pick and ban rates for every champion in Emerald+ solo/duo on EUW, from ${plural(db.matches, "ranked match", "ranked matches")}.</p>
        <a class="cta" href="#/insights">
          <span class="cta__label">See the analysis <span aria-hidden="true">&rarr;</span></span>
          <span class="cta__sub">What wins games: objectives, gold leads and bans, modelled in T-SQL</span>
        </a>
      </div>
      ${kpiTriangle(db.volume)}
    </div>
    <div class="toolbar">
      ${tabs(ROLES, role, (r) => (r === "ALL" ? "#/tiers" : `#/role/${r}`))}
      <label class="search">
        <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
        <input type="search" placeholder="Search champions" aria-label="Search champions" value="${esc(tierQuery)}" autocomplete="off" spellcheck="false">
        <kbd aria-hidden="true">/</kbd>
      </label>
    </div>
    <div class="table-slot">${tierTable(role)}</div>
    <p class="method">± is the 95% margin of error. Tiers rank champions within each role by win rate after
      adding ${num(Math.round(db.tiers[0]?.prior_games ?? 0))} games at 50%, so a short lucky run can't top the list
      (<a href="#/insights">why</a>). A champion needs a 1% pick rate in a role to be ranked. Weak against shows the lane opponents
      the champion does worst against compared with its usual win rate, from matchups with ${MATCHUP_MIN_GAMES}+ games.</p>
  </div>`;
  const el = view.firstElementChild;
  current = { page: "tiers", el, role };
  wireTabs(el);
  reveal(el);

  // Search filters the table as you type; Enter opens the top result, Escape clears.
  const search = el.querySelector(".search input");
  search.addEventListener("input", () => {
    tierQuery = search.value;
    el.querySelector(".table-slot").innerHTML = tierTable(current.role, false);
  });
  search.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      const first = el.querySelector("tr[data-href]");
      if (first) location.hash = first.dataset.href;
    } else if (e.key === "Escape" && search.value) {
      search.value = "";
      search.dispatchEvent(new Event("input"));
    }
  });

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

// ---------- Skill order ----------

const SKILL_KEYS = ["Q", "W", "E", "R"];
// Ability names, icons and max ranks from Data Dragon; letters and the usual ranks if it can't be reached.
const championDetails = (champ) => (files[`abilities/${champ.champion_key}`] ??=
  fetch(`${IMG}/${db.version}/data/en_GB/champion/${champ.champion_key}.json`)
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => d?.data?.[champ.champion_key] ?? null)
    .catch(() => null));
const abilities = (champ) => championDetails(champ).then((d) => d?.spells ?? null);

// The champion's passive and four abilities, each with Riot's short clip of it in game (the same
// clips as the official champion pages), one playing at a time. Riot has moved these clips before,
// so each one tries the current address, then the mp4, then the old address.
const ABILITY_VIDEOS = [
  (id, key) => `https://lol.dyn.riotcdn.net/x/videos/champion-abilities/${id}/ability_${id}_${key}1.webm`,
  (id, key) => `https://lol.dyn.riotcdn.net/x/videos/champion-abilities/${id}/ability_${id}_${key}1.mp4`,
  (id, key) => `https://d28xe8vt774jo5.cloudfront.net/champion-abilities/${id}/ability_${id}_${key}1.webm`,
];
// Data Dragon's numbers per rank, "8/7/6/5/4" or "8", tidied for reading. Ranges over 5000 are global.
const perRank = (burn) => (burn && !/^0(\/0)*$/.test(burn) ? burn.split("/").join(" / ") : "");
const abilityRange = (burn) => {
  const top = Math.max(...String(burn ?? "").split("/").map(Number).filter(Number.isFinite));
  return !top ? "" : top > 5000 ? "Global" : perRank(burn);
};

function abilityShowcase(champ, details) {
  if (!details?.spells) return "";
  const id = String(champ.champion_id).padStart(4, "0");
  const resource = details.partype && !/none|^$/i.test(details.partype) ? details.partype : "";
  const list = [
    { key: "P", label: "Passive", name: details.passive.name, text: details.passive.description,
      img: `${IMG}/${db.version}/img/passive/${details.passive.image.full}`, facts: [] },
    ...details.spells.map((s, i) => {
      const cost = perRank(s.costBurn);
      const range = abilityRange(s.rangeBurn);
      return {
        key: SKILL_KEYS[i], label: `${SKILL_KEYS[i]} ability`, name: s.name, text: s.description,
        img: `${IMG}/${db.version}/img/spell/${s.image.full}`,
        facts: [
          ["Cooldown", perRank(s.cooldownBurn) && `${perRank(s.cooldownBurn)}s`],
          ["Cost", cost && resource ? `${cost} ${resource}` : ""],
          ["Range", range],
        ].filter(([, value]) => value),
      };
    }),
  ].map((a) => ({ ...a, videos: ABILITY_VIDEOS.map((url) => url(id, a.key)) }));
  return { list, html: `<section class="cd-abilities">
      <h2>Abilities</h2>
      <div class="panel ability-panel">
        <div class="ability-video"><video muted loop playsinline autoplay preload="none"></video><p class="ability-novideo" hidden>No clip for this ability.</p></div>
        <div class="ability-side">
          <div class="ability-picks" role="tablist">${list.map((a, i) => `<button class="ability-pick" role="tab" aria-selected="${i === 0}" data-ability="${i}" title="${esc(a.name)}" aria-label="${a.label}: ${esc(a.name)}">
            <img src="${a.img}" alt="" width="52" height="52" loading="lazy"><b>${a.key}</b></button>`).join("")}</div>
          <div class="ability-info"></div>
        </div>
      </div>
    </section>` };
}

function abilityInfo(a) {
  return `<span class="ability-kind">${a.label}</span>
    <h3>${esc(a.name)}</h3>
    ${a.facts.length ? `<dl class="ability-facts">${a.facts.map(([label, value]) => `<div><dt>${label}</dt><dd>${esc(value)}</dd></div>`).join("")}</dl>` : ""}
    ${paragraphs(plainText(a.text), "ability-text")}`;
}

// Hover cards for items, summoner spells and runes, with details from Data Dragon fetched once on
// the first hover of each kind.
const ddragon = (file, pick) => (files[`ddragon/${file}`] ??=
  fetch(`${IMG}/${db.version}/data/en_GB/${file}.json`)
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => (d ? pick(d) : null))
    .catch(() => null));
const itemDetails = () => ddragon("item", (d) => d.data);
const spellDetails = () => ddragon("summoner", (d) => d.data);
// Runes keyed by icon path, the one thing the rune images already carry.
const runeDetails = () => ddragon("runesReforged", (trees) =>
  Object.fromEntries(trees.flatMap((t) => t.slots.flatMap((s) => s.runes)).map((r) => [r.icon, r])));

// Data Dragon writes descriptions in its own markup. Keep the words and line breaks, drop the tags.
const plainText = (html = "") => html.replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]+>/g, "")
  .replace(/&nbsp;/g, " ").replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
const paragraphs = (text, cls = "tip-text") => text.split(/\n{2,}/).filter(Boolean)
  .map((p) => `<p class="${cls}">${esc(p).replace(/\n/g, "<br>")}</p>`).join("");

const tipHead = (src, name, sub) => `<div class="item-tip-head">
    <img src="${src}" alt="" width="40" height="40">
    <div><strong>${esc(name)}</strong>${sub ? `<span class="gold">${sub}</span>` : ""}</div>
  </div>`;

function itemCard(id, details, note) {
  const ours = db.items.get(id);
  const gold = details?.gold?.total ?? ours?.total_gold;
  const desc = details?.description ?? "";
  const stats = plainText(desc.match(/<stats>([\s\S]*?)<\/stats>/i)?.[1] ?? "").split("\n").filter(Boolean);
  const effects = [...desc.replace(/<stats>[\s\S]*?<\/stats>/i, "")
    .matchAll(/<(passive|active)>([\s\S]*?)<\/\1>([\s\S]*?)(?=<(?:passive|active)>|<\/mainText>|$)/gi)]
    .map(([, kind, title, body]) => ({ kind, title: plainText(title), body: plainText(body).replace(/\n+/g, " ") }));
  return `${tipHead(`${IMG}/${db.version}/img/item/${id}.png`, details?.name ?? ours?.item_name ?? `Item ${id}`, gold ? `${num(gold)} gold` : "")}
    ${stats.length ? `<ul class="item-tip-stats">${stats.map((line) => `<li>${esc(line)}</li>`).join("")}</ul>` : ""}
    ${effects.map((e) => `<p class="tip-text"><b>${e.kind === "active" ? "Active" : "Passive"}: ${esc(e.title)}</b> ${esc(e.body)}</p>`).join("")}
    ${note ? `<p class="item-tip-note">${esc(note)}</p>` : ""}`;
}

function spellCard(key, details) {
  const ours = [...db.spells.values()].find((s) => s.spell_key === key);
  return `${tipHead(`${IMG}/${db.version}/img/spell/${key}.png`, details?.name ?? ours?.spell_name ?? key, details ? `${details.cooldownBurn}s cooldown` : "")}
    ${details ? paragraphs(plainText(details.description)) : ""}`;
}

function runeCard(path, name, details, loaded) {
  // Stat shards aren't in runesReforged; their names already say what they give.
  return `${tipHead(`${IMG}/img/${path}`, details?.name ?? name, details || !loaded ? "" : "Stat shard")}
    ${details ? paragraphs(plainText(details.shortDesc)) : ""}`;
}

// What each kind of icon looks like, how to draw its card without details, and how to fetch them.
const TIPS = [
  ["img[data-item]", (img) => Number(img.dataset.item), (id, d, img) => itemCard(id, d?.[id], img.closest("[data-note]")?.dataset.note), itemDetails],
  ["img[data-spell]", (img) => img.dataset.spell, (key, d) => spellCard(key, d?.[key]), spellDetails],
  ["img[data-perk]", (img) => img.dataset.perk, (path, d, img) => runeCard(path, img.alt, d?.[path], !!d), runeDetails],
];

// One hover card for every item, summoner spell and rune icon on the site.
function wireTips() {
  const tip = document.createElement("div");
  tip.className = "item-tip";
  tip.hidden = true;
  tip.setAttribute("role", "tooltip");
  document.body.append(tip);
  let target = null;
  const place = () => {
    const box = target.getBoundingClientRect();
    const { width, height } = tip.getBoundingClientRect();
    let left = box.left + box.width / 2 - width / 2;
    left = Math.min(Math.max(left, 8), innerWidth - width - 8);
    const top = box.top - height - 10 >= 8 ? box.top - height - 10 : box.bottom + 10;
    tip.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`;
  };
  document.addEventListener("mouseover", async (e) => {
    const kind = TIPS.find(([selector]) => e.target.closest?.(selector));
    if (!kind) return;
    const [selector, idOf, card, load] = kind;
    const img = e.target.closest(selector);
    if (img === target) return;
    target = img;
    const id = idOf(img);
    tip.innerHTML = card(id, null, img);
    tip.hidden = false;
    place();
    const details = await load();
    if (target !== img || !details) return;
    tip.innerHTML = card(id, details, img);
    place();
  });
  document.addEventListener("mouseout", (e) => {
    if (target && e.target === target && !target.contains(e.relatedTarget)) { target = null; tip.hidden = true; }
  });
  window.addEventListener("scroll", () => { target = null; tip.hidden = true; }, { passive: true });
}

// The skill taken at each level 1–18 (1–3 = Q, W, E; 4 = R). path.levels is the most common pick
// at each level, taken separately, so it can ask for a sixth point, or put R a level late when
// some players hold the point. A usual three-rank R goes at 6, 11 and 16; any other level that
// breaks the rules, or that too few players reached, goes to the next skill in the max order.
// Champions whose R ranks differently (Jayce, Udyr, ...) keep R where players put it.
function skillLevels(path, spells) {
  const maxRank = [0, ...SKILL_KEYS.map((_, i) => spells?.[i]?.maxrank ?? (i === 3 ? 3 : 5))];
  const usualUlt = maxRank[4] === 3;
  const order = [...new Set([...path.max_order].map(Number).concat([1, 2, 3]))];
  const points = [0, 0, 0, 0, 0];
  const fits = (slot) => points[slot] < maxRank[slot];
  return Array.from({ length: 18 }, (_, i) => {
    const level = i + 1;
    let slot = Number(path.levels?.[i]);
    const ultLevel = [6, 11, 16].includes(level);
    if (usualUlt && ultLevel) slot = 4;
    const allowed = slot >= 1 && slot <= 4 && fits(slot)
      && (!usualUlt || (slot === 4 ? ultLevel : points[slot] < Math.ceil(level / 2)));
    if (!allowed) {
      slot = [6, 11, 16].includes(level) && fits(4) ? 4
        : order.find((s) => fits(s) && points[s] < Math.ceil(level / 2)) ?? order.find(fits) ?? 4;
    }
    points[slot] += 1;
    return slot;
  });
}

function skillOrder(champ, rows, spells) {
  const best = rows.filter(enoughGames).sort((a, b) => b.win_rate - a.win_rate)[0];
  if (!best) return `<div class="panel"><div class="empty">No skill path has ${num(db.minGames)}+ games yet.</div></div>`;
  const popular = rows[0];
  const icon = (slot) => {
    const spell = spells?.[slot - 1];
    const key = SKILL_KEYS[slot - 1];
    return `<span class="skill-icon">${spell ? `<img src="${IMG}/${db.version}/img/spell/${esc(spell.image.full)}" alt="" loading="lazy" width="40" height="40">` : ""}<b>${key}</b></span>`;
  };
  const priority = (path) => [...path.max_order].map(Number);
  const levels = skillLevels(best, spells);
  const rowsHtml = [1, 2, 3, 4].map((slot) => `<div class="skill-row">
      <span class="skill-name">${icon(slot)}<span class="name">${esc(spells?.[slot - 1]?.name ?? SKILL_KEYS[slot - 1])}</span></span>
      <span class="skill-cells">${levels.map((s, i) => `<span class="skill-cell${s === slot ? " on" : ""}">${s === slot ? i + 1 : ""}</span>`).join("")}</span>
    </div>`).join("");
  return `<div class="panel skill-card">
      <div class="skill-priority">
        <h3 class="sub-head">Skill priority</h3>
        <div class="skill-keys">${priority(best).map(icon).join('<span class="arrow" aria-hidden="true">&rarr;</span>')}</div>
        <div class="skill-figure"><strong>${wr(best.win_rate)}</strong> win rate <small>${moe(1.96 * Math.sqrt(0.25 / best.games))}</small></div>
        <div class="vs">${plural(best.games, "game")} · ${pct(best.pick_share)} of players</div>
        ${popular !== best ? `<div class="alt">Most played: ${priority(popular).map((s) => SKILL_KEYS[s - 1]).join(" → ")} first ${popular.start
          .split("").map((s) => SKILL_KEYS[s - 1]).join("-")}, ${pct(popular.pick_share)} of players · ${pct(popular.win_rate)} win rate</div>` : ""}
      </div>
      <div class="skill-path">
        <h3 class="sub-head">Skill path <span>levels 1–18</span></h3>
        ${rowsHtml}
      </div>
    </div>`;
}

// ---------- Champion page ----------

const ordinal = (n) => `${n}${[, "st", "nd", "rd"][n] ?? "th"}`;
const itemName = (id) => esc(db.items.get(id)?.item_name ?? `Item ${id}`);

// A starter set, most expensive item first: [icons, main item, "+ 2 Health Potion"].
function starterSet(starterItems) {
  const items = starterItems.split(",").map((pair) => pair.split(":").map(Number))
    .sort(([a], [b]) => (db.items.get(b)?.total_gold ?? 0) - (db.items.get(a)?.total_gold ?? 0));
  const icons = items.map(([id, qty]) => (qty > 1 ? `<span class="qty">${itemImg(id)}<span>${qty}</span></span>` : itemImg(id))).join("");
  const extras = items.slice(1).map(([id, qty]) => `${qty > 1 ? `${qty} ` : ""}${itemName(id)}`);
  return [icons, itemName(items[0][0]), extras.length ? `+ ${extras.join(" + ")}` : ""];
}
const spellName = (id) => esc(db.spells.get(id)?.spell_name ?? "");

// One grid cell: icon plus win rate, pick share and games, dimmed unless `on`.
function runeCell(icon, stats, on, extraClass = "") {
  // Every rune shows how often it is taken; the most picked ones also show their win rate.
  const figures = !stats ? `<div class="faint">–</div>`
    : `${on ? `<div class="good">${pct(stats.win_rate)}</div>` : ""}<div class="games">${pct(stats.pick_share)}</div>`;
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
    <div class="rune-tree shards"><h4>Shards</h4>${shardRows}</div>
  </div>`;
}

// Playstyle: the champion's stat in this role against the role's average.
const PLAYSTYLE = [["kda", "KDA", 2], ["cs_per_min", "CS / min", 1], ["damage_per_min", "Damage / min", 0], ["vision_per_min", "Vision / min", 2]];

// Win rate by rank: one point per band on a 35–65% scale, with a dashed line at 50% and a faint
// line at the champion's win rate across every rank.
const RANK_BANDS = [["EMERALD", "Emerald", "emerald"], ["DIAMOND", "Diamond", "diamond"], ["MASTER+", "Master+", "master"]];
const RANK_SCALE = [0.35, 0.65];

// Win rate by rank as a small line chart: one point per band on a 35–65% scale with its 95% margin
// of error, a dashed line at 50% and a faint one at the champion's win rate across every rank.
function rankTrend(rows, overall) {
  const [w, h, top, bottom, side] = [300, 190, 22, 74, 34];
  const y = (x) => top + (1 - (Math.min(Math.max(x, RANK_SCALE[0]), RANK_SCALE[1]) - RANK_SCALE[0]) / (RANK_SCALE[1] - RANK_SCALE[0])) * (h - top - bottom);
  const x = (i) => side + i * ((w - side * 2) / (RANK_BANDS.length - 1));
  const points = RANK_BANDS.map(([band, label, emblem], i) => {
    const r = rows.find((row) => row.rank_band === band);
    return { i, label, emblem, r, ok: r && enoughGames(r) };
  });
  const shown = points.filter((p) => p.ok);
  const line = shown.map((p) => `${x(p.i)},${y(p.r.win_rate)}`).join(" ");
  return `<svg class="rank-trend" viewBox="0 0 ${w} ${h}" role="img" aria-label="Win rate by rank">
    <line class="even" x1="0" x2="${w}" y1="${y(0.5)}" y2="${y(0.5)}"/><text class="axis" x="0" y="${y(0.5) - 4}">50%</text>
    <line class="usual" x1="0" x2="${w}" y1="${y(overall)}" y2="${y(overall)}"/>
    ${shown.length > 1 ? `<polyline points="${line}"/>` : ""}
    ${points.map((p) => p.ok ? `
      <circle class="${p.r.win_rate < 0.5 ? "under" : ""}" cx="${x(p.i)}" cy="${y(p.r.win_rate)}" r="5"/>
      <text class="value" x="${x(p.i)}" y="${y(p.r.win_rate) - 11}">${(p.r.win_rate * 100).toFixed(1)}%</text>`
      : `<text class="value faint" x="${x(p.i)}" y="${y(0.5) - 8}">–</text>`).join("")}
    ${points.map((p) => `<image href="img/rank-${p.emblem}.png" x="${x(p.i) - 14}" y="${h - 66}" width="28" height="28"/>
      <text class="band" x="${x(p.i)}" y="${h - 20}">${p.label}</text>
      <text class="games" x="${x(p.i)}" y="${h - 4}">${p.r ? plural(p.r.games, "game") : "no games"}</text>`).join("")}
  </svg>`;
}

async function renderChampion(key, role, ticket) {
  const champ = db.byKey.get(key.toLowerCase());
  if (!champ) return renderNotFound();

  const allRoles = db.tiers.filter((t) => t.champion_id === champ.champion_id).sort(byGames);
  if (!allRoles.length) return renderNotFound(`${champ.champion_name} hasn't been played in the sample yet.`);
  const stats = allRoles.find((r) => r.role === role) ?? allRoles.find((r) => r.tier != null) ?? allRoles[0];
  role = stats.role;
  // Role tabs: every role with enough games to show builds for, plus the one on screen.
  const roles = allRoles.filter((r) => r.tier != null || r.games >= db.minGames || r.role === role);

  view.innerHTML = `<div class="loading">Loading ${esc(champ.champion_name)}…</div>`;
  const [[starters, boots, core, late, pages, runePicks, shardPicks, spells, ranks, skillPaths], champDetails] = await Promise.all([
    Promise.all(["champion_starter_sets", "champion_boots", "champion_core_items", "champion_late_items", "champion_rune_stats",
      "champion_rune_picks", "champion_shard_picks", "champion_spell_stats", "champion_rank_win_rate", "champion_skill_paths"].map(load)),
    championDetails(champ),
  ]);
  if (ticket !== navigation) return;  // the reader has already moved on
  const abilitySpells = champDetails?.spells ?? null;
  const showcase = abilityShowcase(champ, champDetails);

  const mine = (rows) => forChampion(rows, champ.champion_id, role).sort(byGames);
  const top = (rows, n) => rows.filter(enoughGames).slice(0, n);
  const runePages = mine(pages).filter((p) => p.page_rank <= 2 && enoughGames(p)).sort((a, b) => a.page_rank - b.page_rank);
  const board = (page) => runeBoard(page,
    mine(runePicks).filter((p) => p.page_rank === page.page_rank),
    mine(shardPicks).filter((s) => s.page_rank === page.page_rank));


  // The core: the three items finished 1st to 3rd most often, in the order they usually come.
  // After the core: every other finished item, wherever it was built, out of all the champion's
  // games with a timeline.
  const coreRows = mine(core);
  const coreThree = coreRows.filter(enoughGames).slice(0, 3).sort((a, b) => a.avg_slot - b.avg_slot);
  const timelineGames = coreRows.length ? Math.round(coreRows[0].games / coreRows[0].pick_share) : 0;
  const inCore = new Set(coreThree.map((r) => r.item_id));
  const rest = new Map();
  for (const r of [...coreRows, ...mine(late)].filter((r) => !inCore.has(r.item_id))) {
    const item = rest.get(r.item_id) ?? { item_id: r.item_id, games: 0, wins: 0, slots: 0 };
    item.games += r.games;
    item.wins += r.wins;
    item.slots += r.avg_slot * r.games;
    rest.set(r.item_id, item);
  }
  const restRows = [...rest.values()].filter((r) => r.games >= 3).sort(byGames).slice(0, 8)
    .map((r) => ({ ...r, avg_slot: r.slots / r.games, win_rate: r.wins / r.games, pick_share: r.games / timelineGames }));

  // Dashboard style: a summary panel (win rate, playstyle against the role, win rate by rank),
  // the build beside the runes, then the skill order.
  const buildRow = (label, row, pick) => {
    if (!row) return `<div class="build-row"><span class="label">${label}</span><span class="faint">Not enough games yet</span></div>`;
    const [icons, name] = pick(row);
    return `<div class="build-row"><span class="label">${label}</span><span class="icons">${icons}</span><strong>${name}</strong>
      <span class="figure">${wr(row.win_rate)}<small>${pct(row.pick_share)} of games</small></span></div>`;
  };
  const playstyle = PLAYSTYLE.map(([key, label, digits]) => {
    const value = stats[key];
    const average = stats[`role_${key}`];
    const diff = value != null && average ? value / average - 1 : null;
    // The bar runs from the middle: right when the champion is above the role's average, up to ±30%.
    const size = diff == null ? 0 : Math.min(Math.abs(diff), 0.3) / 0.3 * 50;
    return `<div class="vs-row"><span class="label">${label}</span>
      <strong>${value == null ? "–" : value.toLocaleString("en-GB", { maximumFractionDigits: digits, minimumFractionDigits: digits })}</strong>
      <span class="vs-bar"><span class="${diff >= 0 ? "up" : "down"}" style="${diff >= 0 ? "left: 50%" : `right: 50%`}; width: ${size}%"></span></span>
      <span class="${diff >= 0 ? "good" : "muted"} vs-diff">${diff == null ? "" : signed(diff)}</span></div>`;
  }).join("");

  view.innerHTML = `<div class="page champ-dash">
    <a class="back" href="#/role/${role}">← Tier list</a>
    <div class="cd-head">
      <div class="champ-head">
        <img src="${IMG}/${db.version}/img/champion/${champ.champion_key}.png" alt="">
        <div>
          <h1>${esc(champ.champion_name)}</h1>
          <p class="sub">${[...new Set([ROLE_NAME[role], champ.primary_class])].map(esc).join(" · ")}</p>
        </div>
      </div>
      ${roles.length > 1 ? tabs(roles.map((r) => [r.role, ROLE_NAME[r.role]]), role, (r) => `#/champion/${champ.champion_key}/${r}`) : ""}
    </div>
    <div class="cd-summary panel">
      <div class="cd-hero">
        <span class="label">Win rate</span>
        <div class="cd-hero-figure">${pct(stats.win_rate, 2)}<small>${moe(stats.win_rate_moe)}</small></div>
        <div class="cd-hero-tier">${stats.tier ? `<span class="tier tier-${stats.tier}">${stats.tier}</span> tier among ${ROLE_PLAYER[role]}s` : "Not ranked"}</div>
        <dl class="cd-hero-more">
          <div><dt>Pick</dt><dd>${pct(stats.pick_rate, 2)}</dd></div>
          <div><dt>Ban</dt><dd>${pct(stats.ban_rate, 2)}</dd></div>
          <div><dt>Games</dt><dd>${num(stats.games)}</dd></div>
        </dl>
      </div>
      <div class="cd-vs">
        <span class="label">Against the average ${ROLE_PLAYER[role]}</span>
        ${playstyle}
      </div>
      <div class="cd-rank">
        <span class="label">Win rate by rank</span>
        ${rankTrend(mine(ranks), stats.win_rate)}
      </div>
    </div>
    ${stats.games < db.minGames ? `<p class="cd-warn">Only ${plural(stats.games, "game")} as a ${ROLE_PLAYER[role]}, so treat these numbers as rough.</p>` : ""}


    <div class="cd-pair cd-pair-build">
      <section>
        <h2>Build</h2>
        <div class="panel build-list">
          ${buildRow("Spells", top(mine(spells), 1)[0], (r) => [spellImg(r.spell_a_id) + spellImg(r.spell_b_id), `${spellName(r.spell_a_id)} + ${spellName(r.spell_b_id)}`])}
          ${buildRow("Start", top(mine(starters), 1)[0], (r) => starterSet(r.starter_items))}
          ${buildRow("Boots", top(mine(boots), 1)[0], (r) => [itemImg(r.item_id), itemName(r.item_id)])}
          ${[0, 1, 2].map((i) => buildRow(`${ordinal(i + 1)} item`, coreThree[i], (r) => [itemImg(r.item_id), itemName(r.item_id)])).join("")}
          ${restRows.length ? `<div class="build-later"><span class="label">Then</span><div>${restRows.map((r) => `<span class="cd-chip" data-note="${pct(r.win_rate, 1)} win rate · ${pct(r.pick_share)} of games · usually ${ordinal(Math.round(r.avg_slot))} item">${itemImg(r.item_id)}<span>${pct(r.win_rate, 0)}</span></span>`).join("")}</div></div>` : ""}
        </div>
      </section>

      <section>
        <h2>Runes</h2>
        ${runePages.length ? `<div class="rune-panel"><div class="rune-pages">${runePages.map((p, i) => `<${runePages.length > 1 ? `button aria-pressed="${i === 0}"` : "div"} class="rune-page" data-page="${i}">
          <div class="icons">${perkImg(db.runes.get(p.keystone_id)?.icon_path, p.keystone_name, "lg")}
            <div class="page-name"><strong>${esc(p.keystone_name)}</strong><small>${esc(p.primary_tree_name)} + ${esc(p.secondary_tree_name)}</small></div></div>
          <div class="figure">${wr(p.win_rate)}<small>${pct(p.pick_share)} of games</small></div>
        </${runePages.length > 1 ? "button" : "div"}>`).join("")}</div>
        <div class="rune-slot">${board(runePages[0])}</div>
        </div>`
        : `<div class="panel"><div class="empty">No rune page has ${num(db.minGames)}+ games yet.</div></div>`}
      </section>
    </div>

    <div class="cd-pair cd-pair-skill">
      <section>
        <h2>Skill order</h2>
        ${skillOrder(champ, mine(skillPaths), abilitySpells)}
      </section>
    </div>
    ${showcase ? showcase.html : ""}
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
  if (showcase) {
    const video = el.querySelector(".ability-video video");
    const missing = el.querySelector(".ability-novideo");
    const info = el.querySelector(".ability-info");
    let tries = [];
    const pick = (i) => {
      const a = showcase.list[i];
      el.querySelectorAll(".ability-pick").forEach((b) => b.setAttribute("aria-selected", b.dataset.ability === String(i)));
      info.innerHTML = abilityInfo(a);
      missing.hidden = true;
      video.hidden = false;
      [video.src, ...tries] = a.videos;
      video.play().catch(() => {});
    };
    video.muted = true;  // the attribute alone doesn't always count as muted for autoplay
    video.addEventListener("loadeddata", () => video.play().catch(() => {}));
    // Chrome pauses a muted clip that's off screen or in a background tab, so restart it when it's back.
    let inView = false;
    const resume = () => {
      if (!video.isConnected) return document.removeEventListener("visibilitychange", resume);  // page changed
      if (inView && video.paused && !document.hidden) video.play().catch(() => {});
    };
    new IntersectionObserver(([entry]) => { inView = entry.isIntersecting; resume(); }).observe(video);
    document.addEventListener("visibilitychange", resume);
    video.addEventListener("error", () => {
      if (tries.length) { video.src = tries.shift(); return; }
      video.hidden = true;
      missing.hidden = false;
    });
    el.querySelector(".ability-picks").addEventListener("click", (e) => {
      const button = e.target.closest(".ability-pick");
      if (button) pick(Number(button.dataset.ability));
    });
    pick(0);
  }
  window.scrollTo({ top: 0 });
}

// ---------- Insights ----------

// [name, what the count chart counts] for each objective in the match JSON.
const OBJECTIVES = {
  inhibitor: ["First inhibitor", "inhibitors"],
  baron: ["First Baron", "Barons"],
  tower: ["First tower", "towers"],
  riftHerald: ["Rift Herald", "Rift Heralds"],
  dragon: ["First dragon", "dragons"],
  champion: ["First blood", null],
  horde: ["First void grubs", "void grubs"],
};
const objectiveName = (key) => OBJECTIVES[key]?.[0] ?? key;
const inSentence = (name) => name.replace(/^First /, "first ");
const LEAD_MINUTES = [10, 15, 20, 25];
const leadBand = (b) => (b.band_max == null ? `${b.band_min / 1000}k+` : `${b.band_min / 1000}–${b.band_max / 1000}k`);

// A win-rate column on a 0–100% scale, with its 95% margin of error.
const rateColumn = (key, rate, margin, label, tipText, digits = 1) => `<div class="column" data-key="${esc(key)}" tabindex="0" data-tip="${esc(tipText)}">
    <span class="column-plot">
      <span class="column-bar${rate < 0.5 ? " against" : ""}" style="--h: ${rate.toFixed(4)}"></span>
      <span class="whisker" style="--lo: ${Math.max(rate - margin, 0).toFixed(4)}; --hi: ${Math.min(rate + margin, 1).toFixed(4)}"></span>
    </span>
    <strong>${pct(rate, digits)}</strong>
    <small>${esc(label)}</small>
  </div>`;

const RANK_NAME = { EMERALD: "Emerald", DIAMOND: "Diamond", MASTER: "Master", GRANDMASTER: "Grandmaster", CHALLENGER: "Challenger" };
const RANK_ORDER = Object.keys(RANK_NAME);
// Plain-English names for the winners-against-losers stats.
const METRIC_LABEL = {
  "Deaths": "Deaths", "Kills + assists": "Kills + assists", "CS / min": "Farm per minute",
  "Damage / min": "Damage per minute", "Vision / min": "Vision per minute", "First item (min)": "Time to first item",
};
const dateName = (iso) => new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "short" });
const statValue = (v) => (v >= 100 ? num(Math.round(v)) : v.toFixed(v >= 10 ? 1 : 2));

// ---------- Dashboard pieces ----------

const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

// Headline figures count up from zero the first time they scroll into view.
const KPI_FORMAT = {
  num: (v) => num(Math.round(v)),
  compact: (v) => (v >= 1e6 ? `${(v / 1e6).toFixed(1)}M` : num(Math.round(v))),
};
const kpi = (label, value, note = "", format = "num", cls = "") => `<div class="kpi${cls ? ` ${cls}` : ""}">
    <div class="label">${label}</div>
    <div class="value" data-count="${value}" data-format="${format}">${KPI_FORMAT[format](value)}</div>
    ${note ? `<div class="note">${note}</div>` : ""}
  </div>`;

function countUp(el) {
  const target = Number(el.dataset.count);
  const format = KPI_FORMAT[el.dataset.format];
  // Hold the finished number's width, so the text around it doesn't move while it counts.
  el.style.minWidth = `${el.getBoundingClientRect().width}px`;
  const start = performance.now();
  const step = (now) => {
    const t = Math.min((now - start) / 1400, 1);
    el.textContent = format(target * (1 - (1 - t) ** 4));
    if (t < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

// The three headline figures, biggest first: item events on top, player records and matches under it.
const kpiTriangle = (v) => `<div class="kpi-triangle reveal">
    ${kpi("Item events", v.item_events, "", "num", "apex")}
    ${kpi("Player records", v.player_records)}
    ${kpi("Ranked matches", v.matches)}
  </div>`;

// Marks each .reveal block visible as it scrolls in: CSS grows its bars, and its figures count up.
function reveal(root) {
  const blocks = root.querySelectorAll(".reveal");
  if (reduceMotion || !("IntersectionObserver" in window)) {
    blocks.forEach((block) => block.classList.add("is-visible"));
    return;
  }
  const observer = new IntersectionObserver((entries) => entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add("is-visible");
    entry.target.querySelectorAll("[data-count]").forEach(countUp);
    observer.unobserve(entry.target);
  }), { threshold: 0.15 });
  blocks.forEach((block) => observer.observe(block));
}

// A pill of options, styled like the role tabs. Clicking one calls onPick(value).
function slicer(options, selected, label) {
  const buttons = options
    .map(([value, text]) => `<button role="tab" aria-selected="${value === selected}" data-value="${value}">${text}</button>`)
    .join("");
  return `<div class="tabs slicer" role="tablist" aria-label="${esc(label)}"><span class="indicator"></span>${buttons}</div>`;
}

function wireSlicer(bar, onPick) {
  bar.addEventListener("click", (e) => {
    const button = e.target.closest("button[data-value]");
    if (!button || button.getAttribute("aria-selected") === "true") return;
    bar.querySelectorAll("button").forEach((b) => b.setAttribute("aria-selected", b === button));
    moveIndicator(bar.parentElement);
    onPick(button.dataset.value);
  });
}

// Re-renders a list and slides rows that stay to their new place (FLIP); new rows fade in.
function reorder(list, html) {
  const before = new Map([...list.children].map((el) => [el.dataset.key, el.getBoundingClientRect().top]));
  list.innerHTML = html;
  if (reduceMotion) return;
  [...list.children].forEach((el, i) => {
    const top = before.get(el.dataset.key);
    const frames = top == null
      ? [{ opacity: 0, transform: "translateY(0.75rem)" }, { opacity: 1, transform: "none" }]
      : [{ transform: `translateY(${top - el.getBoundingClientRect().top}px)` }, { transform: "none" }];
    el.animate(frames, { duration: 700, delay: top == null ? i * 40 : 0, easing: "cubic-bezier(0.16, 1, 0.3, 1)", fill: "backwards" });
  });
}

// Updates el to match html in place when the structure is the same, so bars and columns
// animate between states; anything that differs is swapped for the new markup.
function morph(el, html) {
  const next = document.createElement(el.tagName);
  next.innerHTML = html;
  const sync = (a, b) => {
    if (a.childNodes.length !== b.childNodes.length) return a.replaceChildren(...b.childNodes);
    [...b.childNodes].forEach((bn, i) => {
      const an = a.childNodes[i];
      if (an.nodeName !== bn.nodeName) return an.replaceWith(bn);
      if (bn.nodeType === Node.TEXT_NODE) {
        if (an.textContent !== bn.textContent) an.textContent = bn.textContent;
        return;
      }
      if (bn.nodeType !== Node.ELEMENT_NODE) return;
      for (const { name, value } of bn.attributes) if (an.getAttribute(name) !== value) an.setAttribute(name, value);
      for (const { name } of [...an.attributes]) if (!bn.hasAttribute(name)) an.removeAttribute(name);
      sync(an, bn);
    });
  };
  sync(el, next);
}

// Grows columns up from zero, for charts whose columns were just replaced.
function growColumns(root) {
  if (reduceMotion) return;
  root.querySelectorAll(".column-bar").forEach((bar, i) => bar.animate(
    [{ transform: "scaleY(0)" }, { transform: "scaleY(1)" }],
    { duration: 900, delay: i * 50, easing: "cubic-bezier(0.16, 1, 0.3, 1)", fill: "backwards" },
  ));
}

// One tooltip for every element with data-tip ("Title\nline\nline"), on hover, tap or keyboard focus.
const tip = Object.assign(document.createElement("div"), { className: "tip", role: "tooltip" });
document.body.append(tip);
let tipTarget = null;
function showTip(target, x, y) {
  if (target !== tipTarget) {
    const [title, ...lines] = target.dataset.tip.split("\n");
    tip.innerHTML = `<strong>${esc(title)}</strong>${lines.map((l) => `<span>${esc(l)}</span>`).join("")}`;
    tipTarget = target;
  }
  tip.classList.add("on");
  const left = Math.min(Math.max(x + 14, 8), innerWidth - tip.offsetWidth - 8);
  const top = y - tip.offsetHeight - 14 < 8 ? y + 20 : y - tip.offsetHeight - 14;
  tip.style.transform = `translate(${left}px, ${top}px)`;
}
function hideTip() {
  tip.classList.remove("on");
  tipTarget = null;
}
document.addEventListener("pointermove", (e) => {
  const target = e.target.closest?.("[data-tip]");
  if (target) showTip(target, e.clientX, e.clientY);
  else if (tipTarget) hideTip();
}, { passive: true });
document.addEventListener("focusin", (e) => {
  const target = e.target.closest?.("[data-tip]");
  if (!target) return hideTip();
  const box = target.getBoundingClientRect();
  showTip(target, box.left + box.width / 2, box.top);
});
window.addEventListener("scroll", hideTip, { passive: true });

// ---------- Insights ----------

async function renderInsights(ticket) {
  view.innerHTML = `<div class="loading">Loading insights…</div>`;
  const [gaps, bans, banBands, sides, sample, checks, objectives, objectiveCounts, goldLeads, laneLeads, lengths] = await Promise.all(
    ["role_win_gap", "ban_vs_win", "ban_band_win_rate", "side_win_rate", "sample_by_tier", "data_checks",
      "objective_win_rate", "objective_count_win_rate", "gold_lead_win_rate", "lane_lead_win_rate",
      "champion_game_length"].map(load),
  );
  if (ticket !== navigation) return;
  const now = (rows) => rows.filter((r) => r.patch === db.patch);
  const vol = db.volume;

  // Objectives: the win rate of the team that took each one first. Picking one charts
  // win rate by how many of it a team took.
  const firsts = now(objectives).filter((o) => o.games >= db.minGames).sort((a, b) => b.win_rate - a.win_rate);
  const objectiveCountRows = now(objectiveCounts);
  const firstOf = (key) => firsts.find((o) => o.objective === key);
  let objective = firstOf("dragon") ? "dragon" : firsts[0]?.objective;
  // 99.6% would round to 100%, which reads as every game.
  const takenIn = (share) => `Taken in ${share < 1 ? Math.min(99, Math.round(share * 100)) : 100}% of games`;
  const objectiveRows = () => firsts.map((o) => `<button class="bar-row" data-key="${esc(o.objective)}" aria-pressed="${o.objective === objective}"
      data-tip="${esc(`${objectiveName(o.objective)}\nThe team that took it won ${num(o.wins)} of ${num(o.games)} games (${moe(o.win_rate_moe)})\n${takenIn(o.taken_share)}`)}">
      <span class="bar-label">${esc(objectiveName(o.objective))}<small>${takenIn(o.taken_share)}</small></span>
      <span class="bar-track even"><span class="bar" style="--w: ${o.win_rate.toFixed(4)}"></span></span>
      <span class="bar-value">${pct(o.win_rate)}</span>
    </button>`).join("");
  const objectiveChart = () => {
    const rows = objectiveCountRows.filter((c) => c.objective === objective && c.games >= db.minGames).sort((a, b) => a.taken - b.taken);
    const noun = OBJECTIVES[objective]?.[1] ?? objective;
    if (!rows.length) {
      // First blood happens once a game, so compare the team that got it with the team that gave it up.
      const o = firstOf(objective);
      const tipText = (who, wins) => `${who}\nWon ${num(wins)} of ${num(o.games)} games`;
      return {
        title: `Win rate with and without ${inSentence(objectiveName(objective))}`,
        n: 2,
        html: rateColumn("got", o.win_rate, o.win_rate_moe, "Got it", tipText("Got it", o.wins), 0)
          + rateColumn("gave", 1 - o.win_rate, o.win_rate_moe, "Gave it up", tipText("Gave it up", o.games - o.wins), 0),
      };
    }
    return {
      title: `Win rate by ${noun} taken`,
      n: rows.length,
      html: rows.map((c) => {
        const label = `${c.taken}${c.is_capped ? "+" : ""}`;
        return rateColumn(label, c.win_rate, c.win_rate_moe, label,
          `${label} ${noun}\nTeams won ${num(c.wins)} of ${num(c.games)} games\n${pct(c.win_rate)} (${moe(c.win_rate_moe)})`, 0);
      }).join(""),
    };
  };
  const objectivePanel = () => {
    const chart = objectiveChart();
    return `<h3 class="sub-head">${esc(chart.title)}</h3>
      <div class="columns${chart.n > 6 ? " dense" : ""}" style="--n: ${chart.n}; --even: 0.5">${chart.html}</div>`;
  };
  const [topObjective] = firsts;
  const firstBlood = firstOf("champion");
  // Inhibitors and Baron winning most is no surprise, so the headline compares the early objectives.
  const [herald, firstDragon, firstTower, grubs] = ["riftHerald", "dragon", "tower", "horde"].map(firstOf);
  const objectiveTitle = herald && firstDragon && herald.win_rate > firstDragon.win_rate
    ? `Teams that take Rift Herald win ${pct(herald.win_rate, 0)} of games`
    : firstBlood ? `First blood wins only ${pct(firstBlood.win_rate, 0)}` : `${objectiveName(topObjective?.objective)} wins ${pct(topObjective?.win_rate, 0)}`;
  const early = [firstTower, herald, firstDragon, grubs].filter(Boolean)
    .map((o, i) => `${esc(inSentence(objectiveName(o.objective)))} ${i ? "" : "won "}${pct(o.win_rate, 0)}${i ? "" : " of games"}`);
  const late = ["inhibitor", "baron"].map(firstOf).filter(Boolean);
  // Herald against first dragon: the gap in points, and whether it is bigger than both margins of error together.
  const heraldGap = herald && firstDragon ? (herald.win_rate - firstDragon.win_rate) * 100 : 0;
  const heraldMargin = herald && firstDragon ? Math.hypot(herald.win_rate_moe, firstDragon.win_rate_moe) * 100 : 0;
  const heraldLine = heraldGap > 0
    ? `Herald came out ${heraldGap.toFixed(1)} points ahead of first dragon, which is ${heraldGap > heraldMargin
      ? `well outside the ±${heraldMargin.toFixed(1)}-point margin of error` : `inside the ±${heraldMargin.toFixed(1)}-point margin of error, so it could still be chance`},
      even though a team only takes it in ${pct(herald.taken_share, 0)} of games.`
    : "";

  // Game length: which champions win short games and which win long ones. Each row is a
  // dumbbell from the short-game win rate (grey) to the long-game win rate (orange).
  const lengthRows = now(lengths).sort((a, b) => b.swing - a.swing);
  const lateChamps = lengthRows.filter((r) => r.swing > 0).slice(0, 6);
  const earlyChamps = lengthRows.filter((r) => r.swing < 0).reverse().slice(0, 6);
  const [lateTop] = lateChamps, [earlyTop] = earlyChamps;
  const DUMBBELL = [0.35, 0.65];   // the win-rate range the dumbbells are drawn on
  const along = (rate) => Math.min(1, Math.max(0, (rate - DUMBBELL[0]) / (DUMBBELL[1] - DUMBBELL[0])));
  const points = (r) => `${r.swing > 0 ? "+" : "−"}${Math.abs(r.swing * 100).toFixed(1)}`;
  const lengthRow = (r) => {
    const c = db.champions.get(r.champion_id) ?? { champion_key: "", champion_name: r.champion_name };
    const [from, to] = [along(r.short_win_rate), along(r.long_win_rate)];
    return `<a class="length-row" href="#/champion/${c.champion_key}"
        data-tip="${esc(`${r.champion_name}\nUnder 25 min: won ${pct(r.short_win_rate)} of ${num(r.short_games)} games\n33+ min: won ${pct(r.long_win_rate)} of ${num(r.long_games)} games\nSwing ${points(r)} points (${moe(r.swing_moe)})`)}">
      <span class="champ-cell">${champImg(c, "sm")}<span class="name">${esc(r.champion_name)}</span></span>
      <span class="swing">
        <span class="swing-line${r.swing < 0 ? " falling" : ""}" style="left: ${(Math.min(from, to) * 100).toFixed(2)}%; width: ${(Math.abs(to - from) * 100).toFixed(2)}%"></span>
        <span class="swing-dot short" style="left: ${(from * 100).toFixed(2)}%"></span>
        <span class="swing-dot long" style="left: ${(to * 100).toFixed(2)}%"></span>
      </span>
      <span class="bar-value">${points(r)}</span>
    </a>`;
  };

  // Gold leads: the leading team's win rate by lead size, and by a lane lead in each role,
  // at the minute picked in the slicer.
  const leadRows = now(goldLeads);
  const laneRows = now(laneLeads);
  const minutes = LEAD_MINUTES.filter((m) => leadRows.some((r) => r.minute === m));
  let minute = minutes.includes(15) ? 15 : minutes[0];
  const bandsAt = () => leadRows.filter((r) => r.minute === minute).sort((a, b) => a.band_min - b.band_min);
  const lanesAt = () => ROLES.slice(1).map(([role]) => laneRows.find((r) => r.minute === minute && r.role === role)).filter(Boolean);
  const bandFrom = (min) => bandsAt().find((b) => b.band_min === min);
  const leadTitle = () => {
    const b = bandFrom(2000);
    return b ? `A 2k lead at ${minute} minutes wins ${pct(b.win_rate, 0)}` : `Gold leads at ${minute} minutes`;
  };
  const leadLede = () => {
    const bands = bandsAt(), lanes = [...lanesAt()].sort((a, b) => a.win_rate - b.win_rate);
    const [small] = bands, big = bands.at(-1), mid = bandFrom(1000);
    if (!small || !mid || lanes.length < 2) return "";
    const [worst, ...others] = lanes;
    return `Small leads don't count for much. Teams less than 1k gold ahead at ${minute} minutes won ${pct(small.win_rate, 0)},
      rising to ${pct(mid.win_rate, 0)} at 1–2k and ${pct(big.win_rate, 0)} at ${leadBand(big)}. By role, a 1k+ lane lead was
      worth least for ${ROLE_PLAYER[worst.role]}s (${pct(worst.win_rate, 0)}), with the other roles between
      ${pct(others[0].win_rate, 0)} and ${pct(others.at(-1).win_rate, 0)}.`;
  };
  const leadColumns = () => bandsAt().map((b) => rateColumn(b.band_min, b.win_rate, b.win_rate_moe, leadBand(b),
    `${leadBand(b)} gold ahead at ${minute} min\nWon ${num(b.wins)} of ${num(b.games)} games\n${pct(b.win_rate)} (${moe(b.win_rate_moe)})`, 0)).join("");
  const laneBars = () => lanesAt().map((r) => `<div class="bar-row" data-key="${r.role}" tabindex="0"
      data-tip="${esc(`${ROLE_NAME[r.role]} 1k+ gold ahead at ${minute} min\nTheir team won ${num(r.wins)} of ${num(r.games)} games\n${pct(r.win_rate)} (${moe(r.win_rate_moe)})`)}">
      <span class="bar-label">${ROLE_NAME[r.role]}</span>
      <span class="bar-track even"><span class="bar" style="--w: ${r.win_rate.toFixed(4)}"></span></span>
      <span class="bar-value">${pct(r.win_rate)}</span>
    </div>`).join("");
  const leadMethod = () => `The leading team's win rate by team gold at ${minute}:00, with the 95% margin of error. The
    dashed line is 50%. Only games still going at that minute count (${num(bandsAt().reduce((s, b) => s + b.games, 0))} at ${minute}
    minutes, with ties left out), so the later minutes lean towards longer games. A lane lead is a player 1,000+ gold ahead
    of their opponent in the same role. A gold lead also shows which team is playing better, so it isn't only the gold
    that's winning games.`;

  // Winners against losers: one bar per stat, for the role picked in the slicer.
  const gapRows = now(gaps);
  const metrics = [...new Map([...gapRows].sort((a, b) => a.metric_order - b.metric_order).map((g) => [g.metric, g])).values()];
  const roles = ROLES.slice(1);
  const gapOf = (metric, role) => gapRows.find((g) => g.metric === metric && g.role === role);
  const gapScale = Math.max(...gapRows.map((g) => Math.abs(g.gap)));
  const range = (metric) => {
    const values = roles.map(([role]) => Math.abs(gapOf(metric, role)?.gap ?? 0) * 100);
    return `${Math.round(Math.min(...values))}–${Math.round(Math.max(...values))}%`;
  };
  // Farm per minute, without supports: they leave the farm to their bot laner, so winning
  // supports can farm less.
  const laners = roles.filter(([role]) => role !== "UTILITY");
  const farmGaps = laners.map(([role]) => (gapOf("CS / min", role)?.gap ?? 0) * 100);
  const farmRange = `${Math.round(Math.min(...farmGaps))}–${Math.round(Math.max(...farmGaps))}%`;
  const supportFarm = gapOf("CS / min", "UTILITY")?.gap;
  let gapRole = roles[0][0];
  const gapBar = (m) => {
    const g = gapOf(m.metric, gapRole);
    if (!g) return `<div class="bar-row" data-key="${esc(m.metric)}"><span class="bar-label">${esc(METRIC_LABEL[m.metric] ?? m.metric)}</span><span class="faint">–</span></div>`;
    const better = g.lower_is_better ? -g.gap : g.gap;          // + = the winners' way
    return `<div class="bar-row" data-key="${esc(m.metric)}" tabindex="0"
        data-tip="${esc(`${METRIC_LABEL[m.metric] ?? m.metric}, ${ROLE_NAME[gapRole]}\nWinners ${statValue(g.winners)}, losers ${statValue(g.losers)}\n${num(g.players)} player records`)}">
      <span class="bar-label">${esc(METRIC_LABEL[m.metric] ?? m.metric)}</span>
      <span class="bar-track"><span class="bar${better < 0 ? " against" : ""}" style="--w: ${(Math.abs(g.gap) / gapScale).toFixed(4)}"></span></span>
      <span class="bar-value">${Math.round(Math.abs(g.gap) * 100)}% ${g.gap < 0 ? "lower" : "higher"}</span>
    </div>`;
  };
  // Changing role only changes each bar's width and label, so the bars slide between roles.
  const updateGaps = (card) => card.querySelectorAll(".bar-row").forEach((row, i) => {
    const fresh = document.createElement("div");
    fresh.innerHTML = gapBar(metrics[i]);
    const next = fresh.firstElementChild;
    const bar = row.querySelector(".bar"), nextBar = next.querySelector(".bar");
    if (!bar || !nextBar) return row.replaceWith(next);
    bar.style.cssText = nextBar.style.cssText;
    bar.className = nextBar.className;
    row.querySelector(".bar-value").textContent = next.querySelector(".bar-value").textContent;
    row.dataset.tip = next.dataset.tip;
  });

  // Bans: a column per ban band; picking one lists its most banned champions.
  const banRows = now(bans);
  const bands = now(banBands).sort((a, b) => a.band_order - b.band_order);
  const [topBand] = bands;
  const bandOf = (b) => (b.ban_rate >= 0.1 ? 1 : b.ban_rate >= 0.03 ? 2 : 3);
  const mostBanned = [...banRows].sort((a, b) => b.ban_rate - a.ban_rate);
  const banScale = mostBanned[0]?.ban_rate || 1;
  const [yLo, yHi] = [0.4, 0.6];
  const height = (v) => (Math.min(Math.max(v, yLo), yHi) - yLo) / (yHi - yLo);
  let band = 1;
  const bandColumns = () => bands.map((b) => `<button class="column" data-band="${b.band_order}" aria-pressed="${b.band_order === band}"
      data-tip="${esc(`${b.band}\n${num(b.champions)} champions, ${num(b.games)} games\nWon ${pct(b.win_rate, 2)} (${moe(b.win_rate_moe)})`)}">
      <span class="column-plot">
        <span class="column-bar" style="--h: ${height(b.win_rate).toFixed(4)}"></span>
        <span class="whisker" style="--lo: ${height(b.win_rate - b.win_rate_moe).toFixed(4)}; --hi: ${height(b.win_rate + b.win_rate_moe).toFixed(4)}"></span>
      </span>
      <strong>${pct(b.win_rate)}</strong>
      <small>${b.band.replace("Banned in ", "").replace(" of games", "")}</small>
    </button>`).join("");
  const banList = () => banRows.filter((b) => bandOf(b) === band).sort((a, b) => b.ban_rate - a.ban_rate).slice(0, 8)
    .map((b) => {
      const c = db.champions.get(b.champion_id);
      return `<div class="ban-row" data-key="${b.champion_id}" tabindex="0"
          data-tip="${esc(`${b.champion_name}\nBanned in ${pct(b.ban_rate)} of games\nWon ${num(b.wins)} of ${num(b.games)} (${pct(b.win_rate)})`)}">
        <span class="champ-cell">${c ? champImg(c, "sm") : ""}<span class="name">${esc(b.champion_name)}</span></span>
        <span class="bar-track"><span class="bar" style="--w: ${(b.ban_rate / banScale).toFixed(4)}"></span></span>
        <span class="bar-value">${pct(b.ban_rate)}</span>
        <span class="bar-value">${wr(b.win_rate)}</span>
      </div>`;
    }).join("");

  // Small samples: raw against adjusted win rate for the top ten, ranked either way.
  const ranked = db.tiers.filter((t) => t.tier != null);
  const prior = Math.round(ranked[0]?.prior_games ?? 0);
  const byRaw = [...ranked].sort((a, b) => b.win_rate - a.win_rate);
  const byAdjusted = [...ranked].sort((a, b) => b.adjusted_win_rate - a.adjusted_win_rate);
  const [luckiest] = byRaw, [leader] = byAdjusted;
  const ordinal = (n) => `${n}${[, "st", "nd", "rd"][(n % 100 >> 3) ^ 1 && n % 10] || "th"}`;
  // The raw top ten's biggest faller once the 50% games are added.
  const faller = byRaw.slice(0, 10).map((t, i) => ({ t, from: i + 1, to: byAdjusted.indexOf(t) + 1 }))
    .sort((a, b) => b.to - b.from - (a.to - a.from))[0];
  const shown = [...byRaw.slice(0, 10), ...byAdjusted.slice(0, 10)].flatMap((t) => [t.win_rate, t.adjusted_win_rate]);
  const [xLo, xHi] = [Math.floor(Math.min(0.5, ...shown) * 20) / 20, Math.ceil(Math.max(...shown) * 20) / 20];
  const at = (v) => `${(((v - xLo) / (xHi - xLo)) * 100).toFixed(2)}%`;
  let rankBy = "raw";
  const dumbbells = () => (rankBy === "raw" ? byRaw : byAdjusted).slice(0, 10).map((t) => {
    const c = db.champions.get(t.champion_id) ?? { champion_key: "", champion_name: t.champion_name };
    const [lo, hi] = [Math.min(t.win_rate, t.adjusted_win_rate), Math.max(t.win_rate, t.adjusted_win_rate)];
    return `<a class="dumbbell" data-key="${t.champion_id}-${t.role}" href="#/champion/${c.champion_key}/${t.role}"
        data-tip="${esc(`${t.champion_name}, ${ROLE_NAME[t.role]}\nWon ${pct(t.win_rate)} of ${num(t.games)} games\nAdjusted: ${pct(t.adjusted_win_rate)}, tier ${t.tier}`)}">
      <span class="champ-cell">${champImg(c, "sm")}<span class="name">${esc(t.champion_name)}<small>${ROLE_NAME[t.role]} · ${plural(t.games, "game")}</small></span></span>
      <span class="dumbbell-track" style="--even: ${at(0.5)}">
        <span class="dumbbell-line" style="left: ${at(lo)}; width: calc(${at(hi)} - ${at(lo)})"></span>
        <span class="dot raw" style="left: ${at(t.win_rate)}"></span>
        <span class="dot adjusted" style="--from: ${at(t.win_rate)}; --to: ${at(t.adjusted_win_rate)}"></span>
      </span>
      <span class="bar-value">${pct(t.win_rate)} <span class="faint">→</span> <strong>${pct(t.adjusted_win_rate)}</strong></span>
    </a>`;
  }).join("");
  const axisTicks = Array.from({ length: Math.round((xHi - xLo) * 20) + 1 }, (_, i) => xLo + i * 0.05)
    .map((v) => `<span style="left: ${at(v)}">${pct(v, 0)}</span>`).join("");

  // Sides and the sample.
  const [blue, red] = ["Blue", "Red"].map((side) => now(sides).find((s) => s.side === side));
  const redAhead = red.win_rate >= blue.win_rate;
  const sideVerdict = Math.abs(red.win_rate - 0.5) > red.win_rate_moe
    ? `${redAhead ? "Red" : "Blue"} side is ${(Math.abs(red.win_rate - 0.5) * 100).toFixed(1)} points above an even split, outside the ${moe(red.win_rate_moe)}-point margin of error, so it's unlikely to be chance.`
    : `The gap is inside the ${moe(red.win_rate_moe)}-point margin of error, so it could still be chance.`;
  const ranks = now(sample).sort((a, b) => RANK_ORDER.indexOf(a.sample_tier) - RANK_ORDER.indexOf(b.sample_tier));
  const rankScale = Math.max(...ranks.map((r) => r.share_of_matches));
  const topRank = ranks.find((r) => r.share_of_matches === rankScale);
  const passed = checks.filter((c) => c.failures === 0).length;

  view.innerHTML = `<div class="page insights">
    <div class="hero hero--split">
      <div>
        <h1>Key<br>findings</h1>
        <p>I love using data to make informed decisions, so as a League of Legends player I built this dashboard to
          test my data and software skills and help me make better decisions in my own games. Python pulls ranked games
          (Emerald+ solo/duo, EUW) from the Riot Games API and SQL Server models them. Every figure below comes from a
          T-SQL view that has to pass its data checks before it's published. So far that's ${num(db.matches)} games
          from patch ${esc(patchName(db.patch))}.</p>
      </div>
      ${kpiTriangle(vol)}
    </div>

    <div class="kpi-strip reveal">
      ${kpi("Rune choices", vol.rune_choices, "Six per player")}
      ${kpi("Bans", vol.bans, "Up to ten per match")}
      ${kpi("Champions played", banRows.length, "Across all five roles")}
      ${kpi("Days of games", Math.round((new Date(db.lastGame) - new Date(db.firstGame)) / 864e5) + 1, `${dateName(db.firstGame)} – ${dateName(db.lastGame)}`)}
    </div>

    ${topObjective ? `<section class="card reveal" id="objectives">
      <div class="card-head">
        <div>
          <h2>${esc(objectiveTitle)}</h2>
          <p class="lede">${early.length ? `I wanted to know which early objective is worth the most. The team that took ${early.slice(0, -1).join(", ")}${early.length > 1 ? " and " : ""}${early.at(-1)}.` : ""}${heraldLine ? `
            ${heraldLine}` : ""}${firstBlood ? `
            First blood, the first kill of the game, mattered less than I expected at ${pct(firstBlood.win_rate, 0)}.` : ""}${late.length ? `
            ${late.map((o, i) => `${esc(i ? inSentence(objectiveName(o.objective)) : objectiveName(o.objective))} (${pct(o.win_rate, 0)})`).join(" and ")}
            are higher, but by the time they're taken the game is usually decided.` : ""}</p>
        </div>
      </div>
      <div class="insight-grid">
        <div class="bars objective-list">${objectiveRows()}</div>
        <div class="objective-chart">${objectivePanel()}</div>
      </div>
      <p class="method">The win rate of the team that took each objective first, in games where either team took it.
        The dashed line is 50%. Towers and inhibitors are the buildings guarding each base, and the others are neutral
        monsters. These are correlations, and a team that's already ahead is more likely to take objectives. To separate
        Herald's own effect, I'd next compare teams that were level on gold just before it spawned. Pick an objective to
        see win rate by how many a team took. The last column includes anything above it.</p>
    </section>` : ""}

    ${lateTop && earlyTop ? `<section class="card reveal" id="length">
      <div class="card-head">
        <div>
          <h2>Scaling champions at a glance</h2>
          <p class="lede">Some champions get stronger the longer a game goes, which players call scaling.
            ${esc(lateTop.champion_name)} won ${pct(lateTop.short_win_rate, 0)} of games that ended within 25 minutes and
            ${pct(lateTop.long_win_rate, 0)} of games that went past 33. ${esc(earlyTop.champion_name)} went the other way,
            from ${pct(earlyTop.short_win_rate, 0)} in short games to ${pct(earlyTop.long_win_rate, 0)} in long ones.</p>
        </div>
      </div>
      <div class="insight-grid">
        <div>
          <h3 class="sub-head">Better in long games</h3>
          <div class="length-list">${lateChamps.map(lengthRow).join("")}</div>
        </div>
        <div>
          <h3 class="sub-head">Better in short games</h3>
          <div class="length-list">${earlyChamps.map(lengthRow).join("")}</div>
        </div>
      </div>
      <p class="method">Each line runs from a champion's win rate in short games <span class="swing-key short"></span>
        (${pct(lateTop.short_match_share, 0)} of games) to long games <span class="swing-key long"></span>
        (${pct(lateTop.long_match_share, 0)}), on a scale from ${pct(DUMBBELL[0], 0)} to ${pct(DUMBBELL[1], 0)} with 50% dashed.
        The figure on the right is the change in percentage points. I combined all roles and only included champions
        with 300+ games of each length. With a few hundred games each, the margin of error on a swing is around ±${Math.round([...lateChamps, ...earlyChamps].reduce((sum, r) => sum + r.swing_moe, 0) / (lateChamps.length + earlyChamps.length) * 100)} points,
        so the order is more reliable than the exact figures. Hover for details, or click a champion to open their page.</p>
    </section>` : ""}

    ${minute ? `<section class="card reveal" id="leads">
      <div class="card-head">
        <div>
          <h2 class="lead-title">${esc(leadTitle())}</h2>
          <p class="lede lead-lede">${leadLede()}</p>
        </div>
        ${slicer(minutes.map((m) => [String(m), `${m} min`]), String(minute), "Minute")}
      </div>
      <div class="insight-grid leads-grid">
        <div>
          <h3 class="sub-head">Leading team's win rate, by gold lead</h3>
          <div class="columns lead-columns" style="--n: ${bandsAt().length}; --even: 0.5">${leadColumns()}</div>
        </div>
        <div>
          <h3 class="sub-head">Team win rate with a 1k+ lane lead</h3>
          <div class="bars lane-bars">${laneBars()}</div>
        </div>
      </div>
      <p class="method lead-method">${leadMethod()}</p>
    </section>` : ""}

    <section class="card reveal" id="gaps">
      <div class="card-head">
        <div>
          <h2>Fights, not farm, separate winners</h2>
          <p class="lede">Against the losing player in the same role, winners farmed (killed minions and monsters for
            gold) only ${farmRange} more per minute.${supportFarm < 0
            ? ` Winning supports farmed ${Math.round(-supportFarm * 100)}% less, since they leave the minions to their bot laner.` : ""}
            Their first item came ${range("First item (min)")} sooner. The bigger differences were in fights, with winners
            getting ${range("Kills + assists")} more kills and assists and dying ${range("Deaths")} less. Some of that comes
            from winning rather than causing it, because a team that's ahead gets to choose its fights.</p>
        </div>
        ${slicer(roles, gapRole, "Role")}
      </div>
      <div class="bars">${metrics.map(gapBar).join("")}</div>
      <p class="method">Winning players' average compared with losing players' in the same role.
        <span class="swatch"></span> favours the winners and <span class="swatch against"></span> the losers. Hover over a bar to see the averages.</p>
    </section>

    <section class="card reveal" id="bans">
      <div class="card-head">
        <div>
          <h2>Bans don't predict wins</h2>
          <p class="lede">The ${num(topBand.champions)} champions banned in 10%+ of games won ${pct(topBand.win_rate)}
            of the games they weren't banned in, compared with ${pct(bands.at(-1).win_rate)} for the ${num(bands.at(-1).champions)}
            banned in under 3%. That's only ${(Math.abs(topBand.win_rate - bands.at(-1).win_rate) * 100).toFixed(1)} points for a
            very big difference in how often they're banned. It looks like players ban the champions they find frustrating
            to play against, more than the ones that win.</p>
        </div>
      </div>
      <div class="ban-grid">
        <div>
          <div class="columns" style="--even: ${height(0.5)}">${bandColumns()}</div>
          <p class="method">Win rate by how often a champion is banned, with the 95% margin of error. The dashed line is 50%. Pick a column to list its champions. "Won" covers every role a champion was played in, so it can differ from the one-role win rate on their champion page.</p>
        </div>
        <div>
          <div class="ban-row head" aria-hidden="true"><span>Most banned</span><span></span><span>Banned</span><span>Won</span></div>
          <div class="ban-list">${banList()}</div>
        </div>
      </div>
    </section>

    <section class="card reveal" id="samples">
      <div class="card-head">
        <div>
          <h2>Small samples mislead</h2>
          <p class="lede">${luckiest === leader
            ? `${esc(leader.champion_name)} has the highest win rate, ${pct(leader.win_rate)} over ${num(leader.games)} games,
              which is enough games for it to hold up. To stop a short lucky run from topping the tier list, I add
              ${num(prior)} games at 50% to every champion before ranking them. ${esc(faller.t.champion_name)} won
              ${pct(faller.t.win_rate)} of only ${num(faller.t.games)} games and drops from ${ordinal(faller.from)} to
              ${ordinal(faller.to)} once they're added.`
            : `${esc(luckiest.champion_name)} has the highest raw win rate at ${pct(luckiest.win_rate)}, but from only
              ${num(luckiest.games)} games. To stop a short lucky run from topping the tier list, I add ${num(prior)} games
              at 50% to every champion before ranking them. ${esc(leader.champion_name)}, at ${pct(leader.win_rate)} over
              ${num(leader.games)} games, holds up better and ranks first instead.`}</p>
        </div>
        ${slicer([["raw", "Raw"], ["adjusted", "Adjusted"]], rankBy, "Rank by")}
      </div>
      <div class="dumbbell-axis" aria-hidden="true"><span></span><span class="axis-ticks">${axisTicks}</span><span></span></div>
      <div class="dumbbells">${dumbbells()}</div>
      <p class="method"><span class="dot-key raw"></span> Raw win rate, <span class="dot-key adjusted"></span> after adding
        ${num(prior)} games at 50%. The dashed line is 50%. I didn't pick ${num(prior)} myself. On every export, SQL Server
        estimates how much of the spread in champions' win rates is real rather than chance and sets the number from
        that (empirical Bayes).</p>
    </section>

    <div class="grid-2">
      <section class="card reveal">
        <h2>${redAhead ? "Red" : "Blue"} side wins ${pct(Math.max(red.win_rate, blue.win_rate))}</h2>
        <div class="split" data-tip="${esc(`Blue ${num(blue.wins)} wins, red ${num(red.wins)}\nOut of ${num(red.games)} games`)}">
          <span class="split-blue" style="--w: ${blue.win_rate}"><strong>${pct(blue.win_rate)}</strong>Blue</span>
          <span class="split-red" style="--w: ${red.win_rate}"><strong>${pct(red.win_rate)}</strong>Red</span>
        </div>
        <div class="split-counts">
          <span><strong>${num(blue.wins)}</strong> blue wins</span>
          <span><strong>${num(red.wins)}</strong> red wins</span>
        </div>
        <p class="method">Each game puts one team on the blue side of the map and one on the red. ${sideVerdict} The dashed line is an even split.</p>
      </section>

      <section class="card reveal">
        <h2>Sample by rank</h2>
        <div class="bars ranks">${ranks.map((r) => `<div class="bar-row" tabindex="0" data-tip="${esc(`${RANK_NAME[r.sample_tier] ?? r.sample_tier}\n${num(r.matches)} matches`)}">
          <span class="bar-label"><img class="rank-icon" src="img/rank-${r.sample_tier.toLowerCase()}.png" alt="" width="28" height="28">${RANK_NAME[r.sample_tier] ?? esc(r.sample_tier)}</span>
          <span class="bar-track"><span class="bar rank-${r.sample_tier.toLowerCase()}" style="--w: ${(r.share_of_matches / rankScale).toFixed(4)}"></span></span>
          <span class="bar-value">${pct(r.share_of_matches, 0)}</span>
        </div>`).join("")}</div>
        <p class="method">Games lasted ${db.avgMinutes.toFixed(1)} minutes on average. Each game is counted under the
          rank of the player whose match history I found it in.${topRank ? ` ${RANK_NAME[topRank.sample_tier] ?? esc(topRank.sample_tier)}
          makes up ${pct(topRank.share_of_matches, 0)} of the sample, so the overall figures lean towards
          ${RANK_NAME[topRank.sample_tier] ?? esc(topRank.sample_tier)} games.` : ""}</p>
      </section>
    </div>

    <section class="card reveal flow-card">
      <div class="card-head">
        <div>
          <h2>From API to dashboard</h2>
          <p class="lede">I collect the games with Python and model them in SQL Server, and every figure on this site comes from a T-SQL view.</p>
        </div>
      </div>
      <ol class="flow">
        <li style="--i: 0">
          <span class="flow-figure" data-count="${vol.ladder_players}" data-format="num">${num(vol.ladder_players)}</span>
          <span class="flow-label">Riot API</span>
          <span>Ladder players scanned for Emerald+ ranked games and timelines, within the API's rate limits.</span>
        </li>
        <li style="--i: 1">
          <span class="flow-figure" data-count="${vol.matches + vol.timelines}" data-format="num">${num(vol.matches + vol.timelines)}</span>
          <span class="flow-label">SQL Server staging</span>
          <span>Games and timelines, each stored as it arrived, as compressed raw JSON.</span>
        </li>
        <li style="--i: 2">
          <span class="flow-figure" data-count="${vol.fact_rows}" data-format="compact">${KPI_FORMAT.compact(vol.fact_rows)}</span>
          <span class="flow-label">T-SQL ETL</span>
          <span>Fact rows parsed with OPENJSON into a star schema of match, player, item and rune facts.</span>
        </li>
        <li style="--i: 3">
          <span class="flow-figure" data-count="${vol.mart_views}" data-format="num">${num(vol.mart_views)}</span>
          <span class="flow-label">Mart views</span>
          <span>T-SQL views compute every rate, tier and build on this site, with window functions.</span>
        </li>
        <li style="--i: 4">
          <span class="flow-figure" data-count="${checks.length}" data-format="num">${num(checks.length)}</span>
          <span class="flow-label">Checks, then publish</span>
          <span>Data checks run before each export to the JSON this site reads.</span>
        </li>
      </ol>
      <details class="checks">
        <summary><span class="pulse" aria-hidden="true"></span>${passed} of ${checks.length} data checks pass${passed < checks.length ? `, ${checks.length - passed} ${checks.some((c) => c.failures && c.is_blocking) ? "flagged" : "warnings"}` : ""}</summary>
        <ul>${checks.map((c) => `<li><span class="${c.failures === 0 ? "good" : c.is_blocking ? "bad" : "warn"}">${c.failures === 0 ? "✓" : c.is_blocking ? "✗" : "!"}</span>
          ${esc(c.check_name)}${c.failures ? ` <span class="faint">(${num(c.failures)})</span>` : ""}${c.is_blocking ? "" : ' <span class="faint">· warning only</span>'}</li>`).join("")}</ul>
      </details>
    </section>
  </div>`;

  const el = view.firstElementChild;
  current = { page: "insights", el };
  window.scrollTo({ top: 0 });
  moveIndicator(el);
  reveal(el);

  const objectiveCard = el.querySelector("#objectives");
  objectiveCard?.querySelector(".objective-list").addEventListener("click", (e) => {
    const row = e.target.closest("button[data-key]");
    if (!row || row.dataset.key === objective) return;
    objective = row.dataset.key;
    objectiveCard.querySelectorAll(".objective-list button").forEach((b) => b.setAttribute("aria-pressed", b === row));
    const chart = objectiveCard.querySelector(".objective-chart");
    const columnsBefore = chart.querySelectorAll(".column").length;
    morph(chart, objectivePanel());
    if (chart.querySelectorAll(".column").length !== columnsBefore) growColumns(chart);
  });
  const leadCard = el.querySelector("#leads");
  if (leadCard) wireSlicer(leadCard.querySelector(".slicer"), (value) => {
    minute = Number(value);
    morph(leadCard.querySelector(".lead-title"), esc(leadTitle()));
    morph(leadCard.querySelector(".lead-lede"), leadLede());
    morph(leadCard.querySelector(".lead-columns"), leadColumns());
    morph(leadCard.querySelector(".lane-bars"), laneBars());
    morph(leadCard.querySelector(".lead-method"), leadMethod());
  });

  const gapCard = el.querySelector("#gaps");
  wireSlicer(gapCard.querySelector(".slicer"), (role) => { gapRole = role; updateGaps(gapCard); });
  const samples = el.querySelector("#samples");
  wireSlicer(samples.querySelector(".slicer"), (value) => { rankBy = value; reorder(samples.querySelector(".dumbbells"), dumbbells()); });
  const banCard = el.querySelector("#bans");
  banCard.querySelector(".columns").addEventListener("click", (e) => {
    const column = e.target.closest("[data-band]");
    if (!column || Number(column.dataset.band) === band) return;
    band = Number(column.dataset.band);
    banCard.querySelectorAll("[data-band]").forEach((c) => c.setAttribute("aria-pressed", c === column));
    reorder(banCard.querySelector(".ban-list"), banList());
  });
}

function renderNotFound(message = "That page doesn't exist.") {
  current = null;
  view.innerHTML = `<div class="page hero"><h1>Not found</h1><p>${esc(message)}</p><p><a class="good" href="#/">Back to the insights</a></p></div>`;
}

// ---------- Router ----------

function route() {
  const ticket = ++navigation;
  const [, page, a, b] = (location.hash || "#/").split("/");
  const section = !page || page === "insights" ? "insights" : "tiers";
  document.querySelectorAll("[data-nav]").forEach((link) => link.toggleAttribute("aria-current", link.dataset.nav === section));
  if (page === "tiers") return renderTierList("ALL");
  if (page === "role" && ROLE_NAME[a] && a !== "ALL") return renderTierList(a);
  if (section === "insights") {
    return renderInsights(ticket).catch((error) => {
      if (ticket === navigation) renderNotFound(`Couldn't load the insights (${error.message}).`);
    });
  }
  if (page === "champion" && a) {
    return renderChampion(decodeURIComponent(a), b, ticket).catch((error) => {
      if (ticket === navigation) renderNotFound(`Couldn't load the champion data (${error.message}).`);
    });
  }
  renderNotFound();
}

window.addEventListener("hashchange", () => {
  if (!(current?.page === "tiers" && /^#\/(tiers|role\/\w+)$/.test(location.hash))) current = null;
  route();
});
window.addEventListener("resize", () => current && moveIndicator(current.el));

wireTips();

// "/" jumps to the champion search, wherever the tier list is on screen.
document.addEventListener("keydown", (e) => {
  const search = document.querySelector(".search input");
  if (e.key !== "/" || !search || e.target.closest("input, textarea")) return;
  e.preventDefault();
  search.focus();
});

// The portfolio's nav: frosted once scrolled, with an orange reading-progress line.
const nav = document.querySelector(".site-nav");
const onScroll = () => {
  const max = document.documentElement.scrollHeight - innerHeight;
  nav.classList.toggle("is-scrolled", scrollY > 24);
  nav.style.setProperty("--progress", max > 0 ? (scrollY / max).toFixed(4) : 0);
};
window.addEventListener("scroll", onScroll, { passive: true });
new ResizeObserver(onScroll).observe(document.body);

// Background art in the side margins on wide screens (styles.css), one piece every 62rem down the page,
// alternating sides, for as far as the page goes. Baron, Herald and the Elder Dragon come first so they
// sit beside the opening cards on the insights page. Images load lazily as they scroll near.
// [name, width / height, width in rem, where the face sits across the image (0 to 1), opacity, brightness].
// Right-hand pieces hang off the content edge; left-hand ones are placed by the face, so the head
// lands in the margin at any screen width.
const BACKDROP_ART = [
  ["baron", 643 / 1000, 30, 0.45], ["herald", 728 / 820, 32, 0.55], ["elder-dragon", 1100 / 654, 44, 0.45, 0.6, 1.35],
  ["ocean-drake", 1000 / 629, 40, 0.25], ["velkoz", 774 / 900, 30, 0.5], ["hextech-drake", 1100 / 495, 46, 0.6],
  ["kayle", 501 / 1000, 24, 0.5], ["cloud-drake", 1000 / 520, 42, 0.33], ["voidgrub", 476 / 700, 24, 0.6],
  ["chemtech-drake", 1000 / 753, 40, 0.72], ["braum", 560 / 900, 26, 0.5], ["mountain-drake", 800 / 707, 36, 0.5],
];
const backdrop = document.querySelector(".backdrop");
const wideScreen = matchMedia("(min-width: 1100px)");
const placeBackdrop = () => {
  if (!wideScreen.matches) return;
  const rem = parseFloat(getComputedStyle(document.documentElement).fontSize);
  const slots = Math.max(1, Math.floor((document.body.scrollHeight / rem - 30) / 62) + 1);
  if (backdrop.childElementCount === slots) return;
  backdrop.replaceChildren(...Array.from({ length: slots }, (_, i) => {
    const [name, ratio, width, face, opacity, brightness] = BACKDROP_ART[i % BACKDROP_ART.length];
    const img = Object.assign(new Image(), { src: `img/art-${name}.png`, alt: "", loading: "lazy", decoding: "async" });
    img.className = i % 2 ? "is-left" : "is-right";
    img.width = Math.round(width * rem);
    img.height = Math.round(width * rem / ratio);
    img.style.top = `${3 + i * 62}rem`;
    img.style.width = `${width}rem`;
    img.style.setProperty("--art-width", `${width}rem`);
    img.style.setProperty("--art-face", face);
    if (opacity) img.style.setProperty("--art-opacity", opacity);
    if (brightness) img.style.setProperty("--art-brightness", brightness);
    return img;
  }));
};
new ResizeObserver(placeBackdrop).observe(view);
wideScreen.addEventListener("change", placeBackdrop);

init()
  .then(route)
  .catch((error) => {
    view.innerHTML = `<div class="page hero"><h1>No data</h1><p>${esc(error.message)}</p></div>`;
  });
