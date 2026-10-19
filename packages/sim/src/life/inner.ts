// Inner life: goals, fears, concerns ("on their mind") and fame.

import type { Rng } from "../rng.ts";
import type { Concern, Fear, FearKind, Goal, GoalKind, Npc, Person, Player, World } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { BEHAVIOUR_QUIRKS, hasQ, hasT, personById, randomNick } from "./people.ts";
import { value } from "./ratings.ts";

type PK = Person & { kind?: "player" | "npc" };

// --- concerns ---------------------------------------------------------------------------------

export function addConcern(world: World, p: Person, c: Omit<Concern, "since"> & { since?: number }) {
  const list = (p.concerns ??= []);
  const i = list.findIndex(x => x.kind === c.kind && x.about === c.about);
  const full: Concern = { since: world.day, ...c };
  if (i >= 0) list[i] = full;
  else list.push(full);
  if (list.length > 5) {
    list.sort((a, b) => Math.abs(b.weight) - Math.abs(a.weight));
    list.length = 5;
  }
}

export function dropConcern(p: Person, kind: Concern["kind"], about?: string) {
  if (!p.concerns) return;
  p.concerns = p.concerns.filter(c => !(c.kind === kind && (about === undefined || c.about === about)));
}

export function concernPressure(world: World, p: Person): number {
  let v = 0;
  for (const c of p.concerns ?? []) if (c.until >= world.day) v += c.weight;
  return v;
}

export function pruneConcerns(world: World, p: Person) {
  if (p.concerns?.length) p.concerns = p.concerns.filter(c => c.until >= world.day);
}

// --- goals & fears -------------------------------------------------------------------------------

const FEAR_WEIGHTS: [FearKind, number][] = [
  ["aging", 2], ["being_traded", 2], ["flying", 2], ["the_dark", 1], ["failure", 2], ["pitcher", 1.5], ["birds", 1],
  ["crowds", 1], ["the_press", 1], ["injury", 1.5], ["ghosts", 0.6],
];

const armCache = new WeakMap<World, { day: number; ids: string[] }>();
function topArms(world: World): string[] {
  const c = armCache.get(world);
  if (c && c.day === world.day) return c.ids;
  const ids = Object.values(world.players).filter(q => q.pos === "P" && world.teams[q.teamId]?.level === "ML").sort((a, b) => value(b) - value(a)).slice(0, 12).map(q => q.id);
  armCache.set(world, { day: world.day, ids });
  return ids;
}

export function pickFear(world: World, rng: Rng, p: Person): Fear {
  let kind = rng.weighted(FEAR_WEIGHTS, x => x[1] * (x[0] === "failure" && hasT(p, "CHOKER") ? 4 : 1) * (x[0] === "ghosts" && hasT(p, "SUPERSTITIOUS") ? 5 : 1) *
    (x[0] === "being_traded" && hasT(p, "PARANOID") ? 4 : 1) * (x[0] === "injury" && hasT(p, "FRAGILE") ? 4 : 1) * (x[0] === "aging" && p.age < 28 ? 0.2 : 1))[0];
  const f: Fear = { kind, strength: 1 + rng.int(3) };
  if (kind === "pitcher") {
    // one of the league's best arms
    const arms = topArms(world).filter(id => id !== p.id);
    if (arms.length) f.target = rng.pick(arms);
    else kind = f.kind = "failure";
  }
  return f;
}

const GOAL_NOTE: Record<GoalKind, string> = {
  win_title: "win a title", big_contract: "land a big contract", make_majors: "make the majors", revenge: "get even",
  beat_record: "break a record", become_manager: "manage a club", marry: "get married", get_out: "get out of town",
  buy_club: "buy a ballclub", be_famous: "be famous", comeback: "come back", keep_job: "keep his job",
};
export const goalNote = (g: Goal) => GOAL_NOTE[g.kind];

