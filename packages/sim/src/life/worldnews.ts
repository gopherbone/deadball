// Background world: fictional, satirical late-90s non-baseball news (elections, strikes, fads,
// bubbles, Y2K, comets, weather) with light mechanical effects the rest of the game can read
// through worldMultipliers().

import type { Rng } from "../rng.ts";
import { FIRST, LAST } from "../names.ts";
import type { Weather, World, WorldEffect } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { shiftRelation } from "./people.ts";

export interface WorldMultipliers {
  /** Card pack / marketplace demand (1 = normal). */
  cardDemand: number;
  /** Ballpark attendance. */
  attendance: number;
  /** General economy: betting handle, salaries, ad money. */
  economy: number;
  /** Added to every affected player's daily mood target. */
  mood: number;
  /** Weather bias for upcoming games: rain multiplier and temperature shift. */
  weatherBias: { rain: number; tempF: number };
  /** Titles of the active effects. */
  active: string[];
}

/** Product of all active effects (league-wide ones plus those aimed at this team's club/city). */
export function worldMultipliers(world: World, teamId?: string): WorldMultipliers {
  const out: WorldMultipliers = { cardDemand: 1, attendance: 1, economy: 1, mood: 0, weatherBias: { rain: 1, tempF: 0 }, active: [] };
  const org = teamId ? world.teams[teamId]?.parentId ?? teamId : undefined;
  for (const e of world.effects ?? []) {
    if (e.until < world.day || e.from > world.day) continue;
    if (e.teamId && e.teamId !== org && e.teamId !== teamId) {
      // local effects still count a little league-wide for card demand/economy
      continue;
    }
    out.cardDemand *= e.cardDemand ?? 1;
    out.attendance *= e.attendance ?? 1;
    out.economy *= e.economy ?? 1;
    out.mood += e.mood ?? 0;
    out.weatherBias.rain *= e.rain ?? 1;
    out.weatherBias.tempF += e.tempF ?? 0;
    out.active.push(e.title);
  }
  out.cardDemand = Math.round(out.cardDemand * 100) / 100;
  out.attendance = Math.round(out.attendance * 100) / 100;
  out.economy = Math.round(out.economy * 100) / 100;
  out.mood = Math.round(out.mood * 100) / 100;
  return out;
}

/** Nudge the weather of today's games by active weather streaks (heatwaves, floods, cold snaps). */
export function applyWeatherEffects(world: World, games: { homeId: string; weather: Weather }[]) {
  if (!world.effects?.length) return;
  for (const g of games) {
    const m = worldMultipliers(world, g.homeId);
    if (m.weatherBias.rain === 1 && m.weatherBias.tempF === 0) continue;
    g.weather.rain = Math.round(Math.min(1, g.weather.rain * m.weatherBias.rain) * 100) / 100;
    g.weather.tempF = Math.round(g.weather.tempF + m.weatherBias.tempF);
  }
}

interface Ctx { world: World; rng: Rng; month: number; year: number; offseason: boolean }
interface Made { headline: string; effect?: Partial<WorldEffect>; days?: number; weight?: number; teams?: string[]; after?: () => void }
interface Template { kind: string; weight: (c: Ctx) => number; make: (c: Ctx) => Made; cooldown: number /* days */ }

const pickName = (rng: Rng) => `${rng.pick(FIRST)} ${rng.pick(LAST)}`;
const clubCity = (world: World, id: string) => world.teams[id]?.city ?? "town";
const mlIds = (world: World) => Object.values(world.teams).filter(t => t.level === "ML").map(t => t.id).sort();
const hasTeam = (world: World, id: string) => !!world.teams[id];

