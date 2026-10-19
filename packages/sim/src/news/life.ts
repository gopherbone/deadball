// Life desk: weddings, funerals, debuts, trades, dynasties, personal drama, and the Metro page
// for non-baseball world events. Wire-service register. LifeEvent data is optional and guarded.

import { illustrate, lifeTags, TEAM_TAGS } from "../archive.ts";
import type { Npc, Person, Player, World } from "../types.ts";
import { Rng } from "../rng.ts";
import { capFirst, dateLine, dek, faces, fullName, headline, isPlayer, lastName, num, numWord, person, poss, prominence, pro, seeded, sexOf, str, teamCity, teamName, uniq, wasPhrase } from "./util.ts";
import { dramaDesk, type DeskSpec } from "./drama.ts";
import type { LifeEventLike, Story } from "./types.ts";

const teamOf = (world: World, id: string | undefined): string | undefined => {
  const p = person(world, id);
  return isPlayer(p) ? p.teamId : undefined;
};
const levelOf = (world: World, teamId: string | undefined) => (teamId ? world.teams[teamId]?.level : undefined);

/** A parent who played (or plays) ball: the dynasty hook. */
function famousParent(world: World, p: Person | undefined): Player | undefined {
  const parents = p?.family?.parents ?? [];
  return parents.map(id => world.players[id]).filter((x): x is Player => !!x).sort((a, b) => b.potential - a.potential)[0];
}

const child = (p: Person | undefined) => (sexOf(p) === "F" ? "Daughter" : "Son");

const ROUNDUP = new Set(["callup", "demotion", "release", "signing", "return"]);

/** Kinds this file writes directly; everything else goes to the drama desk. */
const LIFE_KINDS = new Set(["transfer", "exhibition", "playoffs", "season", "debut", "callup", "draft", "wedding", "divorce", "birth", "death", "retirement", "trade", "award", "champion", "hire", "fire", "succession", "coming_of_age", "il", "injury", "milestone", "world"]);