/** Pick a fresh goal suited to this person's situation and character. */
export function pickGoal(world: World, rng: Rng, p: Person): Goal {
  const pl = (p as PK).kind === "player" ? (p as Player) : undefined;
  const npc = (p as PK).kind === "npc" ? (p as Npc) : undefined;
  const lv = pl ? world.teams[pl.teamId]?.level : undefined;
  const w: [GoalKind, number][] = [];
  if (pl) {
    if (lv && lv !== "ML" && lv !== "EL") w.push(["make_majors", 6]);
    w.push(["win_title", hasT(p, "LOYAL") ? 4 : 2]);
    w.push(["big_contract", hasT(p, "GREEDY") ? 5 : 1.5]);
    if (lv === "ML" && value(pl) >= 56) w.push(["beat_record", 2]);
    w.push(["be_famous", hasQ(p, "VAIN") || hasT(p, "SHOWBOAT") ? 4 : 0.5]);
    if (p.age >= 31) w.push(["become_manager", 1.5]);
    if (!p.family.spouse && p.age >= 22) w.push(["marry", 1]);
  } else if (npc) {
    if (npc.role === "owner") w.push(["win_title", 4], ["revenge", 2]);
    else if (npc.role === "manager" || npc.role === "gm") w.push(["keep_job", 3], ["win_title", 3]);
    else if (npc.career) w.push(["become_manager", 2], ["buy_club", 1], ["be_famous", 0.5]);
    else w.push(["marry", 1], ["get_out", 1], ["be_famous", 0.5]);
  }
  if (!w.length) w.push(["win_title", 1]);
  const kind = rng.weighted(w, x => x[1])[0];
  const g: Goal = { kind, since: world.day, intensity: 1 + (rng.chance(0.3) ? 1 : 0) };
  if (kind === "revenge" && npc?.role === "owner") {
    // owners want to humble a rival faction
    const rival = world.relationships.filter(r => (r.a === npc.factionId || r.b === npc.factionId) && r.value < 0 && world.factions[r.a] && world.factions[r.b]);
    if (rival.length) { const r = rng.pick(rival); g.target = r.a === npc.factionId ? r.b : r.a; } else g.kind = "win_title";
  }
  if (kind === "marry") {
    // a sweetheart: someone single in the right age range (sampled, not scanned)
    const ids = Object.keys(world.npcs);
    for (let i = 0; i < 25 && ids.length; i++) {
      const n = world.npcs[ids[rng.int(ids.length)]];
      if (n.sex !== p.sex && !n.family.spouse && n.role === "citizen" && Math.abs(n.age - p.age) <= 6 && n.age >= 19) { g.target = n.id; break; }
    }
  }
  g.note = GOAL_NOTE[g.kind];
  return g;
}

/** Give a person goals, a fear and (rarely) a behaviour quirk, if they have none yet. */
export function seedInnerLife(world: World, rng: Rng, p: Person) {
  if (!p.goals?.length) p.goals = [pickGoal(world, rng, p)];
  if (!p.fears?.length && ((p as PK).kind === "player" || rng.chance(0.5))) p.fears = [pickFear(world, rng, p)];
  if (!p.quirks && rng.chance(0.3)) p.quirks = [rng.pick(BEHAVIOUR_QUIRKS)];
  p.concerns ??= [];
}

export function setGoal(world: World, p: Person, g: Goal) {
  p.goals = [...(p.goals ?? []).filter(x => x.kind !== g.kind), g].slice(-2);
}

/** Mark a goal achieved (and pick a new one). */
export function achieveGoal(world: World, rng: Rng, p: Person, kind: GoalKind, events: LifeEvent[], how: string, target?: string) {
  const g = p.goals?.find(x => x.kind === kind && (target === undefined || x.target === undefined || x.target === target));
  if (!g) return;
  p.goals = p.goals!.filter(x => x !== g);
  const pl = p as Player;
  events.push(mkEvent(world, "goal", [p.id, ...(g.target && personById(world, g.target) ? [g.target] : [])], pl.teamId ? [pl.teamId] : [], {
    sub: "achieved", goal: g.kind, note: GOAL_NOTE[g.kind], how, target: g.target, intensity: g.intensity, yearsWanted: Math.round((world.day - g.since) / 180),
  }));
  p.mood = Math.min(5, p.mood + 1 + g.intensity * 0.5);
  if (p.goals.length < 2) p.goals.push(pickGoal(world, rng, p));
}

