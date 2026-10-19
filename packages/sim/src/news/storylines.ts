// Storyline desk: drama arcs from the life engine (life/storylines.ts). Each public beat
// (start, escalation, resolution) becomes a short wire story. Secret beats are never printed;
// rumoured beats go to the BBS and tips instead (rumorLine).

import type { World } from "../types.ts";
import type { Rng } from "../rng.ts";
import { capFirst, fullName, isPlayer, lastName, num, person, poss, pro, seeded, str, teamCity, teamName } from "./util.ts";
import type { LifeEventLike } from "./types.ts";
import type { DeskSpec } from "./drama.ts";

export interface StoryCtx {
  world: World; ev: LifeEventLike; data: Record<string, unknown>; rng: Rng; seed: string;
  kind: string; stage: string; outcome?: string; begins: boolean; revealed?: string;
  a?: string; b?: string; c?: string; A: string; AL: string; B: string; BL: string; T: string; tId?: string;
  he: string; his: string; He: string; His: string; cause?: string; how?: string; stakes?: string; why?: string;
}

export const isStorylineEvent = (ev: LifeEventLike) => !!str(ev.data?.storyline);
export const isSecret = (ev: LifeEventLike) => ev.data?.secret === true || ev.data?.visibility === "secret";
export const isRumoured = (ev: LifeEventLike) => ev.data?.visibility === "rumoured";

function ctx(world: World, ev: LifeEventLike, rng: Rng): StoryCtx {
  const data = ev.data ?? {};
  const ids = (ev.who ?? []).filter(id => person(world, id));
  const [a, b, c] = ids;
  const pa = person(world, a);
  const tId = ev.teams?.find(t => world.teams[t]) ?? (isPlayer(pa) ? pa.teamId : undefined);
  const he = pro(pa);
  return {
    world, ev, data, rng, seed: ev.id, kind: str(data.kind) ?? str(data.sub) ?? "", stage: str(data.stage) ?? "", outcome: str(data.outcome),
    begins: data.begins === true, revealed: str(data.revealed), a, b, c,
    A: a ? fullName(world, a, false) : "A player", AL: a ? lastName(world, a) : "Player",
    B: b ? fullName(world, b, false) : "another man", BL: b ? lastName(world, b) : "Other",
    T: teamName(world, tId), tId, he, his: poss(pa), He: capFirst(he), His: capFirst(poss(pa)),
    cause: str(data.cause), how: str(data.how), stakes: str(data.stakes), why: str(data.why),
  };
}

const money = (n: number | undefined) => (n === undefined ? undefined : `$${String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")}`);
const sentence = (s: string | undefined) => (s ? `${capFirst(s.replace(/[.\s]+$/, ""))}.` : "");

type Writer = (c: StoryCtx) => DeskSpec | undefined;

