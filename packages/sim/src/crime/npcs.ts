// Citizen NPC factory for crew candidates. Kept in one place so it is easy to update
// when the Person type grows fields (the life agent owns types.ts).

import { Rng } from "../rng.ts";
import { FACES } from "../faces.ts";
import { FIRST, LAST, NICKS } from "../names.ts";
import type { Npc, Trait, World } from "../types.ts";
import type { CrewSkill } from "./types.ts";

export interface RoleDef {
  key: string;
  label: string;
  /** Base skills before noise (0..5). */
  base: Partial<Record<CrewSkill, number>>;
  /** "F", "M", or a probability of F. */
  sex: "F" | "M" | number;
  age: [number, number];
  /** Op kinds this role is especially good at (+success). */
  affinity: string[];
  nicks?: string[];
  firstF?: string[];
  /** BBS self-descriptions; {name} is filled in. */
  pitches: string[];
  /** Traits this role tends to have. */
  traits?: Trait[];
  /** Name prefix like "Sister". */
  title?: string;
}

const F_FIRST = [
  "Agnes", "Mae", "Dot", "Hattie", "Edna", "Lorraine", "Peg", "Ruth", "Velma", "Opal", "Irma", "Lucille", "Bea",
  "Gert", "Rosa", "Consuelo", "Mabel", "Nell", "Ida", "Winnie", "Yoshiko", "Dolores", "Marisol", "Ethel", "Fern",
];

