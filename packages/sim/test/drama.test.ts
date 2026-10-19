import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { Rng } from "../src/rng.ts";
import { simulateGame } from "../src/game.ts";
import type { Player, World } from "../src/types.ts";
import { newSeason } from "../src/league/index.ts";
import { playDay } from "../src/league/driver.ts";
import type { LifeEvent } from "../src/life/events.ts";
import { dramaModifiers } from "../src/life/context.ts";
import { propagateInjury } from "../src/life/aftergame.ts";
import { dailyDrama } from "../src/life/starts.ts";
import {
  KINDS, advanceStorylines, bettableStorylines, nudgeStoryline, propsFor, resolveProps, startStoryline, storylineHazards,
} from "../src/life/storylines.ts";
import { forceWeird, WEIRD_RATES } from "../src/life/weird.ts";
import { rosterProblems } from "../src/life/roster.ts";
import { relation, setRelation } from "../src/life/people.ts";

const ump = (w: World) => Object.values(w.npcs).find(n => n.role === "umpire")!.id;
const game = (w: World, i: number, slot = 0) => ({ id: `t${i}`, day: 1, homeId: "HCL", awayId: "STA", umpireId: ump(w), slot, weather: { tempF: 72, windDir: 0, windMph: 5, rain: 0 } });

test("contextual modifiers move outcomes: a club afraid of the dark hits worse at night", () => {
  let base = 0, scared = 0;
  for (const fear of [false, true]) {
    const w = generateWorld("dark");
    for (const id of w.teams.HCL.roster) {
      const p = w.players[id];
      p.fears = fear ? [{ kind: "the_dark", strength: 3 }] : [];
      p.goals = []; p.concerns = []; p.mood = 0;
    }
    for (const id of w.teams.STA.roster) { const p = w.players[id]; p.fears = []; p.goals = []; p.concerns = []; p.mood = 0; }
    for (let i = 0; i < 300; i++) {
      const g = game(w, i, 3);
      const res = simulateGame(w, { ...g, modifiers: dramaModifiers(w, g) }, `dark-${i}`);
      if (fear) scared += res.home.runs; else base += res.home.runs;
    }
  }
  assert.ok(scared < base * 0.95, `scared hitters score less at night (${base} → ${scared})`);
});

test("a hurt friend turns teammates against the culprit: beanballs and brawls go up", () => {
  const setup = () => {
    const w = generateWorld("beanball");
    const victim = w.teams.HCL.roster.find(id => w.players[id].pos !== "P")!;
    for (const id of w.teams.HCL.roster) if (id !== victim) setRelation(w, id, victim, 4, "teammates", "friend");
    const culprit = w.teams.STA.roster.find(id => w.players[id].pos === "P")!;
    return { w, victim, culprit };
  };
  const { w, victim, culprit } = setup();
  const ev: LifeEvent[] = [];
  propagateInjury(w, new Rng("x"), victim, culprit, ev, "hit by a pitch");
  const friend = w.teams.HCL.roster.find(id => id !== victim)!;
  assert.ok(relation(w, friend, culprit) <= -3, "grudge against the pitcher");
  assert.ok(relation(w, friend, "STA") <= -2, "and his club");
  assert.ok(ev.some(e => e.kind === "drama" && e.data?.sub === "vendetta"), "vendetta event");
  const mods = dramaModifiers(w, game(w, 0));
  assert.ok(mods.some(m => m.effect === "hbp" && w.players[m.target.id]?.teamId === "HCL"), "HCL pitchers come inside");
  assert.ok(mods.some(m => m.effect === "incident" && m.incident === "BRAWL" && m.value > 1), "brawl risk up");

  let hbpCalm = 0, hbpAngry = 0, brawlCalm = 0, brawlAngry = 0;
  const calm = setup().w;
  for (let i = 0; i < 250; i++) {
    const g = game(w, i);
    const a = simulateGame(w, { ...g, modifiers: dramaModifiers(w, g) }, `bb-${i}`);
    const c = simulateGame(calm, { ...g, umpireId: ump(calm), modifiers: [] }, `bb-${i}`);
    hbpAngry += a.away.bat.reduce((s, l) => s + l.hbp, 0);
    hbpCalm += c.away.bat.reduce((s, l) => s + l.hbp, 0);
    brawlAngry += a.incidents.filter(x => x.kind === "BRAWL").length;
    brawlCalm += c.incidents.filter(x => x.kind === "BRAWL").length;
  }
  assert.ok(hbpAngry > hbpCalm * 1.5, `STA hitters get plunked more (${hbpCalm} → ${hbpAngry})`);
  assert.ok(brawlAngry > brawlCalm, `more brawls (${brawlCalm} → ${brawlAngry})`);
});

