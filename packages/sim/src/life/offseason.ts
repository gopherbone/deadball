// The winter: everyone ages, players develop or decline, veterans retire into new lives,
// managers get fired, league kids come of age and are drafted alongside random amateurs,
// organisations reshuffle, and people with no tie to the league drift out of the story.

import type { Rng } from "../rng.ts";
import type { Npc, Player, Umpire, World } from "../types.ts";
import { FREE_AGENT } from "../types.ts";
import { START_YEAR_DEFAULT } from "./constants.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { addDrama, archivePerson, baseballKin, bumpHouse, ensureHouse, living, personById, removeFromTeams, resetFaceCache } from "./people.ts";
import { GROUPS, TEMPLATE, devDelta, develop, groupOf, renormalise, value, type Group } from "./ratings.ts";
import { LEVEL_MEAN, balanceOrg, healthy, mintAmateur, mlTeamIds, movePlayer, orgTeams, perf } from "./roster.ts";
import { KID_AGE, afterlife, fadeSweep, hireManager, isNotable, newUmpire, replaceRole } from "./family.ts";
import { careerTotals } from "../league/stats.ts";
import { tryTrade } from "./trades.ts";
import { findOpen, hireGM, openStorylines, resolveStoryline, setRetireHook, startStoryline } from "./storylines.ts";
import { achieveGoal, addConcern, fameOf, gainFame, goalOf, pickGoal } from "./inner.ts";
import { hasT } from "./people.ts";

export function runOffseason(world: World, rng: Rng): LifeEvent[] {
  const events: LifeEvent[] = [];
  const r = rng.fork(`offseason-${world.season}`);
  const lastHist = world.history[world.history.length - 1];

  // 0. the season's verdicts: awards and titles make people famous; season-long arcs settle
  seasonVerdicts(world, r, events);

  // 1. everyone gets a year older
  for (const p of Object.values(world.players)) p.age++;
  for (const p of Object.values(world.npcs)) p.age++;

  // 2. development, then re-centre the league on its original norms
  for (const p of Object.values(world.players)) develop(p, devDelta(p, r), r);
  renormalise(world);

  // 3. retirements
  for (const p of Object.values(world.players).sort((a, b) => (a.id < b.id ? -1 : 1))) {
    const why = retireReason(world, p, r);
    if (why) retirePlayer(world, r, p, events, why);
  }

  // 4. contracts
  for (const p of Object.values(world.players).sort((a, b) => (a.id < b.id ? -1 : 1))) {
    if (p.teamId === FREE_AGENT || !p.contract) continue;
    p.contract.years--;
    if (p.contract.years > 0) continue;
    const team = world.teams[p.teamId];
    const lv = team?.level ?? "D";
    const cy = findOpen(world, "contract_year", p.id);
    if (lv === "ML" && p.age >= 32 && value(p) < LEVEL_MEAN.ML - 5 && r.chance(0.6)) {
      movePlayer(world, p, FREE_AGENT);
      events.push(mkEvent(world, "release", [p.id], [team.id], { from: team.id, reason: "contract not renewed" }));
      if (cy) resolveStoryline(world, cy, "walked", events, {});
      continue;
    }
    const years = p.age <= 27 ? 2 + r.int(4) : p.age <= 31 ? 1 + r.int(4) : 1 + r.int(2);
    const salary = Math.round((lv === "ML" ? 120 : lv === "AA" ? 25 : 10) * Math.pow(1.09, Math.max(0, value(p) - 40)));
    const before = p.contract.salary;
    if (p.traits.includes("GREEDY") && lv === "ML" && r.chance(0.45)) {
      addDrama(p, { kind: "holdout", since: world.day, weight: -2, days: 45, note: `wants $${Math.round(salary * 1.8)}k` });
      addConcern(world, p, { kind: "holdout", until: world.day + 90, weight: -1.5, note: `wants $${Math.round(salary * 1.8)}k` });
      p.injury = { kind: "holdout", daysLeft: 999 };
      startStoryline(world, "holdout", [p.id], [team.id], { visibility: "public", stage: "holding_out", cause: `wants $${Math.round(salary * 1.8)}k a year`, stakes: "his season", data: { asking: Math.round(salary * 1.8), offered: salary } }, events);
      p.contract = { years, salary: Math.round(salary * 1.4) };
    } else p.contract = { years, salary };
    if (cy) resolveStoryline(world, cy, p.contract.salary >= before * 1.5 || p.contract.salary >= 1000 ? "big_payday" : "re-signed", events, { salary: p.contract.salary, years });
    if (p.contract.salary >= 800 && goalOf(p, "big_contract")) achieveGoal(world, r, p, "big_contract", events, `$${p.contract.salary}k a year`);
  }

  // 5. free agents who never got a call give up
  for (const id of [...world.freeAgents]) {
    const p = world.players[id];
    if (!p) { world.freeAgents = world.freeAgents.filter(x => x !== id); continue; }
    if (p.age >= 34 || value(p) < 34 || r.chance(0.35)) retirePlayer(world, r, p, events, "no offers");
  }

  // 6. staff: managers, umpires, owners
  staffChanges(world, r, events, lastHist?.standings ?? []);

  // 7. league kids come of age; the draft
  const pool = comingOfAge(world, r, events);
  // 8. organisations reshuffle by merit (the majors get the best 26)
  for (const mlId of mlTeamIds(world)) reorganise(world, r, mlId, events);
  draft(world, r, events, pool, lastHist?.standings ?? []);

  // 9. free-agent market and a few winter trades
  freeAgentMarket(world, r, events);
  for (let i = 0; i < 3; i++) if (r.chance(0.5)) tryTrade(world, r, events, {}, true);
  for (const mlId of mlTeamIds(world)) balanceOrg(world, mlId, r, events, { reason: "winter" });
  for (const t of Object.values(world.teams)) if (t.level === "EL") balanceOrg(world, t.id, r, events, { reason: "winter" });

  // 10. houses, relationships, and the people who move away
  houseReputation(world);
  decayRelationships(world);
  fadeSweep(world);
  pruneHouses(world);
  resetFaceCache(world);
  return events;
}