const ARCS: Record<string, Writer> = {
  affair: c => {
    if (c.outcome === "discovered") return { kind: "life", base: 2, tags: ["love", "letter", "camera"],
      heads: [`${c.AL} Affair Made Public`, `${c.AL} Admits Affair`], d: [c.how ? `${capFirst(c.how)}` : `${c.A}'s affair is now known`],
      body: [`${c.A} of the ${c.T} has acknowledged an affair${c.b ? ` with ${c.B}` : ""}. ${sentence(c.how)}`.trim(),
        `${c.His} wife was not at the ballpark Tuesday. ${c.AL} went ${seeded(c.seed, 0, 1)}-for-${seeded(c.seed, 3, 4)} and did not speak to reporters.`] };
    if (c.outcome === "ended_quietly") return undefined;
    return undefined;
  },
  marriage_trouble: c => {
    if (c.stage === "separated") return { kind: "life", heads: [`${c.AL}, Wife Separate`], d: [c.how ? capFirst(c.how) : `${c.A} and his wife have separated`],
      body: [`${c.A} and ${c.his} wife have separated, friends of the couple said. ${sentence(c.how)}`.trim(), `${c.AL} was in the lineup Tuesday.`] };
    if (c.outcome === "divorced") return { kind: "life", heads: [`${c.AL} Divorce Final`], d: [`Papers filed in ${teamCity(c.world, c.tId)}`],
      body: [`${c.A} and ${c.b ? c.B : `${c.his} wife`} are divorced, according to papers filed in ${teamCity(c.world, c.tId)}.`, `She keeps the house. He keeps the car and the dog.`] };
    if (c.outcome === "reconciled") return { kind: "brief", heads: [`${c.AL}, Wife Reconcile`], d: [c.how ? capFirst(c.how) : `The couple is back together`],
      body: [`${c.A} and ${c.his} wife have reconciled. ${sentence(c.how)}`.trim(), `They were seen together at the ballpark on Tuesday.`] };
    if (c.begins && c.cause === "the affair") return undefined;
    return undefined;
  },
  feud: c => {
    if (c.data.clone === true) return undefined; // the clone story covers it
    const press = c.data.withPress === true;
    if (c.begins || c.stage === "public_spat") return { kind: "life", tags: ["argument", "newspaper"],
      heads: press ? [`${c.AL} Feuding With SportsWire`] : [`${c.AL}, ${c.BL} Not Speaking`, `${c.AL}-${c.BL} Feud Goes Public`],
      d: [c.how ? capFirst(c.how) : c.cause ? `It began with ${c.cause}` : `Teammates say they have not spoken in a week`],
      body: press ? [`${c.A} has stopped speaking to SportsWire. ${c.cause ? `It began with ${c.cause}.` : ""}`.trim(), `${c.He} answered questions Tuesday by pointing at a sign taped inside ${c.his} locker. The sign says NO.`]
        : [`${c.A} and ${c.B} ${c.how ? `had a ${c.how}` : "are not speaking"}, according to teammates.${c.cause ? ` The dispute began with ${c.cause}.` : ""}`,
          `The two dress at opposite ends of the clubhouse. Manager ${lastName(c.world, c.world.teams[c.tId ?? ""]?.managerId)} said, "They don't have to like each other."`] };
    if (c.outcome === "reconciled") return { kind: "brief", heads: [`${c.AL}, ${c.BL} End Feud`], d: [c.how ? capFirst(c.how) : `The two shook hands`],
      body: [`${c.A} and ${c.B} have ended their feud. ${sentence(c.how)}`.trim(), `Both said the matter is closed.`] };
    if (c.outcome === "traded") return undefined; // the trade story covers it
    return undefined; // brawls come through as "fight" events
  },
  rivalry: c => {
    if (c.begins || c.stage === "boiling") return { kind: "life", tags: ["argument", "crowd"],
      heads: [`${c.AL}, ${c.BL} Rivalry Grows`, `${c.AL} and ${c.BL} Trade Words`],
      d: [c.how ? capFirst(c.how) : c.cause ? `It started with ${c.cause}` : `The two will face each other again this week`],
      body: [`${c.A} and ${c.B} ${c.how ? `exchanged ${c.how.replace(/^(more |a |an )/, "")}` : "are rivals"}.${c.cause ? ` It started with ${c.cause}.` : ""}`,
        `${c.AL} said, "I don't think about him." ${c.BL} said, "He thinks about me."`] };
    if (c.outcome === "buried_hatchet") return { kind: "brief", heads: [`${c.AL}, ${c.BL} Make Peace`], d: [`The two shook hands at home plate`],
      body: [`${c.A} and ${c.B} shook hands at home plate before Tuesday's game.`, `Both declined to say what changed.`] };
    return undefined;
  },
  gambling_debt: c => {
    const amt = money(num(c.data.amount));
    if (c.stage === "leaned_on") return { kind: "scandal", section: "Crime", base: 2, tags: ["gambling", "debt", "money"],
      heads: [`${c.AL} Owes Bookmaker${amt ? ` ${amt}` : ""}`, `${c.AL}'s Debts Come Due`], d: [c.how ? capFirst(c.how) : `Two men visited his hotel`],
      body: [`${c.A} owes ${amt ?? "money"} to a bookmaker, according to two people familiar with the debt. ${sentence(c.how)}`.trim(), `${c.AL} said, "I have it handled." The ${c.T} declined to comment.`] };
    if (c.stage === "shaving") return { kind: "scandal", base: 3, tags: ["gambling", "bet", "court"],
      heads: [`League Reviews ${c.AL}'s At-Bats`, `${c.AL} Named in Fix Inquiry`], d: [`Investigators examine games since the debt began`],
      body: [`The Commissioner's Office is reviewing games played by ${c.A} of the ${c.T}. Betting records show unusual wagers against the ${c.T} in ${seeded(c.seed, 3, 9)} of them.`, `"I'm in a slump," ${c.AL} said. "That's all it is."`] };
    switch (c.outcome) {
      case "exposed": return { kind: "scandal", base: 3, tags: ["gambling", "newspaper"], heads: [`${c.AL} Gambling Debt Exposed`], d: [`${c.A} owes ${amt ?? "a bookmaker"}; the league opens an inquiry`],
        body: [`${c.A} owes ${amt ?? "a large sum"} to Bets By Bobby, records obtained by SportsWire show.${c.cause ? ` The debt began with ${c.cause}.` : ""}`, `The Commissioner's Office has opened an inquiry.`] };
      case "ejected_from_league": return { kind: "scandal", base: 4, tags: ["court", "gambling"], heads: [`${c.AL} Banned for Life`, `League Bans ${c.AL} Over Gambling`], d: [`The Commissioner cites "the integrity of the game"`],
        body: [`The Commissioner has banned ${c.A} from baseball for life. The ruling cites gambling debts and games played while in debt.`, `${c.AL} cleaned out ${c.his} locker in the morning. ${c.He} took the nameplate.`] };
      case "leg_broken": return { kind: "scandal", section: "Crime", base: 3, tags: ["injury", "hospital", "police"], heads: [`${c.AL} Leg Broken; Police Investigate`, `${c.AL} Attacked, Out ${num(c.data.days) ?? "Indefinitely"}`], d: [`Police say the attack is connected to a debt`],
        body: [`${c.A} of the ${c.T} suffered a broken leg on Monday night. Police said the injury was not accidental.`, `${c.AL} is expected to miss ${num(c.data.days) ?? "several"} days. ${c.He} told police ${c.he} fell.`] };
      case "went_to_commissioner": return { kind: "scandal", base: 3, tags: ["office", "court"], heads: [`${c.AL} Goes to Commissioner`], d: [`${c.A} reports a bookmaker to the league`],
        body: [`${c.A} met with the Commissioner on Tuesday and reported a debt to a bookmaker. ${c.He} told the Commissioner everything.`, `${c.AL} has been given a police escort.`] };
    }
    return undefined;
  },
  hot_seat: c => {
    if (c.stage === "hot") {
      const streak = /losing streak/.test(c.how ?? "");
      return { kind: "brief", heads: [`${c.AL}'s Job in Question`, `${c.T} Owner Backs ${c.AL}`], d: [streak ? `The ${c.T} have lost five straight` : `The owner issues a statement of support`],
        body: [`${c.A}'s job as ${c.T} manager is in question. ${streak ? `The club has lost five straight.` : `The owner issued a statement of support on Monday.`}`, `The owner said ${c.AL} has his full support. He said it twice.`] };
    }
    if (c.outcome === "survived") return { kind: "brief", heads: [`${c.AL} Keeps His Job`], d: [c.how ? capFirst(c.how) : `The streak is over`],
      body: [`${c.A} will remain manager of the ${c.T}. ${sentence(c.how)}`.trim(), `${c.He} said ${c.he} never read the papers.`] };
    return undefined; // "fired" arrives as a fire event
  },
  holdout: c => {
    if (c.outcome === "signed") return { kind: "brief", heads: [`${c.AL} Ends Holdout, Signs`], d: [`${c.A} reports to the ${c.T}${num(c.data.salary) ? ` at $${num(c.data.salary)}k a year` : ""}`],
      body: [`${c.A} signed with the ${c.T} on Tuesday and reported to the ballpark.${num(c.data.salary) ? ` The contract pays $${num(c.data.salary)},000 a year.` : ""}`, `${c.He} took batting practice and said ${c.he} was glad to be back.`] };
    if (c.begins) return { kind: "life", heads: [`${c.AL} Holds Out`], d: [c.stakes ? `${c.A} wants ${c.stakes}` : `${c.A} does not report`],
      body: [`${c.A} did not report to the ${c.T}.${c.stakes ? ` ${c.He} wants ${c.stakes}.` : ""}`, `${c.His} agent said ${c.he} is working out at home.`] };
    return undefined;
  },
  slump: c => {
    if (c.begins) return { kind: "brief", heads: [`${c.AL} in Slump`], d: [c.cause ? capFirst(c.cause) : `${c.A} is hitless in his last ${seeded(c.seed, 14, 30)} at-bats`],
      body: [`${c.A} is in a slump. ${c.cause ? `${capFirst(c.cause)}.` : ""}`.trim(), `${c.He} has taken extra batting practice every day this week. ${c.He} has changed ${c.his} bat, ${c.his} stance and ${c.his} socks.`] };
    if (c.outcome === "broke_out") return { kind: "brief", heads: [`${c.AL} Breaks Out of Slump`], d: [`${c.A} has hits in four straight games`],
      body: [`${c.A}'s slump is over. ${c.He} has hits in four straight games.`, `${c.He} said ${c.he} went back to the old socks.`] };
    if (c.outcome === "demoted") return undefined; // transactions
    return undefined;
  },
  curse: c => {
    if (c.begins || c.stage === "cursed") return { kind: "life", tags: ["religion", "candle", "night"], heads: [`${c.AL} Believes He Is Cursed`], d: [c.cause ? capFirst(c.cause) : `${c.A} has not had a hit since`],
      body: [`${c.A} of the ${c.T} believes ${c.he} is cursed. The curse began with ${c.cause ?? "an incident he would not describe"}.`, `${c.He} has not had a hit since. ${c.He} has asked the clubhouse attendant to burn sage.`] };
    if (c.outcome === "lifted") return { kind: "brief", tags: ["religion", "church"], heads: [`${c.AL} Says Curse Is Lifted`], d: [str(c.data.ritual) ? capFirst(str(c.data.ritual)!) : `${c.A} has a hit`],
      body: [`${c.A} says the curse is lifted. ${str(c.data.ritual) ? `${c.He} ${str(c.data.ritual)}.` : ""}`.trim(), `${c.He} had two hits on Tuesday.`] };
    return undefined;
  },
  comeback: c => {
    if (c.begins) return { kind: "brief", heads: [`${c.AL} Begins Long Rehab`], d: [c.cause ? `${capFirst(c.cause)}; ${c.A} vows to return` : `${c.A} vows to return`],
      body: [`${c.A} began rehabilitation on Tuesday${c.cause ? ` after a ${c.cause}` : ""}.`, `${c.He} said ${c.he} will be back this season. Doctors would not give a date.`] };
    if (c.stage === "setback") return { kind: "brief", heads: [`Setback for ${c.AL}`], d: [`${c.A} will miss another ${num(c.data.daysLeft) ?? "several"} days`],
      body: [`${c.A} has had a setback in ${c.his} recovery. ${c.He} will miss another ${num(c.data.daysLeft) ?? "several"} days.`, `${c.He} said ${c.he} is not discouraged.`] };
    if (c.outcome === "returned") return { kind: "feature", base: 2, tags: ["practice", "training", "baseball"], heads: [`${c.AL} Returns After ${num(c.data.daysOut) ?? "Long"} Days`, `${c.AL} Back in Lineup`],
      d: [`${c.A} plays for the first time since ${c.his} injury`], body: [`${c.A} returned to the ${c.T} lineup Tuesday${num(c.data.daysOut) ? `, ${num(c.data.daysOut)} days after ${c.his} injury` : ""}.`, `The crowd stood when ${c.he} came to bat. ${c.He} grounded out to second.`] };
    if (c.outcome === "retired") return { kind: "life", heads: [`${c.AL} Retires After Setbacks`], d: [c.why ? capFirst(c.why) : `${c.A} ends his comeback`],
      body: [`${c.A} has retired. ${c.why ? `${capFirst(c.why)}, ${c.he} said.` : `${c.He} had ${num(c.data.setbacks) ?? "several"} setbacks.`}`, `${c.He} thanked the trainers.`] };
    return undefined;
  },
  contract_year: c => {
    if (c.outcome === "big_payday") return { kind: "brief", heads: [`${c.AL} Signs Big Contract`], d: [`${c.A} cashes in after his contract year`],
      body: [`${c.A} has signed a new contract with a raise. ${c.He} said ${c.he} would buy ${c.his} mother a house.`, `${c.His} mother said she likes her house.`] };
    return undefined;
  },
  rookie_watch: c => {
    if (c.begins && c.cause && !/prospect/.test(c.cause)) return { kind: "brief", heads: [`Rookie ${c.AL} Draws Attention`], d: [`${c.A} is the ${c.cause}`],
      body: [`${c.A} of the ${c.T} is the ${c.cause}. Scouts are watching ${c.his} at-bats.`, `${c.He} said ${c.he} does not think about it.`] };
    if (c.outcome === "rookie_of_year") return undefined; // award event covers it
    return undefined;
  },
  enhanced_watch: c => {
    if (c.stage === "investigation") return { kind: "scandal", base: 2, tags: ["office", "camera", "space"], heads: [`League Looks Into ${c.AL}`, `Commissioner Studies ${c.AL} Film`],
      d: [c.how ? capFirst(c.how) : `The Commissioner's Office has questions about ${c.A}`],
      body: [`The Commissioner's Office is investigating ${c.A} of the ${c.T}. ${sentence(c.how)}`.trim(), `Players found to have enhanced powers may be transferred to the Enhanced League. ${c.AL} said ${c.he} feels normal.`] };
    if (c.outcome === "cleared") return { kind: "brief", heads: [`${c.AL} Cleared by Commissioner`], d: [c.how ? capFirst(c.how) : `${c.A} stays in the Continental League`],
      body: [`The Commissioner's Office has closed its inquiry into ${c.A}. ${sentence(c.how)}`.trim(), `${c.AL} stays with the ${c.T}.`] };
    return undefined; // "transferred" arrives as a transfer event
  },
  stalker: c => {
    if (c.stage === "following") return { kind: "scandal", section: "Crime", tags: ["police", "letter"], heads: [`Fan Following ${c.AL}, Police Say`], d: [c.how ? capFirst(c.how) : `Police have been notified`],
      body: [`A fan has been following ${c.A} of the ${c.T}, police said. ${sentence(c.how)}`.trim(), `${c.AL} has asked for a security escort to his car.`] };
    if (c.outcome === "arrested") return { kind: "scandal", section: "Crime", base: 2, tags: ["police", "arrest"], heads: [`Fan Arrested in ${c.AL} Case`], d: [c.how ? capFirst(c.how) : `Police make an arrest`],
      body: [`Police arrested a man who had followed ${c.A} for several weeks. ${sentence(c.how)}`.trim(), `The man had ${seeded(c.seed, 40, 300)} photographs of ${c.AL} in his apartment.`] };
    if (c.outcome === "confrontation") return { kind: "scandal", section: "Crime", base: 2, tags: ["police", "fan"], heads: [`Fan Confronts ${c.AL}`], d: [c.how ? capFirst(c.how) : `${c.A} was not hurt`],
      body: [`A fan who had followed ${c.A} for weeks ${c.how ?? "confronted him"}. ${c.He} was not hurt.`, `Police took the man into custody.`] };
    return undefined;
  },
};

