// Season wrap-up (awards, leaders, champions), headline scoring, and the history book.

import type { House, Level, SeasonHistory, World } from "../types.ts";
import { LEVELS } from "../types.ts";
import { mkEvent, type LifeEvent } from "../life/events.ts";
import { bumpHouse, personById, shortName, wasPlayer, type AnyPerson } from "../life/people.ts";
import { batValue, compressSeason, era, ipString, leaders, levelLine, pitchValue, rate3, avg, careerTotals } from "./stats.ts";
import type { SeasonState } from "./index.ts";
import { standings } from "./index.ts";

const abbr = (world: World, id: string | undefined) => (id ? world.teams[id]?.abbr ?? id : "?");
const teamName = (world: World, id: string | undefined) => {
  const t = id ? world.teams[id] : undefined;
  return t ? `${t.city} ${t.name}` : id ?? "?";
};
const nm = (world: World, id: string | undefined) => shortName(personById(world, id));

// --- end of season -------------------------------------------------------------------------------

export function finishSeason(world: World, state: SeasonState, events: LifeEvent[]) {
  const season = state.season;
  const po = state.playoff;
  const ml = standings(world, state, "ML");
  const h: SeasonHistory = {
    season, year: state.year, champion: po?.champion, runnerUp: po?.runnerUp, finalScore: po?.finalScore,
    standings: ml.map(s => [s.teamId, s.w, s.l]), pennants: {}, awards: {}, awardLines: {}, leaders: {},
    headlines: [...state.headlines],
  };
  for (const lv of LEVELS) h.pennants[lv as Level] = standings(world, state, lv)[0]?.teamId;
  const pct: Record<string, number> = Object.fromEntries(ml.map(s => [s.teamId, s.w / Math.max(1, s.w + s.l)]));

  // awards
  let mvp: [string, number] | undefined, cy: [string, number] | undefined, roy: [string, number] | undefined;
  for (const [id, byS] of Object.entries(world.stats)) {
    const line = levelLine(byS[season], "ML");
    if (!line) continue;
    const p = world.players[id];
    const teamBonus = ((pct[byS[season].teamId] ?? 0.5) - 0.5) * 20;
    let v = -Infinity;
    if (line.bat && line.bat.pa >= 350) {
      const bv = batValue(line.bat) + (line.bat.r + line.bat.rbi) * 0.2 + line.bat.hr * 0.5 + teamBonus;
      v = bv;
      if (!mvp || bv > mvp[1]) mvp = [id, bv];
    }
    if (line.pitch && (line.pitch.outs >= 360 || line.pitch.sv >= 25)) {
      const pv = pitchValue(line.pitch) + line.pitch.w * 0.6 + teamBonus * 0.5;
      v = Math.max(v, pv);
      if (!cy || pv > cy[1]) cy = [id, pv];
    }
    if (p?.debut?.season === season && v > -Infinity && (!roy || v > roy[1])) roy = [id, v];
  }
  const line = (id: string) => {
    const s = levelLine(world.stats[id]?.[season], "ML");
    if (s?.pitch && (!s.bat || s.pitch.outs > 30)) return `${s.pitch.w}-${s.pitch.l}, ${era(s.pitch).toFixed(2)} ERA, ${s.pitch.k} K${s.pitch.sv >= 10 ? `, ${s.pitch.sv} SV` : ""}, ${ipString(s.pitch)} IP`;
    if (s?.bat) return `${rate3(avg(s.bat))}, ${s.bat.hr} HR, ${s.bat.rbi} RBI${s.bat.sb >= 20 ? `, ${s.bat.sb} SB` : ""}`;
    return "";
  };
  const award = (key: "mvp" | "pitcher" | "rookie", w: [string, number] | undefined, label: string, rep: number) => {
    if (!w) return;
    h.awards[key] = w[0];
    h.awardLines[key] = line(w[0]);
    const p = personById(world, w[0]);
    if (p) bumpHouse(world, p.family.house, rep);
    events.push(mkEvent(world, "award", [w[0]], [world.stats[w[0]][season].teamId], { award: label, line: h.awardLines[key] }));
  };
  award("mvp", mvp, "Most Valuable Player", 6);
  award("pitcher", cy, "Pitcher of the Year", 5);
  award("rookie", roy, "Rookie of the Year", 2);

  for (const key of ["avg", "hr", "rbi", "sb", "w", "k", "era", "sv"] as const) h.leaders[key] = leaders(world, season, "ML", key, 1)[0];

  if (po?.champion) {
    const team = world.teams[po.champion];
    const houses = new Set<string>();
    for (const id of [...team.roster, ...(team.il ?? [])]) {
      const p = world.players[id];
      if (!p) continue;
      bumpHouse(world, p.family.house, 2);
      houses.add(p.family.house);
    }
    for (const hid of houses) if (world.houses[hid]) world.houses[hid].titles++;
    events.push(mkEvent(world, "champion", team.roster.slice(), [po.champion, po.runnerUp ?? ""], { score: po.finalScore, series: "Continental Series", circuit: "continental" }));
  }
  // the Enhanced League
  const el = standings(world, state, "EL");
  if (el.length) {
    const epo = state.enhancedPlayoff;
    let mvpE: [string, number] | undefined;
    for (const [id, byS] of Object.entries(world.stats)) {
      const l = levelLine(byS[season], "EL");
      if (l?.bat && l.bat.pa >= 300) { const v = batValue(l.bat) + l.bat.hr * 0.5; if (!mvpE || v > mvpE[1]) mvpE = [id, v]; }
      if (l?.pitch && l.pitch.outs >= 360) { const v = pitchValue(l.pitch) + l.pitch.w * 0.6; if (!mvpE || v > mvpE[1]) mvpE = [id, v]; }
    }
    h.enhanced = { champion: epo?.champion, runnerUp: epo?.runnerUp, finalScore: epo?.finalScore, standings: el.map(x => [x.teamId, x.w, x.l]) };
    if (mvpE) {
      h.enhanced.mvp = mvpE[0];
      const l = levelLine(world.stats[mvpE[0]][season], "EL")!;
      h.enhanced.mvpLine = l.pitch && (!l.bat || l.pitch.outs > 30) ? `${l.pitch.w}-${l.pitch.l}, ${era(l.pitch).toFixed(2)} ERA` : l.bat ? `${rate3(avg(l.bat))}, ${l.bat.hr} HR` : "";
    }
    if (epo?.champion) {
      const t = world.teams[epo.champion];
      events.push(mkEvent(world, "champion", t.roster.slice(), [epo.champion, epo.runnerUp ?? ""], { score: epo.finalScore, series: "Mirage Cup", circuit: "enhanced", mvp: h.enhanced.mvp }));
    }
  }
  compressSeason(world, season);
  world.history.push(h);
}