// --- retirements -----------------------------------------------------------------------------------

function retireReason(world: World, p: Player, rng: Rng): string | undefined {
  const lv = world.teams[p.teamId]?.level;
  const v = value(p);
  if (p.age >= 42) return "age";
  if (p.injury && p.injury.daysLeft > 120 && p.age >= 30 && rng.chance(0.5)) return "injuries";
  if (p.age >= 33) {
    const below = lv ? Math.max(0, LEVEL_MEAN[lv] - v) : 10;
    if (rng.chance(0.06 * (p.age - 32) + below * 0.03 + (lv && lv !== "ML" ? 0.25 : 0))) return lv === "ML" ? "age" : "washed up";
  }
  // career minor-leaguers give up
  if (lv && lv !== "ML" && p.age >= 26 && p.potential < LEVEL_MEAN.ML - 6 && rng.chance(lv === "D" ? 0.35 : lv === "B" ? 0.2 : 0.08)) return "quit baseball";
  return undefined;
}

// Mid-season retirements (lifetime bans, men cut loose in the desert) must refill the hole at once;
// the offseason path rebalances every organisation in bulk afterwards.
setRetireHook((w, rng, p, ev, reason) => {
  const t = w.teams[p.teamId];
  const org = t ? t.parentId ?? t.id : undefined;
  retirePlayer(w, rng, p, ev, reason);
  if (org) balanceOrg(w, org, rng, ev, { reason: "retirement" });
});

