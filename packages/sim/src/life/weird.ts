// The weird tier (rare, a handful per season): alien abductions that return people changed,
// team plane crashes, the dead coming back, clones in the low minors, and long-dead historical
// figures turning up to play ball.

import type { Rng } from "../rng.ts";
import type { Player, Pos, Quirk, World } from "../types.ts";
import { FREE_AGENT } from "../types.ts";
import type { PowerKind } from "../powers.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { addDrama, ensureHouse, hasT, living, newHouseId, nextId, pickFace, setRelation, shortName } from "./people.ts";
import { addConcern, gainFame, pickFear, pickGoal } from "./inner.ts";
import { battingFor, clamp, fieldingFor, handsFor, pitchingFor, randomTraits, value, type Group } from "./ratings.ts";
import { balanceOrg, mlTeamIds, movePlayer, orgTeams } from "./roster.ts";
import { killPerson } from "./family.ts";
import { openStorylines, resolveStoryline, startStoryline } from "./storylines.ts";

/** Expected events per season (a season is ~180 life days). */
export const WEIRD_RATES = { abduction: 1.2, plane_crash: 0.15, resurrection: 0.4, clone: 0.4, historical: 0.8 };
const perDay = (perSeason: number) => perSeason / 180;

export function rollWeird(world: World, rng: Rng, events: LifeEvent[], phase: string) {
  returns(world, rng, events);
  const inSeason = phase === "regular" || phase === "playoffs";
  if (rng.chance(perDay(WEIRD_RATES.abduction))) abduction(world, rng, events);
  if (inSeason && rng.chance(perDay(WEIRD_RATES.plane_crash) * 180 / 165)) planeCrash(world, rng, events);
  if (rng.chance(perDay(WEIRD_RATES.resurrection))) resurrection(world, rng, events);
  if (rng.chance(perDay(WEIRD_RATES.clone))) clone(world, rng, events);
  if (rng.chance(perDay(WEIRD_RATES.historical) * (phase === "offseason" ? 3 : 0.8))) historicalArrival(world, rng, events);
}

// --- abductions -----------------------------------------------------------------------------------

const ABDUCTION_HOW = ["vanished from a cornfield outside Cold Spring", "last seen walking toward a bright light behind the bleachers", "his car found idling on a county road, radio playing static", "disappeared from a fishing boat; the boat was found dry", "left the hotel bar 'to look at the lights' and never came back"];
const PITCH_POWERS: PowerKind[] = ["FIREBALL", "STOPPER", "WARP_PITCH", "CLOUD_BALL"];
const BAT_POWERS: PowerKind[] = ["HYPER_HIT", "LEAP_CATCH", "LASER_ARM", "WARP_RUN"];
const ODD_QUIRKS: Quirk[] = ["GLOWS", "KNOWS_THINGS", "NO_SHADOW", "SPEAKS_TO_BIRDS"];

function abduction(world: World, rng: Rng, events: LifeEvent[]) {
  const pool = Object.values(world.players).filter(p => { const lv = world.teams[p.teamId]?.level; return (lv === "ML" || lv === "AA") && !p.injury; });
  if (!pool.length) return;
  const p = rng.weighted(pool, x => 1 + (x.fame ?? 0) / 20 + (hasT(x, "SUPERSTITIOUS") ? 2 : 0));
  const days = 3 + rng.int(10);
  p.injury = { kind: "missing", daysLeft: days };
  addConcern(world, p, { kind: "missing_time", until: world.day + days + 30, weight: -1.5, note: "can't account for the days" });
  startStoryline(world, "weird", [p.id], [p.teamId], { visibility: "public", stage: "missing", cause: rng.pick(ABDUCTION_HOW), stakes: "his whereabouts", data: { weird: "abduction", days } }, events);
}

