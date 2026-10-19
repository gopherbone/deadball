// Where drama comes from: daily rolls per person, driven by traits, quirks, fame, marriages,
// money and the standings; plus friendships and mentors forming in clubhouses.

import type { Rng } from "../rng.ts";
import type { Npc, Player, Storyline, World } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { DAYS_PER_YEAR, addDrama, bumpHouse, createNpc, hasQ, hasT, living, relation, relsOf, setRelation, shiftRelation } from "./people.ts";
import { addConcern, fameOf, gainFame } from "./inner.ts";
import { findOpen as findOpenRaw, maybeCutForScandal, openStorylines, startStoryline as startStorylineRaw, fight, type StoryCtx } from "./storylines.ts";
import { chemistry } from "./context.ts";
import { groupOf } from "./ratings.ts";

const perDay = (annual: number) => annual / DAYS_PER_YEAR;

const SCANDALS = [
  "arrested after a bar fight at the Rusty Anchor", "caught doing 95 in the team bus", "photographed leaving a casino at 6 a.m.",
  "punched a mascot (the Pickle)", "booked for eel-related offences", "sued by a hot dog vendor", "found asleep in the visitors' bullpen",
  "caught selling signed balls he didn't sign", "subject of a grand jury (bowling alley matter)", "streaked through a church picnic",
  "fined for feeding nachos to a raccoon on the field", "arrested for impersonating an umpire", "wrecked a rental car in a cornfield",
];
const BRANDS = ["Fizzo Cola", "the Batt-O-Matic 2000", "Uncle Ed's Hair Tonic", "Volta Power & Light", "Mullane's Pickled Eggs", "Slammer Caps", "Pinkerton Motors", "Dr. Gooch's Liniment"];
const CHARITY = ["visited the children's hospital", "paid off a widow's mortgage", "bought the Little League new uniforms", "ran a soup kitchen on an off day", "gave his World's Fair tickets to an orphanage"];
const HAZING = ["dressed the rookies as sailors for the road trip", "sent the rookie to find the 'key to the batter's box'", "nailed the rookie's cleats to the floor", "made the rookies carry the beer in pink backpacks", "shaved the rookie's head into a pennant"];
const AFFAIR_PARTNERS = ["a lounge singer", "the team's travel agent", "a cocktail waitress", "a Harbor City socialite", "a weather girl", "the owner's niece"];
const FEUD_REASONS = [
  "words about a girlfriend", "a stolen parking spot", "a bad tip at the team dinner", "a bat-flip", "a cleat to the shin", "a radio interview",
  "money owed from cards", "who gets the corner locker", "a prank involving a catfish", "who's the real star", "a shared girlfriend (unknowingly)",
];

