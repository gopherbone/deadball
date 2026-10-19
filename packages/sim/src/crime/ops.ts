// The operations catalog and how a job turns into modifiers. Nothing here scripts an
// outcome: a job changes ratings or incident odds, and the sim rolls the dice.

import type { Modifier } from "../modifiers.ts";
import type { Player, Umpire, World } from "../types.ts";
import { buildStaff } from "../lineup.ts";
import { roleDef } from "./npcs.ts";
import { bleacherBan, guardNote, securityDetail, teamHostility } from "./hostility.ts";
import type { CrewMember, CrewSkill, GearDef, CrewNudge, OpKindDef, OpOrder, Risk } from "./types.ts";

export const GEAR: Record<string, GearDef> = {
  burlap_sack: { id: "burlap_sack", name: "Burlap sack x3", cost: 15, success: 0.06, note: "Three sacks. Each holds one raccoon or one mascot head." },
  fake_habit: { id: "fake_habit", name: "Fake nun habit", cost: 40, exposure: 0.7, skills: { sneak: 1 }, note: "A Benedictine habit, size large. Guards do not search nuns." },
  eels: { id: "eels", name: "Bucket of eels", cost: 25, quality: 0.2, exposure: 1.25, note: "A five-gallon bucket of live eels. Makes things worse." },
  vaseline: { id: "vaseline", name: "Tub of Vaseline", cost: 10, quality: 0.15, note: "Five pounds. Industrial." },
  jumpsuit: { id: "jumpsuit", name: "Grounds crew jumpsuit", cost: 25, skills: { access: 1 }, note: "Green. Says GROUNDS on the back." },
  rabbit_crate: { id: "rabbit_crate", name: "Crate of juiced balls", cost: 60, quality: 0.3, note: "144 balls, wound in a garage in Ohio." },
  exlax: { id: "exlax", name: "Ex-Lax (bulk)", cost: 20, quality: 0.25, exposure: 1.1, note: "Twelve boxes. Chocolate." },
  envelope: { id: "envelope", name: "Fat envelope", cost: 200, success: 0.12, quality: 0.2, note: "$4,000 in twenties." },
  laser_deluxe: { id: "laser_deluxe", name: "Military laser", cost: 45, quality: 0.3, exposure: 1.15, note: "Army surplus. Range two miles." },
  binoculars: { id: "binoculars", name: "Opera glasses", cost: 30, success: 0.08, note: "Opera glasses. Mother-of-pearl." },
  walkies: { id: "walkies", name: "Walkie-talkies", cost: 50, success: 0.05, exposure: 0.85, note: "Two units. Channel 9." },
  bolt_cutters: { id: "bolt_cutters", name: "Bolt cutters", cost: 25, success: 0.08, note: "Twenty-four inch." },
  megaphone: { id: "megaphone", name: "Megaphone", cost: 20, quality: 0.25, exposure: 1.2, note: "Battery powered. Batteries included." },
  perfume: { id: "perfume", name: "Cheap perfume", cost: 15, quality: 0.2, note: "One ounce. Smells of gin." },
  stationery: { id: "stationery", name: "Monogrammed stationery", cost: 30, success: 0.08, note: "Monogrammed. Not with our initials." },
  camera: { id: "camera", name: "Telephoto camera", cost: 60, success: 0.1, quality: 0.15, note: "300mm lens." },
  getaway: { id: "getaway", name: "Getaway car", cost: 100, exposure: 0.6, note: "A 1968 Chrysler. One hubcap." },
  flowers: { id: "flowers", name: "Flowers and a card", cost: 25, success: 0.08, note: "Carnations. The card is unsigned." },
  rosary: { id: "rosary", name: "Blessed rosary", cost: 5, skills: { nerve: 1 }, note: "Steadies the hands." },
};

