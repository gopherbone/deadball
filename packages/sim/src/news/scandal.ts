// Crime desk: stories from crew jobs that became public. Police-blotter register: who, what,
// where, what the police said. Names crew members (never account names), the club, and the
// factions that commented.

import type { World } from "../types.ts";
import { Rng } from "../rng.ts";
import type { NewsHook } from "../crime/types.ts";
import { article, capFirst, dateLine, dek, faces, fullName, headline, lastName, midName, person, roleLabel, seeded, teamName, uniq } from "./util.ts";
import type { Story } from "./types.ts";
import { illustrate, OP_TAGS, TROUBLE_TAGS } from "../archive.ts";

const CAPER: Record<string, string> = {
  grease_mound: "Mound", rabbit_balls: "Baseball", raccoons: "Raccoon", cooler: "Cooler", bribe_ump: "Umpire Bribery",
  laser: "Laser", steal_signs: "Sign-Stealing", lucky_glove: "Glove", sprinklers: "Sprinkler", heckle: "Heckling",
  love_letter: "Letter", blackmail: "Blackmail", tip_wire: "Leak", kidnap_mascot: "Mascot", blackout: "Blackout",
  security: "Security", bribe_investigator: "Bribery",
};

/** Gerund phrase for each job, used by the crime desk and event cards. */
export const OP_WHAT: Record<string, string> = {
  grease_mound: "applying petroleum jelly to the pitching rubber", rabbit_balls: "replacing the game balls with a crate of altered balls",
  raccoons: "releasing raccoons into the bullpen", cooler: "adding a laxative to the dugout water cooler", bribe_ump: "offering an envelope of cash to an umpire",
  laser: "aiming a laser pointer at batters from the bleachers", steal_signs: "stealing signs with opera glasses", lucky_glove: "taking a pitcher's glove from the clubhouse",
  sprinklers: "running the field sprinklers overnight", heckle: "heckling players with a megaphone", love_letter: "forging a love letter to a player's wife",
  blackmail: "blackmailing a player with photographs", tip_wire: "placing an anonymous call to a newspaper", kidnap_mascot: "taking the club mascot",
  blackout: "cutting power to the stadium", security: "unlicensed security work",
};

/** What the police recovered. Specific, unexplained. */
const EVIDENCE: Record<string, string[]> = {
  raccoons: ["three burlap sacks", "a nun's habit", "a bucket that had held eels"],
  cooler: ["a grocery bag of laxative chocolate", "a grounds crew jumpsuit"],
  bribe_ump: ["an envelope containing $4,000", "a rosary"],
  laser: ["a laser pointer", "a pair of opera glasses", "a nun's habit"],
  kidnap_mascot: ["a foam head", "bolt cutters", "a 1968 Chrysler with one hubcap"],
  blackout: ["bolt cutters", "a grounds crew jumpsuit", "a brick"],
  grease_mound: ["a five-pound tub of petroleum jelly"],
  rabbit_balls: ["a crate of 144 baseballs"],
  sprinklers: ["bolt cutters", "a valve key"],
  heckle: ["a megaphone", "four pages of typed notes"],
  love_letter: ["perfume", "monogrammed stationery"],
  blackmail: ["a telephoto camera", "eleven photographs"],
  steal_signs: ["opera glasses", "two walkie-talkies"],
  lucky_glove: ["a fielder's glove", "a locker key from the bus station"],
};

function factionQuote(world: World, fid: string | undefined, rng: Rng): string | undefined {
  const f = fid ? world.factions[fid] : undefined;
  if (!f) return undefined;
  const leader = person(world, f.leaderId);
  const who = leader ? `${leader.first} ${leader.last} of ${midName(f.name)}` : `a spokesman for ${midName(f.name)}`;
  const lines: Record<string, string[]> = {
    church: [`"We are praying for the bullpen," said ${who}.`, `${capFirst(who)} said the diocese would cooperate with police.`],
    trust: [`${capFirst(who)} said the matter had been referred to the company's lawyers.`, `"We expect to be made whole," said ${who}.`],
    owner: [`"We want to know who paid for it," said ${who}.`, `${capFirst(who)} said the club would add guards at the bullpen gate.`],
    commissioner: [`The Commissioner's Office said it had opened an inquiry.`, `The Commissioner's Office said it was "aware of the matter."`],
    umpires: [`The Umpires' Brotherhood said its members are not for sale.`],
    press: [`SportsWire did not disclose its sources.`],
    bookies: [`Bets By Bobby did not return calls. The line on the next game moved by a run.`],
    mob: [`No one answered the door at the social club.`],
  };
  return rng.pick(lines[f.kind] ?? lines.owner);
}