export function retirePlayer(world: World, rng: Rng, p: Player, events: LifeEvent[], reason: string) {
  const ml = careerTotals(world, p.id, "ML");
  const preSeasons = p.debut && p.debut.season === 0 ? Math.max(0, START_YEAR_DEFAULT - p.debut.year) : 0;
  const mlGames = Math.max(ml.bat.g, ml.pitch.g) + preSeasons * (p.pos === "P" ? 30 : 110);
  const mlTeams = [...new Set(Object.values(world.stats[p.id] ?? {}).filter(s => s.level === "ML").map(s => s.teamId))];
  const honors: string[] = [];
  let titles = 0;
  for (const h of world.history) {
    if (h.awards.mvp === p.id) honors.push(`${h.year} MVP`);
    if (h.awards.pitcher === p.id) honors.push(`${h.year} Pitcher of the Year`);
    if (h.awards.rookie === p.id) honors.push(`${h.year} Rookie of the Year`);
    const s = world.stats[p.id]?.[h.season];
    if (h.champion && s && s.teamId === h.champion) titles++;
  }
  if (titles) honors.push(`${titles}x champion`);
  if (ml.bat.hr >= 300) honors.push(`${ml.bat.hr} career home runs`);
  if (ml.pitch.w >= 150) honors.push(`${ml.pitch.w} career wins`);
  const career = {
    pos: p.pos, from: p.draft?.year ?? p.born! + 18, to: world.year, mlGames, mlSeasons: ml.seasons + preSeasons,
    teams: mlTeams.length ? mlTeams : p.debut ? [p.debut.teamId] : [], peak: Math.max(p.peak ?? 0, Math.round(value(p))), honors,
  };
  const teamId = p.teamId;
  const fid = world.teams[teamId]?.factionId;
  removeFromTeams(world, p);
  delete world.players[p.id];
  const next = afterlife(world, rng, p, career.peak, fid);
  const npc: Npc = {
    fame: p.fame, goals: p.goals, fears: p.fears, concerns: p.concerns, quirks: p.quirks, historical: p.historical, cloneOf: p.cloneOf,
    id: p.id, kind: "npc", role: next.role, factionId: next.role === "coach" || next.role === "scout" ? fid ?? undefined : undefined,
    first: p.first, last: p.last, nickname: p.nickname, face: p.face, sex: p.sex, age: p.age, born: p.born, traits: p.traits,
    mood: 0, family: p.family, active: next.role !== "citizen", stats: {}, talent: p.talent, career,
  };
  if (!npc.nickname) delete npc.nickname;
  if (next.occupation) npc.occupation = next.occupation;
  world.npcs[p.id] = npc;
  bumpHouse(world, p.family.house, Math.max(0, career.peak - 55) / 2 + honors.length);
  events.push(mkEvent(world, "retirement", [p.id], teamId !== FREE_AGENT ? [teamId] : [], {
    reason, age: p.age, career, becomes: next.occupation ?? next.role, fame: Math.round(fameOf(p)),
    tearful: hasT(p, "LOYAL") || fameOf(p) >= 45 || career.honors.length > 0,
  }));
  // nobodies (and their spouses) leave the story unless they have kids coming up
  if (!isNotable(world, npc) && !npc.family.children.some(id => { const c = living(world, id); return c && (c.age < KID_AGE || c.kind === "player"); })) {
    const sp = living(world, npc.family.spouse);
    archivePerson(world, npc.id, "moved");
    // minor-league-only careers aren't worth their box-score lines once he's gone
    if (ml.seasons === 0) delete world.stats[npc.id];
    if (sp && sp.kind === "npc" && !isNotable(world, sp)) archivePerson(world, sp.id, "moved");
  }
}

// --- staff --------------------------------------------------------------------------------------------

