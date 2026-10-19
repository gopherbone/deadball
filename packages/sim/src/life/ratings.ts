// Rating generation, player value and year-to-year development.

import type { Rng } from "../rng.ts";
import type { BattingRatings, FieldingRatings, Pitch, PitchKind, PitchingRatings, Player, Pos, Trait, World } from "../types.ts";

export const clamp = (x: number) => Math.round(Math.max(20, Math.min(80, x)));

export const TRAITS: Trait[] = [
  "HOTHEAD", "LOYAL", "SUPERSTITIOUS", "GAMBLER", "DRUNK", "CLUTCH", "CHOKER", "GREEDY", "PIOUS", "SHOWBOAT",
  "GRINDER", "LAZY", "PARANOID", "IRON_MAN", "FRAGILE", "CHARMING", "CROOKED", "SNITCH",
];

/** Drop mutually exclusive trait pairs. */
export function fixTraits(t: Iterable<Trait>): Trait[] {
  const out = new Set(t);
  if (out.has("CLUTCH") && out.has("CHOKER")) out.delete("CHOKER");
  if (out.has("IRON_MAN") && out.has("FRAGILE")) out.delete("FRAGILE");
  if (out.has("LOYAL") && out.has("SNITCH")) out.delete("SNITCH");
  if (out.has("GRINDER") && out.has("LAZY")) out.delete("LAZY");
  return [...out];
}

export function randomTraits(rng: Rng, n: number): Trait[] {
  const out = new Set<Trait>();
  while (out.size < n) out.add(rng.pick(TRAITS));
  return fixTraits(out);
}

export function battingFor(rng: Rng, pos: Pos, mean: number): BattingRatings {
  if (pos === "P") {
    return { contact: 25, power: 22, eye: 25, gap: 25, lift: 45, pull: 50, speed: clamp(rng.normal(40, 8)), baserunning: 35, vsL: 0 };
  }
  const bias: Partial<Record<Pos, Partial<Record<keyof BattingRatings, number>>>> = {
    C: { power: -2, contact: -3, speed: -10 },
    "1B": { power: 6, speed: -8, contact: 1 },
    SS: { power: -5, speed: 5, contact: 0 },
    "2B": { power: -4, speed: 4 },
    CF: { speed: 9, power: -2 },
    "3B": { power: 3 },
    LF: { power: 3 },
    RF: { power: 4 },
  };
  const b = bias[pos] ?? {};
  const g = (k: keyof BattingRatings, sd = 9) => clamp(rng.normal(mean + (b[k] ?? 0), sd));
  const power = g("power", 10);
  return {
    contact: g("contact"), power, eye: g("eye"), gap: g("gap"),
    lift: clamp(rng.normal(48 + (power - 50) * 0.4, 9)), pull: clamp(rng.normal(50 + (power - 50) * 0.3, 10)),
    speed: g("speed", 10), baserunning: g("baserunning"), vsL: Math.round(rng.normal(0, 3)),
  };
}

export function fieldingFor(rng: Rng, pos: Pos, mean: number): FieldingRatings {
  const g = (d = 0, sd = 9) => clamp(rng.normal(mean + d, sd));
  const positions: FieldingRatings["positions"] = { [pos]: 1 };
  const neighbors: Partial<Record<Pos, Pos[]>> = {
    SS: ["2B", "3B"], "2B": ["SS", "1B"], "3B": ["1B", "SS"], CF: ["LF", "RF"], LF: ["RF", "1B"], RF: ["LF", "1B"], "1B": ["LF"], C: ["1B"],
  };
  for (const n of neighbors[pos] ?? []) positions[n] = Math.round(rng.range(0.5, 0.9) * 100) / 100;
  if (pos === "P") return { range: g(-5), hands: g(-5), arm: g(5), accuracy: g(), reaction: g(), framing: 50, positions };
  return {
    range: g(pos === "SS" || pos === "CF" ? 6 : pos === "1B" ? -8 : 0),
    hands: g(), arm: g(pos === "RF" || pos === "SS" || pos === "3B" || pos === "C" ? 5 : pos === "1B" ? -6 : 0),
    accuracy: g(), reaction: g(), framing: pos === "C" ? g(0, 12) : 50, positions,
  };
}