export const OP_KINDS: OpKindDef[] = [
  { kind: "grease_mound", name: "Grease the mound", blurb: "Petroleum jelly on the pitching rubber before the game. Their pitchers lose their footing.",
    cost: 40, risk: "low", needs: { sneak: 2, access: 2 }, slots: 2, gear: ["vaseline", "jumpsuit"],
    ifWorks: "Their pitchers' control drops.", ifFails: "The grounds crew notices the shine." },
  { kind: "rabbit_balls", name: "Rabbit balls", blurb: "Replace the game balls with a crate of tightly wound ones while they pitch.",
    cost: 90, risk: "mod", needs: { access: 3, knowhow: 2 }, slots: 2, gear: ["rabbit_crate", "jumpsuit"],
    ifWorks: "Their pitches flatten. The other club hits for power.", ifFails: "The umpire opens the crate." },
  { kind: "raccoons", name: "Release raccoons", blurb: "Three sacks of raccoons released into their bullpen before the sixth inning.",
    cost: 60, risk: "mod", needs: { knowhow: 2, nerve: 2, sneak: 2 }, slots: 3, gear: ["burlap_sack", "fake_habit", "eels"],
    ifWorks: "Their relievers lose stamina. Some are treated at the scene.", ifFails: "The raccoons do not leave the sacks." },
  { kind: "cooler", name: "Spike the cooler", blurb: "A laxative in their dugout water cooler.",
    cost: 120, risk: "high", needs: { access: 3, sneak: 2, knowhow: 2 }, slots: 2, gear: ["exlax", "jumpsuit"],
    ifWorks: "Their players leave the dugout in the middle innings.", ifFails: "Our man drinks from the wrong cooler." },
  { kind: "bribe_ump", name: "Bribe the umpire", blurb: "An envelope of cash for the plate umpire. Close calls go against them.",
    cost: 250, risk: "high", needs: { charm: 3, nerve: 2 }, slots: 1, gear: ["envelope", "rosary"],
    ifWorks: "Their hitters see a wide zone. Their pitchers see a narrow one.", ifFails: "The umpire reports the envelope." },
  { kind: "laser", bleachers: true, name: "Laser from the bleachers", blurb: "A laser pointer aimed at their hitters from the bleachers.",
    cost: 50, risk: "mod", needs: { sneak: 3, nerve: 1 }, slots: 1, gear: ["laser_deluxe", "fake_habit"],
    ifWorks: "Their batters make less contact while it is on.", ifFails: "An usher follows the dot back to its source." },
  { kind: "steal_signs", bleachers: true, name: "Steal the signs", blurb: "Opera glasses in center field and a man with a trash can lid in the tunnel.",
    cost: 70, risk: "mod", needs: { sneak: 2, knowhow: 3 }, slots: 2, gear: ["binoculars", "walkies"],
    ifWorks: "Hitters facing them know what is coming.", ifFails: "They change their signs." },
  { kind: "lucky_glove", name: "Hide the lucky glove", blurb: "Their closer's glove is taken from the clubhouse and left in a bus station locker.",
    cost: 30, risk: "low", needs: { sneak: 2, access: 2 }, slots: 1, gear: ["jumpsuit"],
    ifWorks: "Superstitious pitchers lose their stuff.", ifFails: "He finds the glove." },
  { kind: "sprinklers", name: "Sprinklers overnight", blurb: "Open the valve on their side of the field at 3 a.m.",
    cost: 45, risk: "low", needs: { access: 2, knowhow: 2 }, slots: 2, gear: ["bolt_cutters", "jumpsuit"],
    ifWorks: "Their fielders slip and misplay balls.", ifFails: "The night watchman is awake." },
  { kind: "heckle", bleachers: true, name: "Heckle squad", blurb: "Three people behind their dugout with a megaphone and four pages of typed notes.",
    cost: 25, risk: "low", needs: { charm: 1, nerve: 2, muscle: 1 }, slots: 3, gear: ["megaphone"],
    ifWorks: "Hotheads and chokers lose focus. A fight is possible.", ifFails: "Security removes the squad in the second inning." },
  { kind: "love_letter", storyline: { kinds: ["affair", "marriage_trouble"], nudge: "inflame" }, name: "Forged love letter", blurb: "A perfumed letter to their best player, delivered to his home.",
    cost: 35, risk: "mod", needs: { knowhow: 2, charm: 2 }, slots: 2, gear: ["perfume", "stationery"],
    ifWorks: "His mood drops. His hitting follows.", ifFails: "His wife recognizes the handwriting as ours." },
  { kind: "blackmail", storyline: { kinds: ["gambling_debt", "affair", "marriage_trouble", "stalker", "feud"], nudge: "choice" }, name: "Blackmail a player", blurb: "Photographs, a phone call and a request that he go 0-for-4.",
    cost: 150, risk: "high", needs: { sneak: 2, charm: 2, nerve: 3 }, slots: 2, gear: ["camera", "stationery"],
    ifWorks: "Their best player has a bad night.", ifFails: "He takes the photographs to the police." },
  { kind: "tip_wire", storyline: { kinds: "any", nudge: "expose" }, name: "Tip off SportsWire", blurb: "An anonymous call to the SportsWire newsroom about their clubhouse.",
    cost: 20, risk: "low", needs: { charm: 2, knowhow: 1 }, slots: 1, gear: ["stationery"],
    ifWorks: "A story runs. Their players read it.", ifFails: "The newsroom traces the call." },
  { kind: "kidnap_mascot", name: "Kidnap the mascot", blurb: "Take their mascot before the game. Leave a note.",
    cost: 200, risk: "lol", needs: { muscle: 3, sneak: 2, nerve: 2 }, slots: 3, gear: ["burlap_sack", "getaway", "bolt_cutters"], minCrew: 2,
    ifWorks: "Their players are distracted. Fans search the stands.", ifFails: "The mascot resists. He served in the Marines." },
  { kind: "blackout", name: "Cut the power", blurb: "Cut the main cable in the transformer room during the game.",
    cost: 180, risk: "high", needs: { knowhow: 3, access: 3 }, slots: 2, gear: ["bolt_cutters", "jumpsuit"],
    ifWorks: "A long delay ends both starting pitchers' nights.", ifFails: "Our electrician touches the wrong cable." },
  { kind: "smooth_over", storyline: { kinds: "any", nudge: "soothe", only: true }, name: "Smooth it over",
    blurb: "A fixer visits the people involved with flowers, an envelope and a calm voice.",
    cost: 80, risk: "low", needs: { charm: 3, nerve: 1 }, slots: 2, gear: ["flowers", "envelope"],
    ifWorks: "The storyline cools. Escalation is less likely and a quiet ending more likely.", ifFails: "The fixer is recognized. Now it is a bigger story." },
  { kind: "security", name: "Sweep the clubhouse", blurb: "Hire guards for a club's clubhouse for one day. Jobs against them get harder and riskier.",
    cost: 60, risk: "low", needs: { muscle: 2, access: 2, nerve: 1 }, slots: 3, gear: ["walkies", "megaphone"],
    ifWorks: "Rival jobs against this club fail more often and are caught more often.", ifFails: "The guards spend the game at the beer stand." },
];

