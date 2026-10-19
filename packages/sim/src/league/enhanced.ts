// The Enhanced League: a six-team circuit out in the desert where the Commissioner sends the
// players the Continental league can no longer explain. Its own schedule, standings and
// playoffs (the Mirage Cup) on the same day clock, plus occasional exhibitions against
// Continental clubs. The engine handles powers by itself (powers.ts, Side.ultra pools).

import type { Rng } from "../rng.ts";
import { FIRST, LAST } from "../names.ts";
import type { Faction, Park, Player, Pos, Quirk, Team, Umpire, World } from "../types.ts";
import { FREE_AGENT } from "../types.ts";
import type { PowerKind } from "../powers.ts";
import { createNpc, ensureHouse, newHouseId, nextId, pickFace, setRelation } from "../life/people.ts";
import { GROUP_POS, GROUPS, TEMPLATE, battingFor, clamp, fieldingFor, handsFor, pitchingFor, randomTraits, value, type Group } from "../life/ratings.ts";
import { initialFame, seedInnerLife } from "../life/inner.ts";
import { makeHistorical, FIGURES } from "../life/weird.ts";
import { makeWeather, seasonDate, umpirePool, REGULAR_DAYS } from "./calendar.ts";
import type { ScheduledGame } from "./index.ts";

export const MIRAGE_CUP = "the Mirage Cup";

interface ClubDef {
  abbr: string; city: string; name: string;
  owner: { id: string; name: string; kind: Faction["kind"]; wants: string[] } | { existing: string };
  park: Omit<Park, "id">;
}

export const ENHANCED_CLUBS: ClubDef[] = [
  { abbr: "MFP", city: "Mirage Flats", name: "Phantoms",
    owner: { id: "sands", name: "The Desert Sands Casino", kind: "bookies", wants: ["action", "a bigger neon sign", "the Mirage Cup on the betting board"] },
    park: { name: "The Oasis", fences: [300, 350, 420, 350, 300], walls: [8, 8, 30, 8, 8], altitudeFt: 2400, foulTerritory: 30, turf: true, climate: { temp: 16, rain: 0.2 }, note: "the casino's back lot; the scoreboard pays out on home runs" } },
  { abbr: "AN9", city: "Area Nine", name: "Visitors",
    owner: { id: "area9", name: "The Federal Recreation Program (Area Nine)", kind: "commissioner", wants: ["observation", "no photographs", "a clean chain of custody"] },
    park: { name: "Hangar Field", fences: [340, 390, 470, 390, 340], walls: [12, 12, 12, 12, 12], altitudeFt: 4500, foulTerritory: 70, turf: false, climate: { temp: 12, rain: 0.15 }, note: "inside a decommissioned aircraft hangar; the roof is mostly there" } },
  { abbr: "TJP", city: "Tumbleweed Junction", name: "Prospectors",
    owner: { existing: "elc" },
    park: { name: "Tesla Coil Park", fences: [320, 360, 400, 360, 320], walls: [10, 10, 10, 10, 10], altitudeFt: 3300, foulTerritory: 50, turf: true, climate: { temp: 14, rain: 0.25 }, note: "lit by Volta's coils; the ball glows faintly after dark" } },
  { abbr: "SBS", city: "Salt Basin", name: "Saints",
    owner: { id: "spitball", name: "The Church of the Second Spitball", kind: "church", wants: ["converts", "the spitball restored", "St. Albans humbled"] },
    park: { name: "The Salt Flat", fences: [360, 400, 430, 400, 360], walls: [6, 6, 6, 6, 6], altitudeFt: 4200, foulTerritory: 80, turf: false, climate: { temp: 15, rain: 0.1 }, note: "no fences to speak of, just a painted line on the salt" } },
  { abbr: "CCM", city: "Crater City", name: "Meteors",
    owner: { id: "halvorsen", name: "The Halvorsen Comet Society", kind: "owner", wants: ["the comet's return", "a telescope in center field", "proof"] },
    park: { name: "The Crater", fences: [290, 330, 510, 330, 290], walls: [40, 20, 6, 20, 40], altitudeFt: 5600, foulTerritory: 40, turf: false, climate: { temp: 10, rain: 0.2 }, note: "built inside an impact crater: short porches, a canyon in center" } },
  { abbr: "BVG", city: "Bone Valley", name: "Ghosts",
    owner: { id: "ossuary", name: "The Ossuary Trust", kind: "trust", wants: ["quiet", "the old cemetery expanded", "a pennant before the end"] },
    park: { name: "Boot Hill Yard", fences: [315, 365, 405, 375, 330], walls: [12, 12, 12, 12, 12], altitudeFt: 3100, foulTerritory: 60, turf: false, climate: { temp: 18, rain: 0.1 }, note: "next to the old cemetery; night games go very quiet" } },
];

