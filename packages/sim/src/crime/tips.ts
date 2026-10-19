// Tips: in a shared world, word gets around. Planned jobs leak to rival accounts as
// anonymous mail (never to the orderer's own syndicate), along with plenty of rumours
// that are flat wrong.

import type { World } from "../types.ts";
import { Rng } from "../rng.ts";
import { GEAR, groupSkill, opKind } from "./ops.ts";
import { crewRoleLabel } from "./recruit.ts";
import type { CrewMember, MailItem, OpOrder } from "./types.ts";
import { mailPhoto } from "./photos.ts";

export interface TipOpts {
  /** owner id -> syndicate id; allies never get tips about each other. */
  syndicateOf?: Record<string, string>;
  /** Games on the slate, for false rumours. */
  games?: { id: string; homeId: string; awayId: string }[];
  /** Crew lookup, so leaks can mention "a nun" and leakiness follows Sneak. */
  crew?: Record<string, CrewMember>;
  /** Max tips per recipient (default 2). */
  maxPer?: number;
  /** Recent non-baseball headlines ("DOCK STRIKE ENTERS DAY 3"), used as cover stories. */
  flavor?: string[];
}

const SOURCES = ["A Friend", "Anonymous", "Concerned Usher", "Deep Dugout", "Your Pager", "Unknown Fax", "Mrs. Kowalski (Section 9)"];

const LEAKS: Record<string, string[]> = {
  grease_mound: ["Someone bought a five-pound tub of Vaseline. It is for the {team} game."],
  rabbit_balls: ["A crate of 144 baseballs was delivered to the {team} park. The return address is a garage in Ohio."],
  raccoons: ["Someone ordered raccoons for the {team} game. Three sacks. Paid cash.", "A {role} bought burlap sacks on Tuesday and asked which side is the {team} bullpen."],
  cooler: ["A {role} bought twelve boxes of Ex-Lax. The {team} water cooler is unguarded after 4 p.m."],
  bribe_ump: ["An umpire working the {team} game was seen counting an envelope at the Denny's on Route 9."],
  laser: ["A {role} bought a laser pointer at RadioShack. The receipt says section 12, near the {team} dugout."],
  steal_signs: ["Opera glasses were seen in the {team} bleachers. There is no opera in this town."],
  lucky_glove: ["Someone asked the {team} clubhouse man which locker belongs to the closer."],
  sprinklers: ["Someone asked the {team} night watchman what time he takes his break."],
  heckle: ["Three people bought seats behind the {team} dugout. They brought a megaphone and typed notes."],
  love_letter: ["A {role} bought perfume and monogrammed stationery. The letter is for a {team} player's wife."],
  blackmail: ["A {role} with a telephoto lens has followed a {team} player for a week."],
  tip_wire: ["SportsWire received a call about the {team} clubhouse. Read the morning paper."],
  kidnap_mascot: ["Someone rented a 1968 Chrysler and asked when the {team} mascot arrives."],
  blackout: ["A {role} asked a stadium electrician where the {team} transformer room is."],
  security: ["The {team} hired guards for the clubhouse tonight."],
  smooth_over: ["A {role} with carnations has been visiting people close to the {team}."],
};

/**
 * Anonymous tips for `recipients` about today's planned orders. Real leaks depend on
 * the crew's Sneak (sloppy crews leak); false rumours fill in. Deterministic with rng.
 */
