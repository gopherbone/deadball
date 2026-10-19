import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { Rng } from "../src/rng.ts";
import { simulateGame } from "../src/game.ts";
import { buildLineup, buildStaff } from "../src/lineup.ts";
import type { World } from "../src/types.ts";
import { FREE_AGENT } from "../src/types.ts";
import { FACES } from "../src/faces.ts";
import { newSeason, slateFor } from "../src/league/index.ts";
import { playDay } from "../src/league/driver.ts";
import { historyBook } from "../src/league/history.ts";
import type { LifeEvent } from "../src/life/events.ts";
import { moodModifiers, worldMultipliers } from "../src/life/index.ts";
import { personById, wasPlayer } from "../src/life/people.ts";
import { rosterProblems } from "../src/life/roster.ts";
import { TEMPLATE, groupOf } from "../src/life/ratings.ts";

const living = (w: World) => Object.keys(w.players).length + Object.keys(w.npcs).length;

function familyProblems(world: World): string[] {
  const out: string[] = [];
  const all = [...Object.values(world.players), ...Object.values(world.npcs), ...Object.values(world.archive)];
  for (const p of all) {
    for (const c of p.family.children) {
      const k = personById(world, c);
      if (!k) out.push(`${p.id}: child ${c} missing`);
      else if (!k.family.parents.includes(p.id)) out.push(`${p.id} → child ${c} not linked back`);
    }
    for (const par of p.family.parents) {
      const q = personById(world, par);
      if (!q) out.push(`${p.id}: parent ${par} missing`);
      else if (!q.family.children.includes(p.id)) out.push(`${p.id} → parent ${par} not linked back`);
    }
    const sp = p.family.spouse;
    if (sp && !world.archive[p.id]) {
      const q = personById(world, sp);
      if (!q) out.push(`${p.id}: spouse ${sp} missing`);
      else if (!world.archive[sp] && q.family.spouse !== p.id) out.push(`${p.id} ↔ spouse ${sp} not symmetric`);
      if (world.archive[sp]?.dead) out.push(`${p.id} still married to the late ${sp}`);
    }
  }
  return out;
}

test("worldgen: a world with history — sexes, faces, families, houses, retired stars", () => {
  const w = generateWorld("gen");
  const players = Object.values(w.players);
  assert.ok(players.every(p => p.sex === "M"), "players are men");
  const npcs = Object.values(w.npcs);
  assert.ok(npcs.some(n => n.sex === "F") && npcs.some(n => n.sex === "M"));
  const faceIds = new Set(FACES.map(f => f.id));
  for (const p of [...players, ...npcs]) assert.ok(faceIds.has(p.face), `face ${p.face} from the catalogue`);
  // sons/nephews of retired stars in the league
  const kin = players.filter(p => p.family.parents.some(id => wasPlayer(w, personById(w, id))) ||
    p.family.parents.some(id => (personById(w, id)?.family.parents ?? []).some(g => (personById(w, g)?.family.children ?? []).some(s => wasPlayer(w, personById(w, s)) && s !== id))));
  assert.ok(kin.length >= 10, `second-generation players at start (${kin.length})`);
  const stars = npcs.filter(n => n.career && n.career.peak >= 60);
  assert.ok(stars.length >= 20, "retired stars exist as NPCs");
  assert.ok(stars.some(s => s.role === "manager"), "some stars manage now");
  assert.ok(players.filter(p => p.family.spouse).length > 100, "players are married");
  assert.ok(npcs.filter(n => n.age < 18).length > 150, "young children not in baseball yet");
  const houses = Object.values(w.houses).filter(h => h.reputation >= 20);
  assert.ok(houses.length >= 15, "reputable houses");
  assert.deepEqual(familyProblems(w), []);
  assert.deepEqual(rosterProblems(w), []);
  for (const p of players) assert.equal(p.born, w.year - p.age);
});