export function pitchingFor(rng: Rng, mean: number, role: "SP" | "RP", throws: "L" | "R"): PitchingRatings {
  const g = (d = 0, sd = 9) => clamp(rng.normal(mean + d, sd));
  const velo = 92.5 + (mean - 50) * 0.15 + rng.normal(0, 2) + (role === "RP" ? 1.2 : 0) - (throws === "L" ? 1.2 : 0);
  const groundball = g(0, 12);
  const repertoire: PitchKind[] = [groundball > 58 ? "SI" : "FB"];
  const extras: PitchKind[] = rng.shuffle(["SL", "CB", "CH", "CT", "SPL"] as PitchKind[]);
  const nExtra = role === "SP" ? 3 : 1 + rng.int(2);
  repertoire.push(...extras.slice(0, nExtra));
  if (rng.chance(0.04)) repertoire.push(rng.pick(["KN", "SPIT"] as PitchKind[]));
  const pitches: Pitch[] = repertoire.map((kind, i) => ({
    kind,
    quality: g(0, 10),
    velo: Math.round((kind === "FB" || kind === "SI" ? velo : kind === "CT" ? velo - 4 : kind === "SL" ? velo - 8 : kind === "CB" ? velo - 13 : kind === "KN" ? 70 : velo - 9) * 10) / 10,
    usage: i === 0 ? 0.5 : 0.5 / (repertoire.length - 1),
  }));
  return {
    stuff: g(role === "RP" ? 2 : 0), control: g(), command: g(), movement: g(), groundball,
    stamina: role === "SP" ? clamp(rng.normal(60, 7)) : clamp(rng.normal(32, 6)),
    hold: g(), pitches,
  };
}

export function handsFor(rng: Rng, pos: Pos): { throws: "L" | "R"; bats: "L" | "R" | "S" } {
  const throws = rng.chance(pos === "P" ? 0.3 : pos === "1B" || pos === "LF" || pos === "RF" ? 0.2 : 0.06) ? "L" : "R";
  const batsRoll = rng.float();
  const bats = throws === "L" ? (batsRoll < 0.85 ? "L" : "S") : batsRoll < 0.68 ? "R" : batsRoll < 0.9 ? "L" : "S";
  return { throws, bats };
}

// --- roster groups ----------------------------------------------------------------

export type Group = "C" | "IF" | "OF" | "SP" | "RP";
export const GROUPS: Group[] = ["C", "IF", "OF", "SP", "RP"];
/** Every 26-man roster: 13 position players (2 C, 7 IF, 4 OF) and 13 pitchers (6 SP, 7 RP). */
export const TEMPLATE: Record<Group, number> = { C: 2, IF: 7, OF: 4, SP: 6, RP: 7 };
export const GROUP_POS: Record<Group, Pos[]> = { C: ["C"], IF: ["1B", "2B", "SS", "3B", "1B", "SS", "3B"], OF: ["LF", "CF", "RF", "CF"], SP: ["P"], RP: ["P"] };

export function groupOf(p: Player): Group {
  if (p.pos === "P") return (p.pitching?.stamina ?? 30) >= 46 ? "SP" : "RP";
  if (p.pos === "C") return "C";
  if (p.pos === "LF" || p.pos === "CF" || p.pos === "RF") return "OF";
  return "IF";
}

/** Current overall ability on the 20–80 scale (≈ the generation mean). */
export function value(p: Player): number {
  if (p.pos === "P" && p.pitching) {
    const r = p.pitching;
    return r.stuff * 0.4 + r.control * 0.25 + r.command * 0.15 + r.movement * 0.2;
  }
  const b = p.batting, f = p.fielding;
  const off = b.contact * 0.32 + b.power * 0.3 + b.eye * 0.22 + b.gap * 0.08 + b.speed * 0.08;
  const def = p.pos === "C" ? (f.arm + f.hands + f.framing * 2) / 4 : (f.range + f.hands + f.arm + f.reaction) / 4;
  return off * 0.8 + def * 0.2;
}

// --- development --------------------------------------------------------------------

const BAT_KEYS = ["contact", "power", "eye", "gap", "speed", "baserunning"] as const;
const FIELD_KEYS = ["range", "hands", "arm", "accuracy", "reaction"] as const;
const PITCH_KEYS = ["stuff", "control", "command", "movement", "hold"] as const;

/** Expected change in overall rating over one winter for this player. */
export function devDelta(p: Player, rng: Rng): number {
  const v = value(p), age = p.age;
  let d: number;
  if (age <= 27) {
    const gap = Math.max(0, p.potential - v);
    d = gap * (age <= 22 ? 0.3 : age <= 25 ? 0.25 : 0.18);
  } else if (age <= 30) d = 0;
  else d = -(age - 30) * 0.7 - (age >= 35 ? 1.5 : 0);
  if (p.traits.includes("GRINDER")) d += age <= 27 ? 1 : 0.8;
  if (p.traits.includes("LAZY")) d -= age <= 27 ? 1.2 : 1;
  if (p.traits.includes("IRON_MAN") && age > 30) d += 0.6;
  if (p.traits.includes("DRUNK") && age > 28) d -= 0.6;
  return d + rng.normal(0, 1.8);
}

