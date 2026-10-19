// Storylines: drama arcs with a beginning, escalation and a resolution. Each starts secret,
// rumoured or public; daily hazards (driven by traits, fame, relationships and outside nudges)
// move it along. Rumoured/public storylines are bettable through prop questions.

import type { Rng } from "../rng.ts";
import type { Npc, Player, PropQuestion, Storyline, StorylineKind, World } from "../types.ts";
import { FREE_AGENT } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import {
  addDrama, bumpHouse, createNpc, hasQ, hasT, living, relation, setRelation, shiftRelation, shortName, unmarry,
} from "./people.ts";
import { addConcern, dropConcern, fameOf, gainFame } from "./inner.ts";
import { balanceOrg, movePlayer, orgId } from "./roster.ts";

export interface StoryCtx {
  phase: "preseason" | "regular" | "playoffs" | "offseason";
  /** Regular-season records by team id: w, l and the W/L sequence. */
  table?: Record<string, { w: number; l: number; seq: string }>;
  /** Season day. */
  day?: number;
}

export interface Rates {
  /** Chance per day of moving secret → rumoured → public. */
  expose: number;
  /** Chance per day of escalating to the next stage (or the blow-up resolution). */
  escalate: number;
  /** Chance per day of calming down / a quiet resolution. */
  calm: number;
}

interface KindDef {
  /** Every outcome this kind can resolve with (for the "how will it end" prop). */
  outcomes: string[];
  /** Outcomes that count as "yes" for the headline yes/no prop. */
  hit: string[];
  /** Yes/no window in days. */
  window: number;
  question: (w: World, s: Storyline) => string;
  rates: (w: World, s: Storyline, ctx: StoryCtx) => Rates;
  step: (w: World, s: Storyline, rng: Rng, ctx: StoryCtx, ev: LifeEvent[], r: Rates) => void;
  /** Days after which an unresolved arc quietly ends, and with what outcome. */
  timeout: [number, string];
}

const nm = (w: World, id: string | undefined) => shortName(living(w, id) ?? w.archive[id ?? ""]);
const P = (w: World, id: string | undefined) => (id ? w.players[id] : undefined);

// --- core API -------------------------------------------------------------------------------------

export function openStorylines(world: World): Storyline[] {
  return (world.storylines ??= []).filter(s => !s.resolved);
}

export function findOpen(world: World, kind: StorylineKind, personId: string): Storyline | undefined {
  return (world.storylines ??= []).find(s => !s.resolved && s.kind === kind && s.people[0] === personId);
}

export function involving(world: World, personId: string): Storyline[] {
  return (world.storylines ??= []).filter(s => !s.resolved && s.people.includes(personId));
}

export interface StartOpts {
  visibility?: Storyline["visibility"];
  stage: string;
  data?: Record<string, unknown>;
  cause: string;
  stakes?: string;
}

export function startStoryline(world: World, kind: StorylineKind, people: string[], teams: string[], o: StartOpts, events: LifeEvent[]): Storyline {
  const n = (world.seq.sl = (world.seq.sl ?? 0) + 1);
  const vis = o.visibility ?? "secret";
  const s: Storyline = {
    id: `sl${n}`, kind, people, teams: teams.filter(Boolean), startedDay: world.day, season: world.season, visibility: vis, stage: o.stage,
    nudges: { expose: 0, inflame: 0, soothe: 0 }, data: { ...(o.data ?? {}), cause: o.cause, stakes: o.stakes }, log: [],
  };
  if (vis !== "secret") s.bettableDay = world.day;
  world.storylines.push(s);
  beat(world, s, o.stage, events, { begins: true, cause: o.cause, stakes: o.stakes });
  return s;
}

/** Record a stage beat and emit a "drama" event for it. Secret beats are flagged `secret: true` (don't publish). */
export function beat(world: World, s: Storyline, stage: string, events: LifeEvent[], data: Record<string, unknown> = {}): LifeEvent {
  s.stage = stage;
  const e = mkEvent(world, "drama", s.people.filter(id => living(world, id) || world.archive[id]), s.teams, {
    sub: s.kind, kind: s.kind, storyline: s.id, stage, visibility: s.visibility, secret: s.visibility === "secret", ...s.data, ...data,
  });
  s.log.push({ day: world.day, stage, visibility: s.visibility, eventId: e.id });
  if (s.log.length > 12) s.log.splice(1, 1);
  events.push(e);
  return e;
}

export function reveal(world: World, s: Storyline, to: "rumoured" | "public", events: LifeEvent[], how: string) {
  if (s.visibility === to || s.visibility === "public") return;
  s.visibility = to;
  if (s.bettableDay === undefined) s.bettableDay = world.day;
  beat(world, s, s.stage, events, { revealed: to, how });
}

export function resolveStoryline(world: World, s: Storyline, outcome: string, events: LifeEvent[], data: Record<string, unknown> = {}): LifeEvent {
  if (s.resolved) return events[events.length - 1];
  const wasSecret = s.visibility === "secret";
  if (data.publicise !== false && !wasSecret) s.visibility = "public";
  const e = beat(world, s, "resolved", events, { outcome, ...data });
  s.resolved = { day: world.day, outcome, eventId: e.id };
  for (const id of s.people) {
    const p = living(world, id);
    if (p?.concerns) p.concerns = p.concerns.filter(c => c.storyline !== s.id);
  }
  return e;
}

export type NudgeKind = "expose" | "inflame" | "soothe";

/**
 * Outside pressure on a storyline (crew ops, tips, love letters, blackmail). Strength ~1 is a
 * solid push: it roughly doubles the matching hazard while it lasts (nudges decay ~4%/day).
 */
export function nudgeStoryline(world: World, storylineId: string, kind: NudgeKind, strength = 1): boolean {
  const s = (world.storylines ??= []).find(x => x.id === storylineId);
  if (!s || s.resolved) return false;
  s.nudges[kind] = Math.min(6, s.nudges[kind] + Math.max(0, strength));
  return true;
}