function staffChanges(world: World, rng: Rng, events: LifeEvent[], table: [string, number, number][]) {
  const bottom = table.slice(-2).map(x => x[0]);
  for (const team of Object.values(world.teams).sort((a, b) => (a.id < b.id ? -1 : 1))) {
    const m = world.npcs[team.managerId];
    if (!m) { hireManager(world, rng, team.id, events, "nobody"); continue; }
    let why: string | undefined;
    const seat = findOpen(world, "hot_seat", m.id);
    if (seat) {
      if (rng.chance(0.6)) { resolveStoryline(world, seat, "fired", events, { cause: "the winter purge" }); why = "fired"; }
      else resolveStoryline(world, seat, "survived", events, { how: "the owner blinked" });
    }
    if (why) { /* decided above */ }
    else if (m.age >= 70 || (m.age >= 64 && rng.chance(0.25))) why = "retires";
    else if (team.level === "ML" && bottom.includes(team.id) && rng.chance(0.5)) why = "fired";
    else if (team.level === "ML" && rng.chance(0.06)) why = "fired";
    else if (team.level !== "ML" && rng.chance(0.08)) why = "fired";
    if (!why) continue;
    m.role = why === "fired" && m.age < 60 && rng.chance(0.5) ? "scout" : "citizen";
    if (why === "retires") m.stats.retiredManager = 1;
    if (m.role === "citizen") { m.active = false; m.occupation = m.traits.includes("DRUNK") ? "town drunk" : "retired"; }
    events.push(mkEvent(world, why === "fired" ? "fire" : "retirement", [m.id], [team.id], { role: "manager", reason: why }));
    hireManager(world, rng, team.id, events, `${m.first} ${m.last}`);
  }
  // old coaches and scouts hang it up
  for (const n of Object.values(world.npcs)) {
    if ((n.role === "coach" || n.role === "scout") && (n.age >= 72 || (n.age >= 62 && rng.chance(0.2)))) {
      n.occupation = `retired ${n.role}`;
      n.role = "citizen";
      n.active = false;
    }
  }
  // owners sack the general managers of bad clubs
  for (const team of Object.values(world.teams)) {
    if (team.level !== "ML") continue;
    if (!team.gmId || !world.npcs[team.gmId]) { hireGM(world, rng, team.id, events); continue; }
    const owner = world.npcs[world.factions[team.factionId]?.leaderId ?? ""];
    const p = (bottom.includes(team.id) ? 0.3 : 0.04) * (hasT(owner, "HOTHEAD") ? 1.8 : 1) * (hasT(owner, "GREEDY") ? 1.3 : 1);
    if (rng.chance(p)) {
      const gm = world.npcs[team.gmId];
      gm.role = "citizen"; gm.active = false; gm.occupation = "former general manager";
      events.push(mkEvent(world, "fire", [gm.id, ...(owner ? [owner.id] : [])], [team.id], { role: "gm", cause: bottom.includes(team.id) ? "a last-place finish" : "the owner's whim", dramatic: true }));
      hireGM(world, rng, team.id, events);
    }
  }
  // umpires
  for (const u of Object.values(world.npcs).filter(n => n.role === "umpire") as Umpire[]) {
    if (u.age >= 66 || (u.age >= 60 && rng.chance(0.3))) {
      (u as Npc).role = "citizen";
      u.active = false;
      u.occupation = "retired umpire";
      events.push(mkEvent(world, "retirement", [u.id], [], { role: "umpire" }));
      replaceRole(world, rng, { ...u, role: "umpire" } as Npc, events);
    }
  }
  // keep 12 major-league umps
  const umps = Object.values(world.npcs).filter(n => n.role === "umpire") as Umpire[];
  let mlCount = umps.filter(u => u.stats.ml === 1).length;
  for (const u of umps.filter(x => x.stats.ml !== 1).sort((a, b) => b.stats.consistency - a.stats.consistency)) {
    if (mlCount >= 12) break;
    u.stats.ml = 1;
    mlCount++;
  }
  while (umps.length < 32) { umps.push(newUmpire(world, rng) as Umpire); }
  // old owners hand over the keys
  for (const f of Object.values(world.factions)) {
    const o = world.npcs[f.leaderId ?? ""];
    if (o && o.age >= 74 && rng.chance(0.3)) {
      o.active = false;
      const old = { ...o };
      o.role = "citizen";
      o.occupation = "chairman emeritus";
      replaceRole(world, rng, old, events);
    }
  }
}

// --- coming of age and the draft ------------------------------------------------------------------------

/** League kids turning 18: the gifted ones from baseball families become draft-eligible players. */
function comingOfAge(world: World, rng: Rng, events: LifeEvent[]): Player[] {
  const pool: Player[] = [];
  for (const kid of Object.values(world.npcs).sort((a, b) => (a.id < b.id ? -1 : 1))) {
    if (kid.age !== 18 || kid.role !== "citizen" || kid.sex !== "M") continue;
    const kin = baseballKin(world, kid);
    const talent = kid.talent ?? 40;
    const wants = (kin ? 0.75 : 0.25) * (talent >= 50 ? 1 : talent >= 42 ? 0.6 : 0.15);
    if (!rng.chance(wants)) {
      events.push(mkEvent(world, "coming_of_age", [kid.id], [], { choice: "no baseball", kin: kin?.id, relation: kin?.relation, talent }));
      continue;
    }
    // father's position runs in families
    const dad = kid.family.parents.map(id => personById(world, id)).find(q => q?.sex === "M");
    const dadPos = dad && (dad.kind === "player" ? (dad as Player).pos : dad.career?.pos);
    const group: Group = dadPos && rng.chance(0.5)
      ? (dadPos === "P" ? (rng.chance(0.5) ? "SP" : "RP") : dadPos === "C" ? "C" : ["LF", "CF", "RF"].includes(dadPos) ? "OF" : "IF")
      : rng.weighted(GROUPS, g => TEMPLATE[g]);
    const player = mintAmateur(world, rng, group, {
      age: 18, potential: talent + rng.normal(0, 3), identity: kid,
      throws: dad && dad.kind === "player" && rng.chance(0.7) ? (dad as Player).throws : undefined,
    });
    pool.push(player);
    events.push(mkEvent(world, "coming_of_age", [kid.id, ...(kin ? [kin.id] : [])], [], { choice: "baseball", kin: kin?.id, relation: kin?.relation, talent }));
  }
  return pool;
}

