// Trading cards: per-season sets, packs, pulls, values. Visuals are the client's job;
// this module owns the data and the writing (see back.ts).
//
// Sets: "Series N" — every ML player, the top farm prospects, ML managers, owners,
// league figures, umpires, and Moments (big incidents). Defs carry base rarity "common";
// the rarity of a pulled card is rolled per pack slot. Gilded / Misprint / Original are
// serial-numbered: openPack calls `mint(key)` with key `${defId}:${rarity}` and the server
// returns the next serial for that key (1, 2, 3...). Past the print run, the pull falls
// back to a lower rarity (SOLD_OUT_FALLBACK).

import type { Rng } from "../rng.ts";
import type { Player, World } from "../types.ts";
import { INCIDENTS } from "../incidents.ts";
import { illustrate, INCIDENT_TAGS, lifeTags } from "../archive.ts";
import {
  FINAL_SEASON_MULT, MAX_MOMENTS, MISPRINTS, MOMENT_TITLES, ORIGINAL_FLAIRS, PACK_DEFS, PRINT_RUNS, RARITIES, RARITY_LABEL,
  SET_NAMES, SOLD_OUT_FALLBACK, type CardKind, type PackDef, type Rarity,
} from "./data.ts";
import {
  fullName, inferKind, isNpc, isPlayer, overall, personOf, strHash, teamOf,
  type Card, type CardDef, type MomentInput,
} from "./model.ts";
import { batAvg, era, num, outsOf, pitchK, saves, seasonStats } from "./stats.ts";

export { cardBack, wrap as wrapCardText, BACK_LINES, BACK_WIDTH } from "./back.ts";
export {
  FINAL_SEASON_MULT, GILDED_BOOST, ORIGINAL_BOOST, GILDED_REDEEM_EVERY, ORIGINAL_RETIRE_SHARE, MISPRINTS, ORIGINAL_FLAIRS, PRINT_RUNS, RARITIES, RARITY_LABEL, SET_NAMES, PACK_DEFS,
  type Rarity, type CardKind, type PackDef, type MisprintDef, type OriginalDef,
} from "./data.ts";
export type { Card, CardDef, MomentInput, MomentInfo, Redeem } from "./model.ts";
export { redeemFor, redeemLabel, redeemText, redeemValue } from "./redeem.ts";
import { redeemFor, redeemLabel, redeemValue } from "./redeem.ts";

/** Pack catalogue (matches the ARCHITECTURE contract; extra fields: blurb, guarantee, kinds). */
export const PACKS: PackDef[] = PACK_DEFS;

export function setLabel(season: number): string { return `Series ${season}`; }

/** "Series 3: The Great Swindle" (names cycle with a roman-ish suffix after 20 seasons). */
export function setTitle(season: number): string {
  const i = Math.max(0, season - 1);
  const name = SET_NAMES[i % SET_NAMES.length];
  const lap = Math.floor(i / SET_NAMES.length);
  return `${setLabel(season)}: ${name}${lap ? ` ${"II III IV V VI VII VIII IX X".split(" ")[lap - 1] ?? lap + 1}` : ""}`;
}