/** Today's hazards for a storyline, after nudges. */
export function storylineHazards(world: World, s: Storyline, ctx: StoryCtx = { phase: "regular" }): Rates {
  const r = KINDS[s.kind].rates(world, s, ctx);
  const n = s.nudges;
  return {
    expose: Math.min(0.9, r.expose * (1 + n.expose)),
    escalate: Math.min(0.9, r.escalate * (1 + n.inflame) / (1 + n.soothe * 0.5)),
    calm: Math.min(0.9, r.calm * (1 + n.soothe) / (1 + n.inflame * 0.5)),
  };
}

/** Daily: move every open storyline along. */
export function advanceStorylines(world: World, rng: Rng, events: LifeEvent[], ctx: StoryCtx) {
  for (const s of openStorylines(world)) {
    const def = KINDS[s.kind];
    // the main character is gone (dead, archived): it ends
    const lead = living(world, s.people[0]);
    if (!lead) { resolveStoryline(world, s, world.archive[s.people[0]]?.dead ? "death" : "ended_quietly", events, { why: "gone" }); continue; }
    if (world.day - s.startedDay > def.timeout[0]) { resolveStoryline(world, s, def.timeout[1], events, { why: "faded" }); continue; }
    const r = storylineHazards(world, s, ctx);
    if (s.visibility !== "public" && rng.chance(s.visibility === "secret" ? r.expose : r.expose * 0.6)) {
      reveal(world, s, s.visibility === "secret" ? "rumoured" : "public", events, exposeHow(world, s, rng));
    }
    def.step(world, s, rng, ctx, events, r);
    s.nudges.expose *= 0.96; s.nudges.inflame *= 0.96; s.nudges.soothe *= 0.96;
  }
  // forget long-settled arcs (props settle within a season)
  if (world.storylines.length > 600) world.storylines = world.storylines.filter(s => !s.resolved || world.day - s.resolved.day < 250);
}

function exposeHow(world: World, s: Storyline, rng: Rng): string {
  const team = world.teams[s.teams[0] ?? ""];
  const snitch = team?.roster.some(id => id !== s.people[0] && hasT(world.players[id], "SNITCH"));
  if (snitch && rng.chance(0.6)) return "a teammate talked";
  return rng.pick(["a SportsWire tip", "a BBS rumour", "a bartender talked", "a photo in the Harbor City Ledger", "the wife of a teammate talked", "an anonymous letter", "a radio caller"]);
}

/** Common exposure factor: famous people get noticed; SNITCH teammates leak. */
function exposure(world: World, s: Storyline, base: number): number {
  const p = living(world, s.people[0]);
  const fame = fameOf(p);
  const team = world.teams[s.teams[0] ?? ""];
  const snitch = team?.roster.some(id => id !== s.people[0] && hasT(world.players[id], "SNITCH")) ? 1.8 : 1;
  return base * (0.4 + fame / 35) * snitch * (hasT(p, "PARANOID") ? 0.7 : 1);
}

const teamOfP = (w: World, id: string) => w.players[id]?.teamId;

// --- kinds -------------------------------------------------------------------------------------------

const AFFAIR_ENDS = ["it fizzled", "she moved to Paducah", "he found religion", "she married a dentist"];

