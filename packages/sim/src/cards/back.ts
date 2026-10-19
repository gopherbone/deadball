// Card backs: the front looks like 1909, the back reads like a group chat. Short, snarky,
// specific lines built from the person's traits, stats, family, grudges and incidents.
// Fits the Playdate: ≤ 6 lines of ≤ 40 chars, plus a small stat table.

import { Rng } from "../rng.ts";
import type { Person, Player, Trait, World, Drama, Npc, Umpire } from "../types.ts";
import { MISPRINTS, MOMENT_BLURBS, ORIGINAL_FLAIRS } from "./data.ts";
import {
  fullName, inferKind, isNpc, isPlayer, overall, personOf, teamOf,
  type Card,
} from "./model.ts";
import { batAvg, batK, era, fmtAvg, fmtIp, num, outsOf, pitchK, saves, seasonStats, statSeasons } from "./stats.ts";

export const BACK_WIDTH = 40;
export const BACK_LINES = 6;

/** Greedy word wrap. Words longer than the width are hard-split. */
export function wrap(text: string, width = BACK_WIDTH): string[] {
  const out: string[] = [];
  let line = "";
  for (let word of text.split(/\s+/).filter(Boolean)) {
    while (word.length > width) {
      if (line) { out.push(line); line = ""; }
      out.push(word.slice(0, width));
      word = word.slice(width);
    }
    if (!line) line = word;
    else if (line.length + 1 + word.length <= width) line += " " + word;
    else { out.push(line); line = word; }
  }
  if (line) out.push(line);
  return out;
}

interface Pro { he: string; He: string; his: string; him: string; son: string }
function pronouns(p: Person | undefined): Pro {
  const f = (p as { sex?: string } | undefined)?.sex === "F";
  return f
    ? { he: "she", He: "She", his: "her", him: "her", son: "Daughter" }
    : { he: "he", He: "He", his: "his", him: "him", son: "Son" };
}

const POS_NAME: Record<string, string> = {
  P: "pitcher", C: "catcher", "1B": "first baseman", "2B": "second baseman", "3B": "third baseman", SS: "shortstop",
  LF: "left fielder", CF: "center fielder", RF: "right fielder", DH: "designated hitter",
};

// {L} last name, {N} full name, {T} team name, {he}/{his}/{him}/{He}
const TRAIT_LINES: Record<Trait, string[]> = {
  HOTHEAD: ["Has been ejected from two games and one wedding.", "{L} once fought a pitching machine. Lost on points."],
  LOYAL: ["Would take a bullet for the owner. Has been asked to.", "Loyal to the {T} to a degree HR finds concerning."],
  SUPERSTITIOUS: ["Wears the same socks all streak. Teammates have filed a complaint.", "Taps home plate 11 times. Not 10. Never 10."],
  GAMBLER: ["Knows the odds on everything except {his} own at-bats.", "Has a bookie on speed dial and a second on the pager."],
  DRUNK: ["Plays best after a 'light lunch' (liquid).", "Considers the 7th inning stretch a happy hour."],
  CLUTCH: ["Gets better as the stakes get dumber.", "Two outs, bases loaded? {L} is already smiling."],
  CHOKER: ["Fine until it matters. Then very not fine.", "Has a 'big game face.' It looks like a sneeze."],
  GREEDY: ["Asked for a raise during the anthem.", "Charges teammates for autographs."],
  PIOUS: ["Prays before every at-bat. Results vary by deity.", "Blessed the bat rack twice. The bat rack is still slumping."],
  SHOWBOAT: ["Bat flips on walks.", "Owns a cape. Has worn the cape. In games."],
  GRINDER: ["Dirtiest uniform in the league, by a mile.", "Runs out every grounder like it owes {him} money."],
  LAZY: ["Has perfected the jog. Never the sprint.", "Napped through a rain delay and most of the next game."],
  PARANOID: ["Thinks the scoreboard is watching {him}. Might be right.", "Checks {his} glove for bugs. The electronic kind."],
  IRON_MAN: ["Has not missed a game since dial-up was new.", "Played through a broken toe, the flu and a divorce."],
  FRAGILE: ["Pulled a hamstring signing an autograph.", "Has a locker next to the trainer. By request."],
  CHARMING: ["Could sell ice to a raccoon. Has.", "Fans love {L}. So do the umps, suspiciously."],
  CROOKED: ["Has never been convicted. Of anything. Yet.", "Owns three restaurants. None of them serve food."],
  SNITCH: ["Knows things. Tells things. Ask SportsWire.", "Teammates no longer talk near {L}. Smart."],
};

