// Drama desk: personal lives, scandals and the inexplicable. Every event is reported in the
// same flat register as a box score, including the ones involving spacecraft.
//
// The life engine's drama kinds may arrive as LifeEvent.kind ("abduction") or as a sub-kind
// (kind "drama", data.kind "abduction"). Every data field is optional and guarded.

import type { World } from "../types.ts";
import { Rng } from "../rng.ts";
import { capFirst, fullName, isPlayer, lastName, num, numWord, person, poss, pro, seeded, str, teamCity, teamName, wasPhrase } from "./util.ts";
import type { LifeEventLike, Story } from "./types.ts";
import { isSecret, isStorylineEvent, storylineDesk } from "./storylines.ts";

export interface DeskSpec {
  kind: Story["kind"];
  heads: string[];
  d: string[];
  body: string[];
  section?: string;
  /** Archive tags for the photo. */
  tags?: string[];
  /** Base prominence before fame. */
  base?: number;
}

interface Ctx {
  world: World; ev: LifeEventLike; data: Record<string, unknown>; rng: Rng; seed: string;
  a?: string; b?: string; A: string; AL: string; B: string; BL: string; T: string; tId?: string;
  what?: string; he: string; his: string;
}

/** Archive tags for drama kinds the archive's LIFE_TAGS doesn't know yet. */
export const DRAMA_TAGS: Record<string, string[]> = {
  debt: ["debt", "pawn", "gambling", "money"],
  gambling: ["gambling", "bet", "cards", "money"],
  gambling_dispute: ["gambling", "bet", "argument"],
  point_shaving: ["gambling", "bet", "court", "trial"],
  feud: ["argument", "brawl", "fight"],
  fight: ["brawl", "fight"],
  affair: ["love", "letter", "camera"],
  scandal: ["newspaper", "camera", "press"],
  holdout: ["contract", "office", "money"],
  fired: ["fire", "office"],
  firing: ["fire", "office"],
  comeback: ["practice", "training", "baseball"],
  fame: ["press", "camera", "crowd"],
  celebrity: ["celebrity", "society", "camera"],
  goal: ["practice", "baseball", "family"],
  fear: ["night", "doctor"],
  concern: ["family", "letter"],
  illness_in_family: ["hospital", "sick", "doctor"],
  bereavement: ["funeral", "cemetery"],
  newborn: ["baby", "birth"],
  abduction: ["space", "sky", "astronomy", "night"],
  alien: ["space", "sky", "astronomy"],
  powers: ["space", "electric", "illustration"],
  plane_crash: ["travel", "departure", "funeral", "death"],
  resurrection: ["church", "religion", "candle", "cemetery"],
  clone: ["doctor", "machine", "illustration"],
  historical: ["old", "illustration", "society"],
  ghost: ["night", "cemetery", "candle"],
  breakdown: ["hospital", "doctor"],
  rehab: ["hospital", "medicine", "bottle"],
  arrest: ["police", "arrest", "jail"],
  lawsuit: ["court", "lawyer", "trial"],
  suspension: ["office", "court"],
  rivalry: ["argument", "crowd"],
  friendship: ["family", "celebration"],
  mentor: ["practice", "baseball"],
  hall_of_fame: ["award", "trophy", "milestone"],
};

const key = (s: string | undefined) => (s ?? "").toLowerCase().replace(/[\s-]+/g, "_");

/** Which desk handler applies: data.kind / sub / type, then the event kind, then aliases. */
export function dramaKey(ev: LifeEventLike): string | undefined {
  const d = ev.data ?? {};
  const cands = [str(d.weird), str(d.type), str(d.event), str(d.kind), str(d.sub), str(d.drama), ev.kind].map(key);
  for (const c of cands) if (c && DESK[c]) return c;
  for (const c of cands) {
    const alias = Object.keys(ALIAS).find(k => c.includes(k));
    if (alias) return ALIAS[alias];
  }
  return undefined;
}

export function dramaTags(ev: LifeEventLike): string[] | undefined {
  const k = dramaKey(ev);
  return k ? DRAMA_TAGS[k] ?? DRAMA_TAGS[ALIAS[k] ?? ""] : undefined;
}

const ALIAS: Record<string, string> = {
  abduct: "abduction", ufo: "abduction", alien: "abduction", plane: "plane_crash", crash_landing: "plane_crash",
  resurrect: "resurrection", returned_from_dead: "resurrection", clone: "clone", double: "clone",
  historical: "historical", time_travel: "historical", abduction_return: "abduction", shav: "point_shaving", fix: "point_shaving",
  bet: "gambling_dispute", gambl: "gambling_dispute", fist: "fight", punch: "fight", brawl: "fight",
  fire: "fired", sack: "fired", famous: "fame", celebrity: "fame", talk_show: "fame",
  ghost: "ghost", haunt: "ghost", power: "powers",
};