function returns(world: World, rng: Rng, events: LifeEvent[]) {
  for (const s of openStorylines(world)) {
    if (s.kind !== "weird" || s.stage !== "missing") continue;
    const p = world.players[s.people[0]];
    if (!p) { resolveStoryline(world, s, "never_returned", events, {}); continue; }
    if (p.injury?.kind === "missing" && p.injury.daysLeft > 0) continue;
    // back, and not quite the same
    const roll = rng.float();
    let change: Record<string, unknown>;
    if (roll < 0.4) {
      const kind = rng.pick(p.pos === "P" ? PITCH_POWERS : BAT_POWERS);
      p.powers = [...(p.powers ?? []).filter(x => x.kind !== kind), { kind, level: 1 }];
      change = { power: kind };
    } else if (roll < 0.75) {
      const q = rng.pick(ODD_QUIRKS);
      p.quirks = [...new Set([...(p.quirks ?? []), q])];
      change = { quirk: q };
    } else {
      // an absurd rating spike
      if (p.pos === "P" && p.pitching) { p.pitching.stuff = clamp(p.pitching.stuff + 12); change = { rating: "stuff", by: 12 }; }
      else { p.batting.power = clamp(p.batting.power + 12); change = { rating: "power", by: 12 }; }
    }
    if (p.injury?.kind === "missing") delete p.injury;
    gainFame(world, rng, p, 10, events, "abduction");
    resolveStoryline(world, s, "returned_changed", events, { ...change, says: rng.pick(["remembers nothing", "says 'they were very polite'", "won't stop humming", "says he was 'up there'", "brought back a rock that hums"]) });
    events.push(mkEvent(world, "weird", [p.id], [p.teamId], { sub: "abduction_return", storyline: s.id, ...change }));
  }
}

// --- plane crashes -----------------------------------------------------------------------------------

function planeCrash(world: World, rng: Rng, events: LifeEvent[]) {
  const teams = Object.values(world.teams);
  const team = rng.weighted(teams, t => (t.level === "ML" ? 0.6 : 1));
  const victims = rng.shuffle([...team.roster]).slice(0, 1 + rng.int(4)).map(id => world.players[id]).filter(Boolean);
  const mgr = world.npcs[team.managerId];
  const dead = victims.map(v => ({ id: v.id, name: shortName(v) }));
  const withManager = mgr && rng.chance(0.25);
  const e = mkEvent(world, "weird", [...victims.map(v => v.id), ...(withManager ? [mgr.id] : [])], [team.id], {
    sub: "plane_crash", where: rng.pick(["a cornfield outside Keokuk", "Lake Oneida", "a ridge near Durango", "the Sedalia rail yards"]), dead, manager: withManager ? mgr.id : undefined,
    cause: rng.pick(["engine fire", "a storm", "pilot error", "a flock of geese"]), survivors: team.roster.length - victims.length,
  });
  events.push(e);
  for (const v of victims) killPerson(world, rng, v, events, "in a plane crash");
  if (withManager) killPerson(world, rng, mgr, events, "in a plane crash");
  // the league mourns; teammates grieve; anyone afraid of flying is now terrified
  world.effects.push({ id: `w-mem-${world.day}`, kind: "memorial", title: `Memorial patches for the ${team.city} ${team.name}`, from: world.day, until: world.day + 25, mood: -0.3 });
  for (const id of team.roster) { const p = world.players[id]; if (p) addConcern(world, p, { kind: "mourning", until: world.day + 40, weight: -2.5, note: "the crash" }); }
  for (const p of Object.values(world.players)) {
    if (p.fears?.some(f => f.kind === "flying")) {
      addConcern(world, p, { kind: "grieving", until: world.day + 30, weight: -1.5, note: "won't get on a plane" });
    }
  }
  const scared = Object.values(world.players).filter(p => p.fears?.some(f => f.kind === "flying") && world.teams[p.teamId]?.level === "ML").slice(0, 6);
  if (scared.length) events.push(mkEvent(world, "fear", scared.map(p => p.id), [], { sub: "realized", fear: "flying", after: e.id, what: "refusing to fly; taking the bus" }));
}

// --- resurrections ---------------------------------------------------------------------------------