// --- headlines --------------------------------------------------------------------------------------

type Headline = SeasonHistory["headlines"][number];

const playerValue = (world: World, id: string | undefined): number => {
  const p = id ? world.players[id] : undefined;
  return p?.peak ?? (personById(world, id)?.career?.peak ?? 40);
};

export function headlineFor(world: World, e: LifeEvent): Headline | undefined {
  const d = e.data ?? {};
  const who = e.who;
  const p0 = personById(world, who[0]);
  switch (e.kind) {
    case "trade": {
      const [a, b] = who;
      return {
        kind: "trade", who,
        text: `${abbr(world, d.to as string)} got ${nm(world, a)} from ${abbr(world, d.from as string)} for ${nm(world, b)}${d.reason ? ` (${d.reason})` : ""}`,
        weight: Math.max(1, playerValue(world, a) - 48),
      };
    }
    case "drama": return dramaHeadline(world, e);
    case "divorce":
      if (!who.some(id => wasPlayer(world, personById(world, id)))) return undefined;
      return { kind: "scandal", who, text: `${nm(world, who[0])} and ${nm(world, who[1])} divorce${d.reason ? ` (${d.reason})` : ""}`, weight: 2 + Math.max(0, playerValue(world, who[0]) - 52) / 3 };
    case "death": {
      if (!p0) return undefined;
      const star = p0.career && p0.career.peak >= 58;
      const notable = star || (p0 as AnyPerson & { role?: string }).role === "owner" || p0.kind === "player";
      if (!notable) return undefined;
      return { kind: "death", who, text: `Died: ${nm(world, who[0])} (${p0.born ?? "?"}–${world.year})${d.cause ? `, ${d.cause}` : ""}${p0.career ? `, ${p0.career.pos === "P" ? "pitcher" : "slugger"} of ${p0.career.from}–${p0.career.to}` : ""}`, weight: star ? 4 + (p0.career!.peak - 58) / 2 : 5 };
    }
    case "debut":
      if (!d.secondGen) return undefined;
      return { kind: "dynasty", who, text: `${nm(world, who[0])}, ${d.relation} of ${nm(world, d.kin as string)}, debuts for ${abbr(world, e.teams?.[0])}`, weight: 5 + playerValue(world, d.kin as string) / 15 };
    case "milestone":
      return { kind: "milestone", who, text: `${nm(world, who[0])}: ${(d.label ?? d.feat) as string}`, weight: d.feat === "no-hitter" ? 6 : d.label ? 4 + (d.value as number) / 250 : 2 };
    case "succession":
      return { kind: "succession", who, text: (d.what as string) ?? `${nm(world, who[0])} takes over`, weight: 6 };
    case "world":
      return { kind: "world", who, text: d.headline as string, weight: (d.weight as number) ?? 2 };
    case "retirement": {
      if (d.role) return undefined; // managers/umpires stepping down
      const c = p0?.career;
      if (!c || c.peak < 60) return undefined;
      return { kind: "retirement", who, text: `${nm(world, who[0])} retires after ${c.mlSeasons} big-league seasons${c.honors.length ? ` (${c.honors.slice(0, 2).join(", ")})` : ""}`, weight: (c.peak - 55) / 2 };
    }
    case "fire": {
      const role = d.role === "gm" ? "general manager" : "manager";
      const mid = d.midseason ? " mid-season" : "";
      return { kind: "firing", who, text: `${abbr(world, e.teams?.[0])} fire ${role} ${nm(world, who[0])}${mid}${d.cause ? ` (${d.cause})` : ""}`, weight: d.midseason ? 5.5 : d.role === "gm" ? 4 : 2.5 };
    }
    case "fight": {
      const where = d.sub === "on_field" ? "brawl on the field" : d.sub === "clubhouse" ? "clubhouse fight" : "bar fight";
      const hurt = (d.hurt as { id: string }[] | undefined)?.length ? ", injuries" : "";
      return { kind: "fight", who, text: `${nm(world, who[0])} and ${nm(world, who[1])}: ${where}${hurt}`, weight: 2 + fame(world, who) / 18 + (d.sub === "clubhouse" ? 1.5 : 0) };
    }
    case "beanball":
      return d.injured ? { kind: "fight", who, text: `${nm(world, who[0])} hits ${nm(world, who[1])} on purpose (${d.why}); he's hurt`, weight: 3 + fame(world, who) / 25 } : undefined;
    case "weird": {
      const t: Record<string, string> = {
        abduction_return: `${nm(world, who[0])} returns after vanishing${d.power ? ` with a new power (${d.power})` : d.quirk ? `, changed (${String(d.quirk).toLowerCase().replace(/_/g, " ")})` : d.rating ? `, his ${d.rating} up ${d.by}` : ""}`,
        plane_crash: `Plane crash: the ${teamName(world, e.teams?.[0])} lose ${(d.dead as unknown[] | undefined)?.length ?? "several"}${d.manager ? " (manager among them)" : ""} (${d.where}, ${d.cause})`,
        resurrection: `${nm(world, who[0])}, dead since ${d.diedYear}, is back (${d.how})`,
        clone: `A second ${nm(world, d.original as string)} turns up in the minors`,
        historical_arrival: `${d.figure} (${d.era}) signs with ${abbr(world, e.teams?.[0])}; he ${String(d.how).replace(/^found/, "was found")}`,
      };
      const text = t[d.sub as string];
      return text ? { kind: "weird", who, text, weight: d.sub === "plane_crash" ? 12 : 9 } : undefined;
    }
    case "transfer":
      return d.sub === "to_enhanced"
        ? { kind: "weird", who, text: `${nm(world, who[0])} sent to the Enhanced League (${abbr(world, d.to as string)}): ${d.reason}`, weight: 4 + fame(world, who) / 20 }
        : { kind: "weird", who, text: `${nm(world, who[0])} returns from the desert to ${abbr(world, d.to as string)} (${d.reason})`, weight: 3 };
    case "exhibition":
      return d.circuitWinner === "enhanced" ? { kind: "exhibition", who, text: `Exhibition: ${abbr(world, d.winner as string)} (Enhanced) beat ${abbr(world, d.loser as string)} ${d.score}${Number(d.powersUsed) ? `, ${d.powersUsed} powers used` : ""}`, weight: 2.5 } : undefined;
    case "goal":
      if (d.sub === "achieved" && (d.goal === "revenge" || (d.goal === "win_title" && Number(d.yearsWanted ?? 0) >= 5))) return { kind: "goal", who, text: `${nm(world, who[0])} finally ${d.goal === "revenge" ? "gets even" : "wins a title"} (${d.how})`, weight: 3 };
      return undefined;
    default:
      return undefined;
  }
}