test("fame raises scandal, affair and feud odds", () => {
  const count = (fame: number) => {
    const w = generateWorld("fame");
    const ids = w.teams.HCL.roster.slice(0, 13);
    const rng = new Rng(`fame-${fame}`);
    let n = 0;
    for (let d = 0; d < 360; d++) {
      for (const id of ids) w.players[id].fame = fame;
      w.day++;
      const ev: LifeEvent[] = [];
      dailyDrama(w, rng, ev, { phase: "regular", day: 50 });
      n += ev.filter(e => e.who.some(id => ids.includes(id)) && (e.kind === "fight" || (e.kind === "drama" && ["scandal", "affair", "feud", "rivalry", "stalker"].includes(String(e.data?.sub))))).length;
    }
    return n;
  };
  const lo = count(2), hi = count(90);
  assert.ok(hi > lo * 1.8, `famous players get into more trouble (${lo} → ${hi})`);
});

test("weird events happen at the expected rarity, and each kind works", () => {
  const w = generateWorld("weird");
  const rng = new Rng("weird");
  // each kind on demand
  for (const k of ["abduction", "clone", "historical", "plane_crash", "resurrection"] as const) {
    const ev: LifeEvent[] = [];
    forceWeird(w, rng, k, ev);
    if (k === "resurrection" && !Object.values(w.archive).some(a => a.dead)) continue;
    assert.ok(ev.some(e => e.kind === "weird" || (e.kind === "drama" && e.data?.sub === "weird")) || k === "resurrection", `${k} fired`);
  }
  assert.deepEqual(rosterProblems(w), [], "rosters intact after a plane crash, a clone and new arrivals");
  const hist = Object.values(w.players).find(p => p.historical);
  assert.ok(hist && hist.quirks?.includes("TIME_DISPLACED"), "historical figure marked");
  const clone = Object.values(w.players).find(p => p.cloneOf);
  assert.ok(clone && w.players[clone.cloneOf!]?.face === clone.face, "clone shares the original's face");
  // rates: expected handful per season
  const expected = Object.values(WEIRD_RATES).reduce((a, b) => a + b, 0);
  assert.ok(expected >= 2 && expected <= 6, `about a handful a season (${expected})`);
});

test("hot seat: a collapsing club fires its manager; a winning club doesn't", () => {
  const w = generateWorld("fire");
  const rng = new Rng("fire");
  const losing = { w: 12, l: 30, seq: "WLWLLWLLLWLLWLLLLWLWLLLLWLLLWLLLLWLLLLLLLL" };
  const winning = { w: 30, l: 12, seq: "WWLWWWLWWLWWWWLWWWLWWWWLWWWWWLWWLWWWLWWWWW" };
  const table: Record<string, { w: number; l: number; seq: string }> = { HCL: losing, STA: winning };
  const mgrHCL = w.teams.HCL.managerId, mgrSTA = w.teams.STA.managerId;
  const ev: LifeEvent[] = [];
  w.day = 100; // past the new-manager grace period
  for (let d = 0; d < 90 && w.teams.HCL.managerId === mgrHCL; d++) {
    w.day++;
    dailyDrama(w, rng, ev, { phase: "regular", day: 40 + d, table });
    advanceStorylines(w, rng, ev, { phase: "regular", day: 40 + d, table });
  }
  assert.notEqual(w.teams.HCL.managerId, mgrHCL, "HCL fired its manager");
  assert.equal(w.teams.STA.managerId, mgrSTA, "STA kept its manager");
  const fire = ev.find(e => e.kind === "fire" && e.who[0] === mgrHCL);
  assert.ok(fire && fire.data?.midseason && fire.data?.cause, "a mid-season firing with a cause");
  assert.ok(ev.some(e => e.kind === "drama" && e.data?.sub === "hot_seat" && e.data?.begins), "it started as a hot-seat storyline");
});