const KIND_BY_ID: Record<string, OpKindDef> = Object.fromEntries(OP_KINDS.map(k => [k.kind, k]));
export const opKind = (kind: string | undefined): OpKindDef | undefined => (kind ? KIND_BY_ID[kind] : undefined);

export const RISK_EXPOSURE: Record<Risk, number> = { low: 0.07, mod: 0.13, high: 0.2, lol: 0.28 };
export const RISK_HEAT: Record<Risk, number> = { low: 1, mod: 1, high: 2, lol: 2 };

const clamp = (x: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, x));

/** Skill a crew brings as a group: the best member plus a little help from the rest. */
export function groupSkill(crew: CrewMember[], skill: CrewSkill, gear: string[] = []): number {
  if (!crew.length) return 0;
  const vals = crew.map(c => c.skills[skill] ?? 0).sort((a, b) => b - a);
  let v = vals[0] + vals.slice(1).reduce((a, b) => a + b, 0) * 0.25;
  for (const g of gear) v += GEAR[g]?.skills?.[skill] ?? 0;
  return v;
}

export interface Chance {
  p: number;
  /** Short reasons for the planner ("Charm short by 1", "Umpire is a soft touch"). */
  notes: string[];
}

function ump(world: World, order: Pick<OpOrder, "umpireId">): Umpire | undefined {
  const u = order.umpireId ? world.npcs[order.umpireId] : undefined;
  return u && u.role === "umpire" ? (u as Umpire) : undefined;
}

/** Players on the target club who are likely to play (the ML roster). */
function targetPlayers(world: World, teamId: string): Player[] {
  const t = world.teams[teamId];
  return t ? t.roster.map(id => world.players[id]).filter((p): p is Player => !!p && !p.injury) : [];
}

function starValue(p: Player): number {
  if (p.pos === "P" && p.pitching) return p.pitching.stuff + p.pitching.control + (p.pitching.stamina > 50 ? 5 : 0);
  return p.batting.contact + p.batting.power + p.batting.eye * 0.5;
}

