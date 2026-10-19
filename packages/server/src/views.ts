// Builders for the API.md payload shapes from world state and D1 rows.

import type { Card, CrewMember, GameResult, LogEv, Player, ScheduledGame, World } from "./sim.ts";
import { sim, houseName } from "./sim.ts";

export type PersonRef = { id: string; name: string; face: string; teamAbbr?: string; pos?: string };
export type TeamRef = { id: string; abbr: string; city: string; name: string; level: "ML" | "AA" | "B" | "D" | "EL" };

export function personRef(world: World, id: string): PersonRef {
  const p = world.players[id];
  if (p) {
    const t = world.teams[p.teamId];
    return { id, name: `${p.first} ${p.last}`, face: p.face, ...(t ? { teamAbbr: t.abbr } : {}), pos: p.pos };
  }
  const n = world.npcs[id];
  if (n) {
    const r: PersonRef = { id, name: `${n.first} ${n.last}`, face: n.face };
    if (n.role === "umpire") r.pos = "UMP";
    else if (n.role === "manager") r.pos = "MGR";
    return r;
  }
  const a = world.archive?.[id];
  if (a) return { id, name: `${a.first} ${a.last}`, face: a.face };
  return { id, name: "Unknown", face: "face:0" };
}

export function teamRef(world: World, id: string): TeamRef {
  const t = world.teams[id];
  if (!t) return { id, abbr: id, city: "?", name: "?", level: "ML" };
  return { id: t.id, abbr: t.abbr, city: t.city, name: t.name, level: t.level };
}

// ------------------------------------------------------------------ stats
export interface NStat {
  g: number; ab: number; r: number; h: number; d: number; t: number; hr: number; rbi: number; bb: number; k: number; sb: number;
  pg: number; outs: number; ph: number; per: number; pbb: number; pk: number; w: number; l: number; sv: number;
}
const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);

/** Season stats for a player, normalised from world.stats (shape owned by the life module). */
export function statOf(world: World, pid: string, season: number): NStat | undefined {
  const all = (world as unknown as { stats?: Record<string, Record<string, { bat?: Record<string, unknown>; pitch?: Record<string, unknown> }>> }).stats;
  const s = all?.[pid]?.[season];
  if (!s) return undefined;
  const b = s.bat ?? {}, p = s.pitch ?? {};
  const outs = p.outs !== undefined ? n(p.outs) : p.ipOuts !== undefined ? n(p.ipOuts) : Math.round(n(p.ip) * 3);
  return {
    g: n(b.g), ab: n(b.ab), r: n(b.r), h: n(b.h), d: n(b.d ?? b["2b"]), t: n(b.t ?? b["3b"]), hr: n(b.hr), rbi: n(b.rbi), bb: n(b.bb), k: n(b.k ?? b.so), sb: n(b.sb),
    pg: n(p.g), outs, ph: n(p.h), per: n(p.er), pbb: n(p.bb), pk: n(p.k ?? p.so), w: n(p.w), l: n(p.l), sv: n(p.sv ?? p.s),
  };
}
export const avgStr = (h: number, ab: number) => (ab ? (h / ab).toFixed(3).replace(/^0/, "") : ".000");
export const eraStr = (er: number, outs: number) => (outs ? ((er * 27) / outs).toFixed(2) : "0.00");
export const ipStr = (outs: number) => `${Math.floor(outs / 3)}.${outs % 3}`;

export function pitcherLine(world: World, pid: string, season: number): string {
  const s = statOf(world, pid, season);
  return s ? `${s.w}-${s.l}, ${eraStr(s.per, s.outs)}` : "0-0, 0.00";
}
export function playerLine(world: World, pid: string, season: number): string {
  const p = world.players[pid];
  const s = statOf(world, pid, season);
  if (p?.pos === "P") return s ? `${s.w}-${s.l}, ${eraStr(s.per, s.outs)}, ${s.pk} K` : "0-0, 0.00";
  return s ? `${avgStr(s.h, s.ab)}, ${s.hr} HR, ${s.rbi} RBI` : ".000, 0 HR, 0 RBI";
}

// ------------------------------------------------------------------ text helpers
const INC_TEXT: Record<string, string> = {
  RACCOONS_BULLPEN: "Raccoons loose in the {team} bullpen",
  RACCOON_ON_FIELD: "A raccoon takes the field",
  FOOD_POISONING: "Food poisoning sweeps the {team} dugout",
  FAN_ON_FIELD: "A fan runs onto the field",
  LASER_POINTER: "A laser pointer harasses {team} hitters",
  RAIN_DELAY: "Rain delay",
  EJECTION: "{who} is ejected",
  BRAWL: "Benches clear: {who}",
  BALL_TAMPERING: "Ball tampering suspected ({team})",
  BLACKOUT: "The lights go out",
};
export function incidentText(world: World, kind: string, team?: string, who?: string): string {
  const t = team ? world.teams[team]?.name ?? team : "";
  const w = who ? who.split(",").map(id => personRef(world, id).name).join(" and ") : "someone";
  return (INC_TEXT[kind] ?? kind.toLowerCase().replace(/_/g, " ")).replace("{team}", t).replace("{who}", w);
}