export function writeLifeStories(world: World, events: LifeEventLike[]): Story[] {
  const out: Story[] = [];
  const moves: string[] = [];
  const movePeople: string[] = [];
  const moveTeams: string[] = [];
  let day = world.day;
  for (const ev of events ?? []) {
    if (!ev || !Array.isArray(ev.who)) continue;
    day = ev.day ?? day;
    const rng = new Rng(`life:${ev.id}`);
    const data = ev.data ?? {};
    const a = person(world, ev.who[0]);
    const b = person(world, ev.who[1]);
    const aName = fullName(world, ev.who[0]);
    const aLast = lastName(world, ev.who[0]);
    const tId = ev.teams?.find(t => world.teams[t]) ?? teamOf(world, ev.who[0]);
    const tName = teamName(world, tId);
    if (ev.kind === "release" && a && (data.dramatic === true || data.banned === true)) {
      const reason = str(data.reason) ?? "conduct";
      const banned = data.banned === true;
      const rng2 = new Rng(`rel:${ev.id}`);
      out.push({
        ...illustrate(banned ? ["court", "office", "newspaper"] : ["release", "suitcase", "travel"], `story:life:${ev.id}`),
        id: `story:life:${ev.id}`, day: ev.day ?? day, kind: "brief", section: "Sports", dateline: dateLine(world, ev.day ?? day),
        headline: headline(rng2, banned ? [`${aLast} Banned for Life`] : [`${tName} Release ${aLast}`, `${aLast} Cut by ${tName}`]),
        dek: dek([banned ? `${capFirst(reason)}` : `${aLast} ${wasPhrase(str(data.scandal) ?? reason.replace(/^cut after /, ""))}`, capFirst(reason)]),
        body: [`The ${tName} released ${aName} on Tuesday. ${banned ? `The Commissioner cited ${reason.replace(/^banned for life: /, "")}.` : `The move followed an incident in which ${aLast} ${wasPhrase(str(data.scandal) ?? reason.replace(/^cut after /, ""))}.`}`,
          banned ? `The Commissioner has barred ${aLast} from any role in organized baseball. ${capFirst(pro(a))} may appeal in writing.` : `${aLast} cleared waivers. ${capFirst(pro(a))} did not comment.`,
          `${aLast} left the ballpark through the players' lot. ${capFirst(pro(a))} carried one bag.`],
        faceIds: faces(world, [a.id]), people: [a.id], teams: tId ? [tId] : [], prominence: prominence(world, [a.id], banned ? 3 : 1.5),
      });
      continue;
    }
    if (ROUNDUP.has(ev.kind) && !(ev.kind === "callup" && famousParent(world, a))) {
      if (a) {
        const to = ev.teams?.[1] ?? teamOf(world, ev.who[0]);
        const verb = ev.kind === "callup" ? `recalled ${aName} from ${teamFullAbbr(world, ev.teams?.[0])}` : ev.kind === "demotion" ? `optioned ${aName} to ${teamFullAbbr(world, to)}` : ev.kind === "release" ? `released ${aName}` : ev.kind === "return" ? `activated ${aName} from the injured list` : `signed ${aName}`;
        const club = ev.kind === "callup" ? to ?? tId : ev.kind === "demotion" ? world.teams[to ?? ""]?.parentId ?? tId : ev.kind === "signing" ? to ?? tId : tId;
        moves.push(`${capFirst(teamFullName(world, club))} ${verb}.`);
        movePeople.push(a.id);
        if (tId) moveTeams.push(tId);
      }
      continue;
    }
    let s: DeskSpec | undefined;
    const he = pro(a), his = poss(a), He = capFirst(he);
    if (data.secret === true || data.visibility === "secret") continue;
    if (!LIFE_KINDS.has(ev.kind)) {
      const d = dramaDesk(world, ev, rng);
      if (d === null) continue;
      s = d;
    }
    if (!s) switch (ev.kind) {
      case "debut":
      case "callup":
      case "draft": {
        const par = famousParent(world, a);
        const lvl = levelOf(world, tId);
        if (!a || (!par && lvl !== "ML" && ev.kind !== "draft")) break;
        if (par) {
          s = { kind: "life", base: 2, heads: [`${child(a)} of ${par.last} ${ev.kind === "draft" ? "Drafted" : "Debuts"}`, `Another ${par.last} ${ev.kind === "draft" ? "Drafted" : "Reaches Majors"}`],
            d: [`${aName}, ${a.age}, ${ev.kind === "draft" ? "is drafted by" : "debuts with"} the ${tName}; ${his} father played ${par.career ? "in the majors" : "for the club"}`],
            body: [`${aName} ${ev.kind === "draft" ? `was drafted by the ${tName}` : `made ${his} debut for the ${tName}`} on Tuesday. ${He} is ${a.age}.`,
              `${He} is the ${sexOf(a) === "F" ? "daughter" : "son"} of ${fullName(world, par.id, false)}, who ${par.active ? "is still an active player" : "watched from a seat behind the dugout"}.`,
              `"${rng.pick(["I told him to keep his elbow up. He keeps his elbow up.", "He's a better hitter than I was. I've told him that.", "I didn't say much to him. He knows what to do."])}" the elder ${par.last} said.`] };
        } else {
          s = { kind: "brief", heads: [`${aLast} Makes Major League Debut`, `${aLast} Called Up by ${tName}`],
            d: [`${aName}, ${a.age}, joins the ${tName}`],
            body: [`${aName}, ${a.age}, made ${his} major league debut for the ${tName}. ${He} arrived with one bag and a borrowed glove.`,
              `"${rng.pick(["I want to help the club.", "My mother is here. She drove nine hours.", "I've been waiting a long time. I'm ready."])}" ${he} said.`] };
        }
        break;
      }
      case "wedding": {
        if (!a) break;
        const bn = b ? fullName(world, b.id, false) : str(data.spouseName) ?? "a longtime girlfriend";
        s = { kind: "life", heads: [`${aLast} Marries ${b ? b.last : "in Private Ceremony"}`, `${aLast} Weds`],
          d: [`${aName} marries ${bn}; teammates attend`],
          body: [`${aName} of the ${tName} married ${bn} on Saturday at ${rng.pick(["St. Jude's", "the county courthouse", "a Methodist church in " + teamCity(world, tId)])}. ${seeded(ev.id, 6, 14)} teammates attended.`,
            `The reception was held at ${rng.pick(["a VFW hall", "the Elks lodge", "a steakhouse near the ballpark"])}. The couple will travel to Niagara Falls during the All-Star break.`] };
        break;
      }
      case "divorce": {
        if (!a) break;
        s = { kind: "life", heads: [`${aLast} Divorce Final`, `${aLast}, Wife Divorce`],
          d: [`Papers filed in ${teamCity(world, tId)} county court`],
          body: [`${aName} and ${b ? fullName(world, b.id, false) : `${his} wife`} have divorced, according to papers filed in ${teamCity(world, tId)}.`,
            `Teammates said ${aLast} has been sleeping in the trainer's room. The ${tName} declined to comment.`] };
        break;
      }
      case "birth": {
        const kid = ev.who.map(id => person(world, id)).find(p => p && p.age <= 1);
        const parent = ev.who.map(id => person(world, id)).find(p => p && p !== kid && isPlayer(p)) ?? (kid ? person(world, kid.family?.parents?.[0]) : undefined);
        if (!parent || !isPlayer(parent)) break;
        s = { kind: "brief", heads: [`${parent.last} Becomes a Father`, `${sexOf(kid) === "F" ? "Girl" : "Boy"} Born to ${parent.last} Family`],
          d: [`${fullName(world, parent.id, false)} misses batting practice for the birth`],
          body: [`${fullName(world, parent.id, false)} of the ${teamName(world, parent.teamId)} became a father${kid ? ` to ${kid.first}` : ""} at St. Jude's Memorial. The baby weighed seven pounds, ${seeded(ev.id, 1, 15)} ounces.`,
            `${parent.last} missed batting practice. He was in the lineup that night.`] };
        break;
      }
      case "death": {
        if (!a) break;
        const cause = str(data.cause);
        const was = isPlayer(a) ? `${a.active ? "" : "former "}${a.pos === "P" ? "pitcher" : "player"}` : (a as Npc).role === "umpire" ? "umpire" : (a as Npc).role === "owner" ? "club owner" : (a as Npc).role === "manager" ? "manager" : "";
        const kids = a.family?.children?.length ?? 0;
        s = { kind: "life", base: 2, heads: [`${aLast}${was ? `, ${capFirst(was)},` : ""} Dies at ${a.age}`, `${aLast} Dies at ${a.age}`],
          d: [`${aName}${was ? `, ${was},` : ""} dies${cause ? ` of ${cause}` : ""}`],
          body: [`${aName}${was ? `, a ${was}${isPlayer(a) ? ` for the ${teamName(world, a.teamId)}` : ""},` : ""} died ${cause ? `of ${cause} ` : ""}on ${rng.pick(["Monday", "Tuesday", "Wednesday", "Thursday"])}. ${He} was ${a.age}.`,
            `${kids ? `${He} is survived by ${numWord(kids)} ${kids === 1 ? "child" : "children"}${a.family.spouse ? ` and ${his} ${sexOf(a) === "F" ? "husband" : "wife"}` : ""}.` : `${He} had no children.`} Services will be held Thursday. The organist will play "Take Me Out to the Ball Game."`] };
        break;
      }
      case "retirement": {
        if (!a || (isPlayer(a) && a.age < 30 && levelOf(world, a.teamId) !== "ML")) break;
        const seasons = num(data.seasons);
        s = { kind: "life", heads: [`${aLast} Retires${seasons ? ` After ${seasons} Seasons` : ""}`, `${aLast} Announces Retirement`],
          d: [`${aName}, ${a.age}, retires${seasons ? ` after ${seasons} seasons` : ""}`],
          body: [`${aName} announced ${his} retirement on Tuesday. ${He} is ${a.age}.${seasons ? ` ${He} played ${seasons} seasons.` : ""}`,
            `${He} said ${he} plans to ${rng.pick(["open a car wash", "fish", "coach his son's team", "sell insurance"])}. ${He} thanked the fans and the bartender at the Shamrock.`] };
        break;
      }
      case "trade": {
        if (!a) break;
        const from = str(data.from) ?? ev.teams?.[0];
        const to = str(data.to) ?? ev.teams?.[1] ?? teamOf(world, a.id);
        const other = b ? fullName(world, b.id, false) : str(data.for) ?? "a player to be named later";
        s = { kind: "trade", heads: [`${teamName(world, from)} Trade ${aLast} to ${teamName(world, to)}`, `${aLast} Traded to ${teamName(world, to)}`],
          d: [`${aName} goes to ${teamCity(world, to)}; ${teamName(world, from)} get ${other}`],
          body: [`The ${teamName(world, from)} traded ${aName} to the ${teamName(world, to)} for ${other} on Tuesday.`,
            `The trade was completed by fax at 2 a.m. ${aLast} learned of it from a cab driver on the way to the ballpark.`] };
        break;
      }
      case "il":
      case "injury": {
        if (!a || !isPlayer(a) || levelOf(world, a.teamId) !== "ML") break;
        const what = str(data.kind) ?? a.injury?.kind ?? "an undisclosed injury";
        const days = num(data.days) ?? a.injury?.daysLeft;
        s = { kind: "brief", heads: [`${aLast} to Injured List${days ? `, Out ${days} Days` : ""}`, `${aLast} Injured`],
          d: [`${aName} (${what}) ${days ? `expected to miss ${days} days` : "is day-to-day"}`],
          body: [`${aName} of the ${tName} has ${what}. ${days ? `He is expected to miss ${days} days.` : "He is day-to-day."}`,
            `${aLast} said he felt fine apart from the injury.`] };
        break;
      }
      case "milestone": {
        if (!a) break;
        const what = str(data.what) ?? str(data.label) ?? "a career milestone";
        s = { kind: "brief", base: 1.5, heads: [`${aLast} Reaches ${capFirst(what)}`.slice(0, 48), `${aLast} Milestone`],
          d: [`${aName} reaches ${what}; the ball goes to his mother`],
          body: [`${aName} reached ${what} for the ${tName}. The crowd stood for one minute.`,
            `The ball was given to ${his} mother, who was seated behind the dugout.`] };
        break;
      }
      case "award": {
        if (!a) break;
        const award = str(data.award) ?? str(data.what) ?? "an award";
        s = { kind: "feature", base: 2, heads: [`${aLast} Wins ${award}`.slice(0, 48), `${aLast} Named ${award}`.slice(0, 48)],
          d: [`${aName} of the ${tName} is named ${award}`],
          body: [`${aName} of the ${tName} has been named ${award}. ${He} received ${seeded(ev.id, 14, 28)} of 28 first-place votes.`,
            `The trophy was presented at a banquet. Chicken was served. The Commissioner mispronounced ${his} name twice.`] };
        break;
      }
      case "champion": {
        const tid = ev.teams?.[0] ?? tId;
        if (!tid || !world.teams[tid]) break;
        const T = teamName(world, tid), C = teamCity(world, tid);
        const cup = str(data.series) ?? (world.teams[tid].level === "EL" ? "Mirage Cup" : "Continental Series");
        const cupName = cup.replace(/^the /i, "");
        s = { kind: "feature", base: world.teams[tid].level === "EL" ? 3 : 5, heads: [`${T} Win the ${cupName}`.slice(0, 48), `${T} Are Champions`],
          d: [`${C} celebrates; police report ${seeded(ev.id, 20, 90)} arrests downtown`],
          body: [`The ${T} won the ${cupName}. Fans in ${C} filled the streets until 4 a.m.`,
            `Police reported ${seeded(ev.id, 20, 90)} arrests, mostly for climbing lamp posts. One couple was married on the hood of a car.`,
            `"${rng.pick(["We did it for the city.", "I've been waiting for this my whole life.", "We'll celebrate tonight. Tomorrow we start over."])}" said manager ${lastName(world, world.teams[tid].managerId)}.`] };
        break;
      }
      case "hire":
      case "fire": {
        if (!a) break;
        const hired = ev.kind === "hire";
        s = { kind: "brief", base: 1.5, heads: [hired ? `${tName} Hire ${aLast} as Manager` : `${tName} Fire Manager ${aLast}`, hired ? `${aLast} to Manage ${tName}` : `${aLast} Out as ${tName} Manager`],
          d: [hired ? `${aName} signs a ${seeded(ev.id, 1, 3)}-year contract` : `${aName} is dismissed${str(data.cause) ? `; ${str(data.cause)}` : "; the club cites results"}`],
          body: [hired ? `The ${tName} named ${aName} ${str(data.role) === "gm" ? "general manager" : "manager"} on Tuesday. ${He} signed a ${seeded(ev.id, 1, 3)}-year contract.` : `The ${tName} fired ${str(data.role) === "gm" ? "general manager" : "manager"} ${aName} on Tuesday${str(data.record) ? ` with the club at ${str(data.record)}` : ""}. ${str(data.cause) ? `The club cited ${str(data.cause)}. ` : ""}${He} learned of the decision by fax.`,
            hired ? `${He} said ${he} would emphasize fundamentals.` : `${He} cleaned out ${his} office in eleven minutes. ${He} took a lamp.`] };
        break;
      }
      case "succession": {
        if (!a) break;
        const fid = str(data.factionId) ?? (tId ? world.teams[tId]?.factionId : undefined);
        const F = (fid && world.factions[fid]?.name) || "the organization";
        s = { kind: "feature", base: 2, heads: [`${aLast} Takes Control of ${F}`.slice(0, 48), `New Leadership at ${F}`.slice(0, 48)],
          d: [`${aName} assumes control of ${F}`],
          body: [`${aName} has taken control of ${F}. The transition took effect Monday.`,
            `${He} said ${his} first priority is ${rng.pick(["a new stadium", "the parking lot", "the farm system", "the old business with the Friars"])}.`] };
        break;
      }
      case "coming_of_age": {
        const par = famousParent(world, a);
        if (!a || !par) break;
        const chose = data.choice === "baseball" || data.baseball === true;
        s = { kind: "life", heads: [chose ? `${par.last}'s ${child(a)} Chooses Baseball` : `${par.last}'s ${child(a)} Chooses College`],
          d: [chose ? `${aName}, 18, will pursue a baseball career` : `${aName}, 18, will study accounting`],
          body: [`${aName}, ${a.age}, ${chose ? "will pursue a baseball career" : "will not pursue a baseball career"}, the family said.`,
            chose ? `Scouts from three clubs have called the house.` : `${He} will study accounting. ${fullName(world, par.id, false)} said ${he} supports the decision.`] };
        break;
      }
      case "world": {
        s = worldStory(world, ev, rng);
        break;
      }
      case "transfer": {
        if (!a) break;
        const sub = str(data.sub) ?? str(data.kind) ?? "to_enhanced";
        const cause = str(data.cause) ?? str(data.why) ?? str(data.reason);
        const to = str(data.to) ?? (isPlayer(a) ? a.teamId : undefined);
        const from = str(data.from) ?? ev.teams?.find(t => t !== to);
        const power = Array.isArray((a as { powers?: { kind: string }[] }).powers) ? (a as { powers?: { kind: string }[] }).powers![0]?.kind : str(data.power);
        if (sub === "return") s = { kind: "brief", base: 2, heads: [`${aLast} Returns From Enhanced League`, `${aLast} Back in Continental League`],
          d: [`${aName} rejoins ${teamFullName(world, to)}`],
          body: [`${aName} has been cleared to return to the Continental League. He will report to ${teamFullName(world, to)}.`, `He said the desert was "very quiet." He did not say whether he still has his ${power ? power.toLowerCase().replace(/_/g, " ") : "ability"}.`] };
        else s = { kind: "feature", base: 3, tags: ["train", "departure", "travel"], heads: [`${aLast} Sent to Enhanced League`, `Commissioner Sends ${aLast} to Desert`],
          d: [`${aName} leaves ${teamName(world, from)} for ${teamFullName(world, to)}${cause ? `; ${cause}` : ""}`.slice(0, 90), `${aName} is sent to the Enhanced League`],
          body: [`The Commissioner has transferred ${aName} from the ${teamName(world, from)} to ${teamFullName(world, to)} of the Enhanced League.${cause ? ` The order cites ${cause}.` : ""}`,
            `The Enhanced League plays in the desert. Powers are permitted there. ${aLast} left on the morning train with two bags.`,
            `"${rng.pick(["I go where they send me.", "I didn't ask for any of this.", "I hear it's dry heat."])}" ${aLast} said.`] };
        break;
      }
      case "exhibition": {
        const ids = (ev.teams ?? []).filter(t => world.teams[t]);
        const W = str(data.winner) ?? ids[0], Lo = str(data.loser) ?? ids.find(t => t !== W);
        if (!W || !Lo || !world.teams[W] || !world.teams[Lo]) break;
        const score = str(data.score) ?? (num(data.home) !== undefined && num(data.away) !== undefined ? `${Math.max(num(data.home)!, num(data.away)!)}-${Math.min(num(data.home)!, num(data.away)!)}` : undefined);
        const elWon = world.teams[W].level === "EL";
        s = { kind: "brief", base: 2, tags: ["baseball", "crowd", "space"], heads: [`${teamName(world, W)} Beat ${teamName(world, Lo)} in Exhibition`, `Exhibition: ${teamName(world, W)}${score ? ` ${score}` : ""}`],
          d: [`${elWon ? "The Enhanced club wins" : "The Continental club wins"}${score ? `, ${score}` : ""}${num(data.powers) ? `; ${num(data.powers)} powers used` : ""}`],
          body: [`${capFirst(teamFullName(world, W))} beat ${teamFullName(world, Lo)}${score ? `, ${score},` : ""} in an exhibition between the leagues.`,
            elWon ? `Powers were used throughout. The Continental club's manager said his players "saw some things."` : `The Continental club won without powers. Its manager said the result "proves something." He did not say what.`] };
        break;
      }
      case "playoffs": {
        const what = str(data.what) ?? "";
        const W = str(data.winner) ?? str(data.high), Lo = str(data.loser) ?? str(data.low);
        if (/semifinal won/.test(what) && W && Lo) s = { kind: "feature", base: 3, tags: ["baseball", "crowd", "grandstand"],
          heads: [`${teamName(world, W)} Eliminate ${teamName(world, Lo)}`, `${teamName(world, W)} Advance to Series`],
          d: [`${teamName(world, W)} win the series${str(data.score) ? `, ${str(data.score)}` : ""}`],
          body: [`The ${teamName(world, W)} beat the ${teamName(world, Lo)}${str(data.score) ? ` ${str(data.score)} in games` : ""} and advanced to the Continental Series.`, `The ${teamName(world, Lo)} cleaned out their lockers on Tuesday. Several players said they would go fishing.`] };
        else if (/set/.test(what) && W && Lo) s = { kind: "feature", base: 3, tags: ["baseball", "crowd"],
          heads: [`${teamName(world, W)}, ${teamName(world, Lo)} Meet in Series`],
          d: [`Game 1 is in ${teamCity(world, W)}`],
          body: [`The Continental Series will match the ${teamFullName(world, W)} and the ${teamFullName(world, Lo)}.`, `Game 1 is in ${teamCity(world, W)}. Tickets went on sale at 8 a.m. and were gone by 8:40.`] };
        else if (/begin/.test(what)) {
          const seeds = (Array.isArray(data.seeds) ? data.seeds : ev.teams ?? []).filter((x): x is string => typeof x === "string" && !!world.teams[x]);
          if (seeds.length) s = { kind: "feature", base: 2, tags: ["baseball", "grandstand"], heads: [`Playoffs Begin`, `${seeds.length} Clubs Open Playoffs`],
            d: [seeds.map(t => teamName(world, t)).join(", ").slice(0, 90)],
            body: [`The playoffs begin this week. The qualifying clubs are the ${seeds.map(t => teamName(world, t)).join(", the ")}.`, `The semifinals are best of five.`] };
        }
        break;
      }
      case "season": {
        const what = str(data.what) ?? "";
        if (what === "opening day") s = { kind: "feature", base: 2, tags: ["season", "ballpark", "exterior"], heads: [`Season Opens Today`, `Opening Day`],
          d: [`${Object.values(world.teams).filter(t => t.level === "ML").length} clubs open the season`],
          body: [`The season opens today${str(data.date) ? `, ${str(data.date)}` : ""}. First pitch in most parks is at 1:05.`, `Every club is 0-0.`] };
        else if (what === "regular season ends" && tId) s = { kind: "brief", heads: [`${tName} Finish First`], d: [`${tName} end the season ${num(data.w) ?? "?"}-${num(data.l) ?? "?"}`],
          body: [`The regular season is over. The ${tName} finished first with a record of ${num(data.w)}-${num(data.l)}.`, `The playoffs begin this week.`] };
        else if (what === "pennant" && tId) s = { kind: "brief", base: 0.5, heads: [`${tName} Win ${str(data.level) ?? ""} Pennant`.replace("  ", " ")], d: [`${teamFullName(world, tId)} finish ${num(data.w)}-${num(data.l)}`],
          body: [`${capFirst(teamFullName(world, tId))} won the ${str(data.level) ?? "minor league"} pennant with a record of ${num(data.w)}-${num(data.l)}.`, `The club celebrated in the clubhouse with cake.`] };
        break;
      }
      default: {
        const text = str(data.text) ?? str(data.headline) ?? str(data.what);
        if (!a || !text) break;
        s = { kind: "brief", heads: [`${aLast}: ${capFirst(text)}`.slice(0, 48), `${aLast} in the News`], d: [`${aName} ${text}`.slice(0, 90)], body: [`${aName} ${text}.`, `${He} could not be reached for comment.`] };
      }
    }
    if (!s) continue;
    const people = uniq(ev.who.filter(id => !!person(world, id)));
    const body = s.body.length >= 3 ? s.body : [...s.body, closer(rng, s.section)];
    const sub = str(data.sub) ?? str(data.kind) ?? str(data.drama);
    const city = ev.kind === "world" ? TEAM_TAGS[world.teams[tId ?? ""]?.abbr ?? ""] ?? [] : [];
    const tags = s.tags ?? [...lifeTags(ev.kind, sub), ...city];
    const weight = num(data.weight);
    out.push({
      ...illustrate(tags.length ? tags : ["newspaper", "press"], `story:life:${ev.id}`),
      id: `story:life:${ev.id}`, day: ev.day ?? day, kind: s.kind, headline: headline(rng, s.heads), dek: dek(s.d), body, faceIds: faces(world, people),
      people, teams: uniq([...(ev.teams ?? []), ...(tId ? [tId] : [])].filter(id => !!world.teams[id])), section: s.section ?? (s.kind === "trade" ? "Transactions" : "Sports"),
      dateline: dateLine(world, ev.day ?? day), prominence: prominence(world, people, s.base ?? (weight ? weight / 2 : 1)),
    });
  }
  if (moves.length) {
    const rng = new Rng(`moves:${day}:${moves.length}`);
    const list = moves.slice(0, 10);
    out.push({
      id: `story:moves:${day}`, day, kind: "brief", headline: headline(rng, [`Transactions`]),
      dek: dek([`${moves.length} roster moves around the league`]),
      body: [list.slice(0, 5).join(" "), ...(list.length > 5 ? [list.slice(5).join(" ")] : []), `${moves.length > list.length ? `${moves.length - list.length} other moves were announced. ` : ""}All moves are pending physicals.`],
      faceIds: faces(world, movePeople.slice(0, 4)), people: uniq(movePeople), teams: uniq(moveTeams), section: "Transactions", dateline: dateLine(world, day), prominence: 0.5,
      ...illustrate(["train", "station", "travel"], `story:moves:${day}`),
    });
  }
  return out.sort((x, y) => (y.prominence ?? 1) - (x.prominence ?? 1));
}