export function leakTips(world: World, orders: OpOrder[], recipients: string[], day: number, rng: Rng, opts: TipOpts = {}): MailItem[] {
  const out: MailItem[] = [];
  const maxPer = opts.maxPer ?? 2;
  const sorted = [...orders].sort((a, b) => (a.id < b.id ? -1 : 1));
  for (const to of [...recipients].sort()) {
    const r = rng.fork(`tips:${to}:${day}`);
    const mine: MailItem[] = [];
    for (const o of sorted) {
      if (mine.length >= maxPer) break;
      if (o.ownerId === to) continue;
      const toSyn = opts.syndicateOf?.[to];
      const synd = o.syndicateId ?? opts.syndicateOf?.[o.ownerId];
      if (toSyn && synd && toSyn === synd) continue;
      if (o.allies?.includes(to)) continue;
      const def = opKind(o.kind);
      if (!def) continue;
      const crew = o.crew.map(id => opts.crew?.[id]).filter((c): c is CrewMember => !!c);
      const sneak = crew.length ? groupSkill(crew, "sneak", o.gear) : 2;
      const loud = o.gear.reduce((a, g) => a + ((GEAR[g]?.exposure ?? 1) > 1 ? 0.04 : 0), 0);
      const p = Math.max(0.03, 0.22 - 0.035 * sneak + loud + (def.risk === "lol" ? 0.08 : 0));
      if (!r.chance(p)) continue;
      const role = crew.length ? crewRoleLabel(r.pick(crew)) : "stranger";
      mine.push(mailPhoto(tip(world, to, day, `${o.id}:tip:${to}`, r.pick(LEAKS[def.kind] ?? ["Something is planned for the {team} game."]), o.targetTeamId, role, r, true), def.kind));
    }
    // false rumours
    if (mine.length < maxPer && opts.games?.length && r.chance(0.18)) {
      const g = r.pick(opts.games);
      const teamId = r.chance(0.5) ? g.homeId : g.awayId;
      const kinds = Object.keys(LEAKS);
      let text = r.pick(LEAKS[r.pick(kinds)]);
      if (opts.flavor?.length && r.chance(0.4)) text += ` It may be connected to the ${r.pick(opts.flavor).toLowerCase().replace(/[.!]+$/, "")}.`;
      mine.push(mailPhoto(tip(world, to, day, `rumor:${day}:${to}:${g.id}`, text, teamId, r.pick(["nun", "hot dog vendor", "man in a Members Only jacket", "raccoon wrangler"]), r, false)));
    }
    out.push(...mine);
  }
  return out;
}

function tip(world: World, to: string, day: number, id: string, tmpl: string, teamId: string, role: string, r: Rng, truth: boolean): MailItem {
  const team = world.teams[teamId]?.name ?? "home";
  const text = tmpl.replaceAll("{team}", team).replaceAll("{role}", role);
  const sign = r.pick(["Don't say where you heard it.", "Burn this.", "This was sent from a pay phone.", "Do not reply to this number."]);
  return { id, ownerId: to, from: r.pick(SOURCES), subject: r.pick(["Heads up", "FYI", "re: tonight", "Information", "(no subject)"]), body: [text, sign], day, kind: "tip", truth };
}

/** Drama events a bettor would want to know about (debts, fixes, feuds, fights, the inexplicable). */
const DRAMA_TIPS: [RegExp, string[]][] = [
  [/point_shaving|shav|fix/, ["{player} has been seen with a man from Bets By Bobby. Do not bet on the {team} tonight.", "The league is looking at {player}'s at-bats. So should you."]],
  [/debt|gambl/, ["{player} owes money to a bookmaker. People who owe money sometimes go 0-for-4.", "{player} was at the Shamrock with two men in raincoats. He left with them."]],
  [/feud|fight|beanball/, ["{player} and a teammate are not speaking. The {team} clubhouse is quiet.", "There will be a beanball tonight. {player} has been told."]],
  [/affair|divorce/, ["{player}'s wife moved out on Monday. He slept at the ballpark."]],
  [/abduct|ufo|alien|resurrect|clone|histor|weird|power|ghost/, ["{player} has not been himself since he came back. He is hitting everything.", "The {team} are keeping something about {player} out of the papers."]],
  [/holdout|contract/, ["{player} will not report tomorrow. His agent has stopped answering."]],
];

/**
 * Tips built from today's life/drama events, for bettors. `recipients` each get at most one;
 * deterministic per (day, recipient). Unknown event kinds are skipped.
 */
