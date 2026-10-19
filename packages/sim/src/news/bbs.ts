// BBS rumour posts: message-board chatter that follows the news. Fans post plain sightings
// and second-hand facts, lower case, no exclamation. Built from stories, incidents and tips;
// never names accounts.

import type { World } from "../types.ts";
import { Rng } from "../rng.ts";
import { lastName, teamName } from "./util.ts";
import type { BbsPost, Story } from "./types.ts";

const HANDLES = [
  "DUGOUT_DAN", "~*FriarFan*~", "SlurveyMcSlurve", "BleacherCreature96", "xXLamplighterXx", "Organ_Grinder", "HotDogHal_NOT",
  "TheRealUmp", "Bettor_Bob", "RaccoonTruther", "CometWatcher", "PagerKid", "SysOp_Earl", "Mrs.Kowalski", "Y2K_Ready",
];

const SIGHTING = [
  "{player} was at the Shamrock last night. he left at 2.",
  "my brother sells hot dogs at the park. he says {player} tips a dollar every time.",
  "saw {player} at the car wash on route 9 tuesday. he washed his own car.",
  "{player} was at the bank on friday. he was there a long time.",
  "my cousin is an usher. he says {player} sits alone on the bus.",
  "{player} bought four pairs of the same shoes at the mall. i was behind him in line.",
];
const RUMOR = [
  "my cousin works security at the park. he says the {team} clubhouse has a padlock on the cooler now.",
  "{player} is getting traded. my uncle saw it on a fax.",
  "raccoons again at the {team} game. that is {n} this year by my count.",
  "the ump last night called {n} strikes on the black against the {team}. i wrote them down.",
  "{player} owes money to bets by bobby. this is known.",
  "there is a nun in section 12 at every {team} game. she does not keep score.",
  "{player} bought perfume at the mall on saturday. his wife was not with him.",
  "the {team} water cooler is gone. there is a card table there now.",
];
const WEIRD = [
  "i was at the denny's on route 9 that night. i didn't see anything. the pancakes were fine.",
  "my uncle went to {player}'s funeral. now he goes to the ballpark to see him. he says it is the same guy.",
  "they're both {player}. i've seen them stand next to each other. same mustache.",
  "he signed my program in a handwriting nobody uses anymore. i'm keeping it.",
  "the night crew at the park won't work past 2 now. my sister is on the night crew.",
  "my dad says there was a plane like that in 1958 too. he doesn't want to talk about it.",
];
const WEIRD_RE = /(Missing|Returns After|Back; Says|Dead .* Signs|Coroner|Second .* Signs|Identical|Signs With|Plane|Refuse to Fly|Search for)/;

/**
 * A handful of BBS posts for the day. `stories` seeds topical chatter (people, teams,
 * scandals); `tips` adds overheard rumours. Prominent stories get more posts. Deterministic per (day, board).
 */
export function bbsPosts(world: World, day: number, stories: Story[] = [], opts: { board?: string; count?: number; tips?: string[] } = {}): BbsPost[] {
  const board = opts.board ?? "rumors";
  const rng = new Rng(`bbs:${board}:${day}`);
  const count = opts.count ?? 5;
  const out: BbsPost[] = [];
  const mlTeams = Object.values(world.teams).filter(t => t.level === "ML").map(t => t.id);
  const people = stories.flatMap(s => s.people).filter(id => world.players[id]);
  const teams = stories.flatMap(s => s.teams);
  for (let i = 0; i < count; i++) {
    let text: string;
    let subject: string;
    const s = stories.length ? rng.weighted(stories, x => x.prominence ?? 1) : undefined;
    const p = s?.people.find(id => world.players[id] || world.npcs[id]);
    const fill = (t: string, pl?: string, tm?: string) => t.replace("{player}", pl ? lastName(world, pl).toLowerCase() : "somebody").replace("{team}", teamName(world, tm ?? rng.pick(mlTeams)).toLowerCase()).replace("{n}", String(3 + rng.int(9)));
    if (s && WEIRD_RE.test(s.headline) && rng.chance(0.8)) {
      subject = `RE: ${s.headline}`.slice(0, 48);
      text = fill(rng.pick(WEIRD), p);
    } else if (s && rng.chance(0.5)) {
      subject = `RE: ${s.headline}`.slice(0, 48);
      text = rng.pick([
        p ? fill(rng.pick(SIGHTING), p) : "i was there. it happened like the paper says.",
        s.kind === "scandal" ? "the paper had it first but my neighbor had it tuesday." : "i was in section 30. we could see it fine.",
        p ? `${lastName(world, p).toLowerCase()} signed my glove in 1994. he used a pencil.` : "first",
        "does anyone have this on tape. i need it for my son.",
      ]);
    } else if (opts.tips?.length && rng.chance(0.4)) {
      subject = "heard something";
      text = `a man at the bus stop told me: "${rng.pick(opts.tips).slice(0, 120)}" i don't know him.`;
    } else {
      const player = people.length ? rng.pick(people) : undefined;
      const team = teams.length && rng.chance(0.6) ? rng.pick(teams) : undefined;
      subject = rng.pick(["rumor mill", "sightings", "question", "does anyone know", "OT: not baseball"]);
      text = fill(rng.pick(rng.chance(0.4) && player ? SIGHTING : RUMOR), player, team);
    }
    out.push({ id: `bbs:${board}:${day}:${i}`, board, author: rng.pick(HANDLES), day, subject, text });
  }
  return out;
}