/** Each org reshuffles all its players by merit: best 26 to the majors, and so on down. */
function reorganise(world: World, rng: Rng, mlId: string, events: LifeEvent[]) {
  const chain = orgTeams(world, mlId);
  const all = chain.flatMap(t => t.roster.map(id => world.players[id])).filter(Boolean);
  const before = new Map(all.map(p => [p.id, p.teamId]));
  const score = (p: Player) => value(p) + perf(world, p) * 0.5 + (p.age <= 23 ? Math.max(0, p.potential - value(p)) * 0.1 : 0) - (healthy(p) ? 0 : 3);
  for (const t of chain) t.roster = [];
  const extras: Player[] = [];
  for (const g of GROUPS) {
    const ps = all.filter(p => groupOf(p) === g).sort((a, b) => score(b) - score(a));
    let i = 0;
    for (const t of chain) {
      for (let k = 0; k < TEMPLATE[g] && i < ps.length; k++, i++) { t.roster.push(ps[i].id); ps[i].teamId = t.id; }
    }
    extras.push(...ps.slice(i));
  }
  for (const p of extras) { p.teamId = chain[chain.length - 1].id; movePlayer(world, p, FREE_AGENT); events.push(mkEvent(world, "release", [p.id], [chain[chain.length - 1].id], { reason: "no room" })); }
  for (const p of all) {
    const was = before.get(p.id)!, now = p.teamId;
    if (was === now) continue;
    if (now === mlId) events.push(mkEvent(world, "callup", [p.id], [was, now], { from: was, to: now, reason: "earned a spot in camp", offseason: true }));
    else if (was === mlId) events.push(mkEvent(world, "demotion", [p.id], [was, now], { from: was, to: now, reason: "lost his spot", offseason: true }));
  }
  void rng;
}

