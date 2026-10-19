// npm run economy -w @deadball/server [-- --seasons 2 --seed econ-1 --stake 40 --fit --priors]
//
// Bobby's regulars (src/house.ts), simulated: plays whole seasons through the same pure
// pipeline the League DO runs (runDay), seeds every bettable pool with house waves exactly as
// the server does (gameWaves / propWaves from public facts), lets synthetic players bet, settles
// with settleMath and prints the money that flowed: per behaviour (random, favourite-only,
// skilled), solo and in a crowd, with a no-house baseline (the old rules), scaled to a week of
// real time at the default clock (30-minute game days = 336 game days a week).
//
//   --fit     refit the fair game line (HOUSE.line) on the simulated games
//   --priors  re-measure the prop form guide (house.ts PRIORS) on fresh simulated seasons

import { generateWorld, Rng, sim, bettableStorylines, resolveProps, buildStaff, pickStarter, type World, type SeasonState } from "../src/sim.ts";
import { runDay } from "../src/day.ts";
import {
  HOUSE, bettableLevel, fairHome, gameWaves, paysFor, propFair, propWaves, publicFacts, rivals, settleMath, teamForm,
  type HouseWave, type PropQ, type PublicStory, type TeamRecord,
} from "../src/house.ts";

const arg = (k: string, d: string) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const flag = (k: string) => process.argv.includes(`--${k}`);
const SEASONS = Number(arg("seasons", "2"));
const SEED = arg("seed", "econ-1");
const STAKE = Number(arg("stake", "40"));
const DAY_MS = 1_800_000, PRE_MS = Math.round(DAY_MS * 0.25);
const GAME_DAYS_PER_WEEK = (7 * 24 * 3_600_000) / DAY_MS;
/** Game days a week a player bets in: 4 sessions a day vs 1. */
const ENGAGED = 28, CASUAL = 7;
/** Skilled bettors want this expected return per $1, after their own stake moves the pool. */
const EDGE = 1.04;

type Behaviour = "random" | "favourite" | "skilled";
interface Bettor { id: string; b: Behaviour; rng: Rng }
interface Tally { bets: number; staked: number; returned: number; profits: number[] }
const tally = (): Tally => ({ bets: 0, staked: 0, returned: 0, profits: [] });
/** A pool: house money landed so far, player money, the bets. `tag` groups results (game, prop:yes, ...). */
interface Pool { tag: string; house: number[]; player: number[]; bets: { who: Bettor; opt: number; amt: number }[] }

const CROWD: Behaviour[] = ["random", "random", "random", "random", "favourite", "favourite", "favourite", "favourite", "skilled", "skilled"];
const SCENARIOS: { name: string; bettors: Behaviour[]; noHouse?: true }[] = [
  { name: "crowd 4 random + 4 favourite + 2 skilled, NO house money (before)", bettors: CROWD, noHouse: true },
  { name: "solo random", bettors: ["random"] },
  { name: "solo favourite", bettors: ["favourite"] },
  { name: "solo skilled", bettors: ["skilled"] },
  { name: "crowd 4 random + 4 favourite + 2 skilled", bettors: CROWD },
];

/**
 * random: any option. favourite: the option with the most money on it. skilled: the public fair
 * estimate (what the house's sharps use, without the squares' bias and noise) vs the pays it
 * would get after its own stake; bets the best option worth EDGE, else passes.
 */
function choose(who: Bettor, house: number[], player: number[], fair: number[]): number | undefined {
  const seen = house.map((h, i) => h + player[i]);
  if (who.b === "random") return who.rng.int(seen.length);
  if (who.b === "favourite") return seen.indexOf(Math.max(...seen));
  let best: number | undefined, bestEv = EDGE;
  for (let i = 0; i < seen.length; i++) {
    const ev = fair[i] * paysFor(player.map((x, j) => x + (j === i ? STAKE : 0)), house)[i];
    if (ev > bestEv) { bestEv = ev; best = i; }
  }
  return best;
}

const scaled = (k: number, ws: HouseWave[]) => (k === 1 ? ws : ws.map(w => ({ ...w, a: w.a.map(x => Math.floor(x * k)) })));
const land = (p: Pool, ws: HouseWave[]) => { for (const w of ws) w.a.forEach((x, i) => (p.house[i] += x)); };
function probable(world: World, teamId: string) {
  const t = world.teams[teamId];
  try { return t ? pickStarter(buildStaff(world, t))?.id : undefined; } catch { return undefined; }
}