export const ROLES: RoleDef[] = [
  { key: "organist", label: "church organist", base: { charm: 3, access: 2, nerve: 2, sneak: 2 }, sex: 0.5, age: [40, 75],
    affinity: ["heckle", "tip_wire"], traits: ["PIOUS", "SUPERSTITIOUS"],
    pitches: ["Plays the organ at St. Jude's and at the ballpark on Sundays. Has keys to both.", "Has played the seventh-inning stretch for 22 years. Has never missed a game."] },
  { key: "hotdog", label: "hot dog vendor", base: { access: 3, muscle: 2, charm: 2 }, sex: 0.2, age: [22, 60],
    affinity: ["cooler", "rabbit_balls"], nicks: ["Hot Dog", "Mustard", "Relish"],
    pitches: ["Works aisles 100 through 140. Nobody looks at the hot dog man.", "Currently on bail. The charge involves eels."] },
  { key: "groundskeeper", label: "groundskeeper", base: { access: 4, knowhow: 2, muscle: 2 }, sex: 0.15, age: [30, 70],
    affinity: ["grease_mound", "sprinklers"], nicks: ["Rake", "Tarp", "Mulch"],
    pitches: ["Thirty-one years on the grounds crew. Knows where every valve is.", "Has a key to the equipment shed and the umpires' room."] },
  { key: "nun", label: "nun", base: { charm: 3, nerve: 3, sneak: 2 }, sex: "F", age: [28, 80], title: "Sister",
    affinity: ["laser", "heckle", "love_letter"], traits: ["PIOUS"],
    pitches: ["Nobody searches a nun.", "Took a vow of poverty in 1961. Would like to revisit it."] },
  { key: "explayer", label: "disgraced ex-player", base: { knowhow: 3, nerve: 2, charm: 2 }, sex: "M", age: [34, 70],
    affinity: ["steal_signs", "lucky_glove", "bribe_ump"], nicks: ["Lefty", "Pops", "Slats"], traits: ["DRUNK", "GAMBLER"],
    pitches: ["Banned for life in 1971. Still knows the Grays' signs.", "Can read a pitcher's grip from the parking lot. Has done it."] },
  { key: "cop", label: "off-duty cop", base: { muscle: 3, nerve: 3, access: 2 }, sex: 0.2, age: [28, 58],
    affinity: ["blackmail", "kidnap_mascot"], nicks: ["Sarge", "Badge"], traits: ["CROOKED"],
    pitches: ["Works nights at the 9th Precinct. Available days.", "Knows the desk sergeant. Knows the desk sergeant's wife."] },
  { key: "electrician", label: "stadium electrician", base: { knowhow: 4, access: 3 }, sex: 0.1, age: [25, 65],
    affinity: ["blackout", "laser"], nicks: ["Sparky", "Volts"],
    pitches: ["Wired the light towers at three ballparks.", "Has been shocked eleven times. Reports no lasting effects."] },
  { key: "batboy", label: "bat boy (now 41)", base: { access: 3, sneak: 3 }, sex: "M", age: [30, 50],
    affinity: ["lucky_glove", "rabbit_balls", "steal_signs"], nicks: ["Kid", "Junior"],
    pitches: ["Was a bat boy in 1968. Never stopped coming to the clubhouse. Nobody has asked him to leave.", "Still answers to Kid."] },
  { key: "typist", label: "typist", base: { knowhow: 3, sneak: 2, charm: 1 }, sex: 0.7, age: [20, 65],
    affinity: ["love_letter", "tip_wire", "blackmail"],
    pitches: ["Types 110 words a minute. Can sign anybody's name.", "Owns three typewriters. Each has a different letter e."] },
  { key: "wrangler", label: "raccoon wrangler", base: { knowhow: 3, nerve: 3, sneak: 2 }, sex: 0.35, age: [25, 70],
    affinity: ["raccoons", "kidnap_mascot"], nicks: ["Bandit", "Trash King", "Ringtail"],
    pitches: ["Keeps forty raccoons in a former laundromat on Sixth Street.", "The raccoons know him. He feeds them at 6 a.m."] },
  { key: "usher", label: "usher", base: { access: 3, charm: 2, muscle: 1 }, sex: 0.4, age: [18, 75],
    affinity: ["heckle", "laser"],
    pitches: ["Knows every seat with a sightline to home plate.", "Has removed the mayor from the stadium twice."] },
  { key: "plumber", label: "plumber", base: { knowhow: 3, access: 2, muscle: 2 }, sex: 0.1, age: [25, 65],
    affinity: ["sprinklers", "cooler"], nicks: ["Pipes", "Drip"],
    pitches: ["Knows the valves at every park in the league.", "Charges by the hour. Floods by the acre."] },
  { key: "reporter", label: "fired beat reporter", base: { charm: 3, knowhow: 2, sneak: 1 }, sex: 0.35, age: [28, 68],
    affinity: ["tip_wire", "blackmail"], traits: ["SNITCH"], nicks: ["Scoop", "Deadline"],
    pitches: ["Has a SportsWire press pass. It expired in 1987. Nobody checks it.", "Will write anything for $40 and a sandwich."] },
  { key: "strongman", label: "carnival strongman", base: { muscle: 5, nerve: 2 }, sex: 0.1, age: [22, 55],
    affinity: ["kidnap_mascot", "heckle"], nicks: ["Tiny", "Anvil", "The Ox"],
    pitches: ["Can lift a mascot over his head. Has done it twice.", "Bends horseshoes for county fairs."] },
  { key: "fortune", label: "fortune teller", base: { charm: 4, sneak: 1, nerve: 1 }, sex: 0.75, age: [30, 85],
    affinity: ["lucky_glove", "love_letter"], title: "Madame",
    pitches: ["Reads palms, tea leaves and box scores. $20 a session.", "Told a closer he would blow a save. He blew it."] },
  { key: "cabbie", label: "cab driver", base: { sneak: 2, nerve: 3, muscle: 1 }, sex: 0.2, age: [22, 70],
    affinity: ["kidnap_mascot", "raccoons"], nicks: ["Wheels", "Meter"],
    pitches: ["Has a trunk that holds a mascot and two raccoons.", "Knows every alley between here and the county line."] },
  { key: "exump", label: "retired umpire", base: { knowhow: 3, charm: 2, access: 2 }, sex: "M", age: [55, 82],
    affinity: ["bribe_ump", "steal_signs"], traits: ["GREEDY"], nicks: ["Blue", "Squints"],
    pitches: ["Forty years behind the plate. Knows which umpires have boat payments.", "Still has his mask. Wears it to church."] },
  { key: "choirboy", label: "choir boy (big for his age)", base: { sneak: 3, charm: 2 }, sex: "M", age: [16, 19],
    affinity: ["laser", "rabbit_balls"],
    pitches: ["Sings in the St. Jude's choir. Has fast hands.", "Has never been caught. Has never been asked."] },
];