/** Story for a storyline beat; null when the beat must not be printed (secret / not newsworthy). */
export function storylineDesk(world: World, ev: LifeEventLike, rng: Rng): DeskSpec | null {
  if (isSecret(ev) || isRumoured(ev)) return null;
  const c = ctx(world, ev, rng);
  const w = ARCS[c.kind];
  return (w && w(c)) || null;
}

/** A one-line rumour for the BBS and tip mail (rumoured beats; never secret ones). */
export function rumorLine(world: World, ev: LifeEventLike): string | undefined {
  if (isSecret(ev) || !isStorylineEvent(ev)) return undefined;
  const d = ev.data ?? {};
  const a = ev.who?.[0], b = ev.who?.[1];
  const A = a && person(world, a) ? fullName(world, a, false) : undefined;
  const B = b && person(world, b) ? fullName(world, b, false) : undefined;
  if (!A) return undefined;
  switch (str(d.kind)) {
    case "affair": return `${A} has been seen at a motel on Route 9 on off days.`;
    case "feud": return `${A} and ${B ?? "a teammate"} are not speaking. ${str(d.cause) ? `It is about ${str(d.cause)}.` : ""}`.trim();
    case "marriage_trouble": return `${A} has been sleeping at the ballpark.`;
    case "gambling_debt": return `${A} owes money to Bets By Bobby.${num(d.amount) ? ` The figure is ${money(num(d.amount))}.` : ""}`;
    case "stalker": return `Someone has been leaving letters on ${A}'s windshield.`;
    case "hot_seat": return `${A} will be fired if they lose this weekend.`;
    default: return str(d.how) ? `${A}: ${str(d.how)}.` : undefined;
  }
}

/** Rumour lines for today's events (rumoured storyline beats only), for bbsPosts({ tips }) and tip mail. */
export function rumorLines(world: World, events: LifeEventLike[]): string[] {
  return events.filter(e => isRumoured(e)).map(e => rumorLine(world, e)).filter((x): x is string => !!x);
}