function resurrection(world: World, rng: Rng, events: LifeEvent[]) {
  const cands = Object.values(world.archive).filter(a => a.dead && (a.kind === "player" || (a.career && a.career.peak >= 52)) && world.year - (a.died ?? world.year) <= 40);
  if (!cands.length) return;
  const a = rng.pick(cands);
  const pos: Pos = a.career?.pos ?? (rng.chance(0.45) ? "P" : rng.pick(["C", "1B", "2B", "SS", "3B", "LF", "CF", "RF"] as Pos[]));
  const age = Math.min(Math.max(a.age, 24), 38);
  const mean = Math.max(36, Math.min(66, (a.career?.peak ?? 48) - 3));
  const hands = handsFor(rng, pos);
  const p: Player = {
    id: a.id, kind: "player", first: a.first, last: a.last, nickname: a.nickname ?? "Lazarus", face: a.face, sex: "M", age, born: world.year - age,
    traits: a.traits.length ? [...a.traits.slice(1), ...randomTraits(rng, 1)] : randomTraits(rng, 1), mood: 0, bats: hands.bats, throws: hands.throws, pos,
    teamId: FREE_AGENT, family: { ...a.family, spouse: undefined, drama: [] }, active: true,
    batting: battingFor(rng, pos, mean), fielding: fieldingFor(rng, pos, mean), potential: mean, talent: a.talent ?? mean,
    recentPitches: [0, 0, 0, 0, 0], contract: { years: 1, salary: 50 }, career: a.career, quirks: ["RESURRECTED"],
    fame: 45, goals: [{ kind: "comeback", since: world.day, intensity: 3, note: "come back" }],
  };
  if (pos === "P") p.pitching = pitchingFor(rng, mean, rng.chance(0.5) ? "SP" : "RP", hands.throws);
  if (!p.nickname) delete p.nickname;
  delete world.archive[a.id];
  world.players[p.id] = p;
  world.freeAgents.push(p.id);
  const team = placeInOrg(world, rng, p, events);
  events.push(mkEvent(world, "weird", [p.id], team ? [team] : [], { sub: "resurrection", diedYear: a.died, wasDeadYears: world.year - (a.died ?? world.year), how: rng.pick(["walked into spring training in his old uniform", "knocked on his widow's door at 3 a.m.", "found sitting in the dugout at dawn", "climbed out of the river at Port Ellis"]) }));
}

// --- clones -------------------------------------------------------------------------------------------

function clone(world: World, rng: Rng, events: LifeEvent[]) {
  const stars = Object.values(world.players).filter(p => world.teams[p.teamId]?.level === "ML" && (p.fame ?? 0) >= 30);
  if (!stars.length) return;
  const orig = rng.weighted(stars, p => p.fame ?? 1);
  const c: Player = structuredClone(orig);
  c.id = nextId(world, "p");
  c.nickname = rng.pick(["Two", "the Other", "Again", "Copy"]);
  c.traits = randomTraits(rng, 2);
  c.quirks = ["CLONE"];
  c.cloneOf = orig.id;
  c.family = { house: orig.family.house, parents: [], children: [], drama: [] };
  c.mood = 0; c.fame = 15; c.form = 0; c.debut = undefined; c.draft = undefined; c.injury = undefined; c.concerns = [];
  c.goals = [{ kind: "revenge", target: orig.id, since: world.day, intensity: 2, note: "prove he's the real one" }];
  c.contract = { years: 2, salary: 20 };
  c.powers = undefined;
  for (const k of ["contact", "power", "eye"] as const) c.batting[k] = clamp(c.batting[k] - 3 + rng.normal(0, 3));
  if (c.pitching) for (const k of ["stuff", "control"] as const) c.pitching[k] = clamp(c.pitching[k] - 3 + rng.normal(0, 3));
  c.teamId = FREE_AGENT;
  world.players[c.id] = c;
  world.freeAgents.push(c.id);
  const ml = mlTeamIds(world).filter(id => id !== world.teams[orig.teamId]?.parentId && id !== orig.teamId);
  const org = rng.pick(ml);
  const d = orgTeams(world, org)[3];
  movePlayer(world, c, d);
  balanceOrg(world, org, rng, events, { reason: "a clone" });
  setRelation(world, c.id, orig.id, -4, "there can be only one", "clone");
  events.push(mkEvent(world, "weird", [c.id, orig.id], [d.id, orig.teamId], { sub: "clone", original: orig.id, where: rng.pick(["a Cold Spring cattle auction", "a laboratory fire at Volta Power & Light", "the bottom of the Port Ellis harbor", "nobody knows"]) }));
  startStoryline(world, "feud", [orig.id, c.id], [orig.teamId, d.id], { visibility: "public", stage: "public_spat", cause: "a clone turned up", stakes: "who is the real one", data: { clone: true } }, events);
}