/** Who a person-targeted op (blackmail, love letter) goes after. Deterministic. */
export function pickVictim(world: World, order: Pick<OpOrder, "kind" | "targetTeamId" | "targetPlayerId">): Player | undefined {
  if (order.targetPlayerId) {
    const p = world.players[order.targetPlayerId];
    if (p && p.teamId === order.targetTeamId) return p;
  }
  const ps = targetPlayers(world, order.targetTeamId).filter(p => p.pos !== "P" || (p.pitching && p.pitching.stamina < 45));
  if (!ps.length) return undefined;
  const score = (p: Player) => {
    let s = starValue(p);
    if (order.kind === "blackmail" && p.traits.some(t => t === "GAMBLER" || t === "DRUNK" || t === "CROOKED")) s += 25;
    if (order.kind === "love_letter" && p.family?.spouse) s += 20;
    return s;
  };
  return [...ps].sort((a, b) => score(b) - score(a) || (a.id < b.id ? -1 : 1))[0];
}

/** Success chance for an order with this crew. Used by the planner (successPct) and resolveOps. */
export function opChance(world: World, order: Pick<OpOrder, "kind" | "targetTeamId" | "gear" | "umpireId" | "targetPlayerId">, crew: CrewMember[]): Chance {
  const def = opKind(order.kind);
  const notes: string[] = [];
  if (!def) return { p: 0, notes: ["Unknown job"] };
  const gear = order.gear.filter(g => def.gear.includes(g));
  const going = crew.slice(0, def.slots);
  if (going.length === 0) return { p: 0, notes: ["Nobody on the job"] };
  let p = 0.55;
  for (const [sk, need] of Object.entries(def.needs) as [CrewSkill, number][]) {
    const have = groupSkill(going, sk, gear);
    const diff = have - need;
    if (diff >= 0) p += 0.06 * Math.min(diff, 2);
    else {
      p += 0.17 * Math.max(diff, -4);
      notes.push(`${sk} short by ${Math.ceil(-diff)}`);
    }
  }
  if (going.length < (def.minCrew ?? 1)) {
    p -= 0.2 * ((def.minCrew ?? 1) - going.length);
    notes.push("short-handed");
  }
  for (const g of gear) p += GEAR[g]?.success ?? 0;
  const aff = going.some(c => roleDef(c.role)?.affinity.includes(def.kind));
  if (aff) { p += 0.08; notes.push("the right person for it"); }
  // nerves: a hot crew is a twitchy crew
  const heat = going.reduce((a, c) => a + c.heat, 0) / going.length;
  p -= 0.015 * heat;

  if (def.kind === "bribe_ump") {
    const u = ump(world, order);
    const corrupt = u ? u.stats.corruptible : 40;
    p += (corrupt - 45) / 70;
    if (u?.traits.includes("PIOUS")) p -= 0.12;
    if (u?.traits.includes("GREEDY") || u?.traits.includes("CROOKED")) p += 0.12;
    if (corrupt >= 55) notes.push("the ump is a soft touch");
    if (corrupt <= 30) notes.push("the ump is a Boy Scout");
  } else if (def.kind === "lucky_glove") {
    const sup = targetPlayers(world, order.targetTeamId).filter(x => x.pos === "P" && x.traits.includes("SUPERSTITIOUS"));
    if (!sup.length) notes.push("nobody on that staff believes in luck");
  } else if (def.kind === "heckle") {
    const soft = targetPlayers(world, order.targetTeamId).filter(x => x.traits.includes("HOTHEAD") || x.traits.includes("CHOKER"));
    p += Math.min(0.12, soft.length * 0.03);
  } else if (def.kind === "blackmail") {
    const v = pickVictim(world, { ...order, kind: def.kind });
    if (v?.traits.some(t => t === "GAMBLER" || t === "DRUNK" || t === "CROOKED")) { p += 0.12; notes.push("he has secrets"); }
    if (v?.traits.some(t => t === "PIOUS" || t === "LOYAL")) { p -= 0.15; notes.push("he's a choirboy"); }
  } else if (def.kind === "love_letter") {
    const v = pickVictim(world, { ...order, kind: def.kind });
    if (v && !v.family?.spouse) { p -= 0.1; notes.push("he isn't married (yet)"); }
    if (v?.traits.includes("PARANOID")) p += 0.08;
  } else if (def.kind === "tip_wire") {
    const t = world.teams[order.targetTeamId];
    const press = world.relationships.find(r => (r.a === "press" && r.b === t?.factionId) || (r.b === "press" && r.a === t?.factionId));
    if (press && press.value >= 2) { p -= 0.15; notes.push("SportsWire is in their pocket"); }
  }
  return { p: clamp(p, 0.03, 0.95), notes };
}