export const KINDS: Record<StorylineKind, KindDef> = {
  affair: {
    outcomes: ["discovered", "ended_quietly", "death"], hit: ["discovered"], window: 20, timeout: [150, "ended_quietly"],
    question: (w, s) => `Will ${nm(w, s.people[0])}'s affair be discovered within 20 days?`,
    rates: (w, s) => {
      const p = living(w, s.people[0]);
      const discover = s.visibility === "secret" ? 0.005 : s.visibility === "rumoured" ? 0.03 : 0.06;
      return { expose: exposure(w, s, 0.02), escalate: discover * (s.people[2] ? 1.4 : 1), calm: 0.006 * (hasT(p, "PIOUS") ? 3 : 1) * (hasQ(p, "CHARITABLE") ? 1.5 : 1) };
    },
    step: (w, s, rng, _c, ev, r) => {
      const p = living(w, s.people[0])!;
      if (!p.family.spouse) { resolveStoryline(w, s, "ended_quietly", ev, { why: "no longer married" }); return; }
      if (rng.chance(r.escalate)) {
        const wife = living(w, p.family.spouse);
        const partner = s.people[1] ? living(w, s.people[1]) : undefined;
        const cuckold = s.people[2] ? P(w, s.people[2]) : undefined;
        const e = resolveStoryline(w, s, "discovered", ev, { how: rng.pick(["his wife found the letters", "a hotel clerk sold the story", "photographed at a roadside motel", "the partner's husband walked in", "it came out at a charity dinner"]) });
        addDrama(p, { kind: "scandal", since: w.day, weight: -3, note: "the affair" });
        addConcern(w, p, { kind: "marriage", about: wife?.id, until: w.day + 60, weight: -2, note: "the affair is out" });
        gainFame(w, rng, p, 3, ev, "scandal");
        bumpHouse(w, p.family.house, -2);
        if (wife) {
          addDrama(wife, { kind: "affair", with: p.id, since: w.day, weight: -4, note: "betrayed" });
          startStoryline(w, "marriage_trouble", [p.id, wife.id], s.teams, { visibility: "public", stage: "cold", cause: "the affair", stakes: "the marriage" }, ev);
        }
        if (cuckold && partner) {
          setRelation(w, p.id, cuckold.id, -5, "the affair", "grudge");
          addConcern(w, cuckold, { kind: "feud", about: p.id, until: w.day + 90, weight: -2.5, note: "his wife's affair" });
          const teammates = cuckold.teamId === (p as Player).teamId;
          startStoryline(w, teammates ? "feud" : "rivalry", [cuckold.id, p.id], [cuckold.teamId, (p as Player).teamId], { visibility: "public", stage: "public_spat", cause: "the affair", stakes: "his marriage" }, ev);
          const ct = w.teams[cuckold.teamId];
          if (ct && ct.level === "ML") startStoryline(w, "marriage_trouble", [cuckold.id, partner.id], [cuckold.teamId], { visibility: "public", stage: "cold", cause: "her affair", stakes: "the marriage" }, ev);
        }
        maybeCutForScandal(w, rng, p as Player, ev, "the affair", e.id);
      } else if (rng.chance(r.calm)) {
        resolveStoryline(w, s, "ended_quietly", ev, { why: rng.pick(AFFAIR_ENDS) });
      }
    },
  },

  marriage_trouble: {
    outcomes: ["divorced", "reconciled", "death"], hit: ["divorced"], window: 30, timeout: [160, "reconciled"],
    question: (w, s) => `Will ${nm(w, s.people[0])} and ${nm(w, s.people[1])} divorce within 30 days?`,
    rates: (w, s) => {
      const a = living(w, s.people[0]), b = living(w, s.people[1]);
      const kind = (x: typeof a) => (hasT(x, "PIOUS") ? 2 : 1) * (hasQ(x, "CHARITABLE") ? 1.5 : 1) * (hasQ(x, "JEALOUS") ? 0.6 : 1);
      const baby = (a?.family.drama ?? []).some(d => d.kind === "newborn") ? 2 : 1;
      return { expose: exposure(w, s, 0.03), escalate: s.stage === "cold" ? 0.02 : 0.035, calm: 0.012 * kind(a) * kind(b) * baby };
    },
    step: (w, s, rng, _c, ev, r) => {
      const a = living(w, s.people[0]), b = living(w, s.people[1]);
      if (!a || !b || a.family.spouse !== b.id) { resolveStoryline(w, s, a && b ? "divorced" : "death", ev); return; }
      if (rng.chance(r.escalate)) {
        if (s.stage === "cold") {
          beat(w, s, "separated", ev, { how: rng.pick(["he moved into the team hotel", "she changed the locks", "he's sleeping at the ballpark", "she went to her mother's"]) });
          addConcern(w, a, { kind: "marriage", about: b.id, until: w.day + 60, weight: -2.5, storyline: s.id, note: "separated" });
        } else {
          unmarry(a, b);
          for (const x of [a, b]) addDrama(x, { kind: "divorce", with: x === a ? b.id : a.id, since: w.day, weight: -3 });
          setRelation(w, a.id, b.id, -4, "the divorce", "ex");
          bumpHouse(w, a.family.house, -1);
          const e = resolveStoryline(w, s, "divorced", ev, {});
          ev.push(mkEvent(w, "divorce", [a.id, b.id], s.teams, { reason: String(s.data.cause ?? "irreconcilable differences"), storyline: s.id, eventOf: e.id }));
        }
      } else if (rng.chance(r.calm)) {
        setRelation(w, a.id, b.id, 2, "patched it up", "family");
        resolveStoryline(w, s, "reconciled", ev, { how: rng.pick(["a second honeymoon in Natchez", "marriage counselling (Brother Amos)", "he sold his motorcycle", "a new baby on the way"]) });
      }
    },
  },

  feud: {
    outcomes: ["brawl", "reconciled", "traded", "fizzled", "death"], hit: ["brawl"], window: 20, timeout: [80, "fizzled"],
    question: (w, s) => `Will the ${nm(w, s.people[0])}–${nm(w, s.people[1])} feud come to blows within 20 days?`,
    rates: (w, s) => {
      const a = living(w, s.people[0]), b = living(w, s.people[1]);
      const hot = (x: typeof a) => (hasT(x, "HOTHEAD") ? 2 : 1) * (hasQ(x, "JEALOUS") ? 1.3 : 1) * (hasT(x, "DRUNK") ? 1.2 : 1);
      const cool = (x: typeof a) => (hasT(x, "PIOUS") ? 1.6 : 1) * (hasQ(x, "CHARITABLE") ? 1.6 : 1) * (hasT(x, "LOYAL") ? 1.2 : 1) * (hasT(x, "HOTHEAD") ? 0.6 : 1);
      return { expose: exposure(w, s, 0.04), escalate: 0.018 * hot(a) * hot(b), calm: 0.008 * cool(a) * cool(b) };
    },
    step: (w, s, rng, _c, ev, r) => {
      const a = living(w, s.people[0]), b = living(w, s.people[1]);
      if (!a || !b) { resolveStoryline(w, s, "death", ev); return; }
      const pa = a as Player, pb = b as Player;
      const teammates = pa.teamId && pa.teamId === pb.teamId;
      if (s.data.teammates && !teammates && pa.kind === "player" && pb.kind === "player") { resolveStoryline(w, s, "traded", ev, { why: "one of them is gone" }); return; }
      if (rng.chance(r.escalate)) {
        if (s.stage === "words") {
          if (s.visibility === "secret") s.visibility = "public";
          if (s.bettableDay === undefined) s.bettableDay = w.day;
          beat(w, s, "public_spat", ev, { how: rng.pick(["shouting match in the dugout", "traded insults in the papers", "a shove at batting practice", "a sign in his locker"]) });
          shiftRelation(w, a.id, b.id, -1, "the feud", "rival");
        } else {
          const where = teammates ? "clubhouse" : rng.chance(0.5) ? "bar" : "parking lot";
          const fe = fight(w, rng, [a.id, b.id], where, ev, s.id);
          resolveStoryline(w, s, "brawl", ev, { where, fightEvent: fe.id });
        }
      } else if (rng.chance(r.calm)) {
        setRelation(w, a.id, b.id, 1, "buried the hatchet", "friend");
        resolveStoryline(w, s, "reconciled", ev, { how: rng.pick(["a handshake at home plate", "drinks on the road trip", "a fishing trip", "the manager knocked their heads together", "a teammate's wedding"]) });
      }
    },
  },

  rivalry: {
    outcomes: ["brawl", "buried_hatchet", "season_over", "death"], hit: ["brawl"], window: 30, timeout: [200, "season_over"],
    question: (w, s) => `Will ${nm(w, s.people[0])} and ${nm(w, s.people[1])} brawl within 30 days?`,
    rates: (w, s) => {
      const a = living(w, s.people[0]), b = living(w, s.people[1]);
      const hot = (x: typeof a) => (hasT(x, "HOTHEAD") ? 1.8 : 1);
      return { expose: 0.2, escalate: 0.01 * hot(a) * hot(b), calm: 0.004 * (hasT(a, "PIOUS") || hasQ(a, "CHARITABLE") ? 2 : 1) };
    },
    step: (w, s, rng, _c, ev, r) => {
      const a = living(w, s.people[0]), b = living(w, s.people[1]);
      if (!a || !b) { resolveStoryline(w, s, "death", ev); return; }
      if (s.stage === "simmering" && rng.chance(r.escalate)) {
        beat(w, s, "boiling", ev, { how: rng.pick(["more words in the papers", "a staredown at the plate", "a pointed home run trot", "a dead fish delivered to his locker"]) });
        shiftRelation(w, a.id, b.id, -1, "the rivalry", "rival");
      } else if (s.stage === "boiling" && rng.chance(r.escalate * 0.25)) {
        const fe = fight(w, rng, [a.id, b.id], rng.pick(["bar", "hotel lobby", "parking lot"]), ev, s.id);
        resolveStoryline(w, s, "brawl", ev, { where: "off the field", fightEvent: fe.id });
      } else if (rng.chance(r.calm)) {
        setRelation(w, a.id, b.id, 0, "let it go", "rival");
        resolveStoryline(w, s, "buried_hatchet", ev, {});
      }
    },
  },

  gambling_debt: {
    outcomes: ["paid_off", "exposed", "ejected_from_league", "leg_broken", "went_to_commissioner", "death"], hit: ["exposed", "ejected_from_league", "leg_broken"], window: 30, timeout: [220, "paid_off"],
    question: (w, s) => `Will ${nm(w, s.people[0])}'s gambling debt end in scandal or injury within 30 days?`,
    rates: (w, s) => {
      const p = P(w, s.people[0]);
      const shaved = Number(s.data.shaved ?? 0);
      const rich = (p?.contract?.salary ?? 0) >= 500 ? 2 : 1;
      return {
        expose: exposure(w, s, 0.008 * (1 + shaved * 0.6)),
        escalate: 0.02 * (hasT(p, "GAMBLER") ? 1.3 : 1) * (hasT(p, "CROOKED") ? 1.6 : 1),
        calm: 0.012 * rich * (s.stage === "owes" ? 1 : 0.4),
      };
    },
    step: (w, s, rng, _c, ev, r) => {
      const p = P(w, s.people[0]);
      if (!p) { resolveStoryline(w, s, "ended_quietly", ev, { why: "out of baseball" }); return; }
      const amount = Number(s.data.amount ?? 1000);
      if (s.stage === "owes") {
        if (rng.chance(r.escalate)) {
          beat(w, s, "leaned_on", ev, { how: rng.pick(["two of Bobby's men visited his hotel", "a dead fish in his glove", "his car was towed with a note inside", "a phone call at 3 a.m."]) });
          addConcern(w, p, { kind: "debt", about: s.people[1], until: w.day + 80, weight: -3, storyline: s.id, note: `owes $${amount}` });
        } else if (rng.chance(r.calm)) {
          if (s.people[1]) shiftRelation(w, p.id, s.people[1], 2, "paid up", "owes");
          dropConcern(p, "debt");
          resolveStoryline(w, s, "paid_off", ev, { publicise: false });
        }
      } else if (s.stage === "leaned_on") {
        const honest = (hasT(p, "PIOUS") || hasT(p, "LOYAL") || hasT(p, "SNITCH")) && !hasT(p, "CROOKED");
        if (honest && rng.chance(0.03)) {
          if (s.people[1]) setRelation(w, p.id, s.people[1], -5, "went to the Commissioner", "grudge");
          resolveStoryline(w, s, "went_to_commissioner", ev, { how: "he told the Commissioner everything" });
          gainFame(w, rng, p, 4, ev, "blew the whistle");
        } else if (rng.chance(r.escalate)) {
          if (hasT(p, "CROOKED") || rng.chance(0.3)) {
            beat(w, s, "shaving", ev, { how: "agreed to 'take a little off' in certain games" });
            addConcern(w, p, { kind: "shaving", about: s.people[1], until: w.day + 120, weight: -2, storyline: s.id, note: "throwing games" });
          } else if (w.day - (s.log[s.log.length - 1]?.day ?? w.day) > 20) {
            p.injury = { kind: rng.pick(["broken leg ('fell down some stairs')", "broken hand ('car door')", "broken kneecap ('slipped in the tub')"]), daysLeft: 30 + rng.int(40) };
            resolveStoryline(w, s, "leg_broken", ev, { how: "Bobby's men collected", days: p.injury.daysLeft });
          }
        } else if (rng.chance(r.calm)) {
          resolveStoryline(w, s, "paid_off", ev, { publicise: false });
        }
      } else if (s.stage === "shaving") {
        const shaved = Number(s.data.shaved ?? 0);
        const caught = 0.006 * (1 + shaved * 0.8) * (s.visibility === "secret" ? 1 : 3) * (1 + s.nudges.expose);
        if (rng.chance(caught)) {
          const banned = (shaved >= 6 && hasT(p, "CROOKED")) || (shaved >= 8 && rng.chance(0.5));
          const e = resolveStoryline(w, s, banned ? "ejected_from_league" : "exposed", ev, { shaved, games: s.data.games, how: rng.pick(["a betting-line analyst noticed", "a teammate testified", "a wiretap on Bets By Bobby", "his bookie's ledger turned up"]) });
          gainFame(w, rng, p, 6, ev, "point shaving");
          bumpHouse(w, p.family.house, -6);
          addDrama(p, { kind: "scandal", since: w.day, weight: -4, note: "point shaving" });
          if (banned) banFromLeague(w, rng, p, ev, "point shaving", e.id);
          else p.injury = { kind: "suspension (gambling)", daysLeft: 30 };
        } else if (shaved >= 3 && rng.chance(0.02)) {
          dropConcern(p, "shaving");
          resolveStoryline(w, s, "paid_off", ev, { publicise: false, shaved });
        }
      }
    },
  },

  hot_seat: {
    outcomes: ["fired", "survived", "death"], hit: ["fired"], window: 15, timeout: [200, "survived"],
    question: (w, s) => `Will ${w.teams[s.teams[0]]?.city ?? "the club"} fire ${nm(w, s.people[0])} within 15 days?`,
    rates: (w, s, ctx) => {
      const t = w.teams[s.teams[0]];
      const rec = ctx.table?.[s.teams[0]];
      const owner = t ? w.npcs[w.factions[t.factionId]?.leaderId ?? ""] : undefined;
      const mgr = living(w, s.people[0]);
      let streak = 0;
      if (rec) for (let i = rec.seq.length - 1; i >= 0 && rec.seq[i] === "L"; i--) streak++;
      const pct = rec && rec.w + rec.l ? rec.w / (rec.w + rec.l) : 0.5;
      const ownerF = (hasT(owner, "HOTHEAD") ? 1.8 : 1) * (hasT(owner, "GREEDY") ? 1.3 : 1) * (hasT(owner, "LOYAL") || hasT(owner, "PIOUS") ? 0.7 : 1);
      const blowups = Number(s.data.blowups ?? 0);
      const fire = (0.003 + Math.max(0, streak - 4) * 0.006 + Math.max(0, 0.45 - pct) * 0.08) * ownerF * (1 + blowups * 0.5) * (fameOf(mgr) > 50 ? 0.7 : 1);
      return { expose: 0.06, escalate: ctx.phase === "regular" ? fire : 0, calm: 0 };
    },
    step: (w, s, rng, ctx, ev, r) => {
      const team = w.teams[s.teams[0]];
      const mgr = w.npcs[s.people[0]];
      if (!team || !mgr || team.managerId !== mgr.id) { resolveStoryline(w, s, mgr ? "survived" : "death", ev, { why: "moved on" }); return; }
      const rec = ctx.table?.[team.id];
      const last10 = rec ? [...rec.seq.slice(-10)].filter(c => c === "W").length : 5;
      if (ctx.phase !== "regular") return;
      const pctNow = rec ? rec.w / Math.max(1, rec.w + rec.l) : 0.5;
      if (last10 >= 8 && pctNow >= 0.47 && w.day - s.startedDay >= 10) { resolveStoryline(w, s, "survived", ev, { how: `won ${last10} of 10` }); return; }
      if (s.stage === "warm" && rec && (rec.seq.endsWith("LLLLL") || rec.w / Math.max(1, rec.w + rec.l) < 0.4)) {
        s.visibility = "public";
        beat(w, s, "hot", ev, { how: rec.seq.endsWith("LLLLL") ? "another losing streak" : "the owner's 'vote of confidence'" });
      }
      // public blow-ups: tirades, thrown furniture
      if (rng.chance(hasT(mgr, "HOTHEAD") ? 0.04 : 0.012)) {
        s.data.blowups = Number(s.data.blowups ?? 0) + 1;
        beat(w, s, s.stage, ev, { blowup: rng.pick(["threw the postgame spread at a reporter", "called the owner 'a cheap so-and-so' on the radio", "tore out a dugout phone", "challenged a heckler to a fistfight", "benched the whole infield for a day"]) });
      }
      if (rng.chance(r.escalate)) {
        const chem = Number(s.data.chemistry ?? 0);
        const cause = Number(s.data.blowups ?? 0) > 0 && rng.chance(0.5) ? "public blowup" : chem < -1 ? "clubhouse revolt" : rec && rec.seq.endsWith("LLLLLL") ? "losing streak" : "the owner's whim";
        const e = resolveStoryline(w, s, "fired", ev, { cause, record: rec ? `${rec.w}-${rec.l}` : undefined });
        fireManager(w, rng, team.id, cause, ev, e.id);
      }
    },
  },

  holdout: {
    outcomes: ["signed", "traded", "retired"], hit: ["signed"], window: 10, timeout: [90, "signed"],
    question: (w, s) => `Will ${nm(w, s.people[0])} end his holdout within 10 days?`,
    rates: (w, s, ctx) => ({ expose: 0.3, escalate: 0.006, calm: ctx.phase === "offseason" ? 0.08 : 0.045 }),
    step: (w, s, rng, _c, ev, r) => {
      const p = P(w, s.people[0]);
      if (!p) { resolveStoryline(w, s, "retired", ev); return; }
      const clear = () => { if (p.injury?.kind === "holdout") delete p.injury; dropConcern(p, "holdout"); };
      if (rng.chance(r.calm)) {
        clear();
        resolveStoryline(w, s, "signed", ev, { salary: p.contract?.salary });
      } else if (rng.chance(r.escalate)) {
        clear();
        const e = resolveStoryline(w, s, "traded", ev, {});
        swapTrade(w, rng, p, ev, "holdout", e.id);
      }
    },
  },

  slump: {
    outcomes: ["broke_out", "demoted", "season_over"], hit: ["broke_out"], window: 10, timeout: [120, "season_over"],
    question: (w, s) => `Will ${nm(w, s.people[0])} break out of his slump within 10 days?`,
    rates: () => ({ expose: 0.5, escalate: 0, calm: 0 }),
    step: (w, s, rng, _c, ev) => {
      const p = P(w, s.people[0]);
      if (!p) { resolveStoryline(w, s, "season_over", ev); return; }
      if (w.teams[p.teamId]?.level !== "ML") { resolveStoryline(w, s, "demoted", ev, { to: p.teamId }); return; }
      if ((p.form ?? 0) > 0.25) { dropConcern(p, "slump"); resolveStoryline(w, s, "broke_out", ev, {}); return; }
      if (!s.data.curse && hasT(p, "SUPERSTITIOUS") && rng.chance(0.05)) {
        s.data.curse = true;
        startStoryline(w, "curse", [p.id], [p.teamId], { visibility: "public", stage: "cursed", cause: rng.pick(CURSES), stakes: "his season" }, ev);
      }
    },
  },

  curse: {
    outcomes: ["lifted", "season_over"], hit: ["lifted"], window: 15, timeout: [120, "season_over"],
    question: (w, s) => `Will ${nm(w, s.people[0])}'s curse be lifted within 15 days?`,
    rates: () => ({ expose: 0.5, escalate: 0, calm: 0.035 }),
    step: (w, s, rng, _c, ev, r) => {
      const p = P(w, s.people[0]);
      if (!p) { resolveStoryline(w, s, "season_over", ev); return; }
      if ((p.form ?? 0) > 0.3 || rng.chance(r.calm)) {
        p.form = Math.max(p.form ?? 0, 0.3);
        resolveStoryline(w, s, "lifted", ev, { ritual: rng.pick(RITUALS) });
      }
    },
  },

  comeback: {
    outcomes: ["returned", "setback", "retired", "stalled"], hit: ["returned"], window: 30, timeout: [260, "stalled"],
    question: (w, s) => `Will ${nm(w, s.people[0])} be back in the majors within 30 days?`,
    rates: (w, s) => {
      const p = P(w, s.people[0]);
      return { expose: 0.5, escalate: 0.006 * (hasT(p, "FRAGILE") ? 2 : 1) * (hasT(p, "IRON_MAN") ? 0.4 : 1) * (hasT(p, "LAZY") ? 1.3 : 1), calm: 0 };
    },
    step: (w, s, rng, _c, ev, r) => {
      const p = P(w, s.people[0]);
      if (!p) { resolveStoryline(w, s, "retired", ev); return; }
      const hurt = p.injury && p.injury.daysLeft > 0;
      const team = w.teams[p.teamId];
      if (!hurt && team?.level === "ML" && team.roster.includes(p.id)) {
        dropConcern(p, "comeback");
        gainFame(w, rng, p, 3, ev, "comeback");
        resolveStoryline(w, s, "returned", ev, { daysOut: w.day - s.startedDay });
        return;
      }
      if (!hurt && s.stage === "rehab") beat(w, s, "rehab_assignment", ev, { team: p.teamId });
      if (hurt && rng.chance(r.escalate)) {
        const n = Number(s.data.setbacks ?? 0) + 1;
        s.data.setbacks = n;
        p.injury!.daysLeft += 20 + rng.int(25);
        if (n >= 2 && p.age >= 32 && rng.chance(0.5)) resolveStoryline(w, s, "retired", ev, { setbacks: n, why: "the body said no" });
        else beat(w, s, "setback", ev, { setbacks: n, daysLeft: p.injury!.daysLeft });
      }
    },
  },

  contract_year: {
    outcomes: ["re-signed", "big_payday", "walked", "traded"], hit: ["re-signed", "big_payday"], window: 400, timeout: [400, "re-signed"],
    question: (w, s) => `Will ${nm(w, s.people[0])} stay with ${w.teams[s.teams[0]]?.city ?? "his club"} after his contract year?`,
    rates: () => ({ expose: 1, escalate: 0, calm: 0 }),
    step: (w, s, _rng, _c, ev) => {
      const p = P(w, s.people[0]);
      if (!p) { resolveStoryline(w, s, "walked", ev, { why: "gone" }); return; }
      const t = w.teams[p.teamId];
      if (t && orgId(t) !== s.teams[0]) resolveStoryline(w, s, "traded", ev, { to: orgId(t) });
    },
  },

  rookie_watch: {
    outcomes: ["rookie_of_year", "solid", "sent_down"], hit: ["rookie_of_year"], window: 400, timeout: [300, "solid"],
    question: (w, s) => `Will ${nm(w, s.people[0])} win Rookie of the Year?`,
    rates: () => ({ expose: 1, escalate: 0, calm: 0 }),
    step: (w, s, _rng, _c, ev) => {
      const p = P(w, s.people[0]);
      if (!p) { resolveStoryline(w, s, "sent_down", ev); return; }
      const lv = w.teams[p.teamId]?.level;
      if (lv && lv !== "ML") {
        s.data.downDays = Number(s.data.downDays ?? 0) + 1;
        if (Number(s.data.downDays) >= 10) resolveStoryline(w, s, "sent_down", ev, { to: p.teamId });
      }
    },
  },

  stalker: {
    outcomes: ["arrested", "confrontation", "vanished"], hit: ["arrested"], window: 20, timeout: [120, "vanished"],
    question: (w, s) => `Will ${nm(w, s.people[0])}'s stalker be arrested within 20 days?`,
    rates: () => ({ expose: 0.15, escalate: 0.012, calm: 0.02 }),
    step: (w, s, rng, _c, ev, r) => {
      const p = living(w, s.people[0]);
      if (!p) { resolveStoryline(w, s, "vanished", ev); return; }
      if (rng.chance(r.calm)) {
        resolveStoryline(w, s, "arrested", ev, { how: rng.pick(["caught in the team bus luggage bay", "arrested in the bullpen dressed as a groundskeeper", "turned himself in for the reward"]) });
      } else if (rng.chance(r.escalate)) {
        if (s.stage === "letters") beat(w, s, "following", ev, { how: rng.pick(["seen outside his house", "booked the hotel room next door", "sent a cake shaped like his face"]) });
        else {
          addConcern(w, p, { kind: "stalker", about: s.people[1], until: w.day + 40, weight: -2.5, note: "shaken" });
          (p.fears ??= []).push({ kind: "crowds", strength: 2 });
          resolveStoryline(w, s, "confrontation", ev, { how: rng.pick(["confronted him in the players' lot", "broke into his home; he was unhurt", "rushed the field"]) });
        }
      }
    },
  },

  enhanced_watch: {
    outcomes: ["transferred", "cleared", "retired", "death"], hit: ["transferred"], window: 30, timeout: [300, "cleared"],
    question: (w, s) => `Will the Commissioner send ${nm(w, s.people[0])} to the Enhanced League within 30 days?`,
    rates: (w, s) => {
      const p = P(w, s.people[0]);
      const lvl = Math.max(0, ...(p?.powers ?? []).map(x => x.level));
      const used = Number(s.data.used ?? 0);
      const fame = fameOf(p);
      const team = p ? w.teams[p.teamId] : undefined;
      const owner = team ? w.factions[team.factionId]?.id : undefined;
      const heat = owner ? (relation(w, owner, "commish") < 0 ? 1.5 : relation(w, owner, "commish") >= 3 ? 0.6 : 1) : 1;
      return {
        expose: 0.05 * (0.5 + fame / 30) * (1 + used * 0.5),
        escalate: 0.007 * (1 + lvl * 0.5) * (0.5 + fame / 40) * (1 + used * 0.4) * heat * (s.stage === "investigation" ? 2 : 1),
        calm: lvl > 0 ? 0.002 : 0,
      };
    },
    step: (w, s, rng, _c, ev, r) => {
      const p = P(w, s.people[0]);
      if (!p) { resolveStoryline(w, s, "retired", ev); return; }
      if (w.teams[p.teamId]?.level === "EL") { resolveStoryline(w, s, "transferred", ev, { already: true }); return; }
      if (rng.chance(r.escalate)) {
        if (s.stage === "whispers") {
          if (s.visibility === "secret") s.visibility = "rumoured";
          if (s.bettableDay === undefined) s.bettableDay = w.day;
          beat(w, s, "investigation", ev, { how: rng.pick(["the Commissioner's office sent a man with a clipboard", "an opposing manager filed a protest", "SportsWire ran the slow-motion photos", "a scientist from Volta Power & Light asked for a blood sample"]) });
        } else {
          const e = resolveStoryline(w, s, "transferred", ev, { cause: s.data.cause });
          transferHook?.(w, rng, p, ev, String(s.data.cause ?? "unexplained"), e.id);
        }
      } else if (rng.chance(r.calm)) {
        p.powers = undefined;
        resolveStoryline(w, s, "cleared", ev, { how: "the power faded; the Commissioner lost interest" });
      }
    },
  },

  weird: {
    outcomes: ["returned", "returned_changed", "never_returned"], hit: ["returned", "returned_changed"], window: 7, timeout: [60, "never_returned"],
    question: (w, s) => `Will ${nm(w, s.people[0])} turn up within 7 days?`,
    rates: () => ({ expose: 0.6, escalate: 0, calm: 0 }),
    step: () => { /* driven by weird.ts */ },
  },
};