// --- historical figures ---------------------------------------------------------------------------------

export interface Figure { figure: string; first: string; last: string; era: string; pos: Pos; group?: Group; boost: Partial<Record<"contact" | "power" | "eye" | "speed" | "stuff" | "control" | "command" | "movement", number>>; traits: Player["traits"]; quirks?: Quirk[]; nick?: string }

export const FIGURES: Figure[] = [
  { figure: "Abraham Lincoln", first: "Abe", last: "Lincoln", era: "1860s", pos: "1B", boost: { power: 12, eye: 6 }, traits: ["PIOUS", "LOYAL"], nick: "Honest Abe" },
  { figure: "Napoleon Bonaparte", first: "Napoleon", last: "Bonaparte", era: "1800s", pos: "2B", boost: { speed: 12, contact: 6 }, traits: ["HOTHEAD", "SHOWBOAT"], quirks: ["VAIN"], nick: "the Little Corporal" },
  { figure: "Benjamin Franklin", first: "Ben", last: "Franklin", era: "1770s", pos: "C", boost: { eye: 14 }, traits: ["CHARMING"], quirks: ["KNOWS_THINGS"], nick: "Poor Richard" },
  { figure: "Genghis Khan", first: "Genghis", last: "Khan", era: "1200s", pos: "LF", boost: { power: 15 }, traits: ["HOTHEAD", "GREEDY"], nick: "the Great Khan" },
  { figure: "Edgar Allan Poe", first: "Edgar", last: "Poe", era: "1840s", pos: "P", group: "RP", boost: { stuff: 10, movement: 6 }, traits: ["SUPERSTITIOUS", "DRUNK"], quirks: ["LONER"], nick: "the Raven" },
  { figure: "Julius Caesar", first: "Julius", last: "Caesar", era: "40s BC", pos: "SS", boost: { contact: 8, power: 6 }, traits: ["PARANOID", "SHOWBOAT"], nick: "Big Julie" },
  { figure: "Leonardo da Vinci", first: "Leonardo", last: "da Vinci", era: "1500s", pos: "P", group: "SP", boost: { control: 12, command: 10 }, traits: ["GRINDER"], quirks: ["KNOWS_THINGS"], nick: "the Maestro" },
  { figure: "William Shakespeare", first: "Will", last: "Shakespeare", era: "1600s", pos: "CF", boost: { contact: 8, speed: 6 }, traits: ["SHOWBOAT", "CHARMING"], nick: "the Bard" },
  { figure: "Isaac Newton", first: "Isaac", last: "Newton", era: "1680s", pos: "P", group: "SP", boost: { movement: 14, stuff: 6 }, traits: ["PARANOID"], quirks: ["LONER"], nick: "Gravity" },
  { figure: "Attila the Hun", first: "Attila", last: "Hun", era: "400s", pos: "3B", boost: { power: 12, contact: 4 }, traits: ["HOTHEAD", "CROOKED"], nick: "the Scourge" },
  { figure: "Wolfgang Amadeus Mozart", first: "Wolfgang", last: "Mozart", era: "1780s", pos: "2B", boost: { contact: 12 }, traits: ["SHOWBOAT", "GAMBLER"], quirks: ["PRANKSTER"], nick: "Wolfie" },
  { figure: "Ludwig van Beethoven", first: "Ludwig", last: "Beethoven", era: "1800s", pos: "P", group: "SP", boost: { stuff: 12 }, traits: ["HOTHEAD"], quirks: ["LONER"], nick: "Deaf Lud" },
  { figure: "Blackbeard (Edward Teach)", first: "Edward", last: "Teach", era: "1710s", pos: "RF", boost: { power: 10, speed: 4 }, traits: ["CROOKED", "DRUNK"], nick: "Blackbeard" },
  { figure: "Galileo Galilei", first: "Galileo", last: "Galilei", era: "1610s", pos: "P", group: "RP", boost: { control: 10, stuff: 4 }, traits: ["GRINDER"], quirks: ["KNOWS_THINGS"] },
  { figure: "Alexander the Great", first: "Alexander", last: "Magnus", era: "330s BC", pos: "SS", boost: { contact: 6, power: 8, speed: 4 }, traits: ["SHOWBOAT", "CLUTCH"], quirks: ["VAIN"], nick: "the Great" },
  { figure: "Socrates", first: "Socrates", last: "of Athens", era: "400s BC", pos: "C", boost: { eye: 16 }, traits: ["PIOUS"], nick: "the Gadfly" },
  { figure: "Hannibal Barca", first: "Hannibal", last: "Barca", era: "210s BC", pos: "CF", boost: { speed: 10, power: 6 }, traits: ["GRINDER", "CLUTCH"] },
  { figure: "Marco Polo", first: "Marco", last: "Polo", era: "1290s", pos: "CF", boost: { speed: 14 }, traits: ["CHARMING"], nick: "the Traveler" },
  { figure: "Grigori Rasputin", first: "Grigori", last: "Rasputin", era: "1910s", pos: "P", group: "SP", boost: { stuff: 8 }, traits: ["IRON_MAN", "DRUNK", "CHARMING"], quirks: ["RESURRECTED"], nick: "the Mad Monk" },
  { figure: "Davy Crockett", first: "Davy", last: "Crockett", era: "1830s", pos: "RF", boost: { power: 8, contact: 4 }, traits: ["LOYAL"], nick: "King of the Wild Frontier" },
  { figure: "Wild Bill Hickok", first: "Bill", last: "Hickok", era: "1870s", pos: "LF", boost: { contact: 6, eye: 6 }, traits: ["GAMBLER", "HOTHEAD"], nick: "Wild Bill" },
  { figure: "Mark Twain", first: "Samuel", last: "Clemens", era: "1880s", pos: "1B", boost: { contact: 8, eye: 6 }, traits: ["CHARMING"], quirks: ["PRANKSTER"], nick: "Mark Twain" },
  { figure: "Nikola Tesla", first: "Nikola", last: "Tesla", era: "1900s", pos: "P", group: "SP", boost: { stuff: 14 }, traits: ["PARANOID"], quirks: ["LONER", "GLOWS"], nick: "the Wizard" },
  { figure: "Harry Houdini", first: "Harry", last: "Houdini", era: "1910s", pos: "SS", boost: { speed: 10, contact: 6 }, traits: ["SHOWBOAT"], quirks: ["PRANKSTER"], nick: "the Escape King" },
  { figure: "Ulysses S. Grant", first: "Ulysses", last: "Grant", era: "1860s", pos: "3B", boost: { power: 8, eye: 4 }, traits: ["DRUNK", "GRINDER"], nick: "Unconditional Surrender" },
  { figure: "Charles Darwin", first: "Charles", last: "Darwin", era: "1850s", pos: "C", boost: { eye: 10, contact: 4 }, traits: ["GRINDER"], quirks: ["SPEAKS_TO_BIRDS"] },
  { figure: "Vincent van Gogh", first: "Vincent", last: "van Gogh", era: "1880s", pos: "P", group: "RP", boost: { movement: 10, stuff: 6 }, traits: ["HOTHEAD", "SUPERSTITIOUS"], quirks: ["LONER"] },
  { figure: "Sun Tzu", first: "Sun", last: "Tzu", era: "500s BC", pos: "P", group: "SP", boost: { command: 14, control: 8 }, traits: ["CLUTCH"], quirks: ["KNOWS_THINGS"], nick: "the General" },
  { figure: "Leif Erikson", first: "Leif", last: "Erikson", era: "1000s", pos: "CF", boost: { power: 6, speed: 8 }, traits: ["IRON_MAN"] },
  { figure: "Richard the Lionheart", first: "Richard", last: "Plantagenet", era: "1190s", pos: "1B", boost: { power: 12 }, traits: ["HOTHEAD", "LOYAL"], nick: "Lionheart" },
];