/**
 * Modifiers for a successful job. `q` is quality (0.2..1.2). Targets the target club,
 * or the opponent's hitters where that's who benefits (when the server tells us who).
 */
export function opModifiers(world: World, order: OpOrder, q: number): { mods: Modifier[]; note: string } {
  const src = order.id;
  const team = (id: string) => ({ kind: "team" as const, id });
  const mods: Modifier[] = [];
  const t = order.targetTeamId;
  const opp = order.opponentTeamId;
  const add = (suffix: string, target: Modifier["target"], effect: Modifier["effect"], value: number, extra: Partial<Modifier> = {}) =>
    mods.push({ id: `${src}:${suffix}`, source: src, target, effect, value: Math.round(value * 1000) / 1000, ...extra });
  let note = "";
  switch (order.kind) {
    case "grease_mound":
      add("ctl", team(t), "control", -(4 + 7 * q), { note: "greased mound" });
      note = "The rubber has been treated. Five pounds were used.";
      break;
    case "rabbit_balls":
      add("stf", team(t), "stuff", -(2 + 3 * q), { note: "juiced balls" });
      if (opp) add("pow", team(opp), "power", 3 + 6 * q, { note: "juiced balls" });
      note = "The crate is in the umpires' room, labeled GAME BALLS.";
      break;
    case "raccoons":
      add("rac", team(t), "incident", 150 + 450 * q, { incident: "RACCOONS_BULLPEN", note: "raccoons in the pen" });
      add("rof", { kind: "game", id: order.gameId }, "incident", 4 + 10 * q, { incident: "RACCOON_ON_FIELD", note: "stragglers" });
      note = "Three sacks are under the bullpen bench. They are moving.";
      break;
    case "cooler":
      add("fp", team(t), "incident", 150 + 400 * q, { incident: "FOOD_POISONING", note: "spiked cooler" });
      note = "The cooler has been treated. It smells faintly of chocolate.";
      break;
    case "bribe_ump": {
      const u = ump(world, order);
      const corrupt = u ? u.stats.corruptible : 40;
      // negative zone on a team: their pitchers lose edges, their hitters get squeezed
      add("zone", team(t), "zone", -(0.03 + 0.08 * q) * (0.6 + corrupt / 100), { note: "bought umpire" });
      note = "The umpire accepted the envelope. He counted it first.";
      break;
    }
    case "laser":
      add("laser", team(t), "incident", 400 + 1100 * q, { incident: "LASER_POINTER", note: "laser in the bleachers" });
      note = "Our man has a seat in section 12, row F. The laser is charged.";
      break;
    case "steal_signs":
      if (opp) {
        add("con", team(opp), "contact", 2 + 4 * q, { note: "stolen signs" });
        add("eye", team(opp), "eye", 2 + 4 * q, { note: "stolen signs" });
      } else add("stf", team(t), "stuff", -(2 + 4 * q), { note: "stolen signs" });
      note = "We have their signs. Two fingers is a slider.";
      break;
    case "lucky_glove": {
      const ps = targetPlayers(world, t).filter(x => x.pos === "P");
      const sup = ps.filter(x => x.traits.includes("SUPERSTITIOUS"));
      const closer = buildStaff(world, world.teams[t]).closer;
      const hit = new Set(sup.map(x => x.id));
      if (closer) hit.add(closer.id);
      for (const id of hit) {
        const believes = sup.some(x => x.id === id);
        add(`stf-${id}`, { kind: "player", id }, "stuff", -(believes ? 5 + 8 * q : 2 + 2 * q), { note: "lucky glove missing" });
        if (believes) add(`ctl-${id}`, { kind: "player", id }, "control", -(2 + 4 * q), { note: "lucky glove missing" });
      }
      note = "The glove is in a locker at the Greyhound station.";
      break;
    }
    case "sprinklers":
      add("fld", team(t), "fielding", -(5 + 10 * q), { note: "flooded field" });
      add("spd", team(t), "speed", -(2 + 3 * q), { note: "flooded field" });
      note = "Their side of the field is under an inch of water.";
      break;
    case "heckle": {
      const soft = targetPlayers(world, t).filter(x => x.traits.includes("HOTHEAD") || x.traits.includes("CHOKER"));
      for (const x of soft) add(`con-${x.id}`, { kind: "player", id: x.id }, "contact", -(3 + 5 * q), { note: "heckled" });
      add("brawl", team(t), "incident", 3 + 6 * q, { incident: "BRAWL", note: "heckle squad" });
      note = `The squad has typed notes on ${soft.length} of their players.`;
      break;
    }
    case "love_letter":
    case "blackmail": {
      const v = pickVictim(world, order);
      if (v) {
        const k = order.kind === "blackmail" ? 1.6 : 1;
        if (v.pos === "P") {
          add("stf", { kind: "player", id: v.id }, "stuff", -(3 + 4 * q) * k, { note: order.kind });
          add("ctl", { kind: "player", id: v.id }, "control", -(3 + 4 * q) * k, { note: order.kind });
        } else {
          add("con", { kind: "player", id: v.id }, "contact", -(3 + 4 * q) * k, { note: order.kind });
          add("pow", { kind: "player", id: v.id }, "power", -(3 + 4 * q) * k, { note: order.kind });
        }
        note = order.kind === "blackmail" ? `${v.last} has seen the photos.` : `${v.last}'s wife has read the letter. She read it twice.`;
      }
      break;
    }
    case "tip_wire":
      add("mood", team(t), "contact", -(1 + 2 * q), { note: "scandal in the papers" });
      note = "SportsWire will run it tomorrow on page one.";
      break;
    case "kidnap_mascot":
      add("con", team(t), "contact", -(2 + 3 * q), { note: "mascot kidnapped" });
      add("pow", team(t), "power", -(1 + 3 * q), { note: "mascot kidnapped" });
      add("fan", { kind: "game", id: order.gameId }, "incident", 5 + 10 * q, { incident: "FAN_ON_FIELD", note: "fans searching for mascot" });
      note = "The mascot head is in the trunk of the Chrysler. It is facing up.";
      break;
    case "blackout":
      add("dark", team(t), "incident", 300 + 900 * q, { incident: "BLACKOUT", note: "cut cable" });
      note = "The transformer room door is propped open with a brick.";
      break;
  }
  return { mods, note };
}