export const MOODS = ["miserable", "miserable", "sour", "sour", "glum", "fine", "chipper", "chipper", "happy", "elated", "on top of the world"];
export const moodStr = (m: number) => MOODS[Math.max(0, Math.min(10, Math.round(m) + 5))];
export const formatWeather = (w: { tempF: number; windMph: number; windDir: number; rain: number }) =>
  `${w.tempF}F, wind ${w.windMph} mph ${w.windMph < 3 ? "calm" : Math.abs(w.windDir) < 30 ? "out to CF" : w.windDir < 0 ? "out to LF" : "out to RF"}${w.rain > 0.3 ? ", rain likely" : w.rain > 0 ? ", showers" : ""}`;

// ------------------------------------------------------------------ game summary (computed at sim time)
export type TeamBoxView = {
  bat: { p: PersonRef; ab: number; r: number; h: number; rbi: number; bb: number; k: number; avg: string }[];
  pitch: { p: PersonRef; ip: string; h: number; r: number; er: number; bb: number; k: number; pc: number }[];
  r: number; h: number; e: number;
};
export interface GameSummaryRow {
  box: { home: TeamBoxView; away: TeamBoxView };
  line: { home: (number | null)[]; away: (number | null)[] };
  decisions: { w: PersonRef; l: PersonRef; s?: PersonRef };
  /** incidents keyed to pitch index so they can be revealed as the game airs */
  inc: { i: number; inning: number; text: string }[];
  /** [pitchIdx, half (0-based: inning*2 + bottom), home, away] at each half start and each run */
  tl: [number, number, number, number][];
  pitches: number;
  innings: number;
  /** box-score notes from the newsroom (e.g. powers used), major-league games only */
  notes?: string[];
}

export function buildSummary(world: World, res: GameResult, season: number): GameSummaryRow {
  const boxView = (b: GameResult["home"]): TeamBoxView => ({
    bat: b.bat.map(l => {
      const s = statOf(world, l.id, season);
      return { p: personRef(world, l.id), ab: l.ab, r: l.r, h: l.h, rbi: l.rbi, bb: l.bb, k: l.k, avg: s ? avgStr(s.h, s.ab) : avgStr(l.h, l.ab) };
    }),
    pitch: b.pitch.map(l => ({ p: personRef(world, l.id), ip: ipStr(l.outs), h: l.h, r: l.r, er: l.er, bb: l.bb, k: l.k, pc: l.pitches })),
    r: b.runs, h: b.hits, e: b.errors,
  });
  const tl: [number, number, number, number][] = [];
  const inc: GameSummaryRow["inc"] = [];
  let pitch = 0, half = 0, home = 0, away = 0, top = true, inning = 1;
  for (const ev of res.log as LogEv[]) {
    if (ev.k === "p") pitch++;
    else if (ev.k === "half") { top = ev.top; inning = ev.inn; half = (ev.inn - 1) * 2 + (ev.top ? 0 : 1); tl.push([pitch, half, home, away]); }
    else if (ev.k === "mv" && ev.to === 4) { if (top) away++; else home++; tl.push([pitch, half, home, away]); }
    else if (ev.k === "inc") inc.push({ i: pitch, inning, text: incidentText(world, ev.kind, ev.team, ev.who) });
  }
  const line = (l: number[]) => l.map(x => (Number.isNaN(x) ? null : x));
  return {
    box: { home: boxView(res.home), away: boxView(res.away) },
    line: { home: line(res.home.line), away: line(res.away.line) },
    decisions: {
      w: personRef(world, res.decisions.w), l: personRef(world, res.decisions.l),
      ...(res.decisions.s ? { s: personRef(world, res.decisions.s) } : {}),
    },
    inc, tl, pitches: pitch, innings: res.innings,
  };
}