/** Daily drama starts for players (majors at full rate, AA at a third) and managers. */
export function dailyDrama(world: World, rng: Rng, events: LifeEvent[], ctx: StoryCtx) {
  const inSeason = ctx.phase === "regular" || ctx.phase === "playoffs";
  const bookie = world.factions.book?.leaderId;
  const press = world.factions.press?.leaderId;
  // open storylines by person (built once; new arcs started below are added as we go)
  const byPerson = new Map<string, Storyline[]>();
  for (const s of openStorylines(world)) for (const id of s.people) (byPerson.get(id) ?? byPerson.set(id, []).get(id)!).push(s);
  const involving = (_w: World, id: string) => (byPerson.get(id) ?? []).filter(s => !s.resolved);
  const findOpen = (_w: World, kind: Storyline["kind"], id: string) => involving(world, id).find(s => s.kind === kind && s.people[0] === id);
  const startStoryline = (...args: Parameters<typeof startStorylineRaw>) => {
    const s = startStorylineRaw(...args);
    for (const id of s.people) (byPerson.get(id) ?? byPerson.set(id, []).get(id)!).push(s);
    return s;
  };
  for (const team of Object.values(world.teams)) {
    if (team.level !== "ML" && team.level !== "AA" && team.level !== "EL") continue;
    const scale = team.level === "ML" ? 1 : team.level === "EL" ? 0.5 : 0.33;
    const roster = team.roster;
    for (const id of roster) {
      const p = world.players[id];
      if (!p) continue;
      const F = 1 + fameOf(p) / 40;
      const t = (x: Player["traits"][number], m: number) => (hasT(p, x) ? m : 1);
      const q = (x: NonNullable<Player["quirks"]>[number], m: number) => (hasQ(p, x) ? m : 1);
      const open = involving(world, p.id);
      const busy = open.length >= 3;

      // affairs (secret)
      const wife = living(world, p.family.spouse);
      if (wife && !busy && !open.some(s => s.kind === "affair") && rng.chance(perDay(0.07 * scale * F * t("CHARMING", 3) * q("VAIN", 1.6) * t("PIOUS", 0.1) * t("LOYAL", 0.6)))) {
        const wives = roster.map(x => world.players[x]).filter(x => x && x.id !== p.id && x.family.spouse).map(x => x.family.spouse!);
        const partnerId = wives.length && rng.chance(0.25) ? rng.pick(wives) : undefined;
        const cuckold = partnerId ? roster.find(x => world.players[x]?.family.spouse === partnerId) : undefined;
        startStoryline(world, "affair", [p.id, ...(partnerId ? [partnerId] : []), ...(cuckold ? [cuckold] : [])], [team.id], {
          visibility: "secret", stage: "ongoing", cause: partnerId ? "a teammate's wife" : rng.pick(AFFAIR_PARTNERS), stakes: "his marriage",
          data: { partner: partnerId, partnerText: partnerId ? undefined : rng.pick(AFFAIR_PARTNERS), teammateWife: !!cuckold },
        }, events);
        addConcern(world, p, { kind: "secret_affair", until: world.day + 60, weight: -0.5, note: "keeping a secret" });
      }
      // feuds: teammates (jealousy, tempers), the press (vanity), or opponents (rivalries)
      if (!busy && rng.chance(perDay(0.12 * scale * F * t("HOTHEAD", 3) * q("JEALOUS", 2) * q("PRANKSTER", 1.4) * q("CHARITABLE", 0.5) * q("LONER", 0.7) * t("PIOUS", 0.6)))) {
        const roll = rng.float();
        if (roll < 0.12 && press && (hasQ(p, "VAIN") || hasT(p, "SHOWBOAT") || fameOf(p) > 40)) {
          setRelation(world, p.id, press, -3, "a hit piece", "rival");
          startStoryline(world, "feud", [p.id, press], [team.id], { visibility: "public", stage: "public_spat", cause: "a SportsWire column", stakes: "his reputation", data: { withPress: true } }, events);
        } else if (roll < 0.75) {
          const mates = roster.filter(x => x !== p.id && !hasQ(world.players[x], "LONER"));
          // the jealous pick on the famous
          const other = hasQ(p, "JEALOUS") ? mates.map(x => world.players[x]).reduce((a, b) => (fameOf(b) > fameOf(a) ? b : a), world.players[rng.pick(mates)]) : world.players[rng.pick(mates)];
          if (other && !involving(world, other.id).some(s => s.kind === "feud" && s.people.includes(p.id))) {
            const why = hasQ(p, "JEALOUS") ? "who's the real star" : rng.pick(FEUD_REASONS);
            setRelation(world, p.id, other.id, Math.min(-2, relation(world, p.id, other.id) - 2), why, "rival");
            startStoryline(world, "feud", [p.id, other.id], [team.id], { visibility: rng.chance(0.4) ? "rumoured" : "secret", stage: "words", cause: why, stakes: "the clubhouse", data: { teammates: true } }, events);
            addConcern(world, p, { kind: "feud", about: other.id, until: world.day + 40, weight: -1, note: why });
          }
        } else if (team.level === "ML") {
          const opps = Object.values(world.teams).filter(x => x.level === "ML" && x.id !== team.id);
          const ot = rng.pick(opps);
          const other = world.players[rng.pick(ot.roster)];
          if (other) {
            setRelation(world, p.id, other.id, -3, "bad blood", "rival");
            startStoryline(world, "rivalry", [p.id, other.id], [team.id, ot.id], { visibility: "public", stage: "simmering", cause: rng.pick(["a bat-flip", "trash talk in the papers", "a hard slide", "a showboat home-run trot", "an old minor-league grudge"]), stakes: "pride" }, events);
          }
        }
      }
      // gambling debts
      if (bookie && !findOpen(world, "gambling_debt", p.id) && rng.chance(perDay(scale * (hasT(p, "GAMBLER") ? 0.3 : 0.012) * (fameOf(p) > 50 ? 1.3 : 1)))) {
        const amount = (5 + rng.int(60)) * 100;
        shiftRelation(world, p.id, bookie, -2, `owes $${amount}`, "owes");
        startStoryline(world, "gambling_debt", [p.id, bookie], [team.id], { visibility: "secret", stage: "owes", cause: rng.pick(["a bad week at the track", "the dog races", "a can't-miss tip on the Ironmen", "poker on the team bus", "a sure thing in Natchez"]), stakes: `$${amount}`, data: { amount } }, events);
      }
      // marriage trouble (the road is hard)
      if (wife && !busy && !findOpen(world, "marriage_trouble", p.id) && rng.chance(perDay(0.04 * scale * q("JEALOUS", 2) * t("DRUNK", 1.5) * t("GAMBLER", 1.3)))) {
        startStoryline(world, "marriage_trouble", [p.id, wife.id], [team.id], { visibility: "secret", stage: "cold", cause: rng.pick(["the road trips", "his drinking", "money", "her career", "his mother"]), stakes: "the marriage" }, events);
      }
      // bar brawls
      if (rng.chance(perDay(0.04 * scale * F * t("DRUNK", 4) * t("HOTHEAD", 2) * t("PIOUS", 0.2)))) {
        const others = Object.values(world.teams).filter(x => x.level === team.level && x.id !== team.id);
        const ot = rng.pick(others);
        const other = world.players[rng.pick(ot.roster)];
        if (other) {
          fight(world, rng, [p.id, other.id], "bar", events);
          bumpHouse(world, p.family.house, -1);
          if (team.level === "ML" && rng.chance(0.4)) startStoryline(world, "rivalry", [p.id, other.id], [team.id, ot.id], { visibility: "public", stage: "boiling", cause: "a bar fight", stakes: "pride" }, events);
          maybeCutForScandal(world, rng, p, events, "a bar fight");
        }
      }
      // public scandals (any press is press)
      if (rng.chance(perDay(scale * F * (0.01 + (hasT(p, "DRUNK") ? 0.15 : 0) + (hasT(p, "CROOKED") ? 0.08 : 0) + (hasT(p, "SHOWBOAT") ? 0.05 : 0))))) {
        const what = rng.pick(SCANDALS);
        addDrama(p, { kind: "scandal", since: world.day, weight: -2.5, note: what });
        bumpHouse(world, p.family.house, -1);
        gainFame(world, rng, p, 2.5, events, "scandal");
        events.push(mkEvent(world, "drama", [p.id], [team.id], { sub: "scandal", kind: "scandal", what, fame: Math.round(fameOf(p)) }));
        maybeCutForScandal(world, rng, p, events, what);
      }
      // the famous: endorsements, stalkers; the kind: charity
      if (fameOf(p) >= 45 && rng.chance(perDay(0.6 * scale * t("GREEDY", 1.5)))) {
        const brand = rng.pick(BRANDS);
        p.mood = Math.min(5, p.mood + 1);
        events.push(mkEvent(world, "fame", [p.id], [team.id], { sub: "endorsement", brand, fee: Math.round(fameOf(p) * (5 + rng.int(20))) }));
      }
      if (fameOf(p) >= 60 && !findOpen(world, "stalker", p.id) && rng.chance(perDay(0.12 * scale))) {
        const fan = createNpc(world, rng, { sex: rng.chance(0.6) ? "F" : "M", age: 20 + rng.int(40), occupation: "superfan" });
        startStoryline(world, "stalker", [p.id, fan.id], [team.id], { visibility: "rumoured", stage: "letters", cause: "fan letters (many)", stakes: "his peace of mind" }, events);
      }
      if (hasQ(p, "CHARITABLE") && rng.chance(perDay(0.8 * scale))) {
        gainFame(world, rng, p, 2, events, "charity");
        events.push(mkEvent(world, "fame", [p.id], [team.id], { sub: "charity", what: rng.pick(CHARITY) }));
      }
      // sick family
      if (rng.chance(perDay(0.05 * scale))) {
        const rel = [...p.family.parents, ...p.family.children].map(x => living(world, x)).filter(Boolean);
        if (rel.length) {
          const who = rng.pick(rel)!;
          const kid = p.family.children.includes(who.id);
          addConcern(world, p, { kind: kid ? "sick_kid" : "sick_parent", about: who.id, until: world.day + 30 + rng.int(30), weight: -2, note: `${who.first} is ill` });
          events.push(mkEvent(world, "drama", [p.id, who.id], [team.id], { sub: "illness", kind: "illness_in_family", what: `${kid ? (who.sex === "F" ? "his daughter" : "his son") : (who.sex === "F" ? "his mother" : "his father")} is seriously ill` }));
        }
      }
    }
    // friendships, mentors, pranks
    if (rng.chance(0.06) && roster.length > 2) {
      const a = world.players[rng.pick(roster)], b = world.players[rng.pick(roster)];
      if (a && b && a.id !== b.id && !hasQ(a, "LONER") && !hasQ(b, "LONER") && relation(world, a.id, b.id) >= 0) {
        setRelation(world, a.id, b.id, Math.min(5, relation(world, a.id, b.id) + 2 + (hasT(a, "CHARMING") ? 1 : 0)), rng.pick(["roommates on the road", "same hometown", "fishing buddies", "card partners", "both new in town"]), "friend");
      }
    }
    if (rng.chance(0.01)) {
      const vets = roster.map(x => world.players[x]).filter(x => x && x.age >= 30 && !hasQ(x, "LONER"));
      const kids = roster.map(x => world.players[x]).filter(x => x && x.age <= 24);
      if (vets.length && kids.length) {
        const v = rng.pick(vets), k = kids.find(x => groupOf(x) === groupOf(v)) ?? rng.pick(kids);
        setRelation(world, v.id, k.id, 4, `${v.last} took him under his wing`, "mentor");
      }
    }
    if (inSeason && ctx.day !== undefined && ctx.day >= 2 && ctx.day <= 12 && team.level === "ML" && rng.chance(0.05)) {
      const prankster = roster.map(x => world.players[x]).find(x => x && hasQ(x, "PRANKSTER") && x.age >= 26);
      const rookie = roster.map(x => world.players[x]).find(x => x && x.debut?.season === world.season);
      if (prankster && rookie) {
        const sour = hasT(rookie, "HOTHEAD") || hasQ(rookie, "VAIN");
        if (sour) setRelation(world, rookie.id, prankster.id, -3, "the hazing", "rival");
        else shiftRelation(world, rookie.id, prankster.id, 1, "survived the hazing", "friend");
        addConcern(world, rookie, { kind: "hazing", about: prankster.id, until: world.day + 10, weight: sour ? -1.5 : 0.5 });
        events.push(mkEvent(world, "drama", [prankster.id, rookie.id], [team.id], { sub: "hazing", what: rng.pick(HAZING), tookItBadly: sour }));
        if (sour) startStoryline(world, "feud", [rookie.id, prankster.id], [team.id], { visibility: "rumoured", stage: "words", cause: "the hazing", stakes: "the clubhouse", data: { teammates: true } }, events);
      }
    }
  }
  if (ctx.phase === "regular") hotSeats(world, rng, events, ctx);
}

