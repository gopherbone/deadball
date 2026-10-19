// Builds a fresh league: clubs, farm chains, factions, parks, players, umpires, and the
// web of grudges and debts between them.

import { Rng } from "./rng.ts";
import type { Faction, Level, Npc, Park, Player, Pos, Relationship, Role, Sex, Team, World } from "./types.ts";
import { FIRST, LAST, NICKS, FARM_CITIES, FARM_NAMES } from "./names.ts";
import { REFERENCE_NORMS, battingFor, clamp, fieldingFor, handsFor, pitchingFor, randomTraits, renormalise, value } from "./life/ratings.ts";
import { createNpc, ensureHouse, pickFace, nextId, newHouseId } from "./life/people.ts";
import { seedFamilies } from "./life/seed.ts";
import { seedRelationships } from "./life/starts.ts";
import { initialFame, seedInnerLife } from "./life/inner.ts";
import { hireGM } from "./life/storylines.ts";
import { isNotable } from "./life/family.ts";
import { seedEnhanced } from "./league/enhanced.ts";

import { START_YEAR_DEFAULT } from "./life/constants.ts";

/** Season 1 is played in this calendar year. */
export const START_YEAR = START_YEAR_DEFAULT;

interface ClubDef {
  abbr: string; city: string; name: string;
  owner: { name: string; kind: Faction["kind"]; wants: string[] };
  park: { name: string; fences: Park["fences"]; walls: Park["walls"]; altitudeFt: number; foulTerritory: number; turf: boolean };
  farm?: [string, string][]; // fixed farm clubs [city, name] for AA, B, D
}

const CLUBS: ClubDef[] = [
  { abbr: "HCL", city: "Harbor City", name: "Lamplighters",
    owner: { name: "The Haldane Organization", kind: "owner", wants: ["a pennant", "a new stadium", "Kessler fired"] },
    park: { name: "Bellwood Park", fences: [318, 368, 404, 372, 322], walls: [12, 10, 10, 10, 14], altitudeFt: 20, foulTerritory: 45, turf: false },
    farm: [["Lockport", "Canallers"], ["Fall River", "Spinners"], ["Bellwood", "Colts"]] },
  { abbr: "STA", city: "St. Albans", name: "Friars",
    owner: { name: "The Archdiocese of St. Albans", kind: "church", wants: ["respectability", "the Haldane land", "a miracle"] },
    park: { name: "Sanctuary Field", fences: [335, 380, 410, 380, 335], walls: [8, 8, 8, 8, 8], altitudeFt: 300, foulTerritory: 70, turf: false } },
  { abbr: "PEM", city: "Port Ellis", name: "Mariners",
    owner: { name: "Port Ellis Shipping Trust", kind: "trust", wants: ["cheap labor", "a dock strike broken", "silence"] },
    park: { name: "Wharf Street Grounds", fences: [310, 355, 395, 360, 305], walls: [25, 12, 10, 12, 8], altitudeFt: 5, foulTerritory: 35, turf: false } },
  { abbr: "MIL", city: "Millbrook", name: "Ironmen",
    owner: { name: "Millbrook Steel", kind: "trust", wants: ["union busted", "Ironmen in the black", "a bigger furnace"] },
    park: { name: "Furnace Field", fences: [330, 375, 400, 375, 330], walls: [10, 10, 10, 10, 10], altitudeFt: 900, foulTerritory: 50, turf: true } },
  { abbr: "CSR", city: "Cold Spring", name: "Rustlers",
    owner: { name: "Cold Spring Cattle Company", kind: "trust", wants: ["water rights", "a winning season", "the sheriff re-elected"] },
    park: { name: "Stockyard Park", fences: [340, 385, 415, 385, 340], walls: [8, 8, 12, 8, 8], altitudeFt: 5200, foulTerritory: 60, turf: false } },
  { abbr: "NCG", city: "New Corinth", name: "Grays",
    owner: { name: "The Corinth Club", kind: "owner", wants: ["old money kept old", "no scandals", "the commissioner's ear"] },
    park: { name: "Corinth Commons", fences: [325, 370, 400, 370, 325], walls: [10, 10, 10, 10, 10], altitudeFt: 150, foulTerritory: 55, turf: false } },
  { abbr: "MRL", city: "Marlow", name: "Pilgrims",
    owner: { name: "Brother Amos's Fellowship", kind: "church", wants: ["converts", "Sunday ball banned", "the Friars humbled"] },
    park: { name: "Plymouth Yard", fences: [345, 385, 420, 385, 345], walls: [10, 10, 16, 10, 10], altitudeFt: 400, foulTerritory: 65, turf: false } },
  { abbr: "ELC", city: "Electric City", name: "Comets",
    owner: { name: "Volta Power & Light", kind: "trust", wants: ["night games", "a monopoly", "the Ironmen's furnace contract"] },
    park: { name: "Dynamo Stadium", fences: [320, 360, 395, 360, 320], walls: [10, 10, 10, 10, 10], altitudeFt: 600, foulTerritory: 40, turf: true } },
];