const DRAMA_LINES: Record<Drama["kind"], string[]> = {
  newborn: ["New baby at home. Sleeping 3 hours a night and hitting like it.", "Just became a parent. Changes diapers between innings."],
  divorce: ["Going through a divorce. The lawyer is having a better season.", "Divorcing. Kept the dog, lost the boat."],
  illness_in_family: ["Family member is sick. Be nice in the comments."],
  affair: ["Linked to an affair by SportsWire. Denied it wearing a fake mustache."],
  feud: ["Feuding with {W}. Nobody remembers why. Not even them.", "Not speaking to {W}. Communicates by bat flip."],
  debt: ["In debt to some very patient men in very wide hats.", "Owes money to people who don't send reminder letters."],
  scandal: ["Currently in a scandal. Card value up 40%.", "In the papers again, and not the sports section."],
  wedding: ["Just married. Honeymoon postponed for a doubleheader."],
  bereavement: ["Lost someone close this year. Playing for them."],
  holdout: ["Holding out for more money and a better parking spot."],
};

function fill(s: string, vars: Record<string, string>): string {
  return s.replace(/\{(\w+)\}/g, (m, k: string) => vars[k] ?? m);
}

function cap(s: string): string { return s ? s[0].toUpperCase() + s.slice(1) : s; }

function nameOf(world: World, id: string | undefined): string | undefined {
  if (!id) return undefined;
  const p = personOf(world, id) ?? (world.archive?.[id] as Person | undefined);
  return p ? fullName(p) : undefined;
}

function relationshipLines(world: World, p: Person, vars: Record<string, string>): string[] {
  const out: string[] = [];
  const book = world.factions?.book?.leaderId;
  for (const r of world.relationships ?? []) {
    if (r.a !== p.id && r.b !== p.id) continue;
    const otherId = r.a === p.id ? r.b : r.a;
    const other = personOf(world, otherId);
    if (!other) continue;
    if (otherId === book && r.reason.startsWith("owes")) {
      out.push(`${cap(r.reason)} to Bets By Bobby. Interest compounds daily.`);
    } else if (r.value <= -2) {
      out.push(r.value <= -4
        ? `Hates ${other.last} ("${r.reason}"). Keep them apart at the reunion.`
        : `Beef with ${fullName(other)}: "${r.reason}."`);
    } else if (isNpc(other) && other.role === "owner" && r.value >= 3) {
      out.push(`${fullName(other)} ${r.reason}. ${vars.L} hasn't forgotten.`);
    } else if (r.value >= 3 && isPlayer(other)) {
      out.push(`Pals with ${fullName(other)} (${r.reason}).`);
    }
  }
  return out;
}

function familyLines(world: World, p: Person, pro: Pro, vars: Record<string, string>): string[] {
  const out: string[] = [];
  const f = p.family;
  if (!f) return out;
  const parent = f.parents?.map(id => personOf(world, id) ?? (world.archive?.[id] as Person | undefined)).find(Boolean);
  if (parent) {
    const famous = isPlayer(parent) || !!parent.career;
    out.push(famous
      ? `${pro.son} of ${fullName(parent)}. Will mention it.`
      : `${pro.son} of ${fullName(parent)}, who still keeps the scorebook.`);
  }
  const spouse = nameOf(world, f.spouse);
  if (spouse) out.push(`Married to ${spouse}, the brains of the operation.`);
  if (f.exSpouses && f.exSpouses.length >= 2) out.push(`Has ${f.exSpouses.length} ex-spouses. Pays more alimony than taxes.`);
  const kids = f.children?.length ?? 0;
  if (kids >= 4) out.push(`Parent of ${kids}. Could field an infield.`);
  else if (kids === 1) out.push(`One kid, who thinks ${vars.L} is just okay.`);
  else if (kids > 1) out.push(`${kids} kids, all of whom think ${vars.L} is just okay.`);
  const house = world.houses?.[f.house] ?? Object.values(world.houses ?? {}).find(h => h.name === f.house);
  if (house && house.titles > 0) out.push(`House ${house.name}: ${house.titles} title${house.titles > 1 ? "s" : ""}. Never lets you forget it.`);
  for (const d of f.drama ?? []) {
    const opts = DRAMA_LINES[d.kind];
    if (!opts) continue;
    const w = nameOf(world, d.with) ?? "a guy from church";
    out.push(...opts.map(s => fill(s, { ...vars, W: w })));
  }
  return out;
}