const ODD_NICKS = ["the Mirage", "Sand Dollar", "Eyeball", "Coyote", "Dust Devil", "Static", "Neon", "Gila", "Radio", "Jackrabbit", "the Sphinx", "Cactus", "Saguaro", "Tumbleweed", "Bones", "Rattler", "Moonman", "Two Shadows"];
const WEIRD_QUIRKS: Quirk[] = ["GLOWS", "KNOWS_THINGS", "NO_SHADOW", "SPEAKS_TO_BIRDS"];
const PITCH_POWERS: PowerKind[] = ["FIREBALL", "STOPPER", "WARP_PITCH", "CLOUD_BALL"];
const BAT_POWERS: PowerKind[] = ["HYPER_HIT", "LEAP_CATCH", "LASER_ARM", "WARP_RUN"];

export const enhancedTeams = (world: World): Team[] => Object.values(world.teams).filter(t => t.level === "EL").sort((a, b) => (a.id < b.id ? -1 : 1));
export const enhancedTeamIds = (world: World): string[] => enhancedTeams(world).map(t => t.id);

/** An Enhanced League oddball (not on a team yet). `powerChance` = odds of an Ultra power. */
export function mintOddball(world: World, rng: Rng, g: Group, powerChance = 0.35): Player {
  const pos: Pos = rng.pick(GROUP_POS[g]);
  const age = 21 + rng.int(18);
  const mean = 46 + rng.normal(0, 4);
  const hands = handsFor(rng, pos);
  const last = rng.pick(LAST);
  const p: Player = {
    id: nextId(world, "p"), kind: "player", first: rng.pick(FIRST), last, sex: "M", face: pickFace(world, "M", age, rng), age, born: world.year - age,
    traits: randomTraits(rng, rng.chance(0.5) ? 2 : 1), mood: 0, bats: hands.bats, throws: hands.throws, pos, teamId: FREE_AGENT,
    family: { house: newHouseId(world, last), parents: [], children: [], drama: [] }, active: true,
    batting: battingFor(rng, pos, mean), fielding: fieldingFor(rng, pos, mean), potential: clamp(mean + 2), talent: clamp(mean + 4),
    recentPitches: [0, 0, 0, 0, 0], contract: { years: 1 + rng.int(3), salary: 40 + rng.int(60) },
  };
  if (rng.chance(0.4)) p.nickname = rng.pick(ODD_NICKS);
  if (pos === "P") {
    p.pitching = pitchingFor(rng, mean, g === "SP" ? "SP" : "RP", hands.throws);
    p.pitching.stamina = g === "SP" ? Math.max(50, p.pitching.stamina) : Math.min(42, p.pitching.stamina);
  }
  if (rng.chance(powerChance)) {
    const kind = rng.pick(pos === "P" ? PITCH_POWERS : BAT_POWERS);
    const roll = rng.float();
    p.powers = [{ kind, level: (roll < 0.6 ? 1 : roll < 0.9 ? 2 : 3) as 1 | 2 | 3 }];
    if (rng.chance(0.15)) {
      const k2 = rng.pick(pos === "P" ? BAT_POWERS.filter(x => x === "LASER_ARM") : BAT_POWERS.filter(x => x !== kind));
      p.powers.push({ kind: k2, level: 1 });
    }
  }
  if (rng.chance(0.35)) p.quirks = [rng.pick(WEIRD_QUIRKS)];
  p.peak = Math.round(value(p));
  world.players[p.id] = p;
  ensureHouse(world, p.family.house, p).players++;
  return p;
}