function runScenario(bettors: Behaviour[], seasons: number, scale: number) {
  const world: World = generateWorld(SEED);
  let state: SeasonState = sim.newSeason(world, new Rng(`${SEED}:season`));
  let offDays = 0;
  const who: Bettor[] = bettors.map((b, i) => ({ id: `${b}${i}`, b, rng: new Rng(`${SEED}:bettor:${i}`) }));
  const order = new Rng(`${SEED}:order`);
  const T: Record<string, Tally> = Object.fromEntries(who.map(w => [w.id, tally()]));
  const byTag: Record<string, Record<Behaviour, Tally>> = {};
  const tot = { minted: 0, burned: 0, take: 0, playerNet: 0, gamePools: 0, propPools: 0, mintedGames: 0, mintedProps: 0, refunds: 0 };
  const fitRows: { f: number[]; y: number }[] = [];
  const props = new Map<string, { q: PropQ; f: PublicStory; pool: Pool }>();
  let gameDays = 0;

  const settle = (p: Pool, win: number | undefined) => {
    const s = settleMath(p.player, p.house, win);
    const H = p.house.reduce((a, b) => a + b, 0);
    tot.minted += H;
    if (p.tag === "game") { tot.gamePools++; tot.mintedGames += H; } else { tot.propPools++; tot.mintedProps += H; }
    if (s.refund) tot.refunds++;
    else { tot.burned += s.burned; tot.take += s.take; }
    for (const b of p.bets) {
      const pay = s.refund ? b.amt : b.opt === win ? Math.floor((b.amt * s.net) / s.winPool) : 0;
      for (const t of [T[b.who.id], ((byTag[p.tag] ??= {} as Record<Behaviour, Tally>)[b.who.b] ??= tally())]) {
        t.bets++; t.staked += b.amt; t.returned += pay; t.profits.push(pay - b.amt);
      }
      tot.playerNet += pay - b.amt;
    }
  };
  const placeAll = (p: Pool, fair: number[]) => {
    for (const w of order.shuffle([...who])) {
      const opt = choose(w, p.house, p.player, fair);
      if (opt === undefined) continue;
      p.player[opt] += STAKE;
      p.bets.push({ who: w, opt, amt: STAKE });
    }
  };

  const seasonEnd = world.season + seasons;
  for (let guard = 0; guard < 400 * seasons && world.season < seasonEnd; guard++) {
    // ---- games: the house waves land through the pre-game window; players bet after the
    // first two (mid-window), the late sharp wave lands after them
    const slate = sim.slateFor(state, state.day).filter(g => bettableLevel(g.level));
    const table = new Map<string, TeamRecord>();
    for (const lv of ["ML", "EL"] as const) for (const s of sim.standings(world, state, lv)) table.set(s.teamId, s);
    const pools = new Map<string, { pool: Pool; feats?: number[] }>();
    for (const g of slate) {
      const prob = { home: probable(world, g.homeId), away: probable(world, g.awayId) };
      const pHome = fairHome(world, g.homeId, g.awayId, prob, table);
      const series = g.series ? [...(state.playoff?.series ?? []), ...(state.enhancedPlayoff?.series ?? [])].find(s => s.id === g.series) : undefined;
      const streak = (id: string) => teamForm(world, id, undefined, table.get(id)).streak;
      const waves = scaled(scale, gameWaves(SEED, {
        id: g.id, level: g.level, homeId: g.homeId, awayId: g.awayId, pHome, exhibition: !!g.exhibition, playoff: !!g.series, final: series?.round === "final",
        rivalry: rivals(world, g.homeId, g.awayId), streakDiff: streak(g.homeId) - streak(g.awayId),
      }, PRE_MS));
      const pool: Pool = { tag: "game", house: [0, 0], player: [0, 0], bets: [] };
      land(pool, waves.slice(0, 2));
      placeAll(pool, [pHome, 1 - pHome]);
      land(pool, waves.slice(2));
      let feats: number[] | undefined;
      if (flag("fit")) {
        const h = teamForm(world, g.homeId, prob.home, table.get(g.homeId)), a = teamForm(world, g.awayId, prob.away, table.get(g.awayId));
        feats = [1, h.bat - a.bat, h.sp - a.sp, h.pen - a.pen, h.pyth - a.pyth, h.wp - a.wp];
      }
      pools.set(g.id, { pool, feats });
    }
    const r = runDay({ world, state, seed: SEED, orders: [], crew: {}, offDays, offseasonLength: 7 });
    offDays = r.offDays;
    if (r.newSeason) state = r.newSeason;
    if (slate.length) gameDays++;
    for (const pg of r.games) {
      const p = pools.get(pg.game.id);
      if (!p) continue;
      const win = pg.res.winner === "home" ? 0 : 1;
      settle(p.pool, win);
      if (p.feats) fitRows.push({ f: p.feats, y: win === 0 ? 1 : 0 });
    }

    // ---- props: settle what's decided (final), then today's sync (new questions, the day's
    // waves), then players take each new question once
    for (const [id, pr] of props) {
      if (!(world.storylines ?? []).some(x => x.id === pr.f.id)) { settle(pr.pool, undefined); props.delete(id); continue; }
      const res = resolveProps(world, pr.f.id)[id];
      if (res !== undefined) { settle(pr.pool, pr.q.options.indexOf(res)); props.delete(id); }
    }
    const day = world.day;
    for (const { storyline: s, props: qs } of bettableStorylines(world)) {
      const f = publicFacts(s);
      if (!f) continue;
      for (const pq of qs) {
        if (pq.closesDay < day) continue;
        const q: PropQ = { id: pq.id, options: pq.options.map(o => o.key), closesDay: pq.closesDay, resolveBy: pq.resolveBy };
        let pr = props.get(pq.id);
        const first = !pr;
        if (!pr) props.set(pq.id, (pr = { q, f, pool: { tag: `prop:${pq.id.split(":").pop()}`, house: q.options.map(() => 0), player: q.options.map(() => 0), bets: [] } }));
        land(pr.pool, scaled(scale, propWaves(SEED, f, q, day, DAY_MS, first)));
        if (first) placeAll(pr.pool, propFair(f, q, day));
      }
    }
  }
  return { T, tot, who, gameDays, fitRows, byTag };
}