const CURSES = [
  "a fan's hex after a foul ball hit his hat", "sold his lucky glove at a yard sale", "broke a mirror in the visitors' clubhouse",
  "a raccoon crossed his path at the ballpark", "a fortune teller in Natchez", "stepped on the foul line three days running",
];
const RITUALS = [
  "had his bats blessed by Brother Amos", "buried a chicken bone under second base", "wore the same socks for nine days",
  "slept in the dugout", "bought back the lucky glove for $400", "had a fortune teller reverse it (cash only)",
];

// --- consequences shared by several kinds -------------------------------------------------------------

/** A fight between two people: maybe an injury, maybe suspensions; relationships sour; fame rises. */
export function fight(world: World, rng: Rng, ids: [string, string], where: string, events: LifeEvent[], storyline?: string): LifeEvent {
  const [a, b] = ids.map(id => living(world, id));
  const hurt: { id: string; days: number }[] = [];
  for (const x of [a, b]) {
    if (!x || x.kind !== "player") continue;
    if (rng.chance(where === "clubhouse" ? 0.25 : where === "on_field" ? 0.06 : 0.25)) {
      const days = 3 + rng.int(14);
      (x as Player).injury = { kind: rng.pick(["broken hand (fight)", "black eye and stitches", "sprained wrist (fight)"]), daysLeft: days };
      hurt.push({ id: x.id, days });
    }
  }
  const suspended: string[] = [];
  if (where === "on_field" ? rng.chance(0.35) : where !== "clubhouse" && rng.chance(0.3)) {
    for (const x of [a, b]) if (x?.kind === "player" && !(x as Player).injury) { (x as Player).injury = { kind: "suspension (fighting)", daysLeft: 3 + rng.int(4) }; suspended.push(x.id); }
  }
  if (a && b) setRelation(world, a.id, b.id, Math.min(-3, relation(world, a.id, b.id) - 1), `${where} fight`, "rival");
  for (const x of [a, b]) if (x) gainFame(world, rng, x, 2, events, "fight");
  const teams = [a, b].map(x => (x as Player | undefined)?.teamId).filter(Boolean) as string[];
  const e = mkEvent(world, "fight", ids, [...new Set(teams)], { sub: where === "clubhouse" ? "clubhouse" : where === "on_field" ? "on_field" : "bar", where, hurt, suspended, storyline });
  events.push(e);
  return e;
}