function statLines(world: World, p: Player, season: number, vars: Record<string, string>): string[] {
  const s = seasonStats(world, p.id, season);
  const out: string[] = [];
  const S = `S${season}`;
  if (s?.bat && num(s.bat.ab) >= 60) {
    const b = s.bat, a = batAvg(b);
    if (num(b.hr) >= 30) out.push(`${b.hr} homers in ${S}. The bleachers filed for hazard pay.`);
    else if (num(b.hr) >= 20) out.push(`${b.hr} homers in ${S}. Several are still missing.`);
    if (num(b.ab) >= 150 && a >= 0.3) out.push(`Hit ${fmtAvg(a)} in ${S}. Allegedly without cork.`);
    if (num(b.ab) >= 150 && a < 0.2) out.push(`Hit ${fmtAvg(a)} in ${S}. This card hit better.`);
    if (num(b.sb) >= 25) out.push(`Stole ${b.sb} bases in ${S}. Also a golf cart (unconfirmed).`);
    if (batK(b) >= 140) out.push(`Struck out ${batK(b)} times. The breeze was felt in the cheap seats.`);
  }
  if (s?.pitch && outsOf(s.pitch) >= 60) {
    const pi = s.pitch, e = era(pi);
    if (e < 3) out.push(`${e.toFixed(2)} ERA in ${S}. Hitters reportedly in therapy.`);
    if (e > 5.5) out.push(`${e.toFixed(2)} ERA in ${S}. Has given up more bombs than a war movie.`);
    if (num(pi.w) >= 15) out.push(`${pi.w} wins in ${S}. Asked for ${pi.w} raises.`);
    if (saves(pi) >= 20) out.push(`${saves(pi)} saves. Sleeps in the bullpen just in case.`);
    if (pitchK(pi) >= 180) out.push(`${pitchK(pi)} strikeouts. Fans ran out of K signs by June.`);
  }
  const hist = (world.history ?? []).find(h => h.season === season);
  if (hist) {
    if (hist.awards?.mvp === p.id) out.unshift(`${S} MVP. Has mentioned this to a waiter.`);
    if (hist.awards?.pitcher === p.id) out.unshift(`${S} best pitcher. Got a plaque and a bigger head.`);
    if (hist.awards?.rookie === p.id) out.unshift(`${S} rookie of the year. The hazing got worse.`);
  }
  for (const h of p.career?.honors ?? []) out.push(`${h}. Brings it up at funerals.`);
  void vars;
  return out;
}

function ratingLines(p: Player, vars: Record<string, string>, pro: Pro): string[] {
  const out: string[] = [];
  if (p.pitching) {
    const top = Math.max(...p.pitching.pitches.map(x => x.velo));
    if (top >= 97) out.push(`Throws ${top.toFixed(0)}. Catchers request a priest.`);
    if (p.pitching.pitches.some(x => x.kind === "KN")) out.push("Throws a knuckleball. Nobody knows where it goes, including the ball.");
    if (p.pitching.pitches.some(x => x.kind === "SPIT")) out.push("Throws a spitball, which is illegal, which is the point.");
    if (p.pitching.control <= 35) out.push("Control is more of a rumor. Duck.");
    if (p.pitching.stamina >= 68) out.push("Would throw 200 pitches if you let {him}. Please don't.");
  } else {
    if (p.batting.power >= 65) out.push("Hits the ball very far, often into someone's soup.");
    if (p.batting.speed >= 65) out.push("Fast. Once scored from second on a sneeze.");
    if (p.batting.eye >= 65) out.push("Takes walks like a retiree.");
    if (p.batting.contact <= 35) out.push("Contact is more of a concept.");
    if (p.fielding.range >= 65) out.push(`Catches everything except a break.`);
    if (p.fielding.hands <= 35) out.push(`Fields with ${pro.his} feet, mostly.`);
  }
  if (p.injury) out.push(`Currently out (${p.injury.kind}). Get well, ${vars.L}.`);
  if (p.nickname) out.push(`They call ${pro.him} "${p.nickname}." ${pro.He} did not pick it.`);
  return out;
}