export function dramaTips(world: World, events: { id: string; kind: string; who: string[]; teams?: string[]; data?: Record<string, unknown> }[], recipients: string[], day: number, rng: Rng): MailItem[] {
  const out: MailItem[] = [];
  const pool = events.filter(e => {
    const k = `${e.kind}:${String(e.data?.kind ?? "")}:${String(e.data?.sub ?? "")}`.toLowerCase();
    return e.data?.secret !== true && world.players[e.who?.[0] ?? ""] && DRAMA_TIPS.some(([re]) => re.test(k));
  });
  if (!pool.length) return out;
  for (const to of [...recipients].sort()) {
    const r = rng.fork(`dtips:${to}:${day}`);
    if (!r.chance(0.35)) continue;
    const e = r.pick(pool);
    const k = `${e.kind}:${String(e.data?.kind ?? "")}:${String(e.data?.sub ?? "")}`.toLowerCase();
    const lines = DRAMA_TIPS.find(([re]) => re.test(k))![1];
    const p = world.players[e.who[0]];
    const text = r.pick(lines).replaceAll("{player}", `${p.first} ${p.last}`).replaceAll("{team}", world.teams[p.teamId]?.name ?? "club");
    const sl = typeof e.data?.storyline === "string" ? e.data.storyline : undefined;
    out.push(mailPhoto({ id: `dtip:${day}:${to}:${e.id}`, ownerId: to, from: r.pick(SOURCES), subject: r.pick(["Heads up", "FYI", "Information"]), body: [text, r.pick(["Don't say where you heard it.", "Burn this."])], day, kind: "tip", truth: true, ...(sl ? { storylineId: sl } : {}) }));
  }
  out.push(...secretTips(world, recipients, day, rng));
  return out;
}

const SECRET_LINES: Record<string, string[]> = {
  affair: ["{a} has been seeing {b} on off days. The motel is on Route 9.", "{a} is having an affair. His wife does not know yet."],
  marriage_trouble: ["{a} and his wife are not speaking. He has been sleeping at the ballpark."],
  feud: ["{a} and {b} are not speaking. It has not reached the papers."],
  gambling_debt: ["{a} owes Bets By Bobby{amount}. Nobody outside the clubhouse knows.", "{a} is in debt to a bookmaker. Watch his at-bats."],
  hot_seat: ["The owner has a list of replacements for {a}. It is typed."],
  stalker: ["Someone has been leaving letters on {a}'s windshield. He has not told the club."],
  curse: ["{a} believes he is cursed. He has asked the clubhouse man to burn sage."],
};

/**
 * Tips that reveal secret storylines before they leak, so a bettor can get to the prop markets
 * first (and crews can aim ops at them). Each mail carries storylineId; the server marks the
 * arc as known to that account. Roughly one recipient in eight gets one per day.
 */
export function secretTips(world: World, recipients: string[], day: number, rng: Rng): MailItem[] {
  const secret = (world.storylines ?? []).filter(s => !s.resolved && s.visibility === "secret" && SECRET_LINES[s.kind] && (world.players[s.people[0]] || world.npcs[s.people[0]]))
    .sort((a, b) => (a.id < b.id ? -1 : 1));
  const out: MailItem[] = [];
  if (!secret.length) return out;
  for (const to of [...recipients].sort()) {
    const r = rng.fork(`stips:${to}:${day}`);
    if (!r.chance(0.12)) continue;
    const s = r.pick(secret);
    const nm = (id?: string) => { const p = id ? world.players[id] ?? world.npcs[id] : undefined; return p ? `${p.first} ${p.last}` : "someone"; };
    const amt = typeof s.data?.amount === "number" ? ` $${s.data.amount}` : "";
    const text = r.pick(SECRET_LINES[s.kind]).replaceAll("{a}", nm(s.people[0])).replaceAll("{b}", nm(s.people[1])).replaceAll("{amount}", amt);
    out.push(mailPhoto({ id: `stip:${day}:${to}:${s.id}`, ownerId: to, from: r.pick(SOURCES), subject: r.pick(["Not in the papers", "Information", "(no subject)"]), body: [text, "This has not been printed anywhere."], day, kind: "tip", truth: true, storylineId: s.id }));
  }
  return out;
}