export function goalOf(p: Person, kind: GoalKind): Goal | undefined {
  return p.goals?.find(g => g.kind === kind);
}

/** Mood pull of a person's fears and obsessions in their current situation. */
export function innerPressure(world: World, p: Person, ctx: { deadline?: boolean } = {}): number {
  let v = 0;
  for (const f of p.fears ?? []) {
    if (f.kind === "aging" && p.age >= 32) v -= 0.25 * f.strength;
    if (f.kind === "being_traded" && ctx.deadline) v -= 0.3 * f.strength;
    if (f.kind === "the_press" && (p.fame ?? 0) >= 50) v -= 0.2 * f.strength;
  }
  for (const g of p.goals ?? []) if (g.intensity >= 3) v -= 0.4;
  return v;
}

// --- fame -----------------------------------------------------------------------------------

export const fameOf = (p: Person | undefined) => p?.fame ?? 0;

const FAME_TIERS: [number, string][] = [[25, "local favourite"], [50, "fan club"], [75, "household name"], [90, "national icon"]];
const NICKS_FAMOUS = ["the Hammer", "Sweet Lou", "the Professor", "Big Smoke", "the Comet", "Thunder", "the Duke of Dingers", "Ice Water", "the Mailman", "Lightning", "the Iceman", "Pops", "the Butcher", "Silk", "the Natural"];

/** Add fame (scaled for SHOWBOAT/VAIN), emitting tier and nickname events. */
export function gainFame(world: World, rng: Rng, p: Person, amount: number, events: LifeEvent[], why: string) {
  if (amount === 0) return;
  const before = p.fame ?? 0;
  const mult = amount > 0 ? (hasT(p, "SHOWBOAT") ? 1.4 : 1) * (hasQ(p, "VAIN") ? 1.2 : 1) * (hasQ(p, "LONER") ? 0.7 : 1) : 1;
  // diminishing returns near the top
  const delta = amount > 0 ? amount * mult * (1 - before / 115) : amount;
  const after = Math.max(0, Math.min(100, before + delta));
  p.fame = Math.round(after * 10) / 10;
  const pl = p as Player;
  for (const [t, label] of FAME_TIERS) {
    if (before < t && after >= t) {
      events.push(mkEvent(world, "fame", [p.id], pl.teamId ? [pl.teamId] : [], { sub: "tier", tier: label, fame: Math.round(after), why }));
    }
  }
  if (before < 35 && after >= 35 && !p.nickname && (p as PK).kind === "player") {
    p.nickname = rng.chance(0.5) ? rng.pick(NICKS_FAMOUS) : randomNick(rng, p.sex);
    events.push(mkEvent(world, "fame", [p.id], [pl.teamId], { sub: "nickname", nickname: p.nickname, why }));
  }
}

/** Daily: fame drifts back toward a floor set by where they play. */
export function decayFame(world: World, p: Person) {
  if (!p.fame) return;
  const pl = p as Player;
  const floor = (p as PK).kind === "player" ? (world.teams[pl.teamId]?.level === "ML" ? 6 : 1) : p.career ? Math.min(30, (p.career.peak - 45) * 1.5) : 0;
  if (p.fame > floor) p.fame = Math.round((p.fame - (p.fame - floor) * 0.004) * 100) / 100;
}

/** Initial fame from ability, age and level. */
export function initialFame(world: World, rng: Rng, p: Person): number {
  if ((p as PK).kind === "player") {
    const pl = p as Player;
    const lv = world.teams[pl.teamId]?.level;
    if (lv !== "ML") return Math.round(rng.range(0, 6));
    return Math.round(Math.max(2, Math.min(85, (value(pl) - 45) * 3 + (p.age - 22) * 1.5 + rng.range(0, 12))));
  }
  const n = p as Npc;
  if (n.career) return Math.round(Math.max(5, Math.min(80, (n.career.peak - 50) * 3 + rng.range(0, 10))));
  if (n.role === "owner") return Math.round(30 + rng.range(0, 30));
  if (n.role === "manager") return Math.round(15 + rng.range(0, 25));
  if (n.role === "reporter" || n.role === "fixer" || n.role === "official") return Math.round(10 + rng.range(0, 30));
  return 0;
}