test("drama moves mood, and mood moves results", () => {
  const w = generateWorld("mood");
  const team = w.teams.HCL;
  const pid = team.roster.find(id => w.players[id].pos === "P")!;
  w.players[pid].mood = -4;
  const mods = moodModifiers(w, ["HCL"]);
  const stuff = mods.find(m => m.target.id === pid && m.effect === "stuff");
  assert.ok(stuff && stuff.value < 0, "unhappy pitcher loses stuff");
  // a whole club in a funk vs. on cloud nine
  let runsSad = 0, runsHappy = 0;
  const ump = Object.values(w.npcs).find(n => n.role === "umpire")!;
  for (const [mood, add] of [[-5, (n: number) => (runsSad += n)], [5, (n: number) => (runsHappy += n)]] as const) {
    const world = generateWorld("mood");
    for (const id of [...world.teams.HCL.roster]) world.players[id].mood = mood;
    for (let i = 0; i < 120; i++) {
      const res = simulateGame(world, {
        id: `m${i}`, day: 1, homeId: "HCL", awayId: "STA", umpireId: ump.id, weather: { tempF: 72, windDir: 0, windMph: 5, rain: 0 },
        modifiers: moodModifiers(world, ["HCL", "STA"]),
      }, `mood-${i}`);
      add(res.home.runs - res.away.runs);
    }
  }
  assert.ok(runsHappy > runsSad + 60, `happy club outscores sad club (${runsSad} → ${runsHappy} run differential)`);
});

// --- the big one: thirty seasons ------------------------------------------------------------------------

interface Snap { season: number; living: number; ages: Map<string, number> }
/** LIFE_SEASONS=10 for a quicker local run; the default exercises three decades. */
const SEASONS = Math.max(3, Number(process.env.LIFE_SEASONS ?? 30));
const world = generateWorld("dynasty");
const rng = new Rng("dynasty");
const state = newSeason(world, rng);
const events: LifeEvent[] = [];
const snaps: Snap[] = [];
const lineupProblems: string[] = [];
const rosterIssues: string[] = [];
const familyIssues: string[] = [];
const startLiving = living(world);
const t0 = Date.now();
while (world.season <= SEASONS) {
  const season = world.season;
  const o = playDay(world, state, rng);
  events.push(...o.events);
  // spot checks a few times a season
  if (o.phase === "regular" && o.day % 50 === 0) {
    rosterIssues.push(...rosterProblems(world).map(x => `s${season}d${o.day}: ${x}`));
    for (const g of slateFor(state, state.day)) {
      for (const tid of [g.homeId, g.awayId]) {
        const team = world.teams[tid];
        const lu = buildLineup(world, team), st = buildStaff(world, team);
        if (lu.order.length < 9) lineupProblems.push(`${tid} only ${lu.order.length} in lineup`);
        for (const p of [...lu.order.map(x => x.player), ...st.rotation]) {
          if (!world.players[p.id]) lineupProblems.push(`${p.id} in ${tid} lineup but not a living player`);
          if (p.teamId !== tid) lineupProblems.push(`${p.id} in ${tid} lineup but on ${p.teamId}`);
          if (p.dead || world.archive[p.id]) lineupProblems.push(`${p.id} is dead/retired but in lineup`);
        }
      }
    }
  }
  if (world.season !== season) {
    snaps.push({ season, living: living(world), ages: new Map([...Object.values(world.players), ...Object.values(world.npcs)].map(p => [p.id, p.age])) });
    rosterIssues.push(...rosterProblems(world).map(x => `after s${season}: ${x}`));
    if (season % 10 === 0) familyIssues.push(...familyProblems(world));
  }
}
const elapsed = (Date.now() - t0) / 1000;

test(`${SEASONS} seasons: rosters stay 26 (13 P / 13 position) with the right shape`, () => {
  assert.deepEqual(rosterIssues, []);
  for (const t of Object.values(world.teams)) {
    const groups: Record<string, number> = {};
    for (const id of t.roster) groups[groupOf(world.players[id])] = (groups[groupOf(world.players[id])] ?? 0) + 1;
    assert.deepEqual(groups, TEMPLATE, `${t.id} roster template`);
  }
  for (const p of Object.values(world.players)) {
    if (p.teamId === FREE_AGENT) assert.ok(world.freeAgents.includes(p.id));
    else assert.ok(world.teams[p.teamId].roster.includes(p.id) || world.teams[p.teamId].il?.includes(p.id), `${p.id} is on his team`);
  }
});

test("no dead or retired players in lineups", () => {
  assert.deepEqual(lineupProblems, []);
});

test("family links stay symmetric", () => {
  assert.deepEqual(familyIssues, []);
  assert.deepEqual(familyProblems(world), []);
});