const FADS: [string, number, number][] = [
  // name, card demand, attendance
  ["Slammer Caps (cardboard milk caps you flip with a heavier cap) sweep every schoolyard; collectors hoard the holographic ones", 1.3, 1],
  ["Bean Buddies, small beanbag animals with heart-shaped tags, cause a stampede at a Harbor City five-and-dime", 1.25, 1],
  ["Tamago-Pal virtual pets banned from classrooms; three die of neglect during a doubleheader", 1.05, 0.97],
  ["Swing-dance revival: zoot suits back, grandparents baffled, ballpark organists asked for Benny Goodman", 1, 1.04],
  ["The Funky Pelican line dance is performed at every wedding in the league; physicians report record hip injuries", 1, 1.02],
  ["Two-way pagers are the hottest accessory; bullpen coaches caught paging relievers 'just to check'", 1.05, 1],
  ["Trading-card speculation: \"Cards are the new stocks,\" says man with 4,000 rookie cards in his garage", 1.4, 1],
  ["Inline-skate craze: three ushers hospitalised; the Commissioner bans skating on the concourse", 1, 1.03],
  ["Cigar lounges open on every corner; the Archdiocese of St. Albans condemns 'the smoky vice'", 1, 1],
];

const TEMPLATES: Template[] = [
  { kind: "election", cooldown: 60, weight: c => (c.month === 11 ? 4 : 0.6),
    make: c => {
      const id = c.rng.pick(mlIds(c.world)), city = clubCity(c.world, id), who = pickName(c.rng);
      const flavour = c.rng.pick([
        `${who} elected mayor of ${city} by 41 votes; loser demands a recount 'by hand, by me'`,
        `Mayor of ${city} re-elected despite admitting he 'mostly naps'`,
        `${city} council race decided by coin toss; coin later found to be two-headed`,
        `Write-in candidate 'Hot Dog Hal' wins 9% of the vote for ${city} comptroller`,
      ]);
      return { headline: flavour, weight: 2 };
    } },
  { kind: "mayor_scandal", cooldown: 90, weight: () => 0.8,
    make: c => {
      const id = c.rng.pick(mlIds(c.world)), city = clubCity(c.world, id);
      const what = c.rng.pick(["used city snowplows to move his boat", "paid for a mistress's condo with parking-ticket revenue", "fixed his own parking tickets 400 times", "put his brother-in-law in charge of the ballpark hot dogs", "was caught on tape calling the city 'a dump with a ballpark'"]);
      return { headline: `${city} mayor ${what}; resignation calls grow`, effect: { mood: -0.1, teamId: id }, days: 14, weight: 3 };
    } },
  { kind: "strike", cooldown: 120, weight: c => (hasTeam(c.world, "PEM") || hasTeam(c.world, "MIL") ? 0.9 : 0),
    make: c => {
      const opts: [string, string, string][] = [
        ["PEM", "pem", "Dockworkers strike in Port Ellis; Shipping Trust calls them 'ungrateful barnacles'; ships idle, fans picket the Wharf Street Grounds"],
        ["MIL", "mil", "Steelworkers walk out at Millbrook Steel; the furnace goes cold and so does the Ironmen's gate"],
        ["CSR", "csr", "Cattle drivers strike in Cold Spring; Stockyard Park smells unusually fine"],
        ["ELC", "elc", "Linemen strike at Volta Power & Light; night games in Electric City lit by 'emergency candles'"],
      ];
      const [team, fid, headline] = c.rng.pick(opts.filter(o => hasTeam(c.world, o[0])));
      return {
        headline, effect: { attendance: 0.8, economy: 0.97, mood: -0.3, teamId: team, factionId: fid }, days: 10 + c.rng.int(25), weight: 4, teams: [team],
        after: () => {
          if (c.world.factions[fid] && c.world.factions.commish) shiftRelation(c.world, fid, "commish", -1, "the strike");
          if (c.world.factions[fid] && c.world.factions.press) shiftRelation(c.world, fid, "press", -1, "strike coverage");
        },
      };
    } },
  { kind: "fad", cooldown: 70, weight: () => 1.2,
    make: c => {
      const [headline, card, att] = c.rng.pick(FADS);
      return { headline, effect: { cardDemand: card, attendance: att }, days: 40 + c.rng.int(60), weight: card > 1.2 ? 3 : 2 };
    } },
  { kind: "bubble", cooldown: 365, weight: c => (c.year >= 1997 && c.year <= 1999 ? 0.7 : 0),
    make: c => ({
      headline: c.rng.pick([
        "Shares of Yippee.web, which sells nothing, up 900%; shoeshine boys give stock tips at Bellwood Park",
        "Day-trading mania: half the Lamplighters' bullpen now day-trades from the dugout phone",
        "Pets-dot-whatever goes public; sock puppet mascot worth more than three franchises",
      ]),
      effect: { economy: 1.15, cardDemand: 1.1 }, days: 120, weight: 3,
    }) },
  { kind: "crash", cooldown: 3000, weight: c => (c.year >= 2000 && c.year <= 2002 ? 1.5 : 0),
    make: () => ({ headline: "The bubble bursts: Yippee.web worth less than a box of Slammer Caps; season-ticket cancellations pour in", effect: { economy: 0.85, attendance: 0.93, cardDemand: 0.9, mood: -0.2 }, days: 150, weight: 5 }) },
  { kind: "y2k", cooldown: 100000, weight: c => (c.year === 1999 && c.offseason && c.month >= 11 ? 30 : 0),
    make: () => ({ headline: "Y2K panic: canned beans sell out, Volta Power & Light swears the lights stay on at midnight, the Commissioner buys a generator 'just in case'", effect: { economy: 0.96, mood: -0.2, cardDemand: 1.05 }, days: 30, weight: 6 }) },
  { kind: "comet", cooldown: 700, weight: c => (c.year === 1997 ? 2 : 0.15),
    make: c => ({ headline: c.rng.pick(["Comet Halvorsen visible over the league; a Marlow cult waits for the mothership in the Plymouth Yard bleachers", "Astronomers spot a comet 'shaped like a hot dog'; Brother Amos calls it a sign"]), effect: { attendance: 1.05 }, days: 20, weight: 3 }) },
  { kind: "heatwave", cooldown: 40, weight: c => (c.month >= 6 && c.month <= 8 && !c.offseason ? 1.2 : 0),
    make: c => {
      const id = c.rng.pick(mlIds(c.world));
      return { headline: `Heatwave bakes ${clubCity(c.world, id)}: the ice-cream man is a folk hero, an usher fries an egg on the dugout roof`, effect: { tempF: 12, teamId: id, mood: -0.1 }, days: 6 + c.rng.int(6), weight: 2, teams: [id] };
    } },
  { kind: "flood", cooldown: 60, weight: c => (c.month >= 4 && c.month <= 6 && !c.offseason ? 0.8 : 0),
    make: c => {
      const id = c.rng.pick(mlIds(c.world));
      return { headline: `Spring floods in ${clubCity(c.world, id)}: the river visits the ballpark parking lot; tarp crew working triple shifts`, effect: { rain: 2.2, teamId: id, attendance: 0.92 }, days: 7 + c.rng.int(7), weight: 2, teams: [id] };
    } },
  { kind: "blizzard", cooldown: 60, weight: c => (c.offseason || c.month === 4 ? 1 : 0),
    make: c => {
      const id = c.rng.pick(mlIds(c.world));
      return { headline: `Blizzard buries ${clubCity(c.world, id)}; snowplows (the mayor's) nowhere to be seen`, effect: { tempF: -12, rain: 1.5, teamId: id }, days: 5, weight: 2, teams: [id] };
    } },
  { kind: "worlds_fair", cooldown: 3000, weight: c => (c.year >= 1998 && !c.offseason && c.month === 5 ? 1.5 : 0),
    make: () => ({ headline: "The Electric City World's Fair opens: a monorail, a 'Kitchen of 2025', and a talking robot that only says 'Comets in six'", effect: { attendance: 1.12, teamId: "ELC", economy: 1.03 }, days: 90, weight: 4, teams: ["ELC"] }) },
  { kind: "celebrity_wedding", cooldown: 120, weight: () => 0.5,
    make: c => ({ headline: `Soap star ${pickName(c.rng)} marries ${c.rng.pick(["her own agent", "a former child magician", "a man she met in a Bellwood Park beer line", "a weatherman from Channel 6"])}; tabloids weep with joy`, effect: { mood: 0.05 }, days: 7, weight: 2 }) },
  { kind: "war", cooldown: 2000, weight: c => (c.year >= 1998 ? 0.15 : 0),
    make: () => ({ headline: "Troops sent to 'a sandy place overseas'; the Commissioner orders a second anthem and bigger flags", effect: { mood: -0.2, attendance: 0.96 }, days: 60, weight: 4 }) },
  { kind: "blackout", cooldown: 200, weight: () => 0.4,
    make: c => ({
      headline: "Power blackout across Electric City; Volta Power & Light blames squirrels, squirrels decline comment",
      effect: { attendance: 0.9, teamId: "ELC" }, days: 3, weight: 3, teams: ["ELC"],
      after: () => { if (c.world.factions.elc && c.world.factions.commish) shiftRelation(c.world, "elc", "commish", -1, "the blackout"); },
    }) },
  { kind: "civic_absurdity", cooldown: 30, weight: () => 1,
    make: c => {
      const id = c.rng.pick(mlIds(c.world)), city = clubCity(c.world, id);
      return { headline: c.rng.pick([
        `${city} council votes to ban the word 'pennant' 'until further notice'`,
        `${city} unveils statue of a beloved raccoon; vandals immediately give it a hat`,
        `Talk-radio host in ${city} locks himself in the booth until the team 'trades somebody, anybody'`,
        `${city} school board replaces gym class with 'competitive bingo'`,
        `Infomercial for the 'Batt-O-Matic 2000' airs 31 times in one night in ${city}`,
        `A ${city} man claims his toaster predicts box scores; local news agrees it is 'pretty close'`,
      ]), weight: 1 };
    } },
];