/** Church-owned clubs (and any club with a pious owner) cut scandal-plagued fringe players. */
export function maybeCutForScandal(world: World, rng: Rng, p: Player, events: LifeEvent[], scandal: string, eventId?: string) {
  const team = world.teams[p.teamId];
  if (!team) return;
  const faction = world.factions[team.factionId];
  const owner = world.npcs[faction?.leaderId ?? ""];
  const strict = faction?.kind === "church" || hasT(owner, "PIOUS");
  const fringe = fameOf(p) < 40;
  if (!rng.chance((strict ? 0.5 : 0.08) * (fringe ? 1 : 0.3))) return;
  const org = orgId(team);
  movePlayer(world, p, FREE_AGENT);
  events.push(mkEvent(world, "release", [p.id], [team.id], { from: team.id, reason: `cut after ${scandal}`, scandal, eventOf: eventId, dramatic: true }));
  balanceOrg(world, org, rng, events, { reason: "scandal" });
}

/** Banned for life: out of the league, into the archive of disgrace (an NPC "former player"). */
export function banFromLeague(world: World, rng: Rng, p: Player, events: LifeEvent[], why: string, eventId?: string) {
  events.push(mkEvent(world, "release", [p.id], [p.teamId], { reason: `banned for life: ${why}`, banned: true, eventOf: eventId, dramatic: true }));
  retireHook?.(world, rng, p, events, `banned (${why})`);
}

