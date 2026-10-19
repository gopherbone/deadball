// Game recaps for SportsWire. House style: a 1990s wire-service sports page. Short declarative
// sentences, box score facts, flat quotes. Odd events are reported the same way as a sacrifice fly.

import type { BatLine, GameResult, PitchLine, TeamBox } from "../game.ts";
import type { World } from "../types.ts";
import { Rng } from "../rng.ts";
import { quoteLead, capFirst, dateLine, dek, faces, fullName, headline, lastName, nth, numWord, parkName, person, plural, seeded, teamCity, teamName, uniq, weekday } from "./util.ts";
import type { ScheduledGameLike, Story } from "./types.ts";
import { illustrate, INCIDENT_TAGS, RECAP_TAGS } from "../archive.ts";

const ip = (outs: number) => `${Math.floor(outs / 3)}${outs % 3 ? `.${outs % 3}` : ""}`;
const ipWords = (outs: number) => {
  const f = Math.floor(outs / 3), r = outs % 3;
  return r === 0 ? `${numWord(f)} innings` : `${f} ${r === 1 ? "1/3" : "2/3"} innings`;
};

function batScore(l: BatLine): number {
  const singles = l.h - l.d - l.t - l.hr;
  return singles * 1.5 + l.d * 2.3 + l.t * 3 + l.hr * 4.2 + l.rbi * 1.2 + l.r * 0.5 + l.bb * 0.4 + l.sb * 0.5 - l.k * 0.3;
}

function statLine(l: BatLine): string {
  const xb: string[] = [];
  if (l.hr) xb.push(l.hr === 1 ? "a home run" : `${numWord(l.hr)} home runs`);
  if (l.t) xb.push(l.t === 1 ? "a triple" : `${numWord(l.t)} triples`);
  if (l.d) xb.push(l.d === 1 ? "a double" : `${numWord(l.d)} doubles`);
  let s = `${l.h}-for-${l.ab}`;
  if (xb.length) s += ` with ${xb.join(" and ")}`;
  if (l.rbi) s += `${xb.length ? " and" : " with"} ${plural(l.rbi, "RBI", "RBIs")}`;
  return s;
}

function pitchLine(p: PitchLine): string {
  return `${ipWords(p.outs)}, ${plural(p.h, "hit")}, ${plural(p.er, "earned run")}, ${p.k} strikeout${p.k === 1 ? "" : "s"}`;
}

interface Facts {
  W: TeamBox; L: TeamBox; wId: string; lId: string; homeWon: boolean;
  margin: number; score: string; hero?: BatLine; heroP: PitchLine; goat?: BatLine; goatP?: PitchLine;
  walkoff: boolean; walkoffHr: boolean; walkoffBy?: string; noHit: boolean; perfect: boolean; shutout: boolean;
  blowout: boolean; extras: boolean; cycle?: BatLine; multiHr?: BatLine; kKing?: PitchLine; comeback: number;
  incidents: GameResult["incidents"]; pitches: number;
}

function facts(res: GameResult): Facts {
  const homeWon = res.winner === "home";
  const W = homeWon ? res.home : res.away, L = homeWon ? res.away : res.home;
  const hero = [...W.bat].sort((a, b) => batScore(b) - batScore(a))[0];
  const heroP = W.pitch.find(p => p.id === res.decisions.w) ?? W.pitch[0];
  const goat = [...L.bat].filter(l => l.ab >= 3).sort((a, b) => (b.k - b.h * 2) - (a.k - a.h * 2) || b.ab - a.ab)[0];
  const goatP = L.pitch.find(p => p.id === res.decisions.l);
  const lastHome = res.home.line[res.innings - 1];
  const walkoff = homeWon && lastHome !== undefined && !Number.isNaN(lastHome);
  let walkoffBy: string | undefined, walkoffHr = false;
  if (walkoff) {
    for (let i = res.log.length - 1; i >= 0; i--) {
      const e = res.log[i];
      if (e.k === "bip" && !walkoffHr) walkoffHr = e.res === "HR";
      if (e.k === "pa") { walkoffBy = e.bat; break; }
    }
  }
  const noHit = L.hits === 0;
  const perfect = noHit && W.pitch.every(p => p.bb === 0 && p.hbp === 0) && W.errors === 0;
  const cycle = W.bat.concat(L.bat).find(l => l.hr >= 1 && l.t >= 1 && l.d >= 1 && l.h - l.d - l.t - l.hr >= 1);
  const multiHr = [...W.bat, ...L.bat].filter(l => l.hr >= 2).sort((a, b) => b.hr - a.hr)[0];
  const kKing = [...W.pitch, ...L.pitch].filter(p => p.k >= 10).sort((a, b) => b.k - a.k)[0];
  let a = 0, h = 0, comeback = 0;
  for (let i = 0; i < res.innings; i++) {
    a += res.away.line[i] ?? 0;
    comeback = Math.max(comeback, homeWon ? a - h : h - a);
    const hv = res.home.line[i];
    if (hv !== undefined && !Number.isNaN(hv)) h += hv;
    comeback = Math.max(comeback, homeWon ? a - h : h - a);
  }
  const pitches = [...res.home.pitch, ...res.away.pitch].reduce((s, p) => s + p.pitches, 0);
  return {
    W, L, wId: W.teamId, lId: L.teamId, homeWon, margin: W.runs - L.runs, score: `${W.runs}-${L.runs}`, hero, heroP, goat, goatP,
    walkoff, walkoffHr, walkoffBy, noHit, perfect, shutout: L.runs === 0, blowout: W.runs - L.runs >= 7, extras: res.innings > 9,
    cycle, multiHr, kKing, comeback, incidents: res.incidents, pitches,
  };
}