/** Late-90s asides tacked onto BBS pitches now and then. */
export const ERA_ASIDES = [
  "Reachable by pager. Do not call the house.",
  "Has a fax machine.",
  "Not available December 31, 1999.",
  "Has a car phone.",
  "Keeps notes on VHS tapes, labeled by date.",
  "Not available Thursday nights.",
  "Will accept payment in Beanie Babies.",
];

const ROLE_BY_KEY: Record<string, RoleDef> = Object.fromEntries(ROLES.map(r => [r.key, r]));
export const roleDef = (key: string | undefined): RoleDef | undefined => (key ? ROLE_BY_KEY[key] : undefined);

/** Faces already tied to someone in the world, so new citizens get fresh ones. */
function usedFaces(world: World): Set<string> {
  const s = new Set<string>();
  for (const p of Object.values(world.players)) s.add(p.face);
  for (const p of Object.values(world.npcs)) s.add(p.face);
  return s;
}

function pickFace(rng: Rng, sex: "M" | "F", age: number, used: Set<string>): string {
  const bucket = age < 30 ? "young" : age < 55 ? "adult" : "old";
  const fresh = FACES.filter(f => !used.has(f.id));
  const pool = fresh.length ? fresh : FACES;
  const exact = pool.filter(f => f.sex === sex && f.age === bucket);
  const sameSex = pool.filter(f => f.sex === sex);
  const choice = exact.length ? rng.pick(exact) : sameSex.length ? rng.pick(sameSex) : rng.pick(pool);
  used.add(choice.id);
  return choice.id;
}

/**
 * Build a citizen NPC for a crew role. Does not store it in the world.
 * Person gains `sex` (life agent); we attach it without depending on the current type.
 */
export function makeCitizen(world: World, role: RoleDef, id: string, rng: Rng, used = usedFaces(world)): Npc {
  const sex: "M" | "F" = role.sex === "F" ? "F" : role.sex === "M" ? "M" : rng.chance(role.sex) ? "F" : "M";
  const age = role.age[0] + rng.int(role.age[1] - role.age[0] + 1);
  const first = sex === "F" ? rng.pick(F_FIRST) : rng.pick(FIRST);
  const last = rng.pick(LAST);
  const traits: Trait[] = [];
  if (role.traits && rng.chance(0.5)) traits.push(rng.pick(role.traits));
  const extra: Trait[] = ["SNITCH", "LOYAL", "DRUNK", "GREEDY", "CHARMING", "HOTHEAD", "PARANOID", "CROOKED", "SUPERSTITIOUS", "GAMBLER"];
  if (rng.chance(0.6)) {
    const t = rng.pick(extra);
    if (!traits.includes(t)) traits.push(t);
  }
  if (traits.includes("LOYAL") && traits.includes("SNITCH")) traits.splice(traits.indexOf("SNITCH"), 1);
  const core: Omit<Npc, "sex"> = {
    id, kind: "npc", role: "citizen", first, last, face: pickFace(rng, sex, age, used), age, traits, mood: 0,
    stats: {}, family: { house: last, parents: [], children: [], drama: [] }, active: true,
  };
  const p = Object.assign(core, { sex }) as Npc;
  if (role.nicks && rng.chance(0.4)) p.nickname = rng.pick(role.nicks);
  else if (rng.chance(0.08)) p.nickname = rng.pick(NICKS);
  return p;
}

/** "Sister Agnes", "Hot Dog Hal", "Moose Dunphy". */
export function citizenName(p: { first: string; last: string; nickname?: string }, role?: RoleDef): string {
  if (role?.title) return `${role.title} ${p.first}`;
  if (p.nickname === "Hot Dog") return `Hot Dog ${p.first}`;
  if (p.nickname) return `"${p.nickname}" ${p.last}`;
  return `${p.first} ${p.last}`;
}
