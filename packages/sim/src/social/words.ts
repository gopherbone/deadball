// Curated word lists and templates for mad-libs comments (Dark Souls messages / Pokémon
// Easy Chat). No free text: every comment is a template plus words from these lists or
// from the live world (players, notable people, teams, parks, incidents).
//
// House rules for words: funny, not cruel. Nothing hateful or sexual. Mild 90s-internet
// energy. ASCII only (Playdate fonts). Keep each word short enough that any template
// still renders in 120 characters.

export type SlotKind =
  | "player" | "team" | "person" | "adjective" | "noun" | "verb" | "incident"
  | "exclamation" | "emote" | "item" | "number" | "time" | "place";

export const SLOT_KINDS: readonly SlotKind[] = [
  "player", "team", "person", "adjective", "noun", "verb", "incident",
  "exclamation", "emote", "item", "number", "time", "place",
];

export type TemplateKind =
  | "praise" | "trash" | "rumor" | "prophecy" | "nostalgia" | "conspiracy" | "web" | "advice";

/** Template text; slots are derived from `{kind}` markers in order (see comments.ts). */
export const TEMPLATE_TEXT: Record<TemplateKind, string[]> = {
  praise: [
    "{player} is {adjective}!",
    "{player} for MVP {emote}",
    "{team} rule!!!",
    "Name a better {noun} than {player}. I'll wait.",
    "{player} could {verb} in his sleep.",
    "Nobody can {verb} like {player}.",
    "{exclamation}! What a {noun}!",
    "Respect to {person}. Truly {adjective}.",
    "{player} hit one so far it lands {time}.",
    "Put {player} in the Hall of Fame {time}.",
  ],
  trash: [
    "{player} is {adjective}. Sorry not sorry.",
    "{team} couldn't {verb} if their lives depended on it.",
    "My grandma could {verb} better than {player}.",
    "{player} swings like a {noun}.",
    "Trade {player} for a {item} and {number} hot dogs.",
    "{team} fans, {exclamation}! Hahaha",
    "{player} is a {adjective} {noun} and everyone knows it.",
    "{team}? More like the {adjective} Bunch.",
    "Worst {noun} in the league: {player}.",
    "Get {player} off my TV {emote}",
  ],
  rumor: [
    "Heard {player} owes {person} {number} dollars.",
    "Word is {player} was seen at {place} with a {item}.",
    "My cousin says {person} is behind {incident}.",
    "{player} and {person} are feuding again. Source: me.",
    "Sources say {team} will trade {player} {time}.",
    "Don't tell anyone but {player} can't {verb}.",
    "Somebody saw {person} at {place} {time}. Just saying.",
    "{player} has a secret {item}. Ask me how I know.",
  ],
  prophecy: [
    "{team} will win it all {time}. Mark my words.",
    "I predict {incident} {time}.",
    "{player} will {verb} {number} times {time}.",
    "Prophecy: {person} will {verb} {time}.",
    "The stars say {team} is {adjective} this year.",
    "Bet it all on {team} {time} {emote}",
    "A {noun} will decide this pennant. Trust me.",
    "Mark it: {player} goes {adjective} {time}.",
  ],
  nostalgia: [
    "Remember {incident}? Good times.",
    "Back in my day {player} would {verb}.",
    "Nobody remembers {person} but I do.",
    "I was there for {incident}. Still have my {item}.",
    "{team} used to be {adjective}. Sigh.",
    "They don't make 'em like {player} anymore.",
    "I miss {place}. And {person}.",
    "Never forget {incident}.",
  ],
  conspiracy: [
    "{incident} was an inside job.",
    "Follow the money: {person} to {team} to a {item}.",
    "{person} controls the {noun}. Wake up!",
    "Why did {player} need a {item}? Think about it.",
    "{number} raccoons can't be a coincidence.",
    "{incident} plus {incident} equals {person}. Do the math.",
    "The umps are {adjective}. That's all I'll say.",
    "Bobby knows about {incident}. Bobby knows everything.",
    "{place} is a front. Ask {person}.",
  ],
  web: [
    "first!!!",
    "this page rules",
    "bookmarked {emote}",
    "Sign my guestbook!! {team} 4ever",
    "Under construction, like the {team} bullpen.",
    "Best site on the web. Visitor number {number}!",
    "Forwarded this to {person}.",
    "lol {emote}",
    "me too!!!",
    "Can't wait for {time}!!!",
    "{exclamation}!!! {emote}",
    "The webring says {team} is {adjective}.",
    "This comment best viewed in 800x600.",
    "Downloading {player} highlights. 4 hours left.",
    "Join my {player} fan club. Members: {number}.",
    "Webmaster pls add more {noun}.",
  ],
  advice: [
    "Try {verb}.",
    "Is {player} {adjective} or am I crazy?",
    "Pro tip: {verb} before the 7th.",
    "Who else thinks {person} is {adjective}?",
    "Will trade {number} {player} cards for a {item}.",
    "Hot take: the {noun} is {adjective}.",
    "{team} need more {noun}. And a {item}.",
    "Why is {player} holding a {item}?",
    "{exclamation}! {incident} again?!",
    "Agreed with {person}. {emote}",
    "Visit {place} and say {player} sent you.",
    "Never bet against a {adjective} {noun}.",
  ],
};