function playerOpener(world: World, p: Player, kind: string, vars: Record<string, string>, rng: Rng): string {
  const pos = POS_NAME[p.pos] ?? "ballplayer";
  if (kind === "prospect") {
    if (p.potential >= 65) return rng.pick([`Scouts say "future star." Scouts also said the moon was a fad.`, `${p.age}-year-old ${pos} with a ceiling. The {T} are already raising prices.`]);
    return rng.pick([`A ${p.age}-year-old ${pos} for the {T}. Dreams big. Rides the bus.`, `Farmhand. Owns one suit, wears it to every call-up rumor.`]);
  }
  if (p.age >= 34) return `At ${p.age}, ${vars.L} remembers when the bases were flour sacks.`;
  const o = overall(p);
  if (o >= 60) return rng.pick([`${vars.N} is the real deal in a league that mostly isn't.`, `${vars.L} is very good at baseball, which is still technically the point.`]);
  if (o >= 48) return rng.pick([`A solid ${pos} for the {T}. Solid is underrated.`, `${vars.L} plays ${pos} for the {T} and does fine, thanks.`]);
  return rng.pick([`${vars.L} made the {T}. Let's leave it at that.`, `${vars.L} is a ${pos}, technically.`]);
}

function npcLines(world: World, p: Npc, kind: string, vars: Record<string, string>, rng: Rng): string[] {
  const out: string[] = [];
  const faction = p.factionId ? world.factions[p.factionId] : undefined;
  if (kind === "manager") {
    out.push(rng.pick([`Manages the {T}. Has opinions about the bunt.`, `Skipper of the {T}. Chews gum like it owes {him} money.`, `Runs the {T} dugout on gut feel and antacids.`]));
    if (p.career) out.push(`Played ${p.career.mlGames} big-league games. Mentions all of them.`);
  } else if (kind === "umpire") {
    const u = (p as Umpire).stats;
    out.push(rng.pick(["Umpire. Sees all. Calls some.", "Wears the mask so the fans can't find {him} later.", "Umpire since forever. Glasses since never."]));
    if (u.zoneWidth >= 60) out.push("Zone as wide as a barn door, and the barn is generous.");
    else if (u.zoneWidth <= 40) out.push("Zone the size of a postage stamp. A small one.");
    if (u.temper >= 62) out.push("Has ejected a mascot. Twice. Same mascot.");
    if (u.consistency <= 38) out.push("Calls it differently every inning. Keeps it fresh.");
    if (u.corruptible >= 60) out.push("Says {he} can't be bought. Has a price list, though.");
  } else if (kind === "owner") {
    if (faction) out.push(`Runs ${faction.name}. Wants ${faction.wants.slice(0, 2).join(" and ")}.`);
    out.push(rng.pick([`Owns the {T}, and possibly you.`, "Has never paid for a hot dog in {his} life.", "Signs checks with a fountain pen and a sneer."]));
  } else {
    if (faction) out.push(`Runs ${faction.name}. Wants ${faction.wants[0]}.`);
    if (p.role === "fixer") out.push("Takes all bets. Forgives no debts.");
    else if (p.role === "reporter") out.push("Never let a fact get in the way of a scoop.");
    else if (p.role === "official") out.push("Governs mostly from a golf cart.");
  }
  return out;
}