/** Set by offseason.ts to avoid an import cycle. */
export let retireHook: ((w: World, rng: Rng, p: Player, ev: LifeEvent[], reason: string) => void) | undefined;
export function setRetireHook(f: typeof retireHook) { retireHook = f; }
/** Set by family.ts. */
export let hireHook: ((w: World, rng: Rng, teamId: string, ev: LifeEvent[], replacing: string) => Npc) | undefined;
export function setHireHook(f: typeof hireHook) { hireHook = f; }
/** Set by life/enhanced.ts. */
export let transferHook: ((w: World, rng: Rng, p: Player, ev: LifeEvent[], reason: string, eventOf?: string) => void) | undefined;
export function setTransferHook(f: typeof transferHook) { transferHook = f; }
/** Set by trades.ts. */
export let swapHook: ((w: World, rng: Rng, p: Player, ev: LifeEvent[], reason: string) => boolean) | undefined;
export function setSwapHook(f: typeof swapHook) { swapHook = f; }
function swapTrade(w: World, rng: Rng, p: Player, ev: LifeEvent[], reason: string, eventOf: string) {
  void eventOf;
  swapHook?.(w, rng, p, ev, reason);
}

/** Dramatic mid-season firing; two in a season and the owner fires the GM too. */
export function fireManager(world: World, rng: Rng, teamId: string, cause: string, events: LifeEvent[], eventOf?: string) {
  const team = world.teams[teamId];
  const m = world.npcs[team.managerId];
  if (m) {
    m.role = m.age < 62 && rng.chance(0.5) ? "scout" : "citizen";
    if (m.role === "citizen") { m.active = false; m.occupation = hasT(m, "DRUNK") ? "town drunk" : "former manager"; }
    addConcern(world, m, { kind: "hot_seat", until: world.day + 60, weight: -3, note: "fired" });
    gainFame(world, rng, m, 3, events, "fired");
    events.push(mkEvent(world, "fire", [m.id], [teamId], { role: "manager", cause, midseason: true, eventOf, dramatic: true }));
  }
  const fired = (world.seq[`fired:${teamId}:${world.season}`] = (world.seq[`fired:${teamId}:${world.season}`] ?? 0) + 1);
  hireHook?.(world, rng, teamId, events, m ? shortName(m) : "nobody");
  if (fired >= 2 && team.gmId && world.npcs[team.gmId]) {
    const gm = world.npcs[team.gmId];
    gm.role = "citizen"; gm.active = false; gm.occupation = "former general manager";
    events.push(mkEvent(world, "fire", [gm.id], [teamId], { role: "gm", cause: "two managers in one season", midseason: true, dramatic: true }));
    hireGM(world, rng, teamId, events);
  }
}