/** Worldgen: factions, parks, umpires, managers and rosters for the six clubs. */
export function seedEnhanced(world: World, rng: Rng) {
  for (const def of ENHANCED_CLUBS) {
    let fid: string;
    if ("existing" in def.owner) fid = def.owner.existing;
    else {
      fid = def.owner.id;
      world.factions[fid] = { id: fid, name: def.owner.name, kind: def.owner.kind, wants: def.owner.wants };
      const owner = createNpc(world, rng, { sex: rng.chance(0.2) ? "F" : "M", age: 40 + rng.int(30), role: def.owner.kind === "bookies" ? "fixer" : def.owner.kind === "commissioner" ? "official" : "owner", factionId: fid, traits: 2 });
      owner.fame = 20 + rng.int(30);
      world.factions[fid].leaderId = owner.id;
      ensureHouse(world, owner.family.house, owner);
    }
    const park: Park = { id: `park-${def.abbr.toLowerCase()}`, ...def.park };
    world.parks[park.id] = park;
    const mgr = createNpc(world, rng, { sex: "M", age: 38 + rng.int(30), role: "manager", factionId: fid, traits: 2 });
    const team: Team = {
      id: def.abbr, city: def.city, name: def.name, abbr: def.abbr, level: "EL", factionId: fid, parkId: park.id,
      managerId: mgr.id, roster: [], il: [], circuit: "enhanced",
    };
    world.teams[team.id] = team;
    for (const g of GROUPS) for (let i = 0; i < TEMPLATE[g]; i++) {
      const p = mintOddball(world, rng, g);
      p.teamId = team.id;
      team.roster.push(p.id);
    }
  }
  // a couple of historical figures were already out here when the league was founded
  for (const t of rng.shuffle(enhancedTeams(world)).slice(0, 2)) {
    const p = makeHistorical(world, rng, rng.pick(FIGURES.filter(f => f.pos !== "P")));
    if (!p) continue;
    const g = p.pos === "C" ? "C" : ["LF", "CF", "RF"].includes(p.pos) ? "OF" : "IF";
    const out = t.roster.map(id => world.players[id]).find(x => x.pos !== "P" && (x.pos === "C" ? "C" : ["LF", "CF", "RF"].includes(x.pos) ? "OF" : "IF") === g)!;
    t.roster = t.roster.filter(id => id !== out.id);
    delete world.players[out.id];
    world.freeAgents = world.freeAgents.filter(id => id !== p.id);
    p.teamId = t.id;
    t.roster.push(p.id);
  }
  for (const id of enhancedTeamIds(world)) for (const pid of world.teams[id].roster) {
    const p = world.players[pid];
    seedInnerLife(world, rng, p);
    p.fame = Math.max(initialFame(world, rng, p), 12 + rng.int(30));
  }
  // umpires who don't ask questions
  for (let i = 0; i < 6; i++) {
    const u = createNpc(world, rng, { sex: rng.chance(0.15) ? "F" : "M", age: 30 + rng.int(30), role: "umpire", factionId: "umps", stats: { zoneWidth: clamp(rng.normal(52, 12)), consistency: clamp(rng.normal(42, 12)), temper: clamp(rng.normal(50, 12)), corruptible: clamp(rng.normal(55, 15)), ml: 2 } }) as Umpire;
    void u;
  }
  // who likes whom
  const ties: [string, string, number, string][] = [
    ["sands", "book", 3, "the same people, really"], ["area9", "commish", 4, "the Commissioner's pet project"], ["spitball", "sta", -4, "heresy"],
    ["spitball", "mrl", -2, "a rival gospel"], ["halvorsen", "press", 2, "comet coverage"], ["ossuary", "spitball", -2, "a cemetery boundary"],
  ];
  for (const [a, b, v, why] of ties) if (world.factions[a] && world.factions[b]) setRelation(world, a, b, v, why, "faction");
}