function playerStatTable(world: World, p: Player, season: number): string[][] {
  const seasons = statSeasons(world, p.id, season).slice(0, 3);
  const abbr = (tid: string | undefined) => (tid && world.teams[tid]?.abbr) || world.teams[p.teamId]?.abbr || "FA";
  const isP = !!p.pitching;
  if (seasons.length) {
    if (isP) {
      const rows = [["YR", "TM", "W-L", "ERA", "IP", "K"]];
      for (const s of seasons) {
        const st = seasonStats(world, p.id, s)!;
        const pi = st.pitch;
        if (!pi) continue;
        rows.push([`S${s}`, abbr(st.teamId), `${num(pi.w)}-${num(pi.l)}`, outsOf(pi) ? era(pi).toFixed(2) : "-.--", fmtIp(outsOf(pi)), String(pitchK(pi))]);
      }
      if (rows.length > 1) return rows;
    } else {
      const rows = [["YR", "TM", "AVG", "HR", "RBI", "SB"]];
      for (const s of seasons) {
        const st = seasonStats(world, p.id, s)!;
        const b = st.bat;
        if (!b) continue;
        rows.push([`S${s}`, abbr(st.teamId), fmtAvg(batAvg(b)), String(num(b.hr)), String(num(b.rbi)), String(num(b.sb))]);
      }
      if (rows.length > 1) return rows;
    }
  }
  // No stats yet: scouting grades (20–80).
  if (isP) {
    const r = p.pitching!;
    const velo = Math.max(...r.pitches.map(x => x.velo));
    return [["STF", "CTL", "CMD", "MOV", "VEL"], [r.stuff, r.control, r.command, r.movement, Math.round(velo)].map(String)];
  }
  const b = p.batting, f = p.fielding;
  return [["CON", "POW", "EYE", "SPD", "GLV"], [b.contact, b.power, b.eye, b.speed, Math.round((f.range + f.hands) / 2)].map(String)];
}