export function hireGM(world: World, rng: Rng, teamId: string, events: LifeEvent[]): Npc {
  const team = world.teams[teamId];
  const pool = Object.values(world.npcs).filter(n => (n.role === "scout" || (n.role === "coach" && n.factionId === team.factionId)) && n.age < 66);
  const gm = pool.length ? rng.pick(pool) : createNpc(world, rng, { sex: rng.chance(0.15) ? "F" : "M", age: 38 + rng.int(20), role: "gm", factionId: team.factionId });
  gm.role = "gm"; gm.factionId = team.factionId; gm.active = true; gm.occupation = undefined;
  team.gmId = gm.id;
  events.push(mkEvent(world, "hire", [gm.id], [teamId], { role: "gm" }));
  return gm;
}

// --- props --------------------------------------------------------------------------------------------

export interface BettableStoryline { storyline: Storyline; props: PropQuestion[] }

const WHEN_OPTIONS = [
  { key: "d5", label: "≤5 days" }, { key: "d15", label: "6–15 days" }, { key: "d30", label: "16–30 days" }, { key: "later", label: "30+ days / not this season" },
];

/** Prop questions for a storyline (empty while it's still secret). */
export function propsFor(world: World, s: Storyline): PropQuestion[] {
  if (s.bettableDay === undefined) return [];
  const def = KINDS[s.kind];
  const B = s.bettableDay;
  const window = Math.min(def.window, 200);
  const label = (o: string) => o.replace(/_/g, " ");
  return [
    { id: `${s.id}:yes`, storylineId: s.id, question: def.question(world, s), type: "yesno", options: [{ key: "yes", label: "Yes" }, { key: "no", label: "No" }], closesDay: B + Math.max(2, Math.floor(window / 3)), resolveBy: B + window },
    { id: `${s.id}:when`, storylineId: s.id, question: `How long until the ${label(s.kind)} story involving ${nm(world, s.people[0])} is over?`, type: "buckets", options: WHEN_OPTIONS, closesDay: B + 3, resolveBy: B + 31 },
    { id: `${s.id}:how`, storylineId: s.id, question: `How will the ${label(s.kind)} story involving ${nm(world, s.people[0])} end?`, type: "buckets", options: def.outcomes.map(o => ({ key: o, label: label(o) })), closesDay: B + 5, resolveBy: B + def.timeout[0] + 1 },
  ];
}