/** Roll background world events for today. ~1–3 per month of game days, more in the hot stove. */
export function rollWorldEvents(world: World, rng: Rng, ctx: { offseason: boolean; month: number; year: number }): LifeEvent[] {
  // expire old effects
  world.effects = (world.effects ?? []).filter(e => e.until >= world.day);
  const events: LifeEvent[] = [];
  const c: Ctx = { world, rng, month: ctx.month, year: ctx.year, offseason: ctx.offseason };
  const lastSeen = (world.seq as Record<string, number>);
  const tries = ctx.offseason ? 1 + (rng.chance(0.3) ? 1 : 0) : 1;
  for (let i = 0; i < tries; i++) {
    const rate = ctx.offseason ? 0.32 : 0.06;
    // forced events (Y2K) bypass the dice
    const forced = TEMPLATES.filter(t => t.weight(c) >= 30 && world.day - (lastSeen[`w:${t.kind}`] ?? -1e9) > t.cooldown);
    if (!forced.length && !rng.chance(rate)) continue;
    const pool = forced.length ? forced : TEMPLATES.filter(t => t.weight(c) > 0 && world.day - (lastSeen[`w:${t.kind}`] ?? -1e9) > t.cooldown);
    if (!pool.length) continue;
    const t = rng.weighted(pool, x => x.weight(c));
    const made = t.make(c);
    lastSeen[`w:${t.kind}`] = world.day;
    let effect: WorldEffect | undefined;
    if (made.effect) {
      const n = (world.seq.w = (world.seq.w ?? 0) + 1);
      effect = { id: `w${n}`, kind: t.kind, title: made.headline.split(/[;:]/)[0], from: world.day, until: world.day + (made.days ?? 14), ...made.effect };
      world.effects.push(effect);
    }
    made.after?.();
    const title = made.headline.split(/[;:]/)[0].trim();
    const text = made.headline.includes(";") || made.headline.includes(":")
      ? `${made.headline.charAt(0).toUpperCase()}${made.headline.slice(1).replace(/; /g, ". ").replace(/: /, ": ")}.`
      : `${made.headline}.`;
    events.push(mkEvent(world, "world", [], made.teams ?? (effect?.teamId ? [effect.teamId] : []), {
      sub: t.kind, kind: t.kind, title, text, headline: made.headline, weight: made.weight ?? 2,
      factionId: made.effect?.factionId ?? (effect?.teamId ? world.teams[effect.teamId]?.factionId : undefined), who: [],
      effects: effect ? { cardDemand: effect.cardDemand, attendance: effect.attendance, economy: effect.economy, mood: effect.mood, rain: effect.rain, tempF: effect.tempF, days: effect.until - effect.from, teamId: effect.teamId } : undefined,
    }));
  }
  return events;
}