const verb = (rng: Rng, margin: number) =>
  rng.pick(margin === 1 ? ["Edge", "Nip", "Slip Past"] : margin <= 3 ? ["Top", "Beat", "Down", "Defeat"] : margin <= 6 ? ["Beat", "Handle", "Down"] : ["Rout", "Crush", "Rout"]);

const WIN_QUOTES = [
  "We hit with runners on. We didn't do that last week.",
  "He threw strikes. When he throws strikes we usually win.",
  "We'll take it. We play again tomorrow at 7:05.",
  "I don't have a lot to say. We won.",
  "The kid did his job. That's what he's paid for.",
  "We caught the ball. That was most of it.",
];
const LOSE_QUOTES = [
  "We had the bases loaded twice and didn't score. That's the game.",
  "They made pitches. We didn't.",
  "I don't have anything for you.",
  "We'll be here tomorrow. We'll try again.",
  "He left a fastball up. It happens.",
  "We have to be better than that. We weren't.",
];
const HERO_QUOTES = [
  "I was looking fastball. I got one.",
  "I just tried to put it in play.",
  "I didn't see it go out. I heard it.",
  "My father was at the game. I knew where he was sitting.",
  "I felt fine. I always feel fine.",
];

function crowd(seed: string): string {
  return String(seeded(seed, 8000, 38000)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function incidentLine(world: World, inc: GameResult["incidents"][number], ump: string | undefined, seed: string): string {
  const t = teamName(world, inc.team);
  const inn = nth(inc.inning);
  const n = (lo: number, hi: number) => seeded(`${seed}:${inc.kind}:${inc.inning}`, lo, hi);
  switch (inc.kind) {
    case "RACCOONS_BULLPEN": return `In the ${inn} inning, raccoons were found in the ${t} bullpen. Animal control removed ${n(3, 9)} of them. ${n(1, 3) === 1 ? "One reliever was treated at the scene." : `${capFirst(numWord(n(2, 3)))} relievers were treated at the scene.`} The game continued.`;
    case "RACCOON_ON_FIELD": return `A raccoon crossed the infield in the ${inn}. Play was stopped for ${n(3, 9)} minutes.`;
    case "FOOD_POISONING": return `Several ${t} players left the dugout with stomach complaints in the ${inn}. The club said the water cooler had been removed for testing.`;
    case "FAN_ON_FIELD": return `A fan ran onto the field in the ${inn}. He was tackled by an usher near second base and removed.`;
    case "LASER_POINTER": return `A laser pointer was aimed at ${t} hitters from the bleachers in the ${inn}. Security searched the section. No one was detained.`;
    case "RAIN_DELAY": return `Rain stopped play in the ${inn} for ${n(35, 95)} minutes. Neither starting pitcher returned.`;
    case "EJECTION": return `${fullName(world, inc.who, false)} was ejected in the ${inn}${ump ? ` by plate umpire ${ump}` : ""} after arguing a called third strike.`;
    case "BRAWL": {
      const [a, b] = (inc.who ?? "").split(",");
      return `${fullName(world, a, false)} and ${fullName(world, b, false)} fought near home plate in the ${inn} after a hit-by-pitch. Both benches emptied. Both players were ejected.`;
    }
    case "BALL_TAMPERING": return `Umpires removed a ball from play in the ${inn} and sealed it in an envelope for the league office.`;
    case "BLACKOUT": return `The stadium lost power in the ${inn}. Play was suspended for 1 hour, ${n(4, 50)} minutes. Both starting pitchers were removed.`;
    default: return `Play was stopped briefly in the ${inn}.`;
  }
}

export function writeGameStories(world: World, res: GameResult, game: ScheduledGameLike, incidents: GameResult["incidents"] = res.incidents): Story[] {
  const rng = new Rng(`news:${res.id}`);
  const f = facts({ ...res, incidents });
  const Wn = teamName(world, f.wId), Ln = teamName(world, f.lId);
  const homeId = res.home.teamId;
  const heroId = f.hero?.id;
  const heroL = lastName(world, heroId);
  const pL = lastName(world, f.heroP?.id);
  const has = (k: string) => f.incidents.find(i => i.kind === k);
  const v = verb(rng, f.margin);
  const raccoons = has("RACCOONS_BULLPEN"), brawl = has("BRAWL"), sick = has("FOOD_POISONING"), dark = has("BLACKOUT"), laser = has("LASER_POINTER");
  const day = weekday(world, game.day);
  const on = day ? ` ${day}` : "";
  const park = parkName(world, homeId);
  const woL = lastName(world, f.walkoffBy);

  // --- headline angle
  let angle = "default";
  let heads: string[];
  if (f.perfect) { angle = "perfect"; heads = [`${pL} Pitches Perfect Game`, `${pL} Perfect Against ${Ln}`]; }
  else if (f.noHit) { angle = "nohit"; heads = [`${pL} No-Hits ${Ln}`, `${pL} Throws No-Hitter, ${Wn} Win`]; }
  else if (raccoons) { angle = "raccoons"; const t = teamName(world, raccoons.team); heads = [`Raccoons Found in ${t} Bullpen`, `${Wn} ${v} ${Ln} After Raccoon Delay`, `Raccoons Delay Game; ${Wn} Win`]; }
  else if (brawl) { angle = "brawl"; const [a, b] = (brawl.who ?? "").split(","); heads = [`${lastName(world, a)}, ${lastName(world, b)} Ejected After Fight`, `Benches Empty; ${Wn} ${v} ${Ln}`]; }
  else if (sick) { angle = "sick"; const t = teamName(world, sick.team); heads = [`Illness Hits ${t} Dugout; ${Wn} Win`, `${t} Players Fall Ill During Game`]; }
  else if (dark) { angle = "dark"; heads = [`Power Failure Halts ${teamCity(world, homeId)} Game`, `${Wn} Win After Blackout Delay`]; }
  else if (f.walkoff && f.walkoffBy) { angle = "walkoff"; heads = f.walkoffHr ? [`${woL} Homer Wins It in ${nth(res.innings)}`, `${woL}'s Homer Beats ${Ln}`] : [`${woL} Single Beats ${Ln} in ${nth(res.innings)}`, `${woL} Drives In Winner; ${Wn} ${v} ${Ln}`]; }
  else if (f.cycle) { angle = "cycle"; const c = lastName(world, f.cycle.id); heads = [`${c} Hits for the Cycle`, `${c} Cycle Leads ${Wn}`]; }
  else if (f.comeback >= 4) { angle = "comeback"; heads = [`${Wn} Rally From ${f.comeback} Down, ${v} ${Ln}`, `${Wn} Overcome ${f.comeback}-Run Deficit`]; }
  else if (laser) { angle = "laser"; const t = teamName(world, laser.team); heads = [`Laser Aimed at ${t} Hitters`, `${Wn} ${v} ${Ln}; Laser Probe Opens`]; }
  else if (f.blowout) { angle = "blowout"; heads = [`${Wn} ${v} ${Ln}, ${f.score}`, `${Wn} Score ${f.W.runs} in Win Over ${Ln}`]; }
  else if (f.extras) { angle = "extras"; heads = [`${Wn} ${v} ${Ln} in ${res.innings} Innings`, `${Wn} Win in ${nth(res.innings)}`]; }
  else if (f.multiHr) {
    angle = "multihr";
    const m = lastName(world, f.multiHr.id), n = f.multiHr.hr;
    heads = f.W.bat.includes(f.multiHr) ? [`${m} Homers ${n === 2 ? "Twice" : `${capFirst(numWord(n))} Times`}`, `${m} Hits ${n} Homers; ${Wn} Win`] : [`${m}'s ${n} Homers Not Enough`, `${m} Homers ${n === 2 ? "Twice" : `${n} Times`} in Loss`];
  }
  else if (f.kKing) { angle = "k"; const k = lastName(world, f.kKing.id); heads = [`${k} Strikes Out ${f.kKing.k}`, `${k} Fans ${f.kKing.k}${f.W.pitch.includes(f.kKing) ? `; ${Wn} ${v} ${Ln}` : ""}`]; }
  else if (f.shutout) { angle = "shutout"; heads = [`${pL} Shuts Out ${Ln}`, `${Wn} Blank ${Ln}, ${f.score}`]; }
  else heads = [`${Wn} ${v} ${Ln}, ${f.score}`, `${heroL} Leads ${Wn} Past ${Ln}`, `${Wn} ${v} ${Ln}`];
  const head = headline(rng, heads);

  // --- dek
  const heroFull = fullName(world, heroId, false);
  const wpFull = fullName(world, f.heroP?.id, false);
  const deks = [
    f.hero && f.heroP ? `${heroFull} goes ${statLine(f.hero)}; ${lastName(world, f.heroP.id)} gets the win` : "",
    f.hero ? `${heroFull} goes ${statLine(f.hero)}` : "",
    f.heroP ? `${wpFull}: ${ip(f.heroP.outs)} IP, ${f.heroP.k} K. ${Wn} win, ${f.score}` : "",
    `${Wn} ${f.score} over ${Ln}`,
  ];
  if (angle === "walkoff") deks.unshift(`${fullName(world, f.walkoffBy, false)} ends it in the ${nth(res.innings)}; ${Wn} win, ${f.score}`, `${woL} ends it in the ${nth(res.innings)}; ${Wn} win, ${f.score}`);
  if (angle === "raccoons") deks.unshift(`Animal control called in the ${nth(raccoons!.inning)}; ${Wn} win, ${f.score}`);
  if (angle === "sick") deks.unshift(`Water cooler sent for testing; ${Wn} win, ${f.score}`);
  if (angle === "laser") deks.unshift(`Security searches bleachers; ${Wn} win, ${f.score}`);
  if (angle === "nohit" || angle === "perfect") deks.unshift(`${wpFull} throws ${f.heroP?.pitches ?? "his"} pitches; ${Wn} win, ${f.score}`);
  const d = dek(deks);

  // --- body
  const rngBody = rng.fork("body");
  const city = teamCity(world, homeId).toUpperCase();
  const umpP = game.umpireId ? person(world, game.umpireId) : undefined;
  const ump = umpP ? `${umpP.first} ${umpP.last}` : undefined;
  const body: string[] = [];
  const s = f.score;
  const lede = (() => {
    switch (angle) {
      case "perfect": return `${wpFull} retired all 27 ${Ln} batters he faced${on} and the ${Wn} won, ${s}, at ${park}. He threw ${f.heroP?.pitches ?? "an unrecorded number of"} pitches. It was the first perfect game of his career.`;
      case "nohit": return `${wpFull} held the ${Ln} without a hit${on} and the ${Wn} won, ${s}. He threw ${f.heroP?.pitches ?? "an unrecorded number of"} pitches. Teammates did not speak to him after the fifth inning.`;
      case "raccoons": return `Raccoons were found in the ${teamName(world, raccoons!.team)} bullpen in the ${nth(raccoons!.inning)} inning${on} at ${park}. ${capFirst(numWord(seeded(res.id, 2, 3)))} relievers were treated at the scene. The game continued, and the ${Wn} won, ${s}.`;
      case "brawl": { const [a, b] = (brawl!.who ?? "").split(","); return `${fullName(world, a, false)} and ${fullName(world, b, false)} were ejected after a fight in the ${nth(brawl!.inning)} inning${on}, and the ${Wn} beat the ${Ln}, ${s}. Both benches emptied. Order was restored after ${seeded(res.id, 6, 14)} minutes.`; }
      case "sick": return `Several ${teamName(world, sick!.team)} players became ill in the dugout during the ${nth(sick!.inning)} inning${on}. The ${Wn} won, ${s}. The club said the dugout water cooler had been removed for testing.`;
      case "dark": return `The lights at ${park} went out in the ${nth(dark!.inning)} inning${on}. Play resumed after a long delay, and the ${Wn} beat the ${Ln}, ${s}.`;
      case "walkoff": return `${fullName(world, f.walkoffBy)} ${f.walkoffHr ? "homered" : "drove in the winning run"} with ${res.innings > 9 ? "the game tied" : "two outs"} in the ${nth(res.innings)} inning${on} and the ${Wn} beat the ${Ln}, ${s}, at ${park}.`;
      case "cycle": return `${fullName(world, f.cycle!.id)} hit for the cycle${on} and the ${teamName(world, f.W.bat.includes(f.cycle!) ? f.wId : f.lId)} ${f.W.bat.includes(f.cycle!) ? `beat the ${Ln}, ${s}` : `lost to the ${Wn}, ${s}`}. He needed the triple in his last at-bat. He got it.`;
      case "comeback": return `The ${Wn} trailed by ${f.comeback} runs and beat the ${Ln}, ${s}${on} at ${park}. The ${Ln} did not score after the ${nth(Math.min(res.innings, 6))} inning.`;
      case "laser": return `A laser pointer was aimed at ${teamName(world, laser!.team)} hitters from the bleachers in the ${nth(laser!.inning)} inning${on}. Stadium security searched the section and found nothing. The ${Wn} won, ${s}.`;
      case "blowout": return `The ${Wn} scored ${plural(f.W.runs, "run")} on ${plural(f.W.hits, "hit")}${on} and beat the ${Ln}, ${s}, at ${park}. The ${Ln} used ${plural(f.L.pitch.length, "pitcher")}.`;
      case "extras": return `The ${Wn} beat the ${Ln}, ${s}, in ${res.innings} innings${on} at ${park}. The game took ${Math.floor((f.pitches * 0.42 + 30) / 60)} hours, ${Math.round(f.pitches * 0.42 + 30) % 60} minutes.`;
      case "multihr": return `${fullName(world, f.multiHr!.id)} hit ${numWord(f.multiHr!.hr)} home runs${on}, and the ${teamName(world, f.W.bat.includes(f.multiHr!) ? f.wId : f.lId)} ${f.W.bat.includes(f.multiHr!) ? `beat the ${Ln}, ${s}` : `lost to the ${Wn}, ${s}`}.`;
      case "k": return `${fullName(world, f.kKing!.id)} struck out ${f.kKing!.k}${on}, and the ${Wn} beat the ${Ln}, ${s}, at ${park}.`;
      case "shutout": return `${wpFull} and two relievers held the ${Ln} scoreless${on}, and the ${Wn} won, ${s}, at ${park}.`.replace(" and two relievers", f.W.pitch.length > 1 ? ` and ${numWord(f.W.pitch.length - 1)} reliever${f.W.pitch.length > 2 ? "s" : ""}` : "");
      default: return `The ${Wn} beat the ${Ln}, ${s},${on} at ${park}${f.hero ? `. ${heroFull} went ${statLine(f.hero)}` : ""}.`;
    }
  })();
  body.push(`${city} — ${lede}`);

  if (f.hero && angle !== "default") {
    const hp = person(world, f.hero.id);
    const trait = hp?.traits.includes("SHOWBOAT") ? "He tipped his cap after each hit." :
      hp?.traits.includes("DRUNK") ? "He said he had not slept." :
      hp?.traits.includes("PIOUS") ? "He thanked God and the hitting coach." :
      hp?.traits.includes("SUPERSTITIOUS") ? "He has worn the same socks since the homestand began. He said he will keep wearing them." :
      hp?.traits.includes("GAMBLER") ? "Asked about the betting line, he said he does not follow it." :
      `"${quoteLead(rngBody.pick(HERO_QUOTES))}" he said.`;
    body.push(`${heroFull} went ${statLine(f.hero)}${f.hero.bb ? ` and walked ${f.hero.bb === 1 ? "once" : f.hero.bb === 2 ? "twice" : `${numWord(f.hero.bb)} times`}` : ""}${f.hero.sb ? `. He stole ${plural(f.hero.sb, "base")}` : ""}. ${trait}`);
  } else if (f.hero) {
    body.push(`"${quoteLead(rngBody.pick(HERO_QUOTES))}" ${lastName(world, f.hero.id)} said.`);
  }

  if (f.heroP) {
    const save = res.decisions.s ? ` ${fullName(world, res.decisions.s, false)} pitched the ninth for the save.` : "";
    const lose = f.goatP ? ` ${fullName(world, f.goatP.id, false)} took the loss. He allowed ${plural(f.goatP.r, "run")} in ${ipWords(f.goatP.outs)}.` : "";
    body.push(`${wpFull} (${pitchLine(f.heroP)}) got the win.${save}${lose}`);
  }

  const lMgr = person(world, world.teams[f.lId]?.managerId);
  const wMgr = person(world, world.teams[f.wId]?.managerId);
  if (f.goat && f.goat.h === 0 && f.goat.ab >= 4) {
    body.push(`${fullName(world, f.goat.id, false)} went 0-for-${f.goat.ab}${f.goat.k ? ` and struck out ${f.goat.k === 1 ? "once" : f.goat.k === 2 ? "twice" : `${numWord(f.goat.k)} times`}` : ""}.${f.L.errors ? ` The ${Ln} made ${plural(f.L.errors, "error")}.` : ""} "${quoteLead(rngBody.pick(LOSE_QUOTES))}" said ${Ln} manager ${lMgr ? `${lMgr.first} ${lMgr.last}` : "the manager"}.`);
  } else {
    body.push(`"${quoteLead(rngBody.pick(WIN_QUOTES))}" said ${Wn} manager ${wMgr ? `${wMgr.first} ${wMgr.last}` : "the manager"}. ${lMgr ? `${Ln} manager ${lMgr.last}` : "The other manager"} said, "${rngBody.pick(LOSE_QUOTES)}"`);
  }

  const ultras = ultraUses(res);
  if (ultras.length) body.push(ultraParagraph(world, ultras, enhancedGame(world, res, game)));
  const covered = new Set([angle === "raccoons" ? "RACCOONS_BULLPEN" : "", angle === "brawl" ? "BRAWL" : "", angle === "sick" ? "FOOD_POISONING" : "", angle === "dark" ? "BLACKOUT" : "", angle === "laser" ? "LASER_POINTER" : ""]);
  const incs = f.incidents.filter(i => !covered.has(i.kind)).slice(0, 3);
  const incText = incs.map(i => incidentLine(world, i, umpP?.last, res.id));
  if (f.incidents.some(i => i.sources.some(x => x !== "incident"))) incText.push(rngBody.pick(["Police said they are investigating.", "The Commissioner's Office said it had opened an inquiry.", "Police took statements from stadium staff."]));
  if (incText.length) body.push(incText.join(" "));

  const close = [`Attendance was ${crowd(res.id)}.`, `Time of game was ${Math.floor((f.pitches * 0.42 + 30) / 60)}:${String(Math.round(f.pitches * 0.42 + 30) % 60).padStart(2, "0")}.`];
  if (ump) close.push(`${ump} was the plate umpire.`);
  if (game.weather) close.push(`The game-time temperature was ${Math.round(game.weather.tempF)} degrees.`);
  body.push(close.slice(0, 3).join(" "));
  while (body.length > 6) { const last = body.pop()!; body[body.length - 1] += ` ${last}`; }

  const people = uniq([heroId, f.heroP?.id, f.goat?.id, f.goatP?.id, f.walkoffBy, f.cycle?.id, f.multiHr?.id, f.kKing?.id, res.decisions.s].filter((x): x is string => !!x));
  const recap: Story = {
    id: `story:${res.id}:recap`, day: game.day, kind: "recap", headline: head, dek: d, body, faceIds: faces(world, people), people,
    teams: [res.away.teamId, res.home.teamId], gameId: res.id, section: "Sports", dateline: dateLine(world, game.day),
    prominence: angle === "default" ? 1 : angle === "perfect" || angle === "nohit" || angle === "raccoons" ? 4 : 2,
    ...illustrate(RECAP_TAGS[angle] ?? RECAP_TAGS.default, `story:${res.id}:recap`),
  };
  const out = [recap];
  const usedPhotos = recap.photo ? [recap.photo] : [];

  // --- briefs for incidents the recap didn't lead with
  const seen = new Set<string>();
  const majors = !game.level || game.level === "ML";
  for (const i of f.incidents) {
    if (covered.has(i.kind) || seen.has(i.kind) || !BRIEF[i.kind]) continue;
    if (i.kind === "BRAWL" && !majors) continue; // minor-league fights stay in the recap
    seen.add(i.kind);
    const b = BRIEF[i.kind]!(world, i, res.id, umpP?.last);
    out.push({
      id: `story:${res.id}:inc:${i.kind}`, day: game.day, kind: "brief", headline: fitHead(b.h), dek: dek([b.d]), body: b.body,
      faceIds: faces(world, b.people), people: b.people, teams: [i.team ?? homeId].filter(Boolean), gameId: res.id, section: "Sports", dateline: dateLine(world, game.day),
      prominence: 1,
      ...illustrate(INCIDENT_TAGS[i.kind as keyof typeof INCIDENT_TAGS] ?? ["baseball"], `story:${res.id}:inc:${i.kind}`, usedPhotos),
    });
    const ph = out[out.length - 1].photo;
    if (ph) usedPhotos.push(ph);
    if (out.length >= 3) break;
  }
  // powers in a Continental (non-Enhanced) game are a scandal of their own
  if (ultras.length && !enhancedGame(world, res, game)) {
    const st = powerScandal(world, res, game, ultras);
    if (st) out.push(st);
  }
  return out;
}

// --- Enhanced powers ------------------------------------------------------------------------------

export interface UltraUse { who: string; power: string; side: "home" | "away"; i: number }

const POWER_NAME: Record<string, string> = {
  FIREBALL: "fireball", STOPPER: "stopper", WARP_PITCH: "warp pitch", CLOUD_BALL: "cloud ball",
  HYPER_HIT: "hyper hit", LEAP_CATCH: "leaping catch", LASER_ARM: "laser throw", WARP_RUN: "warp run",
};
const POWER_DESC: Record<string, string> = {
  FIREBALL: "threw a fastball that the stadium gun recorded at 107 miles per hour",
  STOPPER: "threw a pitch that stopped in midair for about one second before continuing",
  WARP_PITCH: "threw a pitch that was outside and then, without passing through the space between, was a strike",
  CLOUD_BALL: "threw a pitch that disappeared into a small cloud and reappeared in the catcher's glove",
  HYPER_HIT: "swung hard enough to bend the bat",
  LEAP_CATCH: "jumped eleven feet at the wall",
  LASER_ARM: "threw to the plate on a straight line",
  WARP_RUN: "reached the next base without being seen to run there",
};

export function ultraUses(res: GameResult): UltraUse[] {
  const out: UltraUse[] = [];
  res.log.forEach((e, i) => { if (e.k === "ultra") out.push({ who: e.who, power: e.power, side: e.side, i }); });
  return out;
}

/** True for Enhanced League games (team level "EL", or the schedule says so). */
export function enhancedGame(world: World, res: GameResult, game?: ScheduledGameLike): boolean {
  if ((game?.level as string | undefined) === "EL") return true;
  return [res.home.teamId, res.away.teamId].some(id => (world.teams[id]?.level as string | undefined) === "EL");
}

function ultraParagraph(world: World, uses: UltraUse[], enhanced: boolean): string {
  const byWho = new Map<string, Map<string, number>>();
  for (const u of uses) {
    const m = byWho.get(u.who) ?? new Map<string, number>();
    m.set(u.power, (m.get(u.power) ?? 0) + 1);
    byWho.set(u.who, m);
  }
  const lines: string[] = [];
  for (const [who, m] of [...byWho].slice(0, 3)) {
    const [power, n] = [...m].sort((a, b) => b[1] - a[1])[0];
    lines.push(`${fullName(world, who, false)} ${POWER_DESC[power] ?? "used an enhanced power"}${n > 1 ? `, ${n === 2 ? "twice" : `${numWord(n)} times`}` : ""}.`);
  }
  const lead = enhanced ? `Enhanced powers were used ${uses.length === 1 ? "once" : `${numWord(uses.length)} times`}.` : `Enhanced powers were used ${uses.length === 1 ? "once" : `${numWord(uses.length)} times`} in a Continental League game.`;
  return [lead, ...lines].join(" ");
}

/** Box-score notes ("POWERS: Wiggins (fireball 2), Lomax (hyper hit)"), empty when none were used. */
export function boxNotes(world: World, res: GameResult): string[] {
  const uses = ultraUses(res);
  if (!uses.length) return [];
  const notes: string[] = [];
  for (const side of ["away", "home"] as const) {
    const mine = uses.filter(u => u.side === side);
    if (!mine.length) continue;
    const counts = new Map<string, number>();
    for (const u of mine) counts.set(`${u.who}|${u.power}`, (counts.get(`${u.who}|${u.power}`) ?? 0) + 1);
    const parts = [...counts].map(([k, n]) => { const [who, power] = k.split("|"); return `${lastName(world, who)} (${POWER_NAME[power] ?? power.toLowerCase()}${n > 1 ? ` ${n}` : ""})`; });
    notes.push(`POWERS—${world.teams[side === "home" ? res.home.teamId : res.away.teamId]?.abbr ?? side}: ${parts.join(", ")}.`);
  }
  return notes;
}

function powerScandal(world: World, res: GameResult, game: ScheduledGameLike, uses: UltraUse[]): Story | undefined {
  const who = [...new Set(uses.map(u => u.who))].filter(id => world.players[id]);
  if (!who.length) return undefined;
  const lead = who[0];
  const p = world.players[lead];
  const T = teamName(world, p.teamId);
  const n = uses.filter(u => u.who === lead).length;
  const power = uses.find(u => u.who === lead)!.power;
  const rng = new Rng(`powers:${res.id}`);
  const others = who.slice(1, 3).map(id => fullName(world, id, false));
  const body = [
    `${fullName(world, lead, false)} of the ${T} ${POWER_DESC[power] ?? "used an enhanced power"} during ${game.day ? `${weekday(world, game.day) || "the"} ` : ""}game at ${parkName(world, res.home.teamId)}.${n > 1 ? ` He did it ${n === 2 ? "twice" : `${numWord(n)} times`}.` : ""}`,
    `Enhanced powers are permitted only in the Enhanced League. The Continental League rulebook does not mention them. The Commissioner's Office said it is reviewing the rulebook.`,
    others.length ? `${others.join(" and ")} also used powers in the game.` : `No other player used a power.`,
    `"${rng.pick(["I didn't do anything different,", "It just happens now,", "I threw the pitch the catcher called,", "I don't know what you saw,"])}" ${p.last} said. The umpires let the result stand.`,
  ];
  return {
    id: `story:${res.id}:powers`, day: game.day, kind: "scandal", section: "Sports", gameId: res.id, dateline: dateLine(world, game.day),
    headline: headline(rng, [`League Reviews ${p.last}'s ${capFirst(POWER_NAME[power] ?? "Power")}`, `${p.last} Uses Power in Continental Game`, `Powers Used in ${T} Game`]),
    dek: dek([`${fullName(world, lead, false)} ${POWER_DESC[power] ?? "used a power"}`, `Commissioner reviewing the rulebook after the ${T} game`]),
    body, faceIds: faces(world, who), people: who, teams: [res.away.teamId, res.home.teamId], prominence: 3,
    ...illustrate(["space", "electric", "pitcher", "baseball"], `story:${res.id}:powers`),
  };
}

const fitHead = (h: string) => headline(new Rng(h), [h]);

type Brief = { h: string; d: string; body: string[]; people: string[] };
const BRIEF: Partial<Record<string, (world: World, i: GameResult["incidents"][number], seed: string, ump?: string) => Brief>> = {
  RACCOONS_BULLPEN: (w, i, seed) => ({ h: `Raccoons Found in ${teamName(w, i.team)} Bullpen`, d: `Animal control removes ${seeded(seed, 3, 9)} animals in the ${nth(i.inning)} inning`, people: [],
    body: [`Raccoons were discovered in the ${teamName(w, i.team)} bullpen in the ${nth(i.inning)} inning. Animal control removed ${seeded(seed, 3, 9)} of them.`, `Relievers warmed up in the left-field corner for the rest of the game. A team spokesman said the bullpen gate had been locked before the game. Police took statements from stadium staff.`] }),
  FOOD_POISONING: (w, i) => ({ h: `${teamName(w, i.team)} Players Fall Ill in Dugout`, d: "Water cooler removed for testing", people: [],
    body: [`Several ${teamName(w, i.team)} players left the dugout with stomach complaints in the ${nth(i.inning)} inning.`, `The club removed the dugout water cooler and sent it to a laboratory. Results are expected next week. No players were hospitalized.`] }),
  LASER_POINTER: (w, i) => ({ h: `Laser Aimed at ${teamName(w, i.team)} Hitters`, d: "Security searches the bleachers; no one detained", people: [],
    body: [`A green laser pointer was aimed at ${teamName(w, i.team)} hitters from the bleachers in the ${nth(i.inning)} inning.`, `Security searched the section. They found a keychain and a rosary. No one was detained.`] }),
  BRAWL: (w, i) => { const [a, b] = (i.who ?? "").split(","); return { h: `${lastName(w, a)}, ${lastName(w, b)} Ejected After Fight`, d: "Benches empty after a hit-by-pitch; league to review", people: [a, b].filter(Boolean),
    body: [`${fullName(w, a, false)} and ${fullName(w, b, false)} fought near home plate in the ${nth(i.inning)} inning after a hit-by-pitch.`, `Both benches emptied. Both players were ejected. The league office said it will review the tape.`] }; },
  BLACKOUT: (w, i) => ({ h: `Power Failure Halts Game in ${teamCity(w, i.team)}`, d: "Lights out for more than an hour; utility cites a fluctuation", people: [],
    body: [`The stadium lost power in the ${nth(i.inning)} inning. Play was suspended for more than an hour.`, `The utility company called it a fluctuation. A stadium electrician said the transformer room door had been propped open with a brick. Police are investigating.`] }),
  EJECTION: (w, i, _s, ump) => ({ h: `${lastName(w, i.who)} Ejected in ${capFirst(nth(i.inning))}`, d: "Argued a called third strike", people: i.who ? [i.who] : [],
    body: [`${fullName(w, i.who, false)} was ejected in the ${nth(i.inning)} inning${ump ? ` by plate umpire ${ump}` : ""}.`, `He had argued a called third strike. He kicked dirt onto the plate before leaving. He is expected to be fined.`] }),
};