// ---------------------------------------------------------------- report
const pct = (xs: number[], q: number) => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor(q * s.length))] : 0; };
const $ = (x: number) => `${x < 0 ? "-" : ""}$${Math.abs(Math.round(x)).toLocaleString("en-US")}`;
const roi = (t: Tally) => `${((t.returned / Math.max(1, t.staked) - 1) * 100).toFixed(1)}%`;

function report() {
  const packs = sim.PACKS.filter(p => p.price > 0).sort((a, b) => a.price - b.price).map(p => `${p.name} $${p.price}`).join(", ");
  console.log(`seed ${SEED}, ${SEASONS} season(s), $${STAKE} flat stakes, house cut ${HOUSE.cut * 100}% on player money, ${HOUSE.npcCut * 100}% on house money`);
  console.log(`a week of real time = ${GAME_DAYS_PER_WEEK} game days; "engaged" bets every open pool on ${ENGAGED} of them (4 sessions/day), "casual" on ${CASUAL}. Packs: ${packs}.\n`);
  for (const sc of SCENARIOS) {
    const t0 = Date.now();
    const { T, tot, who, gameDays, fitRows, byTag } = runScenario(sc.bettors, SEASONS, sc.noHouse ? 0 : 1);
    const days = gameDays || 1;
    console.log(`== ${sc.name}  (${((Date.now() - t0) / 1000).toFixed(1)}s, ${gameDays} game days)`);
    console.log(`   pools: ${tot.gamePools} games, ${tot.propPools} props, ${tot.refunds} refunded. House minted ${$(tot.minted)} (${$(tot.minted / days)}/game day: games ${$(tot.mintedGames / days)}, props ${$(tot.mintedProps / days)})`);
    console.log(`   house burned ${$(tot.burned)}, house cut ${$(tot.take)}, players net ${$(tot.playerNet)} (${$(tot.playerNet / days)}/game day)`);
    const by = new Map<Behaviour, Tally>();
    for (const w of who) { const t = by.get(w.b) ?? tally(); const x = T[w.id]; t.bets += x.bets; t.staked += x.staked; t.returned += x.returned; t.profits.push(...x.profits); by.set(w.b, t); }
    for (const [b, t] of by) {
      const n = who.filter(w => w.b === b).length;
      const perDay = (t.returned - t.staked) / n / days;
      const wins = t.profits.filter(p => p > 0);
      const parts = Object.entries(byTag).filter(([, v]) => v[b]).map(([k, v]) => `${k} ${roi(v[b])}`).join(", ");
      console.log(`   ${b.padEnd(9)} x${n}: ${(t.bets / n / days).toFixed(1)} bets/game day, ROI ${roi(t)} (${parts})`);
      console.log(`             ${$(perDay)}/game day -> engaged ${$(perDay * ENGAGED)}/week, casual ${$(perDay * CASUAL)}/week (each)`);
      console.log(`             win rate ${(wins.length / Math.max(1, t.profits.length) * 100).toFixed(0)}%, profit on a winning bet p10/p50/p90/max ${$(pct(wins, 0.1))}/${$(pct(wins, 0.5))}/${$(pct(wins, 0.9))}/${$(pct(wins, 1))}`);
    }
    if (flag("fit") && sc === SCENARIOS[1]) fit(fitRows);
    console.log("");
  }
  if (flag("priors")) priors();
}