/** Managers of struggling clubs end up on the hot seat. */
function hotSeats(world: World, rng: Rng, events: LifeEvent[], ctx: StoryCtx) {
  if ((ctx.day ?? 0) < 18) return;
  for (const team of Object.values(world.teams)) {
    if (team.level !== "ML") continue;
    const rec = ctx.table?.[team.id];
    if (!rec) continue;
    const mgr = world.npcs[team.managerId];
    if (!mgr || findOpenRaw(world, "hot_seat", mgr.id)) continue;
    const pct = rec.w / Math.max(1, rec.w + rec.l);
    const streak = rec.seq.endsWith("LLLLLLL");
    if (pct >= 0.42 && !streak) continue;
    // new managers get a grace period
    const job = mgr.goals?.find(g => g.kind === "keep_job");
    if (job && world.day - job.since < 45) continue;
    if (!rng.chance(0.12)) continue;
    const chem = chemistry(world, team.id);
    startStorylineRaw(world, "hot_seat", [mgr.id], [team.id], {
      visibility: "rumoured", stage: "warm", cause: streak ? "a six-game losing streak" : `a ${rec.w}-${rec.l} start`, stakes: "his job",
      data: { record: `${rec.w}-${rec.l}`, chemistry: chem },
    }, events);
    addConcern(world, mgr, { kind: "hot_seat", until: world.day + 60, weight: -2, note: "job on the line" });
  }
}

