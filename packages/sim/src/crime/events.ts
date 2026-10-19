// Event cards: trouble that needs a decision. Each card carries enough context to
// resolve without server lookups; resolveChoice returns effects for the server to apply.

import type { World } from "../types.ts";
import { Rng } from "../rng.ts";
import { opKind } from "./ops.ts";
import { crewName, crewRoleLabel } from "./recruit.ts";
import { OP_WHAT } from "../news/scandal.ts";
import type { CrewMember, CrimeEffect, EventCard, MailItem, NewsHook, OpOrder, OpOutcome, Risk } from "./types.ts";
import { cardPhoto, mailPhoto } from "./photos.ts";

const LAWYER: Record<Risk, number> = { low: 150, mod: 250, high: 400, lol: 300 };
const JAIL_DAYS = 14;

function judgeName(world: World, seed: string): string {
  // judges are flavour only: a stable name per case
  const r = new Rng(`judge:${seed}`);
  const officials = Object.values(world.npcs).filter(n => n.role === "official");
  const names = ["Hollis", "Pruitt", "Gorman", "Abernathy", "Whitcomb", "Delacroix", "Mudd"];
  return officials.length && r.chance(0.3) ? `Judge ${r.pick(officials).last}` : `Judge ${r.pick(names)}`;
}

function ctxFrom(out: OpOutcome, c: CrewMember) {
  return {
    orderId: out.orderId, opKind: out.kind, crewId: c.id, personId: c.personId, targetTeamId: out.targetTeamId,
    gameId: out.gameId, risk: opKind(out.kind)?.risk ?? "mod", crew: { ...c, skills: { ...c.skills } },
    participants: out.participants ?? (out.ownerId ? [out.ownerId] : []), syndicateId: out.syndicateId,
  };
}

const faceOf = (world: World, personId: string) => world.npcs[personId]?.face;

/** A crew member is in lockup. Their owner decides what happens next. */
export function arrestCard(world: World, out: OpOutcome, c: CrewMember, where: "gate" | "security" | "after" = "after"): EventCard {
  const def = opKind(out.kind);
  const name = crewName(world, c);
  const risk = def?.risk ?? "mod";
  const team = world.teams[out.targetTeamId ?? ""]?.name ?? "ballclub";
  const judge = judgeName(world, out.orderId);
  const what = where === "gate" ? "at the service gate before first pitch" : where === "security" ? "by hired clubhouse security" : "after the game";
  return {
    id: `${out.orderId}:arrest:${c.id}`, ownerId: c.ownerId, kind: "arrest", day: world.day, faceId: faceOf(world, c.personId),
    title: `${name} is in lockup`,
    body: `Picked up ${what} on suspicion of ${OP_WHAT[out.kind ?? ""] ?? "mischief"} at the ${team} game. ${judge} sets the hearing for tomorrow. ${name} has not made a statement.`,
    choices: [
      { key: "lawyer", label: "Hire a lawyer", cost: LAWYER[risk] },
      { key: "judge", label: `Lean on ${judge}`, heat: 2 },
      { key: "deal", label: "Let them take the deal", note: "you get named" },
      { key: "rot", label: "Let them rot", note: "loyalty drops" },
    ],
    defaultKey: "rot", ctx: ctxFrom(out, c),
  };
}

/** A low-loyalty or SNITCH crew member is talking to the D.A. */
export function snitchCard(world: World, out: OpOutcome, c: CrewMember): EventCard {
  const def = opKind(out.kind);
  const name = crewName(world, c);
  const risk = def?.risk ?? "mod";
  const judge = judgeName(world, out.orderId);
  const allies = (out.participants?.length ?? 1) > 1;
  return {
    id: `${out.orderId}:snitch:${c.id}`, ownerId: c.ownerId, kind: "snitch", day: world.day, faceId: faceOf(world, c.personId),
    title: `${name} is talking to the D.A.`,
    body: `The ${crewRoleLabel(c)} was caught ${OP_WHAT[out.kind ?? ""] ?? "on the job"} and told police the package was "just a delivery." The D.A. offers a deal if they name who they work for${allies ? ", and everyone else in the syndicate" : ""}.`,
    choices: [
      { key: "lawyer", label: "Hire a lawyer", cost: LAWYER[risk] + 100 },
      { key: "judge", label: `Lean on ${judge}`, heat: 2 },
      { key: "deal", label: "Let them take the deal", note: allies ? "you and your allies get named" : "you get named" },
      { key: "skip", label: "Buy a bus ticket out of town", cost: 60, note: "they leave the crew" },
    ],
    defaultKey: "deal", ctx: ctxFrom(out, c),
  };
}