test("ages increase by one each season", () => {
  for (let i = 1; i < snaps.length; i++) {
    for (const [id, age] of snaps[i].ages) {
      if ((world.players[id] ?? world.npcs[id] ?? world.archive[id])?.quirks?.includes("RESURRECTED")) continue; // came back at a different age
      const before = snaps[i - 1].ages.get(id);
      if (before !== undefined) assert.equal(age, before + 1, `${id} aged one year`);
    }
  }
  assert.equal(world.year, 1996 + SEASONS);
});

test("population stays stable over decades", () => {
  const counts = snaps.map(s => s.living);
  const last = counts[counts.length - 1];
  assert.ok(last < startLiving * 1.6 && last > startLiving * 0.7, `living ${startLiving} → ${last}`);
  if (counts.length >= 30) {
    const s20 = counts[19];
    assert.ok(last < s20 * 1.15, `last decade grows < 15% (${s20} → ${last})`);
  }
  const players = Object.keys(world.players).length;
  assert.ok(players >= 832 + 156 && players < 1150, `players ${players} (Continental 832 + Enhanced 156 + free agents)`);
});

test("every season crowns a champion", () => {
  assert.equal(world.history.length, SEASONS);
  for (const h of world.history) assert.ok(h.champion, `${h.year} champion`);
});

test("dynasties: league kids grow up, get drafted and debut", () => {
  const secondGen = events.filter(e => e.kind === "debut" && e.data?.secondGen && world.players[e.who[0]]?.draft || (e.kind === "debut" && e.data?.secondGen && personById(world, e.who[0])?.career));
  const drafted = events.filter(e => e.kind === "draft" && e.data?.secondGen);
  assert.ok(drafted.length >= 1, `second-generation draftees (${drafted.length})`);
  if (SEASONS >= 30) assert.ok(secondGen.length >= 1, `second-generation debuts (${secondGen.length})`);
  for (const k of ["birth", "death", "wedding", "divorce", "retirement", "trade", "drama", "coming_of_age", "world"]) {
    assert.ok(events.some(e => e.kind === k), `some ${k}`);
  }
  if (SEASONS >= 4) assert.ok(events.some(e => e.kind === "world" && e.data?.sub === "y2k" && e.data?.year === 1999), "Y2K panic in 1999");
});

test("drama over decades: weird events stay rare, storylines stay bounded and settle", () => {
  const weird = events.filter(e => e.kind === "weird").length / SEASONS;
  assert.ok(weird >= 0.5 && weird <= 12, `weird events per season ${weird.toFixed(1)}`);
  assert.ok(world.storylines.length < 800, `storylines kept bounded (${world.storylines.length})`);
  const open = world.storylines.filter(s => !s.resolved).length;
  assert.ok(open < 80, `open storylines ${open}`);
  const fired = events.filter(e => e.kind === "fire" && e.data?.midseason).length / SEASONS;
  assert.ok(fired >= 0.5, `mid-season firings per season ${fired.toFixed(1)}`);
});

test("world multipliers are sane", () => {
  const m = worldMultipliers(world);
  for (const k of ["cardDemand", "attendance", "economy"] as const) assert.ok(m[k] > 0.4 && m[k] < 2.5, `${k} ${m[k]}`);
});

test("history book is readable", () => {
  const book = historyBook(world);
  assert.ok(book.length > SEASONS * 4);
  assert.ok(book.some(l => l.startsWith("DYNASTIES")));
  assert.ok(book.every(l => !l.includes("undefined") && !l.includes("NaN")), "no undefined/NaN");
  assert.ok(elapsed < 400, `ran in ${elapsed}s`);
});

test("deterministic: same seed, same season", () => {
  const run = () => {
    const w = generateWorld("det");
    const r = new Rng("det");
    const s = newSeason(w, r);
    const ev: string[] = [];
    while (w.season === 1) ev.push(...playDay(w, s, r).events.map(e => `${e.kind}:${e.who.join(",")}`));
    return { h: JSON.stringify(w.history), ev: ev.join("|"), n: Object.keys(w.npcs).length };
  };
  const a = run(), b = run();
  assert.equal(a.h, b.h);
  assert.equal(a.ev, b.ev);
  assert.equal(a.n, b.n);
});