/** Opening day: contract years and other season-long arcs. */
export function seasonOpeners(world: World, rng: Rng, events: LifeEvent[]) {
  for (const team of Object.values(world.teams)) {
    if (team.level !== "ML") continue;
    for (const id of team.roster) {
      const p = world.players[id];
      if (!p || p.contract?.years !== 1) continue;
      if (fameOf(p) < 25 && (p.peak ?? 0) < 55) continue;
      if (findOpenRaw(world, "contract_year", p.id)) continue;
      startStorylineRaw(world, "contract_year", [p.id], [team.id], { visibility: "public", stage: "playing_for_a_deal", cause: "final year of his contract", stakes: `$${p.contract.salary}k a year` }, events);
      addConcern(world, p, { kind: "contract_year", until: world.day + 190, weight: hasT(p, "GREEDY") ? -1 : -0.5, note: "contract year" });
    }
  }
  void rng;
}

/** Worldgen: friendship cliques, mentors, and old family ties. */
export function seedRelationships(world: World, rng: Rng) {
  for (const team of Object.values(world.teams)) {
    const ps = team.roster.map(id => world.players[id]).filter(Boolean);
    for (const p of ps) {
      if (hasQ(p, "LONER")) continue;
      const n = (hasT(p, "CHARMING") ? 3 : 1) + rng.int(2);
      for (let i = 0; i < n; i++) {
        const o = rng.pick(ps);
        if (o.id === p.id || hasQ(o, "LONER") || relation(world, p.id, o.id) !== 0) continue;
        setRelation(world, p.id, o.id, 2 + rng.int(3), rng.pick(["roommates on the road", "same hometown", "came up together", "fishing buddies", "card partners"]), "friend");
      }
    }
    const vets = ps.filter(p => p.age >= 30), kids = ps.filter(p => p.age <= 24);
    for (const v of vets) if (kids.length && rng.chance(0.3)) setRelation(world, v.id, rng.pick(kids).id, 4, `${v.last} took him under his wing`, "mentor");
  }
  // blood ties between players
  for (const p of Object.values(world.players)) {
    for (const id of [...p.family.parents, ...p.family.children]) {
      if (world.players[id] || world.npcs[id]) if (relation(world, p.id, id) === 0) setRelation(world, p.id, id, 3, "family", "family");
    }
  }
  // tag the old untyped entries
  for (const r of world.relationships) {
    if (r.kind) continue;
    if (world.factions[r.a] && world.factions[r.b]) r.kind = "faction";
    else if (/owes/.test(r.reason)) r.kind = "owes";
    else r.kind = r.value < 0 ? "grudge" : "friend";
  }
  void relsOf;
}

export function npcOf(world: World, id: string | undefined): Npc | undefined {
  return id ? world.npcs[id] : undefined;
}