const ARRIVALS = [
  "stepped out of a fog bank at the Electric City World's Fair", "found asleep in the Bellwood Park bleachers in period dress",
  "walked out of a cornfield in Cold Spring asking for 'the general'", "climbed out of a time capsule dug up in Millbrook",
  "appeared in a flash of light during a Volta Power & Light experiment", "showed up at a tryout camp with a signed letter from 'the Department'",
];

function historicalArrival(world: World, rng: Rng, events: LifeEvent[]) {
  const p = makeHistorical(world, rng);
  if (!p) return;
  const team = placeInOrg(world, rng, p, events);
  const f = p.historical!;
  events.push(mkEvent(world, "weird", [p.id], team ? [team] : [], { sub: "historical_arrival", figure: f.figure, era: f.era, how: rng.pick(ARRIVALS) }));
}

/** A historical figure as a free agent (not yet signed); undefined if every figure is already here. */
export function makeHistorical(world: World, rng: Rng, figure?: Figure): Player | undefined {
  const present = new Set([...Object.values(world.players), ...Object.values(world.npcs)].map(p => p.historical?.figure).filter(Boolean));
  const free = FIGURES.filter(f => !present.has(f.figure));
  if (!free.length) return undefined;
  const f = figure && !present.has(figure.figure) ? figure : rng.pick(free);
  const age = 26 + rng.int(12);
  const mean = 50 + rng.normal(0, 4);
  const hands = handsFor(rng, f.pos);
  const p: Player = {
    id: nextId(world, "p"), kind: "player", first: f.first, last: f.last, nickname: f.nick, face: pickFace(world, "M", age, rng), sex: "M", age, born: world.year - age,
    traits: [...f.traits], quirks: [...new Set([...(f.quirks ?? []), "TIME_DISPLACED" as Quirk])], mood: 0, bats: hands.bats, throws: hands.throws, pos: f.pos, teamId: FREE_AGENT,
    family: { house: newHouseId(world, f.last), parents: [], children: [], drama: [] }, active: true,
    batting: battingFor(rng, f.pos, mean), fielding: fieldingFor(rng, f.pos, mean), potential: Math.round(mean + 4), talent: Math.round(mean + 8),
    recentPitches: [0, 0, 0, 0, 0], contract: { years: 2, salary: 150 }, fame: 55, historical: { figure: f.figure, era: f.era },
  };
  if (!p.nickname) delete p.nickname;
  if (f.pos === "P") {
    p.pitching = pitchingFor(rng, mean, f.group === "SP" ? "SP" : "RP", hands.throws);
    p.pitching.stamina = f.group === "SP" ? Math.max(50, p.pitching.stamina) : Math.min(42, p.pitching.stamina);
  }
  for (const [k, v] of Object.entries(f.boost)) {
    if (k === "stuff" || k === "control" || k === "command" || k === "movement") { if (p.pitching) p.pitching[k] = clamp(p.pitching[k] + v!); }
    else p.batting[k as "contact" | "power" | "eye" | "speed"] = clamp(p.batting[k as "contact" | "power" | "eye" | "speed"] + v!);
  }
  p.peak = Math.round(value(p));
  p.goals = [pickGoal(world, rng, p)];
  p.fears = [pickFear(world, rng, p)];
  p.concerns = [{ kind: "missing_time", since: world.day, until: world.day + 60, weight: -1, note: "what year is it?" }];
  world.players[p.id] = p;
  world.freeAgents.push(p.id);
  ensureHouse(world, p.family.house, p).players++;
  return p;
}

/** Sign a newcomer with the organisation that needs him most, at the level his ability merits. */
function placeInOrg(world: World, rng: Rng, p: Player, events: LifeEvent[]): string | undefined {
  const org = rng.pick(mlTeamIds(world));
  const chain = orgTeams(world, org);
  const v = value(p);
  const team = v >= 47 ? chain[0] : v >= 41 ? chain[1] : v >= 35 ? chain[2] : chain[3];
  movePlayer(world, p, team);
  balanceOrg(world, org, rng, events, { reason: "a surprise signing" });
  events.push(mkEvent(world, "signing", [p.id], [team.id], { to: team.id, from: FREE_AGENT, reason: "out of nowhere" }));
  return team.id;
}

void living; void addDrama;

export type WeirdKind = "abduction" | "plane_crash" | "resurrection" | "clone" | "historical";
/** Make one weird event happen now (tests, admin tools). */
export function forceWeird(world: World, rng: Rng, kind: WeirdKind, events: LifeEvent[]) {
  ({ abduction, plane_crash: planeCrash, resurrection, clone, historical: historicalArrival })[kind](world, rng, events);
}