/** Score/inning as of `k` pitches into the broadcast. */
export function scoreAt(sum: GameSummaryRow, k: number): { home: number; away: number; inning: string; half: number } {
  let cur: [number, number, number, number] = [0, 0, 0, 0];
  for (const e of sum.tl) { if (e[0] <= k) cur = e; else break; }
  const inn = Math.floor(cur[1] / 2) + 1;
  return { home: cur[2], away: cur[3], inning: `${cur[1] % 2 ? "BOT" : "TOP"} ${inn}`, half: cur[1] };
}
export function partialLine(sum: GameSummaryRow, k: number): { home: (number | null)[]; away: (number | null)[] } {
  const home: (number | null)[] = [], away: (number | null)[] = [];
  let ph = 0, pa = 0;
  for (const e of sum.tl) {
    if (e[0] > k) break;
    const inn = Math.floor(e[1] / 2);
    while (away.length <= inn) away.push(0);
    if (e[1] % 2) while (home.length <= inn) home.push(0);
    away[inn] = (away[inn] ?? 0) + (e[3] - pa);
    if (e[1] % 2) home[inn] = (home[inn] ?? 0) + (e[2] - ph);
    ph = e[2]; pa = e[3];
  }
  return { home, away };
}

export const finalInning = (innings: number) => (innings === 9 ? "FINAL" : `FINAL/${innings}`);

// ------------------------------------------------------------------ people / teams
const TIE_LIMIT = 8;

export function scouting(p: Player): { label: string; value: number }[] {
  const s = (x: number) => Math.max(1, Math.min(5, Math.round((x - 20) / 15) + 1));
  if (p.pos === "P" && p.pitching) {
    const fb = p.pitching.pitches[0];
    return [
      { label: "Stuff", value: s(p.pitching.stuff) }, { label: "Control", value: s(p.pitching.control) },
      { label: "Stamina", value: s(p.pitching.stamina) }, { label: "Heat", value: s(fb ? 50 + (fb.velo - 93) * 4 : 50) },
    ];
  }
  return [
    { label: "Contact", value: s(p.batting.contact) }, { label: "Power", value: s(p.batting.power) },
    { label: "Eye", value: s(p.batting.eye) }, { label: "Speed", value: s(p.batting.speed) }, { label: "Glove", value: s((p.fielding.range + p.fielding.hands) / 2) },
  ];
}

export function tiesOf(world: World, id: string) {
  const out: { who: PersonRef; value: number; reason: string }[] = [];
  for (const r of world.relationships) {
    if (r.a !== id && r.b !== id) continue;
    const other = r.a === id ? r.b : r.a;
    const f = world.factions[other];
    const who = f ? { ...personRef(world, f.leaderId ?? other), id: f.id, name: f.name } : personRef(world, other);
    out.push({ who, value: r.value, reason: r.reason });
  }
  return out.sort((a, b) => Math.abs(b.value) - Math.abs(a.value)).slice(0, TIE_LIMIT);
}

const DRAMA_TEXT: Record<string, string> = {
  newborn: "New baby at home", divorce: "Going through a divorce", illness_in_family: "Sick family member", affair: "Rumors of an affair",
  feud: "Feuding with {with}", debt: "In debt to {with}", scandal: "Embroiled in scandal", wedding: "Just married", bereavement: "In mourning", holdout: "Holding out for more money",
};
export function dramaLines(world: World, id: string): string[] {
  const p = world.players[id] ?? world.npcs[id] ?? world.archive?.[id];
  if (!p) return [];
  return p.family.drama.slice(-6).map(d => (DRAMA_TEXT[d.kind] ?? d.kind).replace("{with}", d.with ? personRef(world, d.with).name : "somebody"));
}

const TRAIT_TEXT: Record<string, string> = {
  HOTHEAD: "Hothead", LOYAL: "Loyal", SUPERSTITIOUS: "Superstitious", GAMBLER: "Gambler", DRUNK: "Drunk", CLUTCH: "Clutch", CHOKER: "Choker",
  GREEDY: "Greedy", PIOUS: "Pious", SHOWBOAT: "Showboat", GRINDER: "Grinder", LAZY: "Lazy", PARANOID: "Paranoid", IRON_MAN: "Iron Man",
  FRAGILE: "Fragile", CHARMING: "Charming", CROOKED: "Crooked", SNITCH: "Snitch",
};
export const traitStr = (t: string) => TRAIT_TEXT[t] ?? t.charAt(0) + t.slice(1).toLowerCase().replace(/_/g, " ");

export function personStatus(world: World, id: string): string {
  const a = world.archive?.[id];
  if (a) return a.gone === "dead" ? `deceased (${a.goneYear})` : `moved away (${a.goneYear})`;
  const p = world.players[id] ?? world.npcs[id];
  if (!p) return "unknown";
  if (p.dead) return "deceased";
  if (!p.active) return "retired";
  const pl = world.players[id];
  if (pl?.injury) return `injured (${pl.injury.kind}, ${pl.injury.daysLeft}d)`;
  return "active";
}