const MAX_UMPIRES = 12;
const POS_ORDER = ["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "DH", "P"];
const MOMENT_PRIORITY: Record<string, number> = {
  RACCOONS_BULLPEN: 10, BLACKOUT: 9, LASER_POINTER: 9, BALL_TAMPERING: 8, FOOD_POISONING: 8, BRAWL: 7,
  RACCOON_ON_FIELD: 6, SCANDAL: 6, FEUD: 5, EJECTION: 4, FAN_ON_FIELD: 3, RAIN_DELAY: 2,
};
const SCANDALOUS = new Set(["CROOKED", "GAMBLER", "DRUNK", "HOTHEAD", "SNITCH"]);

function playerPosLabel(p: Player): string {
  if (p.pos === "P") return p.pitching && p.pitching.stamina >= 50 ? "SP" : "RP";
  return p.pos;
}

function humanize(kind: string): string {
  return kind.toLowerCase().split("_").map(w => w[0].toUpperCase() + w.slice(1)).join(" ");
}

/** Big moments for a season: explicit ones, the season's history headlines, then grudge/scandal fallbacks. */
export function momentsFor(world: World, season: number, explicit: MomentInput[] = []): MomentInput[] {
  const out: MomentInput[] = explicit.filter(m => m.season === season);
  const hist = (world.history ?? []).find(h => h.season === season);
  (hist?.headlines ?? [])
    .filter(h => h.weight >= 5)
    .sort((a, b) => b.weight - a.weight)
    .slice(0, 6)
    .forEach((h, i) => out.push({
      id: `hist:${season}:${i}`, season, day: 0, kind: h.kind.toUpperCase(), who: h.who ?? [],
      blurb: h.text.length > 110 ? h.text.slice(0, 107) + "..." : h.text,
    }));
  if (out.length < 3) {
    const grudges = (world.relationships ?? [])
      .filter(r => r.value <= -4 && isPlayer(world.players[r.a]) && isPlayer(world.players[r.b]) && world.players[r.a].active && world.players[r.b].active)
      .sort((x, y) => x.value - y.value || (x.a + x.b).localeCompare(y.a + y.b))
      .slice(0, 4);
    for (const r of grudges) {
      const a = world.players[r.a], b = world.players[r.b];
      out.push({
        id: `feud:${season}:${r.a}:${r.b}`, season, day: 0, kind: "FEUD", who: [r.a, r.b], teams: [...new Set([a.teamId, b.teamId])],
        title: `${a.last} vs. ${b.last}`, blurb: `It started when one of them "${r.reason}". It never stopped.`,
      });
    }
    for (const p of Object.values(world.players)) {
      if (out.length >= 6) break;
      if (p.active && p.family?.drama?.some(d => d.kind === "scandal")) {
        out.push({ id: `scandal:${season}:${p.id}`, season, day: 0, kind: "SCANDAL", who: [p.id], teams: [p.teamId], title: `The ${p.last} Affair` });
      }
    }
  }
  const seen = new Set<string>();
  return out
    .filter(m => (seen.has(m.id) ? false : (seen.add(m.id), true)))
    .map((m, i) => ({ m, i }))
    .sort((x, y) => (MOMENT_PRIORITY[y.m.kind] ?? 3) - (MOMENT_PRIORITY[x.m.kind] ?? 3) || x.i - y.i)
    .slice(0, MAX_MOMENTS)
    .map(x => x.m);
}

/** Archive photo for a Moment card: prefer a full-screen picture, else any match. */
function momentPhoto(kind: string, seed: string): { photo?: string; photoCaption?: string } {
  const k = kind.toLowerCase();
  let tags = (INCIDENT_TAGS as Record<string, string[]>)[kind] ?? lifeTags(k);
  if (!tags.length) tags = lifeTags("drama", k);
  if (!tags.length) tags = lifeTags("drama");
  if (!tags.length) tags = ["baseball", "crowd"];
  const full = illustrate(tags, seed, [], { full: true });
  return full.photo ? full : illustrate(tags, seed);
}

function momentDef(m: MomentInput): Omit<CardDef, "id" | "number" | "set" | "season" | "setName"> {
  return {
    personId: m.who?.[0] ?? "", rarity: "common", kind: "moment", pos: "MOMENT", teamId: m.teams?.[0],
    title: m.title ?? MOMENT_TITLES[m.kind] ?? humanize(m.kind),
    moment: { sourceId: m.id, kind: m.kind, day: m.day, who: m.who ?? [], teams: m.teams ?? [], gameId: m.gameId, inning: m.inning, blurb: m.blurb },
  };
}

/**
 * The card set for a season. Deterministic for a given world state; the server should
 * snapshot it at season start (rosters move) and use `extendSet` to add Moments later.
 */
export function setFor(world: World, season: number, moments?: MomentInput[]): CardDef[] {
  const rows: Omit<CardDef, "id" | "number" | "set" | "season" | "setName">[] = [];
  const seen = new Set<string>();
  const add = (personId: string, kind: CardKind, teamId: string | undefined, pos: string) => {
    if (!personId || seen.has(personId)) return;
    seen.add(personId);
    rows.push({ personId, rarity: "common", kind, teamId, pos });
  };
  const ml = Object.values(world.teams).filter(t => t.level === "ML");
  for (const t of ml) {
    const players = t.roster.map(id => world.players[id]).filter(p => p && p.active && !p.dead);
    players.sort((a, b) => POS_ORDER.indexOf(a.pos) - POS_ORDER.indexOf(b.pos) || a.last.localeCompare(b.last) || a.id.localeCompare(b.id));
    for (const p of players) add(p.id, "player", t.id, playerPosLabel(p));
  }
  for (const t of ml) add(t.managerId, "manager", t.id, "MGR");
  const teamFactions = new Set(ml.map(t => t.factionId));
  for (const t of ml) add(world.factions[t.factionId]?.leaderId ?? "", "owner", t.id, "OWN");
  for (const f of Object.values(world.factions)) {
    if (!teamFactions.has(f.id) && f.leaderId && world.npcs[f.leaderId]?.active) add(f.leaderId, "figure", undefined, "EXEC");
  }
  // The 12 most notorious umpires (extreme zones, short fuses), listed alphabetically.
  const notoriety = (n: World["npcs"][string]) => Math.abs(num(n.stats.zoneWidth) - 50) + num(n.stats.temper) + num(n.stats.corruptible) / 2;
  const umps = Object.values(world.npcs).filter(n => n.role === "umpire" && n.active && !n.dead)
    .sort((a, b) => notoriety(b) - notoriety(a) || a.id.localeCompare(b.id))
    .slice(0, MAX_UMPIRES)
    .sort((a, b) => a.last.localeCompare(b.last) || a.id.localeCompare(b.id));
  for (const u of umps) add(u.id, "umpire", undefined, "UMP");
  for (const t of ml) {
    const farm = Object.values(world.teams).filter(f => f.parentId === t.id);
    const prospects = farm.flatMap(f => f.roster.map(id => world.players[id]))
      .filter(p => p && p.active && !p.dead && p.age <= 25)
      .sort((a, b) => b.potential - a.potential || a.id.localeCompare(b.id))
      .slice(0, 3);
    for (const p of prospects) add(p.id, "prospect", p.teamId, playerPosLabel(p));
  }
  for (const m of momentsFor(world, season, moments)) rows.push(momentDef(m));
  const set = setLabel(season), setName = setTitle(season);
  return rows.map((r, i) => {
    const id = `S${season}-${String(i + 1).padStart(3, "0")}`;
    return { ...r, ...(r.moment ? momentPhoto(r.moment.kind, id) : {}), id, season, set, setName, number: i + 1 };
  });
}

/** Append Moments that aren't in `base` yet (numbering continues). Returns the new defs only. */
export function extendSet(world: World, base: CardDef[], moments: MomentInput[]): CardDef[] {
  if (!base.length) return [];
  const season = base[0].season;
  const have = new Set(base.filter(d => d.moment).map(d => d.moment!.sourceId));
  let n = Math.max(...base.map(d => d.number));
  const out: CardDef[] = [];
  for (const m of moments) {
    if (m.season !== season || have.has(m.id)) continue;
    have.add(m.id);
    n++;
    const id = `S${season}-${String(n).padStart(3, "0")}`;
    out.push({ ...momentDef(m), ...momentPhoto(m.kind, id), id, season, set: base[0].set, setName: base[0].setName, number: n });
  }
  void world;
  return out;
}

function rollRarity(odds: Record<Rarity, number>, rng: Rng, atLeast?: Rarity): Rarity {
  const floor = atLeast ? RARITIES.indexOf(atLeast) : 0;
  const options = RARITIES.filter((r, i) => i >= floor && odds[r] > 0);
  if (!options.length) return atLeast ?? "common";
  return rng.weighted(options, r => odds[r]);
}

function pullWeight(world: World, pack: PackDef, def: CardDef): number {
  const kind = inferKind(world, def);
  let w = pack.kinds[kind] ?? 0;
  if (pack.mlOnly && kind !== "player") return 0;
  if (pack.kind === "scandal" && (kind === "player" || kind === "prospect")) {
    const p = world.players[def.personId];
    if (p && (p.traits.some(t => SCANDALOUS.has(t)) || p.family?.drama?.some(d => d.kind === "scandal" || d.kind === "affair" || d.kind === "debt"))) w *= 4;
  }
  return w;
}

/**
 * Open a pack. Deterministic given the rng (and the mint callback's answers).
 * `set` lets the server pass its snapshot; otherwise `setFor(world, season)` is used.
 */
export function openPack(
  world: World, season: number, kind: string, rng: Rng, mint: (defId: string) => number, set?: CardDef[],
): Card[] {
  const pack = PACK_DEFS.find(p => p.kind === kind);
  if (!pack) throw new Error(`unknown pack kind "${kind}"`);
  const defs = set ?? setFor(world, season);
  const weighted = defs.map(d => ({ d, w: pullWeight(world, pack, d) })).filter(x => x.w > 0);
  const pool = weighted.length ? weighted : defs.map(d => ({ d, w: 1 }));
  const cards: Card[] = [];
  const used = new Set<string>();
  for (let i = 0; i < pack.count; i++) {
    let rarity = rollRarity(pack.odds, rng, i === pack.count - 1 ? pack.guarantee : undefined);
    let avail = pool.filter(x => !used.has(x.d.id));
    if (pack.momentShare) {
      const moments = avail.filter(x => x.d.kind === "moment" || !!x.d.moment);
      const others = avail.filter(x => !(x.d.kind === "moment" || !!x.d.moment));
      if (moments.length && others.length) avail = rng.chance(pack.momentShare) ? moments : others;
    }
    const pick = rng.weighted(avail.length ? avail : pool, x => x.w).d;
    used.add(pick.id);
    const card: Card = { ...pick, rarity };
    // Numbered rarities: ask the server for a serial; fall back if the run is sold out.
    for (let guard = 0; guard < 4; guard++) {
      const run = PRINT_RUNS[rarity];
      if (!run) break;
      const serial = mint(`${pick.id}:${rarity}`);
      if (serial >= 1 && serial <= run) { card.serial = serial; card.printRun = run; break; }
      rarity = SOLD_OUT_FALLBACK[rarity] ?? "rare";
    }
    card.rarity = rarity;
    if (rarity === "misprint") card.variant = rng.pick(MISPRINTS).id;
    else if (rarity === "original") card.variant = rng.pick(ORIGINAL_FLAIRS).id;
    else delete card.variant;
    if (!PRINT_RUNS[rarity]) { delete card.serial; delete card.printRun; }
    const redeem = redeemFor(world, pick, rarity, card.serial, rng);
    if (redeem) card.redeem = redeem;
    else delete card.redeem;
    cards.push(card);
  }
  return cards;
}

/** "07/50" for numbered cards. */
export function serialLabel(card: Card): string | undefined {
  if (!card.serial || !card.printRun) return undefined;
  const w = String(card.printRun).length;
  return `${String(card.serial).padStart(w, "0")}/${card.printRun}`;
}

/** Front caption, T206 style ("DUNPHY, HARBOR CITY"); misprints get their errors here. */
export function cardFront(world: World, card: Card): { caption: string; pos: string; team?: string; rarity: string; serial?: string; misprint?: string; redeem?: string; finalSeason?: boolean } {
  const p = card.personId ? personOf(world, card.personId) ?? world.archive?.[card.personId] : undefined;
  const team = teamOf(world, p, card.teamId);
  let last = p?.last ?? "";
  let city = team?.city ?? "";
  const h = strHash(`${card.id}:${card.serial ?? 0}`);
  if (card.rarity === "misprint" && card.variant === "wrong-name") {
    const others = Object.values(world.players).filter(x => x.id !== card.personId && x.active);
    if (others.length) last = others[h % others.length].last;
  }
  if (card.rarity === "misprint" && card.variant === "wrong-team") {
    const others = Object.values(world.teams).filter(t => t.level === "ML" && t.id !== team?.id);
    if (others.length) city = others[h % others.length].city;
  }
  const caption = card.title
    ? card.title.toUpperCase()
    : [last.toUpperCase(), city.toUpperCase()].filter(Boolean).join(", ") || "UNKNOWN";
  return {
    caption, pos: card.pos ?? "", team: team?.abbr, rarity: RARITY_LABEL[card.rarity] ?? card.rarity,
    serial: serialLabel(card), misprint: card.rarity === "misprint" ? MISPRINTS.find(m => m.id === card.variant)?.label : undefined,
    ...(card.redeem ? { redeem: redeemLabel(card.redeem, !world.players[card.personId]) } : {}),
    ...(card.finalSeason ? { finalSeason: true } : {}),
  };
}

const BASE_VALUE: Record<Rarity, number> = { common: 1, uncommon: 4, rare: 15, gilded: 80, misprint: 60, original: 400 };
const KIND_MULT: Record<CardKind, number> = { player: 1, prospect: 0.9, manager: 0.6, umpire: 0.5, owner: 0.7, figure: 0.9, moment: 1.2 };
const clampN = (lo: number, hi: number, x: number) => Math.max(lo, Math.min(hi, x));

/** Suggested market price in whole dollars. */
export function cardValue(world: World, card: Card): number {
  const kind = inferKind(world, card);
  let v = (BASE_VALUE[card.rarity] ?? 1) * KIND_MULT[kind];
  const p = card.personId ? personOf(world, card.personId) ?? world.archive?.[card.personId] : undefined;

  // Quality: talent now (or ceiling for prospects).
  if (isPlayer(p)) {
    const q = kind === "prospect" ? Math.max(overall(p), p.potential - 5) : overall(p);
    v *= clampN(0.35, 6, Math.pow(2, (q - 50) / 9));
    // Performance in the card's season.
    const s = seasonStats(world, p.id, card.season);
    let perf = 1;
    if (s?.bat && num(s.bat.ab) >= 100) perf += clampN(-0.3, 1.5, num(s.bat.hr) / 30 + (batAvg(s.bat) - 0.26) * 8 + num(s.bat.sb) / 60);
    if (s?.pitch && outsOf(s.pitch) >= 90) perf += clampN(-0.3, 1.5, (4.3 - era(s.pitch)) / 2.5 + pitchK(s.pitch) / 250 + saves(s.pitch) / 40);
    v *= perf;
    const hist = (world.history ?? []).find(h => h.season === card.season);
    if (hist && (hist.awards?.mvp === p.id || hist.awards?.pitcher === p.id)) v *= 2;
    else if (hist && hist.awards?.rookie === p.id) v *= 1.5;
  } else if (isNpc(p) && p.role === "umpire") {
    const u = p.stats as { temper?: number; corruptible?: number };
    if ((u.temper ?? 50) >= 62) v *= 1.3; // ejections sell
  }

  // Popularity heuristics: nicknames, showmen, notoriety, legacy.
  if (p) {
    if (p.nickname) v *= 1.15;
    if (p.traits?.some(t => t === "SHOWBOAT" || t === "CHARMING")) v *= 1.2;
    if (p.traits?.includes("CROOKED")) v *= 1.1;
    if (p.family?.drama?.some(d => d.kind === "scandal" || d.kind === "affair")) v *= 1.25;
    if (p.dead) v *= 1.5;
    const house = world.houses?.[p.family?.house ?? ""];
    if (house && house.reputation > 0) v *= 1 + clampN(0, 0.5, house.reputation / 200);
  }

  // Moments: rarer incidents are worth more.
  if (kind === "moment" && card.moment) {
    const def = INCIDENTS[card.moment.kind as keyof typeof INCIDENTS];
    v *= def && def.perGame > 0 ? clampN(1, 3, 0.004 / def.perGame) : (MOMENT_PRIORITY[card.moment.kind] ?? 3) / 4;
  }

  // Scarcity: numbered runs, low and last serials, variants.
  if (card.printRun) {
    v *= Math.pow(50 / card.printRun, 0.25);
    if (card.serial === 1) v *= 1.5;
    else if (card.serial === card.printRun) v *= 1.2;
  }
  if (card.rarity === "misprint") v *= MISPRINTS.find(m => m.id === card.variant)?.mult ?? 1;
  if (card.finalSeason) v *= FINAL_SEASON_MULT;
  if (card.rarity === "original") v *= ORIGINAL_FLAIRS.find(f => f.id === card.variant)?.mult ?? 1;

  // Vintage: older sets appreciate. Fads (world effects) move the whole market.
  v *= 1 + clampN(0, 1, (world.season - card.season) * 0.1);
  for (const e of world.effects ?? []) {
    if (typeof e.cardDemand === "number" && world.day >= e.from && world.day <= e.until) v *= e.cardDemand;
  }
  // Redeemable prints: the printed effect is worth real money on top (until it's used up).
  v += redeemValue(world, card);
  return Math.max(1, Math.round(v));
}

/** Display name for a card subject (Moments use their title). */
export function cardSubject(world: World, card: CardDef): string {
  if (card.title) return card.title;
  const p = personOf(world, card.personId) ?? world.archive?.[card.personId];
  return p ? fullName(p) : "Unknown";
}