/** Modern, snarky writing for the back of a card. Deterministic per card def. */
export function cardBack(world: World, card: Card): { lines: string[]; stats: string[][] } {
  if (card.rarity === "misprint" && card.variant === "blank-back") {
    return { lines: ["", "[ THE PRINTER RAN OUT OF WORDS ]"], stats: [] };
  }
  const rng = new Rng(`back:${card.id}`);
  const kind = inferKind(world, card);
  const p = card.personId ? personOf(world, card.personId) ?? (world.archive?.[card.personId] as Person | undefined) : undefined;
  const pro = pronouns(p);
  const team = teamOf(world, p, card.teamId);
  const vars: Record<string, string> = {
    L: p?.last ?? "Somebody", N: p ? fullName(p) : "Somebody",
    T: team?.name ?? (kind === "umpire" ? "Umpires' Brotherhood" : "league office"),
    he: pro.he, He: pro.He, his: pro.his, him: pro.him,
  };

  let head: string[] = [];
  let pool: string[] = [];
  let stats: string[][] = [];

  if (kind === "moment" && card.moment) {
    const m = card.moment;
    const blurbs = MOMENT_BLURBS[m.kind] ?? MOMENT_BLURBS.SCANDAL;
    head.push(m.blurb ?? rng.pick(blurbs));
    const teams = m.teams.map(t => world.teams[t]?.abbr ?? t).join(" vs ");
    const when = [m.day > 0 ? `Day ${m.day}` : "", m.inning ? `inning ${m.inning}` : "", teams].filter(Boolean).join(", ");
    if (when) head.push(`${when}.`);
    const who = m.who.map(id => personOf(world, id)?.last ?? world.archive?.[id]?.last).filter(Boolean).slice(0, 3);
    if (who.length === 1) pool.push(`Starring ${who[0]}, who refuses to sign this card.`);
    else if (who.length) pool.push(`Starring ${who.join(", ")}. None of them will sign this card.`);
    pool.push("Ask your dad where he was that day. He'll lie.", "Reprinted from the SportsWire archive, sort of.");
    stats = [["SEASON", "DAY", "INN"], [String(card.season), m.day > 0 ? String(m.day) : "-", m.inning ? String(m.inning) : "-"]];
  } else if (isPlayer(p)) {
    const opener = playerOpener(world, p, kind, vars, rng);
    const sl = statLines(world, p, card.season, vars);
    // A real season beats a scouting report: lead with the numbers when there are any.
    if (sl.length) head.push(sl.shift()!);
    if (!sl.length || overall(p) >= 48 || kind === "prospect") head.unshift(opener);
    const traitLines = p.traits.flatMap(t => [rng.pick(TRAIT_LINES[t] ?? [])].filter(Boolean));
    pool = [
      ...sl,
      ...traitLines,
      ...relationshipLines(world, p, vars),
      ...familyLines(world, p, pro, vars),
      ...ratingLines(p, vars, pro),
    ];
    // Stats and awards are the most specific thing we can say: keep one near the top.
    stats = playerStatTable(world, p, card.season);
  } else if (isNpc(p)) {
    const lines = npcLines(world, p, kind, vars, rng);
    head.push(lines[0] ?? `${vars.N}. You know the name, probably.`);
    pool = [
      ...lines.slice(1),
      ...p.traits.map(t => rng.pick(TRAIT_LINES[t] ?? [""])).filter(Boolean),
      ...relationshipLines(world, p, vars),
      ...familyLines(world, p, pro, vars),
    ];
    if (kind === "umpire") {
      const u = (p as Umpire).stats;
      stats = [["ZONE", "CONS", "TEMPER", "PRICE"], [String(u.zoneWidth), String(u.consistency), String(u.temper), "ask"]];
    } else {
      stats = [["AGE", "CLUB", "TRAITS"], [String(p.age), team?.abbr ?? "-", String(p.traits.length)]];
    }
  } else if (p) {
    head.push(rng.pick(["Out of the game for good. Not out of our hearts.", "Gone from baseball. The card stays.", "No longer in the league. Still in your binder."]));
    pool.push(...relationshipLines(world, p, vars), ...familyLines(world, p, pro, vars));
    pool.push(...p.traits.map(t => rng.pick(TRAIT_LINES[t] ?? [""])).filter(Boolean));
  } else {
    head.push("Whoever this was, they were here once.");
  }

  if (card.finalSeason) head.unshift("FINAL SEASON. Retired from baseball by a redeemed card.");
  let redeemTail: string | undefined;
  if (card.redeem && card.rarity !== "misprint") redeemTail = card.redeem.kind === "boost"
    ? `REDEEM: +${card.redeem.boost} ${isPlayer(p) && p.pitching ? "STF/CTL" : "CON/POW/EYE"} FOR ${card.redeem.days} GAME DAYS.`
    : `REDEEM: RETIRES ${(p?.last ?? "SUBJECT").toUpperCase()} FROM BASEBALL.`;
  // Original / misprint notes.
  if (card.rarity === "original") {
    const flair = ORIGINAL_FLAIRS.find(f => f.id === card.variant);
    head.unshift(`1 OF 1. ${flair ? flair.label + "." : "The only one."}`);
  }
  let tail: string | undefined;
  if (card.rarity === "misprint") {
    const mp = MISPRINTS.find(m => m.id === card.variant);
    if (mp) tail = `PRINTER'S NOTE: ${mp.blurb}`;
    if (card.variant === "stats-typo" && stats.length > 1) stats = [stats[0], stats[1].map((v, i) => (i === 2 ? "9.999" : v)), ...stats.slice(2)];
  }

  // Shuffle the flavor pool (stat lines stay ahead of the rest), then pack greedily.
  const statFirst = pool.filter(s => /\bS\d+\b/.test(s));
  const rest = rng.shuffle(pool.filter(s => !/\bS\d+\b/.test(s)));
  const ordered = [...head, ...statFirst.slice(0, 1), ...rest, ...statFirst.slice(1)];
  if (redeemTail) tail = tail ? `${redeemTail} ${tail}` : redeemTail;
  const budget = BACK_LINES - (tail ? wrap(tail).length : 0);
  let text = "";
  for (const raw of ordered) {
    const s = fill(raw, vars).trim();
    if (!s) continue;
    const cand = text ? `${text} ${s}` : s;
    if (wrap(cand).length <= budget) text = cand;
  }
  const lines = wrap(text);
  if (tail) lines.push(...wrap(tail));
  return { lines: lines.slice(0, BACK_LINES), stats };
}