/** Who's asking (accounts on the job + syndicate) and whose park it is, for hostile-owner effects. */
export interface PlannerCtx { parties?: (string | undefined)[]; homeTeamId?: string }

/** Planner helper: everything the op catalog view needs, success shown for this crew. */
export function opPlannerView(world: World, kind: string, targetTeamId: string, crew: CrewMember[], gear: string[], umpireId?: string, ctx: PlannerCtx = {}) {
  const def = opKind(kind);
  if (!def) return undefined;
  const c = opChance(world, { kind, targetTeamId, gear, umpireId }, crew);
  const parties = ctx.parties ?? [];
  // hostile owners: guards on their clubs, and no bleacher seats at their parks
  if (kind !== "security" && parties.length) {
    const h = teamHostility(world, targetTeamId, parties);
    if (h) {
      c.p = Math.max(0.02, c.p - securityDetail(h).success);
      const note = guardNote(world, targetTeamId, parties);
      if (note) c.notes.push(note);
    }
  }
  const blocked = bleacherBan(world, kind, ctx.homeTeamId, parties);
  return {
    ...(blocked ? { blocked } : {}),
    kind, name: def.name, blurb: def.blurb, cost: def.cost + gear.reduce((a, g) => a + (GEAR[g]?.cost ?? 0), 0), risk: def.risk, slots: def.slots,
    needs: Object.entries(def.needs).map(([k, v]) => `${k[0].toUpperCase()}${k.slice(1)}${v}`).join(" "),
    gear: def.gear.map(g => ({ id: g, name: GEAR[g].name, cost: GEAR[g].cost })),
    successPct: Math.round(c.p * 100), notes: c.notes, ifWorks: def.ifWorks, ifFails: def.ifFails, heat: RISK_HEAT[def.risk],
    storyline: def.storyline ? { kinds: def.storyline.kinds, nudge: def.storyline.nudge, required: !!def.storyline.only } : undefined,
  };
}


/** Storyline nudge an order would apply, or undefined if the order isn't a storyline job. */
export function storylineNudge(order: Pick<OpOrder, "kind" | "storylineId" | "nudge">, storylineKind?: string): CrewNudge | undefined {
  const def = opKind(order.kind);
  if (!def?.storyline || !order.storylineId) return undefined;
  const sk = def.storyline.kinds;
  if (storylineKind && sk !== "any" && !sk.includes(storylineKind)) return undefined;
  if (def.storyline.nudge === "choice") return order.nudge === "soothe" ? "soothe" : "expose";
  return def.storyline.nudge;
}