const LEVEL_MEAN: Record<Level, number> = { ML: 50, AA: 43, B: 37, D: 31, EL: 46 };
const LEVEL_AGE: Record<Level, [number, number]> = { ML: [22, 36], AA: [20, 29], B: [19, 26], D: [17, 23], EL: [21, 40] };
export { LEVEL_MEAN, LEVEL_AGE };

/** Share of women by NPC role (late-90s baseball: mostly men in the dugout, fewer in the press box). */
const FEMALE_SHARE: Partial<Record<Role, number>> = { owner: 0.15, reporter: 0.4, official: 0.25, fixer: 0.15, umpire: 0.04, manager: 0.02 };

export function generateWorld(seed: string): World {
  const rng = new Rng(seed);
  const world: World = {
    season: 1, day: 0, year: START_YEAR, factions: {}, teams: {}, players: {}, npcs: {}, parks: {}, relationships: [],
    stats: {}, houses: {}, freeAgents: [], archive: {}, history: [], effects: [], seq: { p: 0, n: 0, e: 0 }, norms: {}, storylines: [],
  };
  const usedNames = new Set<string>();

  const name = () => {
    for (;;) {
      const first = rng.pick(FIRST), last = rng.pick(LAST);
      if (!usedNames.has(first + last)) { usedNames.add(first + last); return { first, last }; }
    }
  };

  const npc = (role: Role, factionId?: string, stats: Record<string, number> = {}): Npc => {
    const sex: Sex = rng.chance(FEMALE_SHARE[role] ?? 0) ? "F" : "M";
    const n = sex === "M" ? name() : { first: undefined, last: rng.pick(LAST) };
    const age = role === "umpire" ? 28 + rng.int(34) : 30 + rng.int(35);
    const p = createNpc(world, rng, { sex, age, role, factionId, first: n.first, last: n.last, stats, traits: rng.int(3) + 1 });
    if (role !== "citizen") ensureHouse(world, p.family.house, p);
    return p;
  };

  // --- league-wide factions
  const leagueFactions: [string, string, Faction["kind"], string[]][] = [
    ["commish", "The Commissioner's Office", "commissioner", ["order", "attendance", "plausible deniability"]],
    ["umps", "The Umpires' Brotherhood", "umpires", ["a raise", "respect", "no more raccoons"]],
    ["press", "SportsWire", "press", ["scoops", "scandal", "ad money"]],
    ["book", "Bets By Bobby", "bookies", ["action", "no cops", "a fixed World Series"]],
  ];
  for (const [id, nm, kind, wants] of leagueFactions) {
    world.factions[id] = { id, name: nm, kind, wants };
    world.factions[id].leaderId = npc(kind === "bookies" ? "fixer" : kind === "press" ? "reporter" : "official", id).id;
  }

  // umpires: a 12-man major-league staff and 20 minor-leaguers
  for (let i = 0; i < 32; i++) {
    const ml = i < 12;
    npc("umpire", "umps", {
      zoneWidth: clamp(rng.normal(50, 10)), consistency: clamp(rng.normal(ml ? 50 : 44, 10)),
      temper: clamp(rng.normal(ml ? 50 : 54, 12)), corruptible: clamp(rng.normal(ml ? 40 : 46, 15)), ml: ml ? 1 : 0,
    });
  }

  // --- clubs, farm chains, players
  for (const def of CLUBS) {
    const fid = def.abbr.toLowerCase();
    world.factions[fid] = { id: fid, name: def.owner.name, kind: def.owner.kind, wants: def.owner.wants };
    world.factions[fid].leaderId = npc("owner", fid).id;
    const park: Park = { id: `park-${fid}`, ...def.park };
    world.parks[park.id] = park;

    const chain: { city: string; name: string; level: Level }[] = [{ city: def.city, name: def.name, level: "ML" }];
    const levels: Level[] = ["AA", "B", "D"];
    levels.forEach((lv, i) => {
      const fixed = def.farm?.[i];
      chain.push({ city: fixed ? fixed[0] : rng.pick(FARM_CITIES), name: fixed ? fixed[1] : rng.pick(FARM_NAMES), level: lv });
    });

    const mlId = def.abbr;
    for (const c of chain) {
      const id = c.level === "ML" ? mlId : `${mlId}-${c.level}`;
      const teamPark = c.level === "ML" ? park : makeFarmPark(rng, id);
      if (c.level !== "ML") world.parks[teamPark.id] = teamPark;
      const team: Team = {
        id, city: c.city, name: c.name, abbr: c.level === "ML" ? def.abbr : `${def.abbr}${c.level}`,
        level: c.level, parentId: c.level === "ML" ? undefined : mlId, factionId: fid, parkId: teamPark.id,
        managerId: npc("manager", fid).id, roster: [], il: [],
      };
      world.teams[id] = team;
      const positions: Pos[] = ["C", "C", "1B", "1B", "2B", "SS", "SS", "3B", "LF", "CF", "CF", "RF", "3B"];
      for (const pos of positions) addPlayer(team, pos);
      for (let i = 0; i < 13; i++) addPlayer(team, "P", i < 6 ? "SP" : "RP");
    }
  }

  function addPlayer(team: Team, pos: Pos, role?: "SP" | "RP") {
    const lv = team.level;
    const mean = LEVEL_MEAN[lv] + rng.normal(0, 3);
    const [a0, a1] = LEVEL_AGE[lv];
    const age = a0 + rng.int(a1 - a0 + 1);
    const n = name();
    const { throws, bats } = handsFor(rng, pos);
    const potential = clamp(mean + Math.max(0, 28 - age) * rng.range(0.5, 2.2) + rng.normal(0, 4));
    const p: Player = {
      id: nextId(world, "p"), kind: "player", ...n, sex: "M", face: pickFace(world, "M", age, rng), age, born: world.year - age,
      traits: randomTraits(rng, rng.chance(0.35) ? 2 : 1),
      mood: 0, bats, throws, pos, teamId: team.id,
      family: { house: newHouseId(world, n.last), parents: [], children: [], drama: [] }, active: true,
      batting: battingFor(rng, pos, mean), fielding: fieldingFor(rng, pos, mean),
      potential, talent: potential,
      recentPitches: [0, 0, 0, 0, 0],
    };
    if (rng.chance(0.18)) p.nickname = rng.pick(NICKS);
    if (pos === "P") {
      p.pitching = pitchingFor(rng, mean, role ?? "RP", throws);
      // starters and relievers stay in their roster groups (see groupOf)
      p.pitching.stamina = role === "SP" ? Math.max(48, p.pitching.stamina) : Math.min(44, p.pitching.stamina);
    }
    p.peak = Math.round(value(p));
    p.contract = { years: 1 + rng.int(lv === "ML" ? 5 : 3), salary: salaryFor(p, lv) };
    if (lv === "ML") p.debut = { year: world.year - Math.max(0, Math.min(age - 22, rng.int(age - 21))), season: 0, teamId: team.id, gameId: "" };
    world.players[p.id] = p;
    team.roster.push(p.id);
    const h = ensureHouse(world, p.family.house, p);
    h.players++;
  }

  // --- relationships: grudges, loyalties, debts
  const playerIds = Object.keys(world.players);
  const fixer = world.factions.book.leaderId!;
  for (let i = 0; i < playerIds.length * 0.08; i++) {
    const a = world.players[rng.pick(playerIds)], b = world.players[rng.pick(playerIds)];
    if (a.id === b.id) continue;
    const grudge = rng.chance(0.6);
    world.relationships.push({
      a: a.id, b: b.id, value: grudge ? -(2 + rng.int(4)) : 2 + rng.int(4),
      reason: grudge ? rng.pick(GRUDGES) : rng.pick(BONDS),
    });
  }
  for (const id of playerIds) {
    const p = world.players[id];
    if (p.traits.includes("GAMBLER") && rng.chance(0.5)) {
      world.relationships.push({ a: id, b: fixer, value: -1, reason: `owes $${(1 + rng.int(9)) * 100}` });
    }
    if (p.traits.includes("LOYAL")) {
      const fid = world.teams[p.teamId].factionId;
      world.relationships.push({ a: id, b: world.factions[fid].leaderId!, value: 3 + rng.int(3), reason: rng.pick(LOYALTIES) });
    }
  }
  // faction rivalries
  const pairs: [string, string, number, string][] = [
    ["hcl", "sta", -5, "the Holy War"], ["sta", "mrl", -4, "doctrinal dispute"], ["hcl", "mil", 3, "trade partners"],
    ["mil", "elc", -3, "the furnace contract"], ["pem", "umps", -2, "a dock-side incident"], ["book", "commish", -4, "the obvious"],
    ["press", "hcl", 2, "Haldane buys ads"], ["csr", "pem", 1, "beef shipments"], ["ncg", "commish", 3, "old friends"],
  ];
  for (const [a, b, value, reason] of pairs) world.relationships.push({ a, b, value, reason } as Relationship);

  // --- families: retired stars and their sons, spouses, children, houses (own stream so ratings above stay put)
  seedFamilies(world, rng.fork("families"), usedNames);

  // --- the drama layer: friendships and mentors, goals and fears, fame, general managers
  const dr = rng.fork("drama");
  seedRelationships(world, dr);
  for (const p of Object.values(world.players)) { seedInnerLife(world, dr, p); p.fame = initialFame(world, dr, p); }
  for (const n of Object.values(world.npcs)) {
    if (isNotable(world, n)) seedInnerLife(world, dr, n);
    const f = initialFame(world, dr, n);
    if (f) n.fame = f;
  }
  for (const t of Object.values(world.teams)) if (t.level === "ML") hireGM(world, dr, t.id, []);

  // --- the Enhanced League out in the desert (own stream: Continental worlds are unchanged)
  seedEnhanced(world, rng.fork("enhanced"));

  // re-centre on the calibration worlds' major-league averages (see REFERENCE_NORMS)
  world.norms = { ...REFERENCE_NORMS };
  renormalise(world);
  for (const p of Object.values(world.players)) p.peak = Math.round(value(p));
  return world;
}