export function hospitalCard(world: World, out: OpOutcome, c: CrewMember): EventCard {
  const name = crewName(world, c);
  return {
    id: `${out.orderId}:hosp:${c.id}`, ownerId: c.ownerId, kind: "hospital", day: world.day, faceId: faceOf(world, c.personId),
    title: `${name} is in the hospital`,
    body: `${name} is at St. Jude's Memorial, room 214. The bill is in your name.`,
    choices: [
      { key: "pay", label: "Pay the bill", cost: 120, note: "loyalty up" },
      { key: "walk", label: "Never heard of them", note: "loyalty down" },
    ],
    defaultKey: "walk", ctx: ctxFrom(out, c),
  };
}

export function turfCard(world: World, out: OpOutcome, rival: OpOrder): EventCard {
  const game = out.gameId ?? "";
  return {
    id: `${out.orderId}:turf:${rival.id}`, ownerId: out.ownerId ?? "", kind: "heat", day: world.day,
    title: "Another crew was at the game",
    body: `Another crew had people at the same game, working for the other side. Their man waved at our man. Our man waved back.`,
    choices: [
      { key: "truce", label: "Send a fruit basket" },
      { key: "escalate", label: "Send a message", heat: 1, note: "relations sour" },
    ],
    defaultKey: "truce",
    ctx: { orderId: out.orderId, opKind: out.kind, gameId: game, targetTeamId: out.targetTeamId, rivalOrderId: rival.id, rivalOwnerId: rival.ownerId, participants: out.participants, syndicateId: out.syndicateId },
  };
}

/** Too much heat: the commissioner's investigator is asking around. */
export function heatCard(world: World, ownerId: string, heat: number, seed: string): EventCard {
  return {
    id: `${seed}:heat:${ownerId}`, ownerId, kind: "heat", day: world.day,
    title: "An investigator is asking about you",
    body: `A man from the Commissioner's Office has been showing your photograph to hot dog vendors. He wears a raincoat. He has been at it for three days. (Heat: ${Math.round(heat)}.)`,
    choices: [
      { key: "laylow", label: "Lay low for a while", note: "heat down a little" },
      { key: "payoff", label: "Pay him off", cost: 300 },
      { key: "deny", label: "Deny everything", note: "coin flip" },
    ],
    defaultKey: "laylow", ctx: {},
  };
}

/** The D.A. named you: the league fines you. */
export function namedCard(world: World, ownerId: string, fine: number, seed: string, opKindId?: string): EventCard {
  return {
    id: `${seed}:named:${ownerId}`, ownerId, kind: "named", day: world.day,
    title: "The Commissioner has your name",
    body: `A sworn statement places you behind the ${opKind(opKindId)?.name.toLowerCase() ?? "recent incidents"}. The Commissioner's Office has faxed a fine of $${fine}.`,
    choices: [
      { key: "pay", label: "Pay the fine", cost: fine },
      { key: "appeal", label: "Appeal", heat: 1, note: "50/50" },
    ],
    defaultKey: "pay", ctx: { opKind: opKindId, fine },
  };
}

export interface ChoiceResult {
  mail: MailItem[];
  effects: CrimeEffect[];
  /** One line for the client ("Agnes walks. The lawyer sends a fruit basket."). */
  result: string;
  /** Follow-up cards (e.g. a fine after being named). */
  events: EventCard[];
}

/**
 * Resolve an event card choice. Unknown keys fall back to the card's default.
 * World-side changes (relationships) are applied here; account state (money, heat,
 * crew) comes back as effects for the server.
 */