export function noteHeadlines(world: World, state: SeasonState, events: LifeEvent[]) {
  const target = state.phase === "offseason" && world.history.length ? world.history[world.history.length - 1].headlines : state.headlines;
  for (const e of events) {
    const h = headlineFor(world, e);
    if (h && h.weight >= 2) target.push(h);
  }
  if (target.length > 80) {
    target.sort((a, b) => b.weight - a.weight);
    target.length = 60;
  }
}

const fame = (world: World, ids: string[]) => Math.max(0, ...ids.map(id => (personById(world, id) as { fame?: number } | undefined)?.fame ?? 0));

/** Storyline beats worth remembering: mostly resolutions, plus public scandals. */
function dramaHeadline(world: World, e: LifeEvent): Headline | undefined {
  const d = e.data ?? {};
  const who = e.who;
  const sub = (d.sub ?? d.kind) as string;
  const A = nm(world, who[0]), B = nm(world, who[1]);
  const F = fame(world, who.slice(0, 2)) / 15;
  if (d.secret) return undefined;
  if (sub === "scandal") return { kind: "scandal", who, text: `${A}: ${d.what}`, weight: 2 + F };
  if (sub === "hazing" || sub === "illness" || sub === "vendetta") return sub === "vendetta" ? { kind: "fight", who, text: `${nm(world, d.injured as string)} hurt by ${nm(world, d.culprit as string)}; his friends swear revenge`, weight: 2 + F / 2 } : undefined;
  if (d.blowup) return { kind: "firing", who, text: `${A} ${d.blowup}`, weight: 2.5 + F / 2 };
  const out = d.outcome as string | undefined;
  if (!out) return undefined;
  switch (sub) {
    case "affair": return out === "discovered" ? { kind: "scandal", who, text: `${A}'s affair${d.teammateWife ? " with a teammate's wife" : d.partnerText ? ` with ${d.partnerText}` : ""} comes out (${d.how})`, weight: 4 + F + (d.teammateWife ? 2 : 0) } : undefined;
    case "marriage_trouble": return out === "divorced" ? { kind: "scandal", who, text: `${A} and ${B} divorce (${d.cause})`, weight: 2.5 + F } : undefined;
    case "feud": return out === "brawl" ? { kind: "fight", who, text: `${A}–${B} feud (${d.cause}) ends in a ${d.where} fight`, weight: 3.5 + F } : undefined;
    case "rivalry": return out === "brawl" ? { kind: "fight", who, text: `${A} and ${B} settle their rivalry with fists (${d.where})`, weight: 3 + F } : undefined;
    case "gambling_debt": {
      const t: Record<string, string> = {
        exposed: Number(d.shaved ?? 0) > 0 ? `${A} caught shaving points to pay a gambling debt (${d.shaved} games); suspended` : `${A} caught agreeing to shave points for his bookie; suspended`,
        ejected_from_league: `${A} banned for life for shaving points (${d.shaved} games)`,
        leg_broken: `${A} "falls down some stairs" over an unpaid gambling debt`,
        went_to_commissioner: `${A} turns in his bookie to the Commissioner`,
      };
      return t[out] ? { kind: "scandal", who, text: t[out], weight: (out === "ejected_from_league" ? 9 : out === "exposed" ? 5.5 : 4.5) + F / 2 } : undefined;
    }
    case "hot_seat": return undefined; // the "fire" event carries it
    case "comeback": return out === "returned" ? { kind: "comeback", who, text: `${A} back in the majors after ${d.daysOut} days (${d.cause})`, weight: 2.5 + F / 2 } : undefined;
    case "stalker": return { kind: "scandal", who, text: `${A}'s stalker ${out === "arrested" ? "arrested" : out === "confrontation" ? "confronts him" : "vanishes"}`, weight: 3 + F / 2 };
    case "curse": return out === "lifted" ? { kind: "weird", who, text: `${A}'s curse (${d.cause}) lifted: ${d.ritual}`, weight: 2.5 } : undefined;
    case "holdout": return { kind: "scandal", who, text: `${A}'s holdout ends: ${out}`, weight: 2 + F / 2 };
    case "contract_year": return out === "big_payday" ? { kind: "money", who, text: `${A} cashes in: $${d.salary}k a year`, weight: 2 + F / 2 } : undefined;
    default: return undefined;
  }
}