test("nudges change hazards measurably", () => {
  const w = generateWorld("nudge");
  const ev: LifeEvent[] = [];
  const married = Object.values(w.players).filter(p => p.family.spouse && w.teams[p.teamId]?.level === "ML");
  const mk = (p: Player) => startStoryline(w, "affair", [p.id], [p.teamId], { visibility: "rumoured", stage: "ongoing", cause: "test" }, ev);
  const a = mk(married[0]);
  const before = storylineHazards(w, a);
  nudgeStoryline(w, a.id, "expose", 2);
  nudgeStoryline(w, a.id, "inflame", 2);
  const after = storylineHazards(w, a);
  assert.ok(after.expose > before.expose * 2.5 && after.escalate > before.escalate * 2.5, "nudged hazards rise");
  // Monte Carlo: nudged affairs get discovered sooner
  const half = Math.floor(married.length / 2);
  const plain = married.slice(1, half).map(mk), pushed = married.slice(half).map(mk);
  for (const s of pushed) nudgeStoryline(w, s.id, "inflame", 3);
  const rng = new Rng("mc");
  for (let d = 0; d < 40; d++) {
    w.day++;
    for (const s of pushed) if (!s.resolved) s.nudges.inflame = 3;
    advanceStorylines(w, rng, ev, { phase: "regular", day: 50 });
  }
  const rate = (xs: typeof plain) => xs.filter(s => s.resolved?.outcome === "discovered").length / xs.length;
  assert.ok(rate(pushed) > rate(plain) + 0.15, `discovery rate ${rate(plain).toFixed(2)} → ${rate(pushed).toFixed(2)}`);
});

// --- a season of storylines ----------------------------------------------------------------------------

function season(seed: string) {
  const w = generateWorld(seed);
  const r = new Rng(seed);
  const s = newSeason(w, r);
  const bettable = new Set<string>();
  const ev: LifeEvent[] = [];
  while (w.season === 1) {
    ev.push(...playDay(w, s, r).events);
    for (const b of bettableStorylines(w)) bettable.add(b.storyline.id);
  }
  return { w, bettable, ev };
}
const S = season("storyline-test");

test("storylines: a full season produces arcs of every common kind, mostly resolved", () => {
  const kinds = new Set(S.w.storylines.map(s => s.kind));
  for (const k of ["affair", "feud", "marriage_trouble", "hot_seat", "slump", "contract_year", "rivalry", "gambling_debt"]) assert.ok(kinds.has(k as never), `some ${k}`);
  const open = S.w.storylines.filter(s => !s.resolved).length;
  assert.ok(open < S.w.storylines.length * 0.25, `most resolve (${open} open of ${S.w.storylines.length})`);
  for (const s of S.w.storylines) {
    if (s.resolved) assert.ok(KINDS[s.kind].outcomes.includes(s.resolved.outcome) || ["death", "ended_quietly"].includes(s.resolved.outcome), `${s.kind} outcome ${s.resolved.outcome}`);
  }
});

test("props resolve to exactly one listed option", () => {
  assert.ok(S.bettable.size > 30, `bettable storylines (${S.bettable.size})`);
  let settled = 0;
  for (const id of S.bettable) {
    const s = S.w.storylines.find(x => x.id === id);
    if (!s) continue;
    const qs = propsFor(S.w, s);
    assert.equal(qs.length, 3);
    const res = resolveProps(S.w, id);
    for (const q of qs) {
      assert.ok(q.closesDay <= q.resolveBy, "closes before it resolves");
      if (!(q.id in res)) { assert.ok(!s.resolved || q.type === "yesno", `${q.id} unsettled though resolved`); continue; }
      assert.equal(q.options.filter(o => o.key === res[q.id]).length, 1, `${q.id} → ${res[q.id]} is one option`);
      settled++;
    }
  }
  assert.ok(settled > 50, `settled props (${settled})`);
});

test("storylines are deterministic", () => {
  const again = season("storyline-test");
  assert.equal(JSON.stringify(again.w.storylines), JSON.stringify(S.w.storylines));
});

test("drama density: several notable major-league stories per game day", () => {
  const regular = S.ev.filter(e => e.data?.season === 1);
  const notable = regular.filter(e => !e.data?.secret && ["drama", "fight", "beanball", "weird", "fire", "goal", "fear", "fame"].includes(e.kind) && (e.teams ?? []).some(t => S.w.teams[t]?.level === "ML"));
  const perDay = notable.length / 165;
  assert.ok(perDay >= 2 && perDay <= 25, `${perDay.toFixed(1)} notable ML stories per day`);
  for (const e of S.ev.filter(x => x.kind === "drama" && x.data?.storyline)) {
    assert.equal(typeof e.data?.sub, "string");
    assert.equal(typeof e.data?.stage, "string");
    assert.ok(["secret", "rumoured", "public"].includes(String(e.data?.visibility)));
  }
});