/** Salary in $k per year, by ability and level. */
export function salaryFor(p: Player, level: Level): number {
  const v = value(p);
  const base = level === "ML" ? 120 : level === "AA" ? 25 : level === "B" ? 12 : 8;
  return Math.round(base * Math.pow(1.09, Math.max(0, v - 40)));
}

function makeFarmPark(rng: Rng, teamId: string): Park {
  const lf = 310 + rng.int(40), cf = 385 + rng.int(40), rf = 310 + rng.int(40);
  return {
    id: `park-${teamId}`, name: "Municipal Field",
    fences: [lf, Math.round((lf + cf) / 2) + 8, cf, Math.round((rf + cf) / 2) + 8, rf],
    walls: [10, 10, 10, 10, 10], altitudeFt: rng.int(1500), foulTerritory: 40 + rng.int(40), turf: false,
  };
}

const GRUDGES = [
  "beaned him in the spring", "stole his girl", "stole his locker", "called him a bum in print", "spiked him at second",
  "owes him $50", "ratted on his card game", "took his starting job", "insulted his mother's pie", "sat on his hat",
];
const BONDS = ["childhood friends", "roomed together in the minors", "same hometown", "saved his life (fishing)", "drinking buddies", "godfather to his kid"];
const LOYALTIES = ["paid his mom's rent", "signed him out of a church league", "kept him out of jail", "gave him a second chance"];