// --- schedule --------------------------------------------------------------------------------------

/**
 * 154 days for six clubs, one game each per day (3 games a day): ten cycles of 3-game series
 * against each rival (home alternating by cycle), then one 4-game set.
 */
export function enhancedSchedule(world: World, season: number, year: number, rng: Rng): ScheduledGame[] {
  const ids = rng.shuffle(enhancedTeamIds(world));
  if (ids.length < 2) return [];
  const n = ids.length - (ids.length % 2);
  const rounds: [string, string][][] = [];
  const rot = ids.slice(1, n);
  for (let r = 0; r < n - 1; r++) {
    const left = [ids[0], ...rot.slice(0, n / 2 - 1)];
    const right = rot.slice(n / 2 - 1).reverse();
    rounds.push(left.map((a, i) => (r % 2 === 0 ? [a, right[i]] : [right[i], a]) as [string, string]));
    rot.unshift(rot.pop()!);
  }
  const pairs: { day: number; home: string; away: string }[] = [];
  let day = 1, cycle = 0;
  while (day <= REGULAR_DAYS) {
    for (const ri of rng.shuffle(rounds.map((_, i) => i))) {
      if (day > REGULAR_DAYS) break;
      const left = REGULAR_DAYS - day + 1;
      const len = left === 4 ? 4 : Math.min(3, left);
      for (let g = 0; g < len; g++) for (const [a, b] of rounds[ri]) {
        const aHome = len === 4 ? g < 2 : cycle % 2 === 0;
        pairs.push({ day: day + g, home: aHome ? a : b, away: aHome ? b : a });
      }
      day += len;
    }
    cycle++;
  }
  const umps = umpirePool(world, "EL");
  const out: ScheduledGame[] = [];
  const byDay = new Map<number, typeof pairs>();
  for (const p of pairs) (byDay.get(p.day) ?? byDay.set(p.day, []).get(p.day)!).push(p);
  for (const [d, games] of [...byDay.entries()].sort((a, b) => a[0] - b[0])) {
    const date = seasonDate(year, d);
    const slots = rng.shuffle(games.map((_, i) => i));
    games.forEach((g, i) => {
      const park = world.parks[world.teams[g.home].parkId];
      out.push({
        id: `S${season}D${d}EL${slots[i]}`, season, day: d, level: "EL", homeId: g.home, awayId: g.away,
        umpireId: umps.length ? umps[(d * games.length + i) % umps.length].id : "", weather: makeWeather(park, date, slots[i] + 1, rng), slot: slots[i],
      });
    });
  }
  return out;
}

/**
 * An exhibition between an Enhanced and a Continental club. Marked `exhibition: true` with level
 * "ML" (full log, bettable like a big-league game); it doesn't count in standings or season stats.
 */
export function makeExhibition(world: World, season: number, year: number, day: number, elId: string, mlId: string, slot: number, rng: Rng): ScheduledGame {
  const desert = rng.chance(0.5);
  const homeId = desert ? elId : mlId, awayId = desert ? mlId : elId;
  const park = world.parks[world.teams[homeId].parkId];
  const umps = umpirePool(world, "ML");
  return {
    id: `S${season}D${day}EX${slot}`, season, day, level: "ML", homeId, awayId, slot,
    umpireId: umps.length ? umps[(day + slot) % umps.length].id : "", weather: makeWeather(park, seasonDate(year, day), slot, rng), exhibition: true,
  };
}