function fit(rows: { f: number[]; y: number }[]) {
  const sig = (x: number) => 1 / (1 + Math.exp(-x));
  const w = rows[0]?.f.map(() => 0) ?? [];
  for (let it = 0; it < 4000; it++) {
    const g = w.map(() => 0);
    for (const r of rows) { const e = sig(r.f.reduce((a, x, i) => a + w[i] * x, 0)) - r.y; r.f.forEach((x, i) => (g[i] += e * x)); }
    w.forEach((_, i) => (w[i] -= ((i === 0 ? 0.5 : 0.03) * g[i]) / rows.length));
  }
  let ll = 0, llNow = 0;
  const L = HOUSE.line, cur = [L.home, L.bat, L.sp, L.pen, L.pyth, L.wp];
  for (const r of rows) {
    const p = sig(r.f.reduce((a, x, i) => a + w[i] * x, 0)), q = sig(r.f.reduce((a, x, i) => a + cur[i] * x, 0));
    ll += -(r.y * Math.log(p) + (1 - r.y) * Math.log(1 - p));
    llNow += -(r.y * Math.log(q) + (1 - r.y) * Math.log(1 - q));
  }
  console.log(`   fit on ${rows.length} games: home/bat/sp/pen/pyth/wp = ${w.map(x => x.toFixed(4)).join(" / ")}; log loss ${(ll / rows.length).toFixed(4)} (HOUSE.line ${(llNow / rows.length).toFixed(4)}, coin flip ${Math.log(2).toFixed(4)})`);
}

function priors() {
  const out: Record<string, { yes: Record<string, number>; when: Record<string, number>; how: Record<string, number> }> = {};
  for (let k = 0; k < 4; k++) {
    const seed = `${SEED}:priors:${k}`;
    const world = generateWorld(seed);
    let state = sim.newSeason(world, new Rng(`${seed}:season`));
    let offDays = 0;
    const seen = new Map<string, string>(), done = new Set<string>();
    for (let d = 0; d < 400; d++) {
      for (const { storyline: s } of bettableStorylines(world)) if (!seen.has(s.id)) seen.set(s.id, s.kind);
      const r = runDay({ world, state, seed, orders: [], crew: {}, offDays, offseasonLength: 7 });
      offDays = r.offDays;
      if (r.newSeason) state = r.newSeason;
      for (const [id, kind] of seen) {
        for (const [q, v] of Object.entries(resolveProps(world, id))) {
          if (done.has(q)) continue;
          done.add(q);
          const e = (out[kind] ??= { yes: {}, when: {}, how: {} });
          const t = q.split(":").pop() as "yes" | "when" | "how";
          e[t][v] = (e[t][v] ?? 0) + 1;
        }
      }
    }
  }
  console.log("form guide (resolved answers per storyline kind; house.ts PRIORS):");
  for (const [k, v] of Object.entries(out)) console.log(`  ${k}: yes ${JSON.stringify(v.yes)} when ${JSON.stringify(v.when)} how ${JSON.stringify(v.how)}`);
}

report();