/** One scandal story from a crime hook. Returns undefined if there's nothing printable. */
export function writeScandalStory(world: World, hook: NewsHook): Story | undefined {
  const seed = `scandal:${hook.kind}:${hook.opKind}:${hook.day}:${hook.targetTeamId}:${hook.people.join(",")}`;
  const rng = new Rng(seed);
  const caper = CAPER[hook.opKind] ?? "Ballpark";
  const what = OP_WHAT[hook.opKind] ?? "trespassing";
  const team = teamName(world, hook.targetTeamId);
  const crew = hook.people.filter(id => world.npcs[id]);
  const players = hook.people.filter(id => world.players[id]);
  const lead = crew[0];
  const leadRole = lead ? roleLabel(world, lead) : "suspect";
  const leadName = lead ? fullName(world, lead, true) : "";
  const leadLast = lead ? lastName(world, lead) : "";
  const age = lead ? person(world, lead)?.age : undefined;
  const named = crew.map(id => `${fullName(world, id, false)}, ${person(world, id)?.age ?? "age unknown"}, ${article(roleLabel(world, id))}`);
  const evidence = EVIDENCE[hook.opKind] ?? ["a duffel bag"];
  const body: string[] = [];
  let heads: string[] = [];
  let d = "";
  const tf = world.teams[hook.targetTeamId]?.factionId;

  switch (hook.kind) {
    case "arrest":
    case "exposed": {
      const arrested = hook.kind === "arrest";
      heads = lead ? [
        `${capFirst(leadRole)} ${arrested ? "Charged" : "Sought"} in ${team} ${caper} Case`,
        `${capFirst(leadRole)} ${arrested ? "Arrested" : "Sought"} at ${team} Game`,
        `${arrested ? "Arrest Made" : "Police Seek Suspects"} in ${caper} Case`,
      ] : [`Police Investigate ${team} ${caper} Incident`];
      d = lead ? `${leadName}, ${age ?? "age unknown"}, is ${arrested ? "charged with" : "sought for"} ${what}` : `Police investigate ${what}`;
      const who = named.length === 1 ? `${named[0]},` : named.length ? `${named.length} people` : "unknown persons";
      body.push(`Police ${arrested ? "have arrested" : "are looking for"} ${who} in connection with ${what} at the ${team} game.${named.length > 1 ? ` They are ${named.slice(0, -1).join("; ")}; and ${named[named.length - 1]}.` : ""}`);
      body.push(`${arrested ? "Officers recovered" : "Officers found"} ${evidence.length > 1 ? `${evidence.slice(0, -1).join(", ")} and ${evidence[evidence.length - 1]}` : evidence[0]}${lead ? ` in a vehicle registered to ${leadLast}` : ""}. ${hook.success === false ? "Police said the plan did not work." : "Police said the plan worked."}`);
      if (crew.length > 1) body.push(`Detectives believe ${fullName(world, crew[1], false)} acted as ${rng.pick(["a lookout", "the driver", "a distraction"])}. ${rng.pick(["None of the suspects would say who paid them.", "Each suspect named a different person as the organizer.", `${lastName(world, crew[1])} told officers ${person(world, crew[1])?.sex === "F" ? "she" : "he"} was birdwatching.`])}`);
      else if (lead) body.push(`Neighbors described ${leadLast} as quiet. ${rng.pick([`${capFirst(leadRole === "nun" ? "She" : person(world, lead)?.sex === "F" ? "She" : "He")} has no prior arrests.`, `${leadLast} has one prior arrest, in 1987, for a similar matter.`, `${leadLast} did not respond to a note left at ${person(world, lead)?.sex === "F" ? "her" : "his"} door.`])}`);
      break;
    }
    case "deal":
      heads = lead ? [`${leadLast} Agrees to Testify in ${caper} Case`, `${capFirst(leadRole)} Cooperating in ${caper} Case`] : [`Deal Reached in ${caper} Case`];
      d = `Prosecutors say the ${leadRole} named the people who paid`;
      body.push(`${leadName || "A defendant"}, charged in the ${team} ${caper.toLowerCase()} case, has agreed to testify for the prosecution in exchange for a reduced charge.`);
      body.push(`The District Attorney would not say who was named. "There are several names," he said. "Some of them are a syndicate."`);
      break;
    case "judge":
      heads = [`Judge Questioned in ${caper} Case`, `Judge's Calls Under Review in ${caper} Case`];
      d = `Clerk reports phone calls before ruling; judge says he bought the boat with savings`;
      body.push(`A county judge presiding over the ${caper.toLowerCase()} case is under review after a court clerk reported ${seeded(seed, 6, 14)} short telephone calls to his chambers the night before a hearing.`);
      body.push(`The judge recently bought a boat. He said he paid for it with savings.${lead ? ` ${leadName}, the ${leadRole} at the center of the case, remains in custody.` : ""}`);
      break;
    case "skipped":
      heads = lead ? [`${leadLast} Fails to Appear in ${caper} Case`, `${capFirst(leadRole)} Missing Before Hearing`] : [`Suspect Fails to Appear`];
      d = `A bus ticket agent recalls a one-way fare paid in coins`;
      body.push(`${leadName || "A defendant"} did not appear for a hearing in the ${team} ${caper.toLowerCase()} case. A warrant has been issued.`);
      body.push(`A ticket agent at the Greyhound station said a ${leadRole} bought a one-way ticket on Tuesday and paid in quarters.`);
      break;
    case "convicted":
      heads = lead ? [`${leadLast} Convicted in ${caper} Case`, `${capFirst(leadRole)} Gets 14 Days`] : [`Conviction in ${caper} Case`];
      d = `Jury deliberates 40 minutes; sentence is 14 days and a fine`;
      body.push(`A jury deliberated for 40 minutes before convicting ${leadName || "the defendant"} of ${what}. The ${leadRole} was sentenced to 14 days in county jail and fined $500.`);
      body.push(`${leadLast || "The defendant"} asked whether the jail receives the ballgame on the radio. The judge said it does.`);
      break;
    case "acquitted":
      heads = lead ? [`Jury Acquits ${leadLast} in ${caper} Case`, `${capFirst(leadRole)} Found Not Guilty`] : [`${caper} Case Ends in Acquittal`];
      d = `Defense argued the raccoons entered the bullpen on their own`;
      body.push(`${leadName || "The defendant"} was found not guilty of ${what}. The defense argued that the animals entered the bullpen without assistance.`);
      body.push(`Outside the courthouse the ${leadRole} thanked the jury and declined further comment.`);
      break;
    case "tip": {
      const p0 = players[0];
      heads = [`Sources Describe Trouble in ${team} Clubhouse`, p0 ? `${lastName(world, p0)} Named in ${team} Report` : `${team} Deny Clubhouse Report`];
      d = p0 ? `Report details ${lastName(world, p0)}'s gambling and late nights; club denies it` : `Report describes a card game with high stakes; club denies it`;
      const sins = players.map(id => {
        const t = world.players[id]?.traits ?? [];
        const sin = t.includes("GAMBLER") ? "plays in a Thursday card game where the pot has exceeded $10,000" : t.includes("DRUNK") ? "has an open tab at the Shamrock of $2,300" : "has a business arrangement with a man he would not name";
        return `${fullName(world, id, false)} ${sin}`;
      });
      body.push(`According to a source who called the SportsWire newsroom collect, ${sins.length ? sins.join(", and ") : "players on the club hold a regular card game with high stakes"}.`);
      body.push(`The club denied the report. The source called back the next day and asked to be paid.`);
      break;
    }
    case "op": {
      if (hook.opKind === "kidnap_mascot") {
        heads = [`${team} Mascot Reported Missing`, `${team} Mascot Taken Before Game`];
        d = `Ransom note, written in crayon, asks for one pennant`;
        body.push(`The ${team} mascot was reported missing before the game. The costume head was also taken.`);
        body.push(`A ransom note written in crayon was left in the mascot's locker. It asks for "one (1) pennant." The club is offering season tickets for information.`);
      } else if (hook.opKind === "love_letter" && players[0]) {
        const p = players[0];
        heads = [`Letter Strains ${lastName(world, p)} Marriage`, `${lastName(world, p)} Leaves Club for Family Matter`];
        d = `Perfumed letter delivered to player's home; club calls it private`;
        body.push(`${fullName(world, p, false)} of the ${team} left the ballpark early Tuesday after a letter arrived at his home. The letter was perfumed and addressed to "my slugger."`);
        body.push(`His wife read it to the neighbors. The ${team} said it is a private matter.`);
      } else return undefined;
      break;
    }
    default:
      return undefined;
  }

  const quotes = [factionQuote(world, tf, rng), factionQuote(world, hook.factions?.find(f => f !== tf), rng)];
  if (hook.opKind === "bribe_ump") quotes.push(factionQuote(world, "umps", rng));
  if (hook.kind === "arrest" || hook.kind === "exposed" || hook.kind === "deal") quotes.push(factionQuote(world, "commish", rng));
  const q = quotes.filter((x): x is string => !!x);
  if (q.length) body.push(q.slice(0, 3).join(" "));
  body.push(rng.pick([
    `The ${team} play again tomorrow. The club said security will be increased.`,
    `Police asked anyone with information to call the department.`,
    `A hearing is scheduled for next week.`,
  ]));

  const people = uniq([...crew, ...players]);
  const id = `story:crime:${hook.kind}:${hook.opKind}:${hook.day}:${hook.targetTeamId}:${people.join("-")}`;
  const opTags = OP_TAGS[hook.opKind] ?? [], trouble = TROUBLE_TAGS[hook.kind] ?? [];
  const tags = hook.kind === "op" || hook.kind === "exposed" || hook.kind === "tip" ? [...opTags, ...trouble] : [...trouble, ...opTags];
  return {
    id,
    day: hook.day, kind: "scandal", headline: headline(rng, heads), dek: dek([d, `Latest in the ${caper.toLowerCase()} case`]), body,
    faceIds: faces(world, people), people, teams: hook.targetTeamId ? [hook.targetTeamId] : [], gameId: hook.gameId, section: "Crime",
    dateline: dateLine(world, hook.day), prominence: hook.kind === "arrest" || hook.kind === "exposed" ? 2 : 1, ...illustrate(tags, id),
  };
}

/** Convenience: stories for a batch of hooks (e.g. effects from resolveChoice). */
export function writeScandalStories(world: World, hooks: NewsHook[]): Story[] {
  return hooks.map(h => writeScandalStory(world, h)).filter((s): s is Story => !!s);
}