export function houseNote(world: World, house: string): string {
  const h = world.houses?.[house];
  const name = houseName(world, house);
  if (h) {
    const rep = h.reputation >= 20 ? "a proud name" : h.reputation >= 5 ? "a respectable name" : h.reputation <= -5 ? "a name people spit after" : "a name nobody's heard of";
    return `House ${name}: ${h.players} ballplayer${h.players === 1 ? "" : "s"}, ${h.titles} title${h.titles === 1 ? "" : "s"}. ${rep[0].toUpperCase()}${rep.slice(1)}.`;
  }
  let n = 0;
  for (const p of Object.values(world.players)) if (p.family.house === house) n++;
  return n <= 1 ? `The ${name}s have one ballplayer. So far.` : `${n} ${name}s have played pro ball.`;
}

// ------------------------------------------------------------------ crew / candidates
export type CrewView = { id: string; person: PersonRef; role: string; skills: { k: string; v: number }[]; loyalty: number; status: string; note: string };
export function crewView(world: World, row: { id: string; role: string; note: string; status: string; data: string }, candidatePerson?: PersonRef): CrewView {
  const m = JSON.parse(row.data) as CrewMember & { person?: PersonRef };
  return {
    id: row.id, person: m.person ?? candidatePerson ?? personRef(world, m.personId), role: row.role,
    skills: Object.entries(m.skills ?? {}).map(([k, v]) => ({ k, v: Number(v) })), loyalty: m.loyalty ?? 0, status: row.status, note: row.note,
  };
}

export type CandidateView = { id: string; person: PersonRef; role: string; skills: { k: string; v: number }[]; ask: number; pitch: string };
/** Normalise whatever the crime module's Candidate looks like. */
export function candidateInfo(world: World, cand: object): CandidateView & { personId: string; npc?: unknown } {
  const c = cand as Record<string, unknown>;
  const person = (c.person ?? c.npc) as { id: string; first: string; last: string; face: string } | undefined;
  const personId = String(c.personId ?? person?.id ?? c.id);
  const ref = person ? { id: person.id, name: `${person.first} ${person.last}`, face: person.face } : personRef(world, personId);
  const skills = (c.skills ?? {}) as Record<string, number>;
  return {
    id: String(c.id), person: ref, personId, npc: person,
    role: String(c.roleLabel ?? c.role ?? c.title ?? "Crew"), skills: Object.entries(skills).map(([k, v]) => ({ k, v: Number(v) })),
    ask: Number(c.ask ?? c.cost ?? c.fee ?? c.price ?? 0), pitch: String(c.pitch ?? c.blurb ?? c.note ?? ""),
  };
}

// ------------------------------------------------------------------ cards
export type CardView = {
  id: string; defId: string; person: PersonRef; team: TeamRef; season: number; set: string; number: number; rarity: string; variant?: string;
  serial?: string; front: { caption: string; pos: string; redeem?: string }; back: { lines: string[]; stats: string[][] }; value: number;
  /** Printed redeemable effect, e.g. { kind: "boost", boost: 12, days: 7, label: "REDEEMABLE: BOOST +12 FOR 7 DAYS" }. */
  redeem?: { kind: "boost"; boost: number; days: number; label: string } | { kind: "retire"; label: string };
  /** Its subject retired via a redeemed card ("Final Season" edition). */
  finalSeason?: boolean;
  /** Moment cards: archive picture (images/archive/<photo>-<400|160|96|48>.png). */
  photo?: string;
  photoCaption?: string;
};
export function cardView(world: World, id: string, card: Card): CardView {
  // the cards module knows retired/archived people and applies misprint errors
  const f = sim.cardFront(world, card);
  const teamId = (card as Card & { teamId?: string }).teamId ?? world.players[card.personId]?.teamId ?? "";
  const team = teamRef(world, teamId);
  const pad = (x: number, w: number) => String(x).padStart(w, "0");
  const view: CardView = {
    id, defId: card.id, person: personRef(world, card.personId), team, season: card.season, set: card.set, number: card.number, rarity: card.rarity,
    front: { caption: f.caption, pos: f.pos, ...(f.redeem ? { redeem: f.redeem } : {}) },
    back: sim.cardBack(world, card), value: Math.max(1, Math.round(sim.cardValue(world, card))),
  };
  if (card.variant) view.variant = card.variant;
  if (card.redeem) view.redeem = { ...card.redeem, label: f.redeem ?? "REDEEMABLE" };
  if (card.finalSeason) view.finalSeason = true;
  if (card.photo) { view.photo = card.photo; if (card.photoCaption) view.photoCaption = card.photoCaption; }
  if (card.serial && card.printRun) view.serial = `${pad(card.serial, String(card.printRun).length)}/${card.printRun}`;
  return view;
}

export const RANKS: [number, string][] = [[50000, "Kingpin"], [15000, "Bigwig"], [5000, "Operator"], [2000, "Sharpie"], [800, "Regular"], [0, "Rube"]];
export const rankFor = (money: number) => (RANKS.find(([m]) => money >= m) ?? RANKS[RANKS.length - 1])[1];

export type { ScheduledGame };