function draft(world: World, rng: Rng, events: LifeEvent[], kids: Player[], table: [string, number, number][]) {
  const ml = mlTeamIds(world);
  // worst record picks first
  const order = [...ml].sort((a, b) => {
    const ra = table.find(x => x[0] === a), rb = table.find(x => x[0] === b);
    return (ra ? ra[1] / (ra[1] + ra[2]) : 0.5) - (rb ? rb[1] / (rb[1] + rb[2]) : 0.5);
  });
  const vacancies = new Map<string, Record<Group, number>>();
  let total = 0;
  for (const id of ml) {
    const v = { C: 0, IF: 0, OF: 0, SP: 0, RP: 0 } as Record<Group, number>;
    for (const t of orgTeams(world, id)) {
      for (const g of GROUPS) {
        const have = t.roster.filter(pid => world.players[pid] && groupOf(world.players[pid]) === g).length;
        v[g] += Math.max(0, TEMPLATE[g] - have);
      }
    }
    vacancies.set(id, v);
    total += GROUPS.reduce((a, g) => a + v[g], 0);
  }
  // random amateurs to fill out the pool
  const need: Record<Group, number> = { C: 0, IF: 0, OF: 0, SP: 0, RP: 0 };
  for (const v of vacancies.values()) for (const g of GROUPS) need[g] += v[g];
  const pool = [...kids];
  for (const g of GROUPS) {
    const have = pool.filter(p => groupOf(p) === g).length;
    for (let i = have; i < Math.ceil(need[g] * 1.5) + 1; i++) pool.push(mintAmateur(world, rng, g, { age: 18 + rng.int(5) }));
  }
  const hype = (p: Player) => {
    const v = value(p);
    return v + (p.potential - v) * 0.6 + (baseballKin(world, p) ? 1.5 : 0) + rng.normal(0, 2);
  };
  const ranked = pool.map(p => ({ p, h: hype(p) })).sort((a, b) => b.h - a.h);
  let round = 1, pick = 1;
  while (total > 0 && ranked.length) {
    let any = false;
    for (const id of order) {
      const v = vacancies.get(id)!;
      const idx = ranked.findIndex(x => v[groupOf(x.p)] > 0);
      if (idx < 0) continue;
      const { p } = ranked.splice(idx, 1)[0];
      const g = groupOf(p);
      v[g]--;
      total--;
      any = true;
      // he goes to the lowest team in the org with a hole in his group
      const chain = orgTeams(world, id);
      const team = [...chain].reverse().find(t => t.roster.filter(pid => world.players[pid] && groupOf(world.players[pid]) === g).length < TEMPLATE[g]) ?? chain[chain.length - 1];
      movePlayer(world, p, team);
      p.draft = { year: world.year + 1, round, pick: pick++, teamId: id };
      p.contract = { years: 3 + rng.int(2), salary: Math.max(5, Math.round(60 / round)) };
      const kin = baseballKin(world, p);
      events.push(mkEvent(world, "draft", [p.id, ...(kin ? [kin.id] : [])], [id, team.id], { round, pick: p.draft.pick, secondGen: !!kin, kin: kin?.id, relation: kin?.relation, potential: p.potential }));
    }
    if (!any) break;
    round++;
  }
  // undrafted: league kids go to free agency, random amateurs vanish
  for (const { p } of ranked) {
    if (kids.includes(p)) {
      if (!world.freeAgents.includes(p.id)) { p.teamId = FREE_AGENT; world.freeAgents.push(p.id); }
    } else {
      const h = world.houses[p.family.house];
      if (h) { h.players--; if (h.players <= 0 && h.reputation <= 0) delete world.houses[p.family.house]; }
      delete world.players[p.id];
    }
  }
}

function freeAgentMarket(world: World, rng: Rng, events: LifeEvent[]) {
  const fas = world.freeAgents.map(id => world.players[id]).filter(p => p && healthy(p)).sort((a, b) => value(b) - value(a));
  for (const fa of fas.slice(0, 12)) {
    const g = groupOf(fa);
    for (const mlId of rng.shuffle(mlTeamIds(world))) {
      for (const t of orgTeams(world, mlId)) {
        const grp = t.roster.map(id => world.players[id]).filter(p => p && groupOf(p) === g);
        if (!grp.length) continue;
        const worst = grp.reduce((a, b) => (value(b) < value(a) ? b : a));
        if (value(fa) > value(worst) + 2 && value(fa) >= LEVEL_MEAN[t.level] - 4) {
          movePlayer(world, fa, t);
          fa.contract = { years: 1 + rng.int(3), salary: Math.round((t.level === "ML" ? 100 : 15) * Math.pow(1.08, Math.max(0, value(fa) - 40))) };
          events.push(mkEvent(world, "signing", [fa.id], [t.id], { to: t.id, from: FREE_AGENT, reason: "free agent", years: fa.contract.years, salary: fa.contract.salary }));
          balanceOrg(world, mlId, rng, events, { reason: "signing" });
          break;
        }
      }
      if (fa.teamId !== FREE_AGENT) break;
    }
  }
}

// --- houses & relationships ----------------------------------------------------------------------------

function houseReputation(world: World) {
  for (const h of Object.values(world.houses)) h.reputation = Math.round(h.reputation * 0.93 * 10) / 10;
  for (const p of Object.values(world.players)) {
    const t = world.teams[p.teamId];
    if (t?.level === "ML") bumpHouse(world, p.family.house, Math.max(0, value(p) - 48) / 4);
  }
}

function pruneHouses(world: World) {
  const live = new Set<string>();
  for (const p of Object.values(world.players)) live.add(p.family.house);
  for (const p of Object.values(world.npcs)) live.add(p.family.house);
  for (const [id, h] of Object.entries(world.houses)) if (!live.has(id) && h.reputation < 8) delete world.houses[id];
}