/** Open storylines the public knows about (rumoured or public), with prop questions. */
export function bettableStorylines(world: World): BettableStoryline[] {
  return openStorylines(world).filter(s => s.visibility !== "secret" && s.bettableDay !== undefined).map(s => ({ storyline: s, props: propsFor(world, s) }));
}

/**
 * Winning option per prop question for a storyline, for every question that can be settled now
 * (exactly one key each). Unsettled questions are left out.
 */
export function resolveProps(world: World, storylineId: string): Record<string, string> {
  const s = (world.storylines ?? []).find(x => x.id === storylineId);
  const out: Record<string, string> = {};
  if (!s || s.bettableDay === undefined) return out;
  const def = KINDS[s.kind];
  const B = s.bettableDay;
  const res = s.resolved;
  for (const q of propsFor(world, s)) {
    if (q.type === "yesno") {
      if (res && def.hit.includes(res.outcome) && res.day <= q.resolveBy) out[q.id] = "yes";
      else if (res || world.day > q.resolveBy) out[q.id] = "no";
    } else if (q.id.endsWith(":when")) {
      if (res) {
        const d = res.day - B;
        out[q.id] = d <= 5 ? "d5" : d <= 15 ? "d15" : d <= 30 ? "d30" : "later";
      } else if (world.day - B > 30) out[q.id] = "later";
    } else if (res) {
      out[q.id] = def.outcomes.includes(res.outcome) ? res.outcome : def.outcomes[def.outcomes.length - 1];
    }
  }
  return out;
}

void teamOfP;