/**
 * Write a story for a drama-tier event. Undefined: this desk doesn't cover it (caller may try
 * others). Null: covered, but must not be printed (secret or rumoured beats, minor beats).
 */
export function dramaDesk(world: World, ev: LifeEventLike, rng: Rng): DeskSpec | undefined | null {
  if (isSecret(ev)) return null;
  if (ev.kind === "drama" && isStorylineEvent(ev) && str(ev.data?.kind) !== "weird") return storylineDesk(world, ev, rng);
  let k = dramaKey(ev);
  if (isStorylineEvent(ev) && (ev.kind === "drama" || ev.kind === "weird")) {
    // weird arcs: the opening beat gets the sub-type story, the ending gets the return story
    if (ev.data?.visibility === "rumoured") return null;
    if (str(ev.data?.outcome) || ev.data?.begins === true) k = "weird_arc";
    else return null; // e.g. abduction_return: the storyline's resolution beat carries the story
  }
  if (!k) return undefined;
  const data = ev.data ?? {};
  const a = ev.who?.[0] && person(world, ev.who[0]) ? ev.who[0] : undefined;
  const b = ev.who?.[1] && person(world, ev.who[1]) ? ev.who[1] : undefined;
  const pa = person(world, a);
  const tId = ev.teams?.find(t => world.teams[t]) ?? (isPlayer(pa) ? pa.teamId : undefined);
  const c: Ctx = {
    world, ev, data, rng, seed: ev.id, a, b,
    A: a ? fullName(world, a, false) : str(data.name) ?? "A man", AL: a ? lastName(world, a) : str(data.name) ?? "Man",
    B: b ? fullName(world, b, false) : str(data.with) ?? str(data.other) ?? "another man", BL: b ? lastName(world, b) : str(data.with) ?? "Other",
    T: teamName(world, tId), tId, what: str(data.what) ?? str(data.note) ?? str(data.text), he: pro(pa), his: poss(pa),
  };
  const spec = DESK[k]?.(c);
  if (spec) spec.tags = spec.tags ?? DRAMA_TAGS[k];
  return spec;
}

const amount = (c: Ctx, lo: number, hi: number) => num(c.data.amount) ?? seeded(c.seed, lo, hi) * 100;
const money = (n: number) => `$${String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")}`;
const He = (c: Ctx) => capFirst(c.he);

const POWER_LINE: Record<string, string> = {
  FIREBALL: "throws a fastball that leaves a trail of smoke", STOPPER: "can stop a batted ball in midair with one hand",
  WARP_PITCH: "throws pitches that arrive slightly before they are released, according to his catcher", CLOUD_BALL: "throws a curveball that disappears into a small cloud",
  HYPER_HIT: "hits the ball harder than the radar gun can measure", LEAP_CATCH: "can jump eleven feet from a standing start",
  LASER_ARM: "throws from the outfield to home plate in a straight line, with a hum", WARP_RUN: "reaches second base without appearing to pass first",
};
const QUIRK_LINE: Record<string, string> = {
  GLOWS: "glows faintly in the dark", KNOWS_THINGS: "knows what pitch is coming, and other things", NO_SHADOW: "no longer casts a shadow",
  SPEAKS_TO_BIRDS: "speaks to birds, and that they answer",
};