/** Apply a development delta to every rating (with per-rating noise). */
export function develop(p: Player, delta: number, rng: Rng) {
  const ageSpeed = p.age > 27 ? -0.4 * (p.age - 27) * 0.5 : 0;
  if (p.pos === "P" && p.pitching) {
    const r = p.pitching;
    for (const k of PITCH_KEYS) r[k] = clamp(r[k] + delta + rng.normal(0, 1));
    for (const pi of r.pitches) {
      pi.quality = clamp(pi.quality + delta + rng.normal(0, 1));
      pi.velo = Math.round((pi.velo + delta * 0.12 + (p.age > 31 ? -0.3 : 0)) * 10) / 10;
    }
    if (p.age > 32) r.stamina = clamp(r.stamina - rng.range(0, 1.5));
  } else {
    const b = p.batting;
    for (const k of BAT_KEYS) b[k] = clamp(b[k] + delta + rng.normal(0, 1) + (k === "speed" ? ageSpeed : 0));
  }
  const f = p.fielding;
  for (const k of FIELD_KEYS) f[k] = clamp(f[k] + delta * 0.6 + rng.normal(0, 0.8) + (k === "range" || k === "reaction" ? ageSpeed * 0.5 : 0));
  if (p.pos === "C") f.framing = clamp(f.framing + delta * 0.5 + rng.normal(0, 0.8));
  p.peak = Math.max(p.peak ?? 0, Math.round(value(p)));
}

// --- league-wide normalisation --------------------------------------------------------

const NORM_BAT = ["contact", "power", "eye", "gap", "speed"] as const;
const NORM_PIT = ["stuff", "control", "command", "movement"] as const;

/** Mean ratings of major-league regulars, used to keep the league calibrated over decades. */
export function measureNorms(world: World): Record<string, number> {
  const acc: Record<string, [number, number]> = {};
  const add = (k: string, v: number) => { const a = acc[k] ?? (acc[k] = [0, 0]); a[0] += v; a[1]++; };
  for (const t of Object.values(world.teams)) {
    if (t.level !== "ML") continue;
    for (const id of t.roster) {
      const p = world.players[id];
      if (!p) continue;
      if (p.pos === "P" && p.pitching) {
        for (const k of NORM_PIT) add(`p.${k}`, p.pitching[k]);
        add("p.quality", p.pitching.pitches.reduce((a, x) => a + x.quality, 0) / p.pitching.pitches.length);
      } else {
        for (const k of NORM_BAT) add(`b.${k}`, p.batting[k]);
        for (const k of FIELD_KEYS) add(`f.${k}`, p.fielding[k]);
      }
    }
  }
  return Object.fromEntries(Object.entries(acc).map(([k, [s, n]]) => [k, s / n]));
}

/**
 * Shift every player's ratings so major-league averages return to the world's original
 * norms. Real leagues are relative: if this year's kids are better, everyone else looks worse.
 */
export function renormalise(world: World) {
  const now = measureNorms(world);
  const shift: Record<string, number> = {};
  for (const [k, target] of Object.entries(world.norms)) if (now[k] !== undefined) shift[k] = target - now[k];
  const avg = (keys: string[]) => keys.reduce((a, k) => a + (shift[k] ?? 0), 0) / keys.length;
  const pShift = avg(NORM_PIT.map(k => `p.${k}`)), bShift = avg(NORM_BAT.map(k => `b.${k}`));
  for (const p of Object.values(world.players)) {
    p.potential = clamp(p.potential + (p.pos === "P" ? pShift : bShift));
    if (p.pos === "P" && p.pitching) {
      for (const k of NORM_PIT) p.pitching[k] = clamp(p.pitching[k] + (shift[`p.${k}`] ?? 0));
      for (const pi of p.pitching.pitches) pi.quality = clamp(pi.quality + (shift["p.quality"] ?? 0));
    } else {
      for (const k of NORM_BAT) p.batting[k] = clamp(p.batting[k] + (shift[`b.${k}`] ?? 0));
      for (const k of FIELD_KEYS) p.fielding[k] = clamp(p.fielding[k] + (shift[`f.${k}`] ?? 0));
    }
  }
}

/**
 * Major-league rating means of the worlds the engine was calibrated on (tools/calibrate.ts,
 * seeds calib-0/calib-1 under the original generator). Every new world is re-centred on these,
 * so league-wide run scoring doesn't swing with the luck of the generator's draw.
 */
export const REFERENCE_NORMS: Record<string, number> = {
  "b.contact": 49.73, "b.power": 49.63, "b.eye": 49.33, "b.gap": 50.4, "b.speed": 48.92,
  "f.range": 51.59, "f.hands": 49.86, "f.arm": 51.4, "f.accuracy": 50.5, "f.reaction": 50.61,
  "p.stuff": 51.57, "p.control": 50.36, "p.command": 50.25, "p.movement": 50.69, "p.quality": 49.34,
};