// --- the history book ------------------------------------------------------------------------------

function houseGenerations(world: World, house: House): { players: AnyPerson[]; generations: number } {
  const members: AnyPerson[] = [];
  for (const coll of [world.players, world.npcs, world.archive] as Record<string, AnyPerson>[]) {
    for (const p of Object.values(coll)) if (p.family.house === house.id && wasPlayer(world, p)) members.push(p);
  }
  const ids = new Set(members.map(m => m.id));
  const depth = (p: AnyPerson, seen = 0): number => {
    if (seen > 6) return 1;
    let best = 1;
    for (const pid of p.family.parents) {
      const par = personById(world, pid);
      if (par && ids.has(pid)) best = Math.max(best, 1 + depth(par, seen + 1));
      else if (par) {
        // grandfather skip (nephews/grandsons count too)
        for (const gid of par.family.parents) if (ids.has(gid)) best = Math.max(best, 2 + depth(personById(world, gid)!, seen + 2) - 1);
      }
    }
    return best;
  };
  return { players: members, generations: members.reduce((a, m) => Math.max(a, depth(m)), 0) };
}

export function historyBook(world: World, opts: { seasons?: number } = {}): string[] {
  const out: string[] = [];
  const hist = opts.seasons ? world.history.slice(-opts.seasons) : world.history;
  const w = (s: string) => out.push(s);
  w(`THE DEADBALL HISTORY BOOK — ${hist.length} season${hist.length === 1 ? "" : "s"}, ${hist[0]?.year ?? world.year}–${hist[hist.length - 1]?.year ?? world.year}`);
  w("");
  for (const h of hist) {
    const champ = h.champion ? world.teams[h.champion] : undefined;
    const rec = h.standings.find(s => s[0] === h.champion);
    w(`${h.year} (Season ${h.season})`);
    if (champ) w(`  Champion: ${teamName(world, h.champion)}${rec ? ` (${rec[1]}-${rec[2]})` : ""} beat ${teamName(world, h.runnerUp)} ${h.finalScore} in the Continental Series`);
    w(`  Standings: ${h.standings.map(([id, ww, l]) => `${abbr(world, id)} ${ww}-${l}`).join(", ")}`);
    if (h.enhanced?.champion) w(`  Enhanced League: ${teamName(world, h.enhanced.champion)} won ${"the Mirage Cup"} over ${teamName(world, h.enhanced.runnerUp)} ${h.enhanced.finalScore}${h.enhanced.mvp ? ` · MVP ${nm(world, h.enhanced.mvp)} (${h.enhanced.mvpLine})` : ""}`);
    const aw: string[] = [];
    if (h.awards.mvp) aw.push(`MVP ${nm(world, h.awards.mvp)} (${h.awardLines.mvp})`);
    if (h.awards.pitcher) aw.push(`Pitcher ${nm(world, h.awards.pitcher)} (${h.awardLines.pitcher})`);
    if (h.awards.rookie) aw.push(`Rookie ${nm(world, h.awards.rookie)}`);
    if (aw.length) w(`  Awards: ${aw.join(" · ")}`);
    const L = h.leaders;
    const lead = (k: string, label: string, fmt: (v: number) => string) => (L[k] ? `${label} ${nm(world, L[k]![0]).split(" ").slice(-1)[0]} ${fmt(L[k]![1])}` : "");
    w(`  Leaders: ${[lead("hr", "HR", v => `${v}`), lead("avg", "AVG", rate3), lead("rbi", "RBI", v => `${v}`), lead("w", "W", v => `${v}`), lead("k", "K", v => `${v}`), lead("era", "ERA", v => v.toFixed(2))].filter(Boolean).join(" · ")}`);
    const top = [...h.headlines].sort((a, b) => b.weight - a.weight);
    const seen = new Set<string>();
    const picks: string[] = [];
    for (const x of top) {
      if (seen.has(x.text) || picks.length >= 5) continue;
      seen.add(x.text);
      picks.push(x.text);
    }
    for (const t of picks) w(`  - ${t}`);
    w("");
  }

  // dynasties
  const houses = Object.values(world.houses).filter(hh => hh.players >= 2 || hh.reputation >= 30).sort((a, b) => b.reputation - a.reputation).slice(0, 12);
  const dyn = houses.map(hh => ({ hh, g: houseGenerations(world, hh) })).filter(x => x.g.players.length >= 2).slice(0, 6);
  if (dyn.length) {
    w("DYNASTIES");
    const dupes = new Set(dyn.map(x => x.hh.name).filter((n, i, a) => a.indexOf(n) !== i));
    for (const { hh, g } of dyn) {
      const founder = personById(world, hh.founderId);
      const label = dupes.has(hh.name) && founder ? `${hh.name} (line of ${founder.first})` : hh.name;
      const names = g.players.sort((a, b) => (a.born ?? 0) - (b.born ?? 0)).map(p => `${p.first}${p.dead ? "†" : ""}`).slice(0, 6).join(", ");
      w(`  House ${label}: reputation ${Math.round(hh.reputation)}, ${g.players.length} ballplayers over ${g.generations} generation${g.generations === 1 ? "" : "s"}, ${hh.titles} title${hh.titles === 1 ? "" : "s"} (${names})`);
    }
    w("");
  }

  const all = hist.flatMap(h => h.headlines.map(x => ({ ...x, year: h.year })));
  const best = (kind: string, n: number) => {
    const seen = new Set<string>();
    return all.filter(x => x.kind === kind).sort((a, b) => b.weight - a.weight).filter(x => (seen.has(x.text) ? false : (seen.add(x.text), true))).slice(0, n);
  };
  const juicy = all.filter(x => ["scandal", "fight", "weird", "firing"].includes(x.kind)).sort((a, b) => b.weight - a.weight);
  const seenJ = new Set<string>();
  const top10 = juicy.filter(x => (seenJ.has(x.text) ? false : (seenJ.add(x.text), true))).slice(0, 10);
  if (top10.length) {
    w("JUICIEST STORIES");
    for (const s of top10) w(`  ${s.year}: ${s.text}`);
    w("");
  }
  const scandals = best("scandal", 5);
  if (scandals.length) {
    w("BIGGEST SCANDALS");
    for (const s of scandals) w(`  ${s.year}: ${s.text}`);
    w("");
  }
  const trades = best("trade", 5);
  if (trades.length) {
    w("BIGGEST TRADES");
    for (const s of trades) w(`  ${s.year}: ${s.text}`);
    w("");
  }
  const worldNews = best("world", 5);
  if (worldNews.length) {
    w("MEANWHILE, IN THE WORLD");
    for (const s of worldNews) w(`  ${s.year}: ${s.text}`);
    w("");
  }

  // career leaders (major leagues, this run)
  const ids = Object.keys(world.stats);
  const car = ids.map(id => ({ id, c: careerTotals(world, id, "ML") }));
  const top = (f: (c: (typeof car)[number]["c"]) => number, n = 3) => car.map(x => [x.id, f(x.c)] as [string, number]).filter(x => x[1] > 0).sort((a, b) => b[1] - a[1]).slice(0, n);
  w(`CAREER LEADERS (major leagues, since ${world.history[0]?.year ?? world.year})`);
  w(`  HR: ${top(c => c.bat.hr).map(([id, v]) => `${nm(world, id)} ${v}`).join(", ")}`);
  w(`  Hits: ${top(c => c.bat.h).map(([id, v]) => `${nm(world, id)} ${v}`).join(", ")}`);
  w(`  Wins: ${top(c => c.pitch.w).map(([id, v]) => `${nm(world, id)} ${v}`).join(", ")}`);
  w(`  Strikeouts: ${top(c => c.pitch.k).map(([id, v]) => `${nm(world, id)} ${v}`).join(", ")}`);
  const titles: Record<string, number> = {};
  for (const h of hist) if (h.champion) titles[h.champion] = (titles[h.champion] ?? 0) + 1;
  w(`  Titles: ${Object.entries(titles).sort((a, b) => b[1] - a[1]).map(([id, n]) => `${abbr(world, id)} ${n}`).join(", ")}`);
  return out;
}