export function resolveChoice(world: World, card: EventCard, key: string, rng: Rng): ChoiceResult {
  const ctx = card.ctx ?? {};
  const effects: CrimeEffect[] = [];
  const mail: MailItem[] = [];
  const events: EventCard[] = [];
  const valid = card.choices.some(c => c.key === key) ? key : card.defaultKey ?? card.choices[0]?.key ?? "";
  const choice = card.choices.find(c => c.key === valid);
  const owner = card.ownerId;
  const day = world.day;
  const r = rng.fork(`choice:${card.id}:${valid}`);
  const c = ctx.crew;
  const name = c ? crewName(world, c) : "your associate";
  const people = ctx.personId ? [ctx.personId] : [];
  const hook = (kind: NewsHook["kind"]): CrimeEffect => ({ kind: "story", hook: { kind, day, opKind: ctx.opKind ?? "", people, targetTeamId: ctx.targetTeamId ?? "", gameId: ctx.gameId } });
  const note = (subject: string, body: string[], kind: MailItem["kind"] = "op", from = "The Clubhouse BBS") =>
    mail.push({ id: `${card.id}:${valid}:m${mail.length}`, ownerId: owner, from, subject, body, day, kind });
  if (choice?.cost) effects.push({ kind: "money", ownerId: owner, delta: -choice.cost, why: choice.label });
  if (choice?.heat) effects.push({ kind: "heat", ownerId: owner, delta: choice.heat, why: choice.label });
  let result = "";

  const nameOwners = (fineEach: number) => {
    const named = ctx.participants?.length ? ctx.participants : [owner];
    for (const o of named) {
      effects.push({ kind: "heat", ownerId: o, delta: 4, why: `named by ${name}` });
      events.push(namedCard(world, o, fineEach, card.id, ctx.opKind));
    }
    effects.push(hook("deal"));
  };

  switch (card.kind) {
    case "arrest":
    case "snitch": {
      if (!c) break;
      const snitch = card.kind === "snitch";
      if (valid === "lawyer") {
        const p = 0.5 + 0.05 * c.skills.charm - (ctx.risk === "high" ? 0.1 : 0) - (snitch ? 0.05 : 0);
        if (r.chance(p)) {
          effects.push({ kind: "crew", crewId: c.id, status: "free", loyalty: Math.min(5, c.loyalty + 1) }, hook("acquitted"));
          result = `Not guilty. ${name} is released. The lawyer's bill follows.`;
        } else {
          effects.push({ kind: "crew", crewId: c.id, status: "jailed", until: day + JAIL_DAYS }, hook("convicted"));
          result = `Guilty. ${name} gets ${JAIL_DAYS} days in county jail.`;
        }
      } else if (valid === "judge") {
        if (r.chance(0.45 + 0.05 * c.skills.nerve)) {
          effects.push({ kind: "crew", crewId: c.id, status: "free" });
          result = `Case dismissed. The judge bought a boat on Friday.`;
        } else {
          effects.push({ kind: "heat", ownerId: owner, delta: 3, why: "judge squealed" }, { kind: "crew", crewId: c.id, status: "jailed", until: day + JAIL_DAYS }, hook("judge"));
          result = `The judge reported the call. ${name} stays in custody. Your name is in the report.`;
        }
      } else if (valid === "deal") {
        effects.push({ kind: "crew", crewId: c.id, status: "free", loyalty: Math.max(0, c.loyalty - 1), heat: Math.min(10, c.heat + 1) });
        nameOwners(snitch ? 300 : 200);
        result = `${name} is released. The D.A. has your name.`;
      } else if (valid === "skip") {
        effects.push({ kind: "crew", crewId: c.id, status: "gone" }, { kind: "heat", ownerId: owner, delta: -1, why: "no witness" }, hook("skipped"));
        result = `${name} left on the 6:40 Greyhound. ${name} did not say where.`;
      } else {
        // rot
        effects.push({ kind: "crew", crewId: c.id, status: "jailed", until: day + JAIL_DAYS, loyalty: Math.max(0, c.loyalty - 2) });
        result = `${name} serves the time. ${name} has asked who paid for the lawyer. No one did.`;
        if (c.loyalty - 2 <= 1 && r.chance(0.4)) {
          // left to rot, they start talking
          const out: OpOutcome = {
            orderId: ctx.orderId ?? card.id, success: false, modifiers: [], exposed: true, heat: 0, arrests: [c.id], mail: [], events: [],
            ownerId: owner, kind: ctx.opKind, gameId: ctx.gameId, targetTeamId: ctx.targetTeamId, participants: ctx.participants, syndicateId: ctx.syndicateId,
          };
          events.push(snitchCard(world, out, { ...c, loyalty: Math.max(0, c.loyalty - 2) }));
          result += " And they've asked to see the D.A.";
        }
      }
      note(`Re: ${card.title}`, [result]);
      break;
    }
    case "hospital": {
      if (!c) break;
      if (valid === "pay") {
        effects.push({ kind: "crew", crewId: c.id, status: "hospital", until: day + 2, loyalty: Math.min(5, c.loyalty + 1) });
        result = `The bill is paid. ${name} will be back in two days.`;
      } else {
        effects.push({ kind: "crew", crewId: c.id, status: "hospital", until: day + 6, loyalty: Math.max(0, c.loyalty - 2) });
        result = `${name} was moved to a bed in the hallway. ${name} has asked for a pen and paper.`;
      }
      note(`Re: ${card.title}`, [result]);
      break;
    }
    case "named": {
      const fine = ctx.fine ?? 200;
      if (valid === "appeal") {
        if (r.chance(0.5)) {
          result = "Appeal granted. The original fax was illegible.";
        } else {
          effects.push({ kind: "money", ownerId: owner, delta: -Math.round(fine * 1.5), why: "appeal denied" });
          result = "Appeal denied. The fine has been increased by half.";
        }
      } else result = "Fine paid. The matter is closed.";
      mail.push({ id: `${card.id}:${valid}:league`, ownerId: owner, from: "Commissioner's Office", subject: "Disciplinary matter", body: [result], day, kind: "league" });
      break;
    }
    case "heat":
    default: {
      if (ctx.rivalOwnerId) {
        if (valid === "escalate") {
          effects.push({ kind: "relation", a: owner, b: ctx.rivalOwnerId, delta: -2, reason: "turf war" });
          applyRelation(world, owner, ctx.rivalOwnerId, -2, "turf war");
          result = "A fish in a team jacket was left on their doorstep.";
          mail.push({ id: `${card.id}:${valid}:rival`, ownerId: ctx.rivalOwnerId, from: "Anonymous", subject: "A fish", body: ["A fish wearing a team jacket was left on your doorstep. Your section and row are written on the jacket."], day, kind: "threat" });
        } else {
          effects.push({ kind: "relation", a: owner, b: ctx.rivalOwnerId, delta: 1, reason: "fruit basket" });
          applyRelation(world, owner, ctx.rivalOwnerId, 1, "fruit basket");
          result = "A fruit basket was delivered. It was mostly pears. They sent a card back.";
        }
        note(`Re: ${card.title}`, [result]);
        break;
      }
      if (valid === "payoff") {
        if (r.chance(0.7)) { effects.push({ kind: "heat", ownerId: owner, delta: -4, why: "investigator paid" }); result = "The investigator has retired. He moved to Florida."; }
        else { effects.push({ kind: "heat", ownerId: owner, delta: 2, why: "bribe refused" }, { kind: "story", hook: { kind: "judge", day, opKind: "bribe_investigator", people: [], targetTeamId: "" } }); result = "He was wearing a wire under the raincoat."; }
      } else if (valid === "deny") {
        const ok = r.chance(0.5);
        effects.push({ kind: "heat", ownerId: owner, delta: ok ? -1 : 1, why: "denied everything" });
        result = ok ? "He wrote it down and left." : "He did not believe you were at the movies. He asked which movie.";
      } else {
        effects.push({ kind: "heat", ownerId: owner, delta: -2, why: "laying low" });
        result = "You stay home for a week. Heat cools a little.";
      }
      note(`Re: ${card.title}`, [result]);
    }
  }
  for (const m of mail) mailPhoto(m, ctx.opKind);
  for (const e of events) cardPhoto(e);
  return { mail, effects, result, events };
}

function applyRelation(world: World, a: string, b: string, delta: number, reason: string) {
  let rel = world.relationships.find(x => (x.a === a && x.b === b) || (x.a === b && x.b === a));
  if (!rel) { rel = { a, b, value: 0, reason }; world.relationships.push(rel); }
  rel.value = Math.max(-5, Math.min(5, rel.value + delta));
  rel.reason = reason;
}