function teamFullAbbr(world: World, id: string | undefined): string {
  const t = id ? world.teams[id] : undefined;
  return t ? `${t.city} (${t.abbr})` : "the minor leagues";
}
function teamFullName(world: World, id: string | undefined): string {
  const t = id ? world.teams[id] : undefined;
  return t ? `the ${t.city} ${t.name}` : "a club";
}

function closer(rng: Rng, section?: string): string {
  return section === "Metro" || section === "Elsewhere"
    ? rng.pick(["City Hall did not return calls.", "Officials said more information would be available Thursday.", "The mayor's office said it was monitoring the situation."])
    : rng.pick(["The club declined further comment.", "More information is expected later this week.", "The club issued a two-sentence statement."]);
}

/** Metro / Elsewhere: non-baseball world events, tied back to the ballpark where possible. */
function worldStory(world: World, ev: LifeEventLike, rng: Rng): DeskSpec | undefined {
  const data = ev.data ?? {};
  const sub = (str(data.sub) ?? str(data.type) ?? str(data.topic) ?? str(data.kind) ?? "other").toLowerCase();
  const title = str(data.title);
  const text = str(data.text) ?? str(data.blurb) ?? str(data.desc);
  const fid = str(data.factionId) ?? str(data.faction);
  const faction = fid ? world.factions[fid] : undefined;
  const teamId = ev.teams?.find(id => world.teams[id]) ?? (fid ? Object.values(world.teams).find(t => t.factionId === fid && t.level === "ML")?.id : undefined)
    ?? rng.pick(Object.values(world.teams).filter(t => t.level === "ML").map(t => t.id));
  const T = teamName(world, teamId), C = teamCity(world, teamId);
  const F = faction?.name ?? "local employers";
  const sec = rng.chance(0.5) ? "Metro" : "Elsewhere";
  // the life engine's own copy is used only where its specifics matter (what the fad is, what
  // the council voted on); elsewhere the desk writes its own flat facts
  const useText = /(fad|civic|celebrity|mayor)/.test(sub) || !/(strike|election|bubble|crash|y2k|weather|heat|flood|blizzard|comet|blackout|fair|war|storm|rain|snow)/.test(sub);
  const own = useText && title && title.length <= 48 ? [capFirst(title)] : [];
  const n = (lo: number, hi: number) => seeded(`${ev.id}:${sub}`, lo, hi);
  const fact = useText && text ? `${text.replace(/[.!]+$/, "")}.` : "";
  const tmpl: Record<string, () => { heads: string[]; d: string; body: string[] }> = {
    strike: () => ({ heads: [...own, `${capFirst(str(data.who) ?? "Dock")} Strike Leaves ${T} Without Hot Dogs`, `Strike Enters Day ${n(2, 9)} in ${C}`],
      d: `Workers walk out on ${F}; ballpark limits hot dogs to one per customer`,
      body: [fact || `Workers in ${C} walked off the job in a dispute with ${F}.`, `At the ${T} game, hot dogs were limited to one per customer. Season ticket holders were allowed two.`, `Union leaders said the picket line will stay up. ${F} said it will not negotiate under pressure.`] }),
    election: () => ({ heads: [...own, `${C} Votes Today`, `Mayoral Candidates Promise ${T} a Stadium`],
      d: `Both candidates promise a new stadium; one also promises a monorail`,
      body: [fact || `${C} votes today.`, `Both candidates have promised the ${T} a new stadium. One has also promised a monorail.`, `Turnout was expected to be light. Precinct 9 is located in a bar.`] }),
    fad: () => ({ heads: [...own, `${capFirst(str(data.what) ?? "New Craze")} Reaches ${C}`.slice(0, 48), `${T} Ban Craze From Clubhouse`],
      d: `The ${T} have banned it from the clubhouse`,
      body: [fact || `A new craze has reached ${C}.`, `Three members of the ${T} were seen taking part in the dugout on Tuesday. The club has banned it from the clubhouse.`, `Sales of related merchandise at the ballpark are up ${n(150, 450)} percent.`] }),
    bubble: () => ({ heads: [...own, `Stocks Rise Again; ${T} Box Seats Sell Out`], d: `Brokers buy luxury boxes; season ticket waiting list grows`,
      body: [fact || `Stock prices rose for the ${n(4, 12)}th straight week.`, `The ${T} sold every luxury box for the season. Most were bought by brokers under 30.`] }),
    crash: () => ({ heads: [...own, `Market Falls; ${T} Luxury Boxes Empty`, `Stocks Drop ${n(8, 22)} Percent`],
      d: `Brokers stay home; ballpark beer prices unchanged`,
      body: [fact || `The stock market fell ${n(8, 22)} percent this week.`, `At the ${T} game, ${n(9, 20)} of ${n(21, 30)} luxury boxes were empty. Men in suits were seen in the upper deck.`, `${F} said it was well positioned.`] }),
    y2k: () => ({ heads: [...own, `${T} Test Scoreboard for Y2K`, `Y2K Concerns Reach the Ballpark`],
      d: `Consultant says the scoreboard may read "1900"`,
      body: [fact || `Concern that computers will fail on January 1 has reached the ballpark.`, `The ${T} hired a consultant to test the scoreboard. He said it may display the year 1900.`, `The club said it will keep score by hand if necessary.`] }),
    weather: () => ({ heads: [...own, `Storm Hits ${C}; ${T} Tarp Lost`, `Weather Delays Games in ${C}`],
      d: `The tarp was last seen heading east`,
      body: [fact || `Severe weather struck ${C} this week.`, `The ${T} lost their infield tarp. It was last seen heading east at about 40 miles per hour.`, `Games will be played as scheduled.`] }),
    heatwave: () => ({ heads: [...own, `Heat Wave Hits ${C}`, `${n(98, 106)} Degrees at ${T} Game`], d: `Fans treated for heat exhaustion; beer sales set a record`,
      body: [fact || `The temperature in ${C} reached ${n(98, 106)} degrees.`, `${n(9, 40)} fans were treated for heat exhaustion at the ${T} game. Beer sales set a club record.`] }),
    flood: () => ({ heads: [...own, `Flooding in ${C}; ${T} Field Underwater`], d: `Outfield under ${n(2, 5)} feet of water; games moved`,
      body: [fact || `The river crested in ${C} on Tuesday.`, `The ${T} outfield is under ${n(2, 5)} feet of water. A rowboat was seen in center field.`] }),
    blizzard: () => ({ heads: [...own, `Blizzard Buries ${C}`], d: `${n(18, 40)} inches of snow; the ballpark is closed`,
      body: [fact || `${C} received ${n(18, 40)} inches of snow.`, `The ${T} ballpark is closed. The grounds crew is shoveling the infield by hand.`] }),
    comet: () => ({ heads: [...own, `Comet Visible Over ${C}`, `Fans Watch Comet During ${T} Game`],
      d: `An entire section turned to look during a bases-loaded triple`,
      body: [fact || `A comet is visible in the night sky this week.`, `At the ${T} game, an entire section turned to look at it during a bases-loaded triple.`, `A local church called it a sign. ${F} called it a distraction.`] }),
    blackout: () => ({ heads: [...own, `Power Out Across ${C}`, `Blackout Darkens ${C}; ${T} Game Delayed`],
      d: `Utility blames a squirrel`,
      body: [fact || `Power failed across ${C} last night.`, `The ${T} game was delayed ${n(40, 120)} minutes. The utility blamed a squirrel.`] }),
    worlds_fair: () => ({ heads: [...own, `World's Fair Opens in ${C}`], d: `Exhibits include a monorail and a robot`,
      body: [fact || `The World's Fair opened in ${C}.`, `Exhibits include a monorail, a kitchen of the future and a robot that says one sentence. Attendance at ${T} games is up.`] }),
    celebrity_wedding: () => ({ heads: [...own, `Soap Star Marries`], d: `The ceremony was held at a hotel; tabloids were present`,
      body: [fact || `A television actress was married on Saturday.`, `The ceremony was held at a downtown hotel. ${n(4, 12)} photographers were removed from the lobby.`] }),
    war: () => ({ heads: [...own, `Troops Deployed; League Adds Anthem`], d: `The Commissioner orders a second anthem before games`,
      body: [fact || `Troops have been deployed overseas.`, `The Commissioner has ordered that the anthem be played twice before every game.`] }),
    civic_absurdity: () => ({ heads: [...own, `${C} Council Acts`], d: `The measure passed ${n(5, 9)}-${n(0, 4)}`,
      body: [fact || `The ${C} city council took an unusual vote on Tuesday.`, `The measure passed ${n(5, 9)}-${n(0, 4)}. The mayor said he would sign it.`] }),
    mayor_scandal: () => ({ heads: [...own, `${C} Mayor Under Investigation`], d: `Investigators examine stadium contracts`,
      body: [fact || `The mayor of ${C} is under investigation.`, `Investigators are examining contracts related to the ${T} ballpark. The mayor said he has done nothing wrong.`] }),
  };
  const key = Object.keys(tmpl).find(k => sub === k || sub.includes(k)) ?? (/(storm|rain|snow)/.test(sub) ? "weather" : undefined);
  const t = key ? tmpl[key]() : title || text ? {
    heads: [...own, `In ${C}`], d: text ? text.slice(0, 88) : `News from ${C}`,
    body: [fact || `${title}.`, `A ${T} spokesman said the club was aware of it.`],
  } : undefined;
  if (!t) return undefined;
  return { kind: "feature", heads: t.heads, d: [t.d], body: [...t.body.filter(Boolean), closer(rng, sec)].slice(0, 4), section: sec, base: num(data.weight) ? num(data.weight)! / 2 : 1 };
}