function decayRelationships(world: World) {
  const isFaction = (id: string) => !!world.factions[id];
  world.relationships = world.relationships.filter(r => {
    if (isFaction(r.a) && isFaction(r.b)) return true;
    if (!personById(world, r.a) || !personById(world, r.b)) return false;
    if (world.archive[r.a] || world.archive[r.b]) return false;
    if (Math.abs(r.value) <= 1) return false;
    r.value -= Math.sign(r.value);
    return true;
  });
}

/** End-of-season verdicts: award and title fame, goals met or missed, season-long arcs settled. */
function seasonVerdicts(world: World, rng: Rng, events: LifeEvent[]) {
  const h = world.history[world.history.length - 1];
  if (h) {
    for (const id of [h.awards.mvp, h.awards.pitcher, h.awards.rookie]) { const p = id ? world.players[id] : undefined; if (p) gainFame(world, rng, p, id === h.awards.rookie ? 8 : 15, events, "award"); }
    if (h.champion) {
      const team = world.teams[h.champion];
      for (const id of [...team.roster, ...(team.il ?? [])]) {
        const p = world.players[id];
        if (!p) continue;
        gainFame(world, rng, p, 5, events, "champion");
        if (goalOf(p, "win_title")) achieveGoal(world, rng, p, "win_title", events, "won the Continental Series");
      }
      for (const nid of [team.managerId, world.factions[team.factionId]?.leaderId]) { const n = nid ? world.npcs[nid] : undefined; if (n && goalOf(n, "win_title")) achieveGoal(world, rng, n, "win_title", events, "won the Continental Series"); }
    }
  }
  // season-long arcs
  for (const s of openStorylines(world)) {
    if (s.kind === "rookie_watch") resolveStoryline(world, s, h?.awards.rookie === s.people[0] ? "rookie_of_year" : "solid", events, {});
    else if (s.kind === "slump" || s.kind === "curse" || s.kind === "rivalry") resolveStoryline(world, s, "season_over", events, {});
  }
  // goals: fame, records; misses turn into obsessions or get abandoned
  const leaders = new Set(Object.values(h?.leaders ?? {}).map(x => x?.[0]).filter(Boolean) as string[]);
  for (const p of [...Object.values(world.players), ...Object.values(world.npcs)]) {
    if (!p.goals?.length) continue;
    for (const g of [...p.goals]) {
      if (g.kind === "be_famous" && fameOf(p) >= 70) { achieveGoal(world, rng, p, "be_famous", events, "a household name"); continue; }
      if (g.kind === "beat_record" && leaders.has(p.id)) { achieveGoal(world, rng, p, "beat_record", events, "led the league"); continue; }
      if (g.kind === "make_majors" && p.age >= 28) { abandon(world, rng, p, g, events, "too old for the dream"); continue; }
      if (g.kind === "marry" && (p.family.spouse || (g.target && !world.npcs[g.target]))) { abandon(world, rng, p, g, events, p.family.spouse ? "married someone else" : "she moved away"); continue; }
      if (world.day - g.since < 150 || !rng.chance(0.6)) continue;
      g.misses = (g.misses ?? 0) + 1;
      const pl = p as Player;
      const public_ = p.kind === "player" ? world.teams[pl.teamId]?.level === "ML" : (p as Npc).role !== "citizen";
      if (g.misses === 2 && g.intensity < 3 && rng.chance(0.5)) {
        g.intensity = 3;
        if (public_) events.push(mkEvent(world, "goal", [p.id], pl.teamId ? [pl.teamId] : [], { sub: "obsessed", goal: g.kind, note: g.note, target: g.target }));
      } else if (g.misses >= 4) abandon(world, rng, p, g, events, "gave up", public_);
    }
  }
}

function abandon(world: World, rng: Rng, p: Player | Npc, g: NonNullable<Player["goals"]>[number], events: LifeEvent[], why: string, public_ = true) {
  p.goals = (p.goals ?? []).filter(x => x !== g);
  if (public_) events.push(mkEvent(world, "goal", [p.id], p.kind === "player" ? [p.teamId] : [], { sub: "abandoned", goal: g.kind, note: g.note, why }));
  p.goals.push(pickGoal(world, rng, p));
}