const DESK: Record<string, (c: Ctx) => DeskSpec | undefined> = {
  // --- gambling
  debt: c => c.a ? {
    kind: "life", heads: [`${c.AL} Owes Money to Bookmaker`, `${c.AL}'s Gambling Debt Reported`],
    d: [`${c.A} owes ${money(amount(c, 4, 30))}, according to people familiar with it`],
    body: [`${c.A} of the ${c.T} owes ${money(amount(c, 4, 30))} to a local bookmaker, according to two people familiar with the debt.`,
      `${c.AL} was seen at the Shamrock on Tuesday night with two men in raincoats. He left with them at 1 a.m.`,
      `The ${c.T} said they are aware of the report. ${c.AL} did not return a call to ${c.his} pager.`] } : undefined,
  gambling_dispute: c => c.a ? {
    kind: "scandal", section: "Crime", base: 2, heads: [`${c.AL} in Dispute Over Gambling Debt`, `Bookmaker, ${c.AL} at Odds Over Money`],
    d: [`${c.A} and a bookmaker disagree about ${money(amount(c, 5, 40))}`],
    body: [`${c.A} is in a dispute with ${c.b ? c.B : "a bookmaker"} over ${money(amount(c, 5, 40))}, according to a police report filed Tuesday.`,
      `The report says the two men argued in a parking lot behind the ballpark. A car window was broken. No one was hurt.`,
      `${c.AL} told police the money was "a loan, sort of." No charges were filed.`] } : undefined,
  point_shaving: c => c.a ? {
    kind: "scandal", section: "Sports", base: 3, heads: [`League Reviews ${c.AL} Games for Fixing`, `${c.AL} Named in Point-Shaving Inquiry`, `Fix Probe Centers on ${c.T}`],
    d: [`Commissioner's Office reviewing ${num(c.data.games) ?? seeded(c.seed, 4, 11)} games; ${c.AL} denies taking money`],
    body: [`The Commissioner's Office is reviewing ${num(c.data.games) ?? seeded(c.seed, 4, 11)} games in which ${c.A} of the ${c.T} played, the office said Tuesday.`,
      `Investigators are examining betting records from Bets By Bobby. In each game under review, ${c.AL} ${c.what ?? "went hitless with the score close"}.`,
      `"I didn't take any money," ${c.AL} said. "I'm just in a slump."`,
      `If the charges are upheld, ${c.he} faces a lifetime ban.`] } : undefined,

  // --- relationships
  feud: c => c.a ? {
    kind: "life", heads: [`${c.AL}, ${c.BL} Not Speaking`, `${c.AL}-${c.BL} Feud Continues`],
    d: [c.what ? `${capFirst(c.what)}` : `Teammates say the two have not spoken in a week`],
    body: [`${c.A} and ${c.B} have not spoken since last week, according to teammates.${c.what ? ` The dispute concerns ${c.what.replace(/^feuding with [^ ]+ [^ ]+ over /, "")}.` : ""}`,
      `The two dress at opposite ends of the clubhouse. On Tuesday they stood at opposite ends of the dugout.`,
      `Manager ${lastName(c.world, c.world.teams[c.tId ?? ""]?.managerId)} said, "They don't have to like each other. They have to play."`] } : undefined,
  fight: c => {
    if (!c.a) return undefined;
    // only major-league fights are news (the life engine reports all levels)
    const lvls = [c.a, c.b].map(id => person(c.world, id)).filter(isPlayer).map(p => c.world.teams[p.teamId]?.level);
    if (!lvls.some(l => l === "ML")) return undefined;
    const where = str(c.data.where) ?? str(c.data.sub) ?? "clubhouse";
    const place = where === "clubhouse" ? `in the ${c.T} clubhouse` : where === "on_field" ? "on the field" : where === "bar" ? "outside a bar" : where;
    const when = where === "bar" ? "early Tuesday" : where === "on_field" ? "during Tuesday's game" : "before Tuesday's game";
    const hurt = Array.isArray(c.data.hurt) ? (c.data.hurt as { id?: string; days?: number }[]).filter(h => h && typeof h.id === "string") : [];
    const susp = Array.isArray(c.data.suspended) ? (c.data.suspended as unknown[]).filter((x): x is string => typeof x === "string") : [];
    const hurtLine = hurt.length ? hurt.map(h => `${lastName(c.world, h.id)} will miss ${h.days ?? "several"} days`).join(". ") + "." : `Neither player was seriously hurt.`;
    return {
      kind: "life", base: 2, heads: [`${c.AL}, ${c.BL} Fight ${where === "bar" ? "Outside Bar" : where === "on_field" ? "on Field" : "in Clubhouse"}`, `${c.AL} and ${c.BL} Come to Blows`],
      d: [hurt.length ? `${lastName(c.world, hurt[0].id)} hurt; ${susp.length ? "suspensions issued" : "no suspensions"}` : `No one seriously hurt; ${susp.length ? "suspensions issued" : "club says matter is closed"}`],
      body: [`${c.A} and ${c.B} fought ${place} ${when}, according to people who saw it.`,
        `${hurtLine}${susp.length ? ` The league suspended ${susp.map(id => lastName(c.world, id)).join(" and ")}.` : ""}`,
        `Neither player would discuss it.`],
    };
  },
  beanball: c => c.a && c.b ? {
    kind: "brief", tags: ["pitcher", "argument", "ejection"], heads: [`${c.AL} Hits ${c.BL}; Words Exchanged`, `${c.BL} Hit by ${c.AL} Pitch`],
    d: [str(c.data.why) ? `${capFirst(str(c.data.why)!)}, players say` : `Both benches warned`],
    body: [`${c.A} hit ${c.B} with a pitch ${c.data.injured ? `and ${c.BL} left the game` : "in the ribs"}. ${str(c.data.why) ? `Players on both clubs called it ${str(c.data.why)}.` : ""}`.trim(),
      `The umpire warned both benches. ${c.AL} said the pitch got away from him.`] } : undefined,
  hazing: c => c.a && c.b ? {
    kind: "brief", heads: [`${c.T} Rookie Hazed`, `${c.BL} Takes Hazing ${c.data.tookItBadly ? "Badly" : "in Stride"}`],
    d: [c.what ? capFirst(c.what) : `A clubhouse tradition`],
    body: [`${c.B}, a rookie, was hazed by ${c.A} on the road trip. ${c.what ? `${capFirst(c.what)}.` : ""}`.trim(),
      c.data.tookItBadly ? `${c.BL} did not find it funny. The two have not spoken since.` : `${c.BL} said it was fine.`] } : undefined,
  endorsement: c => c.a ? {
    kind: "brief", heads: [`${c.AL} Signs With ${str(c.data.brand) ?? "Sponsor"}`.slice(0, 48)],
    d: [`${c.A} will appear in advertisements${num(c.data.fee) ? ` for $${num(c.data.fee)}k` : ""}`],
    body: [`${c.A} of the ${c.T} has signed to appear in advertisements for ${str(c.data.brand) ?? "a regional company"}.${num(c.data.fee) ? ` The deal is worth $${num(c.data.fee)},000.` : ""}`,
      `Filming is scheduled for an off day.`] } : undefined,
  charity: c => c.a ? {
    kind: "brief", heads: [`${c.AL} Gives Back`], d: [c.what ? capFirst(c.what) : `${c.A} visits a hospital`],
    body: [`${c.A} of the ${c.T} ${c.what ?? "visited the children's ward at St. Jude's"}.`, `He did not tell the club in advance.`] } : undefined,
  affair: c => c.a ? {
    kind: "life", base: 2, heads: [`${c.AL} Affair Made Public`, `${c.AL} Admits Affair`],
    d: [c.what ? capFirst(c.what) : `${c.A}'s wife has moved out, neighbors say`],
    body: [`${c.A} of the ${c.T} ${c.what ? `has acknowledged an ${c.what}` : "has acknowledged an affair"}.`,
      `His wife moved out of the family home on Monday, neighbors said. She took the dog and the car.`,
      `${c.AL} played Tuesday and went ${seeded(c.seed, 0, 1)}-for-${seeded(c.seed, 3, 4)}. He did not speak to reporters.`] } : undefined,
  scandal: c => c.a ? {
    kind: "life", base: 2, heads: [`${c.AL} in Off-Field Incident`, `${c.AL} Cited by Police`, `${c.T} Discipline ${c.AL}`],
    d: [c.what ? `${c.AL} ${wasPhrase(c.what)}` : `${c.A} cited; club says it will handle it internally`],
    body: [`${c.A} of the ${c.T} ${c.what ? wasPhrase(c.what) : "was involved in an incident"}, according to police.`,
      `The club said it would handle the matter internally. ${c.AL} was in the lineup Tuesday.`,
      `"I made a mistake," ${c.AL} said. "It won't happen again."`] } : undefined,
  holdout: c => c.a ? {
    kind: "life", heads: [`${c.AL} Holds Out for New Contract`, `${c.AL} Absent From Camp`],
    d: [`${c.A} wants ${money(amount(c, 20, 90) * 10)} a year; club offers less`],
    body: [`${c.A} did not report to the ${c.T} on Tuesday. ${He(c)} is asking for ${money(amount(c, 20, 90) * 10)} a year.`,
      `The club has offered less. Neither side would say how much less.`,
      `${c.AL}'s agent said ${c.he} is "working out at home and keeping his options open." The ${c.T} said the offer stands.`] } : undefined,
  illness_in_family: c => c.a ? {
    kind: "life", heads: [`${c.AL} Leaves Club for Family Illness`, `${c.AL} Granted Leave`],
    d: [c.what ? `${capFirst(c.what)}; ${c.AL} is away indefinitely` : `${c.AL} is away indefinitely`],
    body: [`${c.A} has left the ${c.T} to be with ${c.his} family. ${c.what ? `${capFirst(c.what)}.` : ""}`.trim(),
      `The club said ${c.he} may return when ${c.he} is ready. Teammates signed a card.`] } : undefined,
  bereavement: c => c.a ? {
    kind: "life", heads: [`${c.AL} Mourns Loss`, `${c.AL} Away After Death in Family`],
    d: [`${c.T} grant leave; players will wear black armbands`],
    body: [`${c.A} is away from the ${c.T} after a death in ${c.his} family.`, `Players will wear black armbands for the rest of the homestand.`] } : undefined,
  newborn: c => c.a ? {
    kind: "brief", heads: [`${c.AL} Becomes a Father`], d: [`${c.AL} misses batting practice for the birth`],
    body: [`${c.A} of the ${c.T} became a father on Tuesday. The baby weighed seven pounds, ${seeded(c.seed, 1, 15)} ounces.`, `${c.AL} was back in the lineup the next day.`] } : undefined,

  // --- careers
  fired: c => c.a ? {
    kind: "brief", base: 2, heads: [`${c.T} Fire ${c.AL}`, `${c.AL} Dismissed by ${c.T}`],
    d: [c.what ? capFirst(c.what) : `Club cites "a difference in direction"`],
    body: [`The ${c.T} fired ${c.A} on Tuesday. ${c.what ? `${capFirst(c.what)}.` : `The club cited "a difference in direction."`}`,
      `${c.AL} learned of the decision by fax. ${He(c)} cleaned out ${c.his} office in eleven minutes.`,
      `${He(c)} did not comment.`] } : undefined,
  comeback: c => c.a ? {
    kind: "feature", base: 2, heads: [`${c.AL} Returns After ${num(c.data.years) ?? seeded(c.seed, 2, 6)} Years Away`, `${c.AL} Back in Uniform`],
    d: [`${c.A}, ${person(c.world, c.a)?.age ?? ""}, makes the ${c.T} roster`.replace(", ,", ",")],
    body: [`${c.A} was added to the ${c.T} roster on Tuesday. ${He(c)} last played ${num(c.data.years) ?? seeded(c.seed, 2, 6)} years ago.`,
      `${c.what ? `${capFirst(c.what)}. ` : ""}${He(c)} said ${c.he} has been throwing against a garage door every day.`,
      `"I never said I was done," ${c.AL} said. "Other people said it."`] } : undefined,
  fame: c => {
    if (!c.a) return undefined;
    const sub = str(c.data.sub);
    const why = str(c.data.why);
    if (sub === "endorsement") return DESK.endorsement(c);
    if (sub === "charity") return DESK.charity(c);
    if (sub === "nickname" && str(c.data.nickname)) {
      const nick = str(c.data.nickname)!;
      return { kind: "brief", heads: [`${c.AL} Now Known as '${nick}'`.slice(0, 48), `They Call ${c.AL} '${nick}'`.slice(0, 48)],
        d: [`The name appeared on a bedsheet in the bleachers${why ? ` after ${why}` : ""}`.slice(0, 90)],
        body: [`Fans of the ${c.T} have begun calling ${c.A} "${nick}."${why ? ` The name first appeared after ${why}.` : ""}`,
          `It was painted on a bedsheet in the left-field bleachers on Tuesday. ${c.AL} said ${c.he} has been called worse.`] };
    }
    const tier = str(c.data.tier);
    const tierLine: Record<string, string> = {
      "local favourite": `Children in ${teamCity(c.world, c.tId)} have begun copying ${c.his} batting stance.`,
      "fan club": `A fan club has formed. It meets on Thursdays at a bowling alley and has ${seeded(c.seed, 40, 300)} members.`,
      "household name": `${He(c)} has been asked to appear in an advertisement for a regional muffler chain. ${He(c)} will be paid in cash and mufflers.`,
      "national icon": `${He(c)} will appear on a late-night talk show Thursday. A cereal box is in production.`,
    };
    return {
      kind: "feature", heads: tier === "national icon" ? [`${c.AL} on Cereal Box, Talk Show`, `${c.AL} Becomes a National Name`] : tier === "household name" ? [`${c.AL} Signs Endorsement Deal`] : tier === "fan club" ? [`${c.AL} Fan Club Forms`, `${c.AL} Fans Organize`] : [`${c.AL} Becomes Local Favorite`, `${c.AL} Gains Following`],
      d: [`${tier ? capFirst(tier) : "Recognition"}${why ? ` after ${why}` : ""}; ${c.he} says ${c.he} does not mind`.slice(0, 90)],
      body: [`${c.A} of the ${c.T} is now ${tier ? `what promoters call a ${tier}` : "widely recognized"}${why ? `, following ${why}` : ""}.`,
        tierLine[tier ?? ""] ?? `${He(c)} is now recognized in grocery stores.`,
        `"People stop me at the gas station now," ${c.AL} said. "I don't mind it."`],
    };
  },
  goal: c => {
    if (!c.a) return undefined;
    const note = str(c.data.note) ?? str(c.data.goal)?.replace(/_/g, " ") ?? "win a title";
    const how = str(c.data.how);
    const yrs = num(c.data.yearsWanted);
    const sub = str(c.data.sub);
    if (sub === "achieved" || !sub) return {
      kind: "feature", heads: [`${c.AL} Gets What ${He(c)} Wanted`, `${c.AL}: '${capFirst(note)}.' He Did.`.slice(0, 48)],
      d: [`${c.A} set out to ${note}${yrs ? ` ${yrs} years ago` : ""}${how ? `; ${how}` : ""}`.slice(0, 90)],
      body: [`${c.A} said ${yrs ? `${yrs} years ago` : "some time ago"} that ${c.he} wanted to ${note}. ${how ? `${capFirst(how)}.` : `${He(c)} has now done it.`}`.trim(),
        `${He(c)} said ${c.he} had written it on an index card and kept it in ${c.his} locker. The card was shown to reporters.`,
        `${He(c)} said ${c.he} will now need a new index card.`] };
    if (sub === "obsessed" || sub === "obsession") return {
      kind: "feature", heads: [`${c.AL} Thinks of Only One Thing`],
      d: [`${c.A} wants to ${note}; teammates say ${c.he} talks of little else`],
      body: [`${c.A} wants to ${note}. Teammates say ${c.he} talks about nothing else.`, `${He(c)} has stopped going to the movies. ${He(c)} arrives at the ballpark at 9 a.m.`] };
    return { kind: "brief", heads: [`${c.AL} Gives Up on Goal`], d: [`${c.A} will no longer try to ${note}`],
      body: [`${c.A} said ${c.he} will no longer try to ${note}.`, `${He(c)} said ${c.he} would think of something else.`] };
  },
  fear: c => {
    if (!c.a) return undefined;
    const fear = (str(c.data.fear) ?? "flying").replace(/_/g, " ");
    const who = (c.ev.who ?? []).filter(id => person(c.world, id));
    if (str(c.data.sub) === "realized" && who.length > 1) return {
      kind: "brief", heads: [`${who.length} Players Refuse to Fly`, `Players Take Bus After Crash`],
      d: [`${who.map(id => lastName(c.world, id)).slice(0, 3).join(", ")} will travel by bus`],
      body: [`${who.length} players have told their clubs they will not fly${fear === "flying" ? " after this week's crash" : ""}. They are ${who.slice(0, 6).map(id => fullName(c.world, id, false)).join(", ")}.`, `They will travel by bus. The trip to Cold Spring takes 19 hours.`] };
    return { kind: "feature", heads: [`${c.AL} Confronts Fear of ${capFirst(fear)}`.slice(0, 48)],
      d: [c.what ? capFirst(c.what) : `${c.A} has been afraid of ${fear} since he was a child`],
      body: [`${c.A} is afraid of ${fear}. ${c.what ? `${capFirst(c.what)}.` : `${He(c)} has been since childhood.`}`, `${He(c)} said it does not affect ${c.his} play.`] };
  },
  concern: c => c.a && (str(c.data.concern) ?? c.what) ? {
    kind: "brief", heads: [`${c.AL} Says ${capFirst(str(c.data.concern) ?? c.what!)}`.slice(0, 48)],
    d: [`${c.A} on ${str(c.data.concern) ?? c.what}`.slice(0, 90)],
    body: [`${c.A} told reporters ${c.he} is concerned about ${str(c.data.concern) ?? c.what}.`, `${He(c)} did not elaborate.`] } : undefined,

  // --- the weird tier, reported straight
  abduction: c => c.a ? {
    kind: "feature", base: 3, section: "Sports", heads: [`${c.AL} Says He Was Taken Aboard Craft`, `${c.AL} Missing Two Days, Returns`, `${c.AL} Describes Abduction`],
    d: [`${c.A} was missing for ${num(c.data.days) ?? 2} days; ${c.he} says ${c.he} was examined and returned`],
    body: [`${c.A} of the ${c.T} missed ${numWord(num(c.data.days) ?? 2)} games this week. ${He(c)} returned to the ballpark Wednesday morning.`,
      `${He(c)} told reporters ${c.he} had been taken aboard a craft above Route 9 on Sunday night. ${He(c)} said ${c.he} was examined by "three of them" and returned to the parking lot of a Denny's.`,
      `${str(c.data.power) ? `${He(c)} said that since returning ${c.he} ${str(c.data.power)}.` : `${He(c)} said that since returning ${c.he} can hear AM radio stations without a radio.`} Team doctors found nothing unusual.`,
      `${c.AL} was in the lineup Wednesday. ${str(c.data.result) ?? `${He(c)} went ${seeded(c.seed, 1, 3)}-for-4.`}`] } : undefined,
  powers: c => c.a ? {
    kind: "feature", base: 2, heads: [`${c.AL} Reports Unusual Ability`],
    d: [`${c.A} says ${c.he} ${str(c.data.power) ?? c.what ?? "can see the seams on a fastball from the dugout"}`],
    body: [`${c.A} said Tuesday that ${c.he} ${str(c.data.power) ?? c.what ?? "can see the seams on a fastball from the dugout"}.`, `Team doctors examined ${c.AL} and found nothing unusual. ${He(c)} is batting .${seeded(c.seed, 300, 420)} since.`] } : undefined,
  plane_crash: c => {
    const deadIds = Array.isArray(c.data.dead) ? (c.data.dead as { id?: string }[]).map(d => d?.id).filter((x): x is string => typeof x === "string") : (c.ev.who ?? []);
    const dead = deadIds.filter(id => person(c.world, id));
    const n = dead.length;
    const names = dead.slice(0, 5).map(id => fullName(c.world, id, false));
    const mgr = str(c.data.manager);
    const where = str(c.data.where) ?? `a field outside ${teamCity(c.world, c.tId)}`;
    return {
      kind: "life", base: 6, section: "Sports", heads: [`${n ? `${n} ${c.T} Killed` : `${c.T} Plane Down`} in Plane Crash`, `${c.T} Charter Crashes${n ? `; ${n} Dead` : ""}`],
      d: [`Charter went down in ${where}${str(c.data.cause) ? `; ${str(c.data.cause)} suspected` : ""}`.slice(0, 90)],
      body: [`A charter plane carrying the ${c.T} went down in ${where} on Monday night. ${n ? `${capFirst(numWord(n))} people were killed.` : "Search crews are at the site."}${num(c.data.survivors) ? ` The other ${num(c.data.survivors)} members of the traveling party survived.` : ""}`,
        names.length ? `The dead are ${names.length > 1 ? `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}` : names[0]}.${mgr ? ` Manager ${fullName(c.world, mgr, false)} was among them.` : ""}` : `The club has not released a list of passengers.`,
        `${str(c.data.cause) ? `Investigators said the likely cause was ${str(c.data.cause)}. ` : ""}The league postponed the ${c.T}${c.T.endsWith("s") ? "'" : "'s"} next three games. Flags at every park will fly at half-staff.`],
    };
  },
  resurrection: c => {
    if (!c.a) return undefined;
    const died = num(c.data.diedYear), yrs = num(c.data.wasDeadYears), how = str(c.data.how);
    return {
      kind: "feature", base: 4, heads: [`${c.AL}, Dead ${yrs ? `${yrs} Years` : "Since " + (died ?? "")}, Signs`.replace(/ Since $/, ""), `${c.AL} Returns; Coroner Reviewing File`],
      d: [`${c.A} died${died ? ` in ${died}` : ""}. On Sunday he ${how ? wasPhrase(how) : "reported to the ballpark"}`, `${c.A} died${died ? ` in ${died}` : ""}. He has signed with the ${c.T}`],
      body: [`${c.A}, who died${died ? ` in ${died}` : ""}${yrs ? ` and had been buried for ${yrs} years` : ""}, ${how ? wasPhrase(how) : "reported to the ballpark"} on Sunday. ${He(c)} has signed with the ${c.T}.`,
        `The county coroner said he is reviewing the paperwork. The cemetery said the plot appears undisturbed.`,
        `${c.AL} took batting practice on Tuesday. ${He(c)} said ${c.he} felt a little stiff.`],
    };
  },
  clone: c => {
    if (!c.a) return undefined;
    const orig = str(c.data.original) ?? c.b;
    const O = orig ? fullName(c.world, orig, false) : c.A;
    const where = str(c.data.where);
    return {
      kind: "feature", base: 3, heads: [`Second ${c.AL} Signs in Minors`, `Man Identical to ${lastName(c.world, orig)} Signs`],
      d: [`He has the same face, swing and birthday as ${O}. He was found ${where ? `at ${where}`.replace("at nobody knows", "") : ""}`.trim().slice(0, 90)],
      body: [`A man identical to ${O} has signed with the ${c.T}. He has the same height, weight, batting stance and birthday.`,
        `${where && where !== "nobody knows" ? `He was found at ${where}.` : "No one knows where he came from."} He says he is the original.`,
        `${lastName(c.world, orig)} said, "He isn't." The two have not met.`],
    };
  },
  historical: c => {
    const fig = str(c.data.figure) ?? (c.a ? c.A : undefined);
    if (!fig) return undefined;
    const era = str(c.data.era), how = str(c.data.how);
    const pa = person(c.world, c.a);
    const pos = isPlayer(pa) ? pa.pos : undefined;
    return {
      kind: "feature", base: 3, heads: [`${fig} Signs With ${c.T}`.slice(0, 48), `${c.T} Sign ${fig}`.slice(0, 48)],
      d: [`${how ? `He ${how}` : "The club says his paperwork is in order"}`.slice(0, 90)],
      body: [`The ${c.T} have signed ${fig}${era ? `, last seen in the ${era}` : ""}. He ${how ?? "arrived on Tuesday"}.`,
        `He ${pos === "P" ? "will pitch" : pos ? `will play ${pos === "C" ? "catcher" : pos === "1B" ? "first base" : pos === "2B" ? "second base" : pos === "3B" ? "third base" : pos === "SS" ? "shortstop" : "the outfield"}` : "will report to camp"}. The club said his paperwork is in order.`,
        `Asked what year he believed it to be, he gave an answer. The club did not release it.`],
    };
  },
  ghost: c => ({
    kind: "feature", heads: [`Groundskeepers Report Figure in Outfield`, `${c.T} Staff Report Sighting at Park`],
    d: [`Night crew says a man in an old uniform was seen shagging flies at 3 a.m.`],
    body: [`Members of the ${c.T} night crew said they saw a man in an old wool uniform in center field at about 3 a.m. Tuesday.${c.a ? ` Two said he resembled ${c.A}.` : ""}`,
      `He caught several fly balls that no one had hit. When the lights were turned on, he was not there.`,
      `The club said it has no plans to investigate.`],
  }),
  vendetta: c => {
    const hurt = str(c.data.injured) ?? c.a, culprit = str(c.data.culprit);
    if (!hurt || !culprit || !person(c.world, culprit)) return undefined;
    const friends = Array.isArray(c.data.friends) ? (c.data.friends as unknown[]).filter((x): x is string => typeof x === "string" && !!person(c.world, x)) : [];
    const H = lastName(c.world, hurt), X = lastName(c.world, culprit);
    return {
      kind: "life", base: 2, tags: ["argument", "injury"], heads: [`${teamName(c.world, isPlayer(person(c.world, hurt)) ? (person(c.world, hurt) as { teamId: string }).teamId : c.tId)} Players Want ${X}`, `${H}'s Teammates Blame ${X}`],
      d: [`${friends.length} ${friends.length === 1 ? "player says" : "players say"} ${X} will hear from them`],
      body: [`${fullName(c.world, hurt, false)} was injured${str(c.data.cause) ? ` (${str(c.data.cause)})` : ""} in a play involving ${fullName(c.world, culprit, false)}.`,
        `${friends.length ? `${friends.slice(0, 3).map(id => fullName(c.world, id, false)).join(", ")} said they had not forgotten it.` : "Teammates said they had not forgotten it."} ${X} said it was part of the game.`],
    };
  },
  weird_arc: c => {
    if (!c.a) return undefined;
    const out = str(c.data.outcome);
    const days = num(c.data.days);
    if (!out) return { kind: "feature", base: 3, tags: ["night", "sky", "space"], heads: [`${c.AL} Missing`, `${c.T} Report ${c.AL} Missing`],
      d: [str(c.data.cause) ? capFirst(str(c.data.cause)!) : `${c.A} did not report; police are searching`],
      body: [`${c.A} of the ${c.T} did not report to the ballpark Tuesday.${str(c.data.cause) ? ` The police report reads, in full: "${capFirst(str(c.data.cause)!)}."` : ` ${capFirst(c.his)} car was found in the players' lot with the engine running.`}`,
        `Police are searching. The club has placed ${c.AL} on the inactive list.`] };
    if (out === "never_returned") return { kind: "feature", base: 3, tags: ["night", "sky"], heads: [`Search for ${c.AL} Ends`], d: [`${c.A} has not been found`],
      body: [`Police have ended the search for ${c.A}.`, `${capFirst(c.his)} locker has been left as it was.`] };
    const power = str(c.data.power), quirk = str(c.data.quirk), rating = str(c.data.rating), says = str(c.data.says);
    const change = power ? POWER_LINE[power] ?? "has an ability doctors cannot explain" : quirk ? QUIRK_LINE[quirk] ?? "is different in a way teammates cannot describe" : rating ? (rating === "stuff" ? "throws four miles an hour harder than before" : "hits the ball farther than before") : undefined;
    return { kind: "feature", base: 4, tags: ["space", "sky", "astronomy", "night"],
      heads: [`${c.AL} Returns${days ? ` After ${days} Days` : ""}`, `${c.AL} Back With ${c.T}`],
      d: [change ? `${c.A} is back. Teammates say he ${change}` : "", change ? `${c.AL} is back. Teammates say he ${change}` : "", `${c.A} is back with the ${c.T} after ${days ?? "several"} days`].filter(Boolean),
      body: [`${c.A} returned to the ${c.T} on Tuesday${days ? ` after ${days} days missing` : ""}. ${says ? `${He(c)} ${says.replace(/^says /, "said ").replace(/'([^']+)'/g, '"$1."').replace(/\."$/, '."')}${/"$/.test(says) || /'$/.test(says) ? "" : "."}` : `${He(c)} would not say where ${c.he} had been.`}`,
        change ? `Teammates say ${c.he} ${change}. Team doctors examined ${c.AL} and found nothing wrong.` : `Team doctors examined ${c.AL} and found nothing wrong.`,
        `${c.AL} was in the lineup Wednesday.`] };
  },
};