export const STATIC_WORDS: Record<SlotKind, string[]> = {
  player: [
    "the rookie", "the closer", "the backup catcher", "the cleanup hitter", "the leadoff man", "the ace",
    "the utility guy", "the new guy", "the pinch runner", "the knuckleballer", "the bullpen catcher", "the DH",
  ],
  team: ["the home team", "the visitors", "my team", "your team", "the farm club", "the expansion team"],
  person: [
    "Hot Dog Hal", "the nun", "my mom", "the commissioner", "Bobby", "the batboy", "the mascot", "a guy at the bar",
    "my uncle", "the groundskeeper", "the organist", "the beat reporter", "the webmaster", "my dentist",
    "the raccoon king", "the peanut guy", "a man in a trench coat", "the sysop", "Grandma", "the ump", "the bat dog",
    "the ticket scalper", "a psychic", "the night watchman", "my pen pal", "the team chaplain", "the bus driver",
    "nobody", "the trainer", "the stadium DJ", "my landlord", "the guy from accounting", "the lawyer", "the mailman",
    "the crossword champ", "the fire marshal", "the lunch lady", "my bowling team", "the night shift", "the Haldanes",
  ],
  adjective: [
    "clutch", "washed up", "legendary", "cursed", "suspicious", "sweaty", "beautiful", "overrated", "underrated",
    "majestic", "doomed", "radical", "tubular", "bodacious", "all that", "da bomb", "gnarly", "spooky", "haunted",
    "crooked", "honest", "elite", "lukewarm", "soggy", "greasy", "magnificent", "unstoppable", "mediocre", "fishy",
    "shady", "holy", "unholy", "bananas", "nuts", "wild", "funky", "fresh", "phat", "hilarious", "tragic", "chunky",
    "spicy", "crunchy", "lazy", "loyal", "superstitious", "paranoid", "on fire", "ice cold", "slow", "speedy",
    "confused", "brave", "smelly", "dramatic", "emotional", "mysterious", "unkillable", "radioactive", "grumpy",
    "jolly", "rich", "broke", "rad", "lame", "bogus", "excellent", "triumphant", "heinous", "sus", "built different",
    "way past cool", "fly", "crusty", "flaky", "buttery", "deluxe", "sincere", "feral",
  ],
  noun: [
    "raccoon", "hot dog", "bullpen", "conspiracy", "rally", "curveball", "spitball", "dynasty", "disaster", "legend",
    "bum", "genius", "dumpster fire", "hero", "villain", "menace", "goat", "rookie", "veteran", "mascot", "pennant",
    "grand slam", "triple play", "balk", "pickle", "web page", "modem", "screensaver", "mixtape", "pager",
    "guestbook", "chat room", "potato", "eel", "sandwich", "pigeon", "goose", "clown", "wizard", "ghost", "cowboy",
    "pirate", "knuckleball", "bunt", "bean ball", "bench", "farm system", "front office", "comeback", "collapse",
    "slump", "hot streak", "infield fly", "seventh inning stretch", "bobblehead", "nacho", "rain check", "dugout",
    "blooper", "moonshot", "walk-off", "screwball", "ballpark", "scandal", "prophecy",
  ],
  verb: [
    "bunt", "choke", "rally", "steal home", "pray", "panic", "hit .400", "throw a no-hitter", "moonwalk", "dance",
    "cry", "sweat", "eat 40 hot dogs", "pitch", "catch", "run", "slide", "scheme", "win", "lose", "tank", "hustle",
    "hide", "dig in", "flip the bat", "spit", "nap", "dial up", "log on", "squeeze", "walk off", "beat the shift",
    "argue", "get ejected", "salsa dance", "juggle", "whistle", "yodel", "hit for the cycle", "frame a pitch",
    "rob a homer", "turn two", "check the swing", "go yard", "warm up", "retire", "unretire", "read the BBS",
    "sign autographs", "lift weights", "do the wave", "eat sunflower seeds", "hold the runner", "tip his cap",
  ],
  incident: [
    "the incident", "the hot dog thing", "the eel charges", "the Y2K bug", "the great pigeon strike",
    "the organ meltdown", "the bat dog walkout", "the tarp disaster", "Nickel Beer Night",
  ],
  exclamation: [
    "Wowee", "Holy cow", "Yikes", "Booyah", "Good grief", "Shazam", "Zoinks", "Sweet", "Whoa", "Cowabunga", "Egads",
    "Great Scott", "Jeepers", "Heavens", "Golly", "Hooray", "Boo", "Huzzah", "Yowza", "Oh snap", "As if", "Psych",
    "Word up", "Dang", "Rats", "Phooey", "Ugh", "Hoo boy", "Mamma mia", "Kaboom", "Yeehaw", "Bingo", "Eureka",
    "Gadzooks", "All right", "Yippee", "Oof", "Not", "Whoopsie", "Stee-rike", "Hot diggity", "Sheesh",
  ],
  emote: [
    ":)", ":(", ";)", ":P", ":D", "XD", "<3", "o_O", "^_^", "T_T", ">:(", ":-O", "8)", "B-)", "*rolls eyes*",
    "*shrug*", "*sigh*", "*clap clap*", "lol", ":-)", "rofl", "haha", "hehe", "!!!", "???", "^^;", "\\o/",
    "*wink*", "brb", "afk", "w00t", "*dances*", ":-/", "-_-", "(-_-)zzz", "<3 <3 <3", ">_<", "*spits*",
    ":^)", "=)",
  ],
  item: [
    "hot dog", "rosin bag", "laser pointer", "rally cap", "fake mustache", "beanbag animal", "pager", "floppy disk",
    "foam finger", "eel", "slap bracelet", "virtual pet", "disposable camera", "cassette", "VHS tape",
    "walkie-talkie", "lucky sock", "cursed bat", "rubber chicken", "briefcase of cash", "bucket of balls",
    "lawn chair", "megaphone", "trench coat", "bowling ball", "whoopee cushion", "ham sandwich", "glove",
    "lucky penny", "rabbit's foot", "garden gnome", "crystal ball", "bingo card", "parrot", "trophy", "pizza",
    "fax machine", "jar of pickles", "kazoo", "squirt gun", "tuba", "map", "toupee", "monocle", "raccoon trap",
    "pocket protector", "CD-ROM", "mood ring", "fanny pack", "lava lamp",
  ],
  number: [
    "zero", "one", "two", "3", "7", "12", "40", "99", "100", "1,000", "a million", "eleventy", "a dozen", "a bajillion",
    "nine", "42", "13", "500", "a few", "infinity", "two and a half", "1999", "56", "61", "755", "4",
  ],
  time: [
    "tonight", "tomorrow", "next season", "by Day 40", "in the 9th", "before Y2K", "in 1999", "next Tuesday",
    "after the stretch", "someday", "never", "this week", "by the break", "at midnight", "on opening day",
    "in a fortnight", "when pigs fly", "in extra innings", "after the rain delay", "by October", "right now",
    "yesterday", "during the anthem", "in the year 2000", "on bingo night", "after nap time", "eventually",
    "before lunch", "next millennium", "when the modem connects",
  ],
  place: [
    "the bus station", "the bowling alley", "the dog track", "Hot Dog Hal's", "the bullpen", "church bingo",
    "the docks", "the food court", "a chat room", "the arcade", "the laundromat", "the drive-in", "the pool hall",
    "the racetrack", "the bait shop", "the steel mill", "the parking lot", "the clubhouse", "the press box",
    "the confessional", "the video store", "the roller rink", "the courthouse", "the county fair", "the buffet",
    "the BBS", "the mall", "the car wash", "the bleachers", "the batting cage", "the pawn shop", "the diner",
    "the skating pond", "the night market", "the train yard", "the radio station",
  ],
};

/** Readable phrases for the sim's incident kinds; unknown kinds fall back to a humanized key. */
export const INCIDENT_PHRASES: Record<string, string> = {
  RACCOONS_BULLPEN: "the bullpen raccoons",
  RACCOON_ON_FIELD: "the raccoon on the field",
  FOOD_POISONING: "the food poisoning",
  FAN_ON_FIELD: "the fan on the field",
  LASER_POINTER: "the laser pointer",
  RAIN_DELAY: "the rain delay",
  EJECTION: "the ejection",
  BRAWL: "the brawl",
  BALL_TAMPERING: "the ball tampering",
  BLACKOUT: "the blackout",
};
