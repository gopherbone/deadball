// Core data model. Ratings use the 20–80 scouting scale (50 = league average).

export type Hand = "L" | "R";
export type BatHand = Hand | "S";
export type Pos = "P" | "C" | "1B" | "2B" | "3B" | "SS" | "LF" | "CF" | "RF" | "DH";
export const FIELD_POSITIONS: readonly Pos[] = ["P", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF"];

/** Continental levels ML > AA > B > D, plus "EL": the Enhanced League out in the desert (its own circuit). */
export type Level = "ML" | "AA" | "B" | "D" | "EL";
/** The Continental levels (the Enhanced League is separate: see ENHANCED). */
export const LEVELS: readonly Level[] = ["ML", "AA", "B", "D"];
export const ENHANCED: Level = "EL";
export const ALL_LEVELS: readonly Level[] = ["ML", "AA", "B", "D", "EL"];

export type PitchKind = "FB" | "SI" | "CT" | "SL" | "CB" | "CH" | "SPL" | "KN" | "SPIT";

export interface Pitch {
  kind: PitchKind;
  /** 20–80: how hard this pitch is to square up / whiff-inducing. */
  quality: number;
  /** Average velocity in mph. */
  velo: number;
  /** Relative selection weight. */
  usage: number;
}

export interface BattingRatings {
  contact: number;   // ability to make contact (whiff avoidance)
  power: number;     // exit velocity
  eye: number;       // plate discipline (chase rate)
  gap: number;       // line-drive / doubles tendency
  lift: number;      // launch angle tendency (high = fly balls)
  pull: number;      // pull tendency
  speed: number;     // home-to-first, base-to-base
  baserunning: number; // reads, aggression quality
  vsL: number;       // platoon adjustment (-10..+10) vs LHP
}

export interface FieldingRatings {
  range: number;
  hands: number;     // catching / clean fielding
  arm: number;       // throw strength
  accuracy: number;  // throwing errors
  reaction: number;  // first step / jump
  framing: number;   // catchers only, otherwise 50
  /** Positional familiarity, 0..1. */
  positions: Partial<Record<Pos, number>>;
}

export interface PitchingRatings {
  stuff: number;     // overall bat-missing
  control: number;   // zone rate / walks
  command: number;   // hitting spots, avoiding the middle (hard contact)
  movement: number;  // weak contact / HR suppression
  stamina: number;   // pitch count capacity
  groundball: number; // 20 = fly ball pitcher, 80 = sinkerballer
  hold: number;      // holding runners
  pitches: Pitch[];
}

export type Trait =
  | "HOTHEAD" | "LOYAL" | "SUPERSTITIOUS" | "GAMBLER" | "DRUNK" | "CLUTCH" | "CHOKER"
  | "GREEDY" | "PIOUS" | "SHOWBOAT" | "GRINDER" | "LAZY" | "PARANOID" | "IRON_MAN"
  | "FRAGILE" | "CHARMING" | "CROOKED" | "SNITCH";

export type Sex = "M" | "F";

/**
 * Behaviour quirks beyond the core Trait set (kept separate so exhaustive Trait maps elsewhere
 * stay valid). The last group are "weird tier" marks.
 */
export type Quirk =
  | "VAIN" | "JEALOUS" | "CHARITABLE" | "LONER" | "PRANKSTER"
  | "GLOWS" | "KNOWS_THINGS" | "NO_SHADOW" | "SPEAKS_TO_BIRDS" | "RESURRECTED" | "CLONE" | "TIME_DISPLACED";

export type GoalKind =
  | "win_title" | "big_contract" | "make_majors" | "revenge" | "beat_record" | "become_manager" | "marry"
  | "get_out" | "buy_club" | "be_famous" | "comeback" | "keep_job";
export interface Goal {
  kind: GoalKind;
  /** Person, team or record the goal is about. */
  target?: string;
  since: number;
  /** 1 = idle wish, 2 = driven, 3 = obsessed. */
  intensity: number;
  /** Seasons it has gone unmet. */
  misses?: number;
  note?: string;
}

export type FearKind = "aging" | "being_traded" | "flying" | "the_dark" | "failure" | "pitcher" | "birds" | "crowds" | "the_press" | "injury" | "ghosts";
export interface Fear { kind: FearKind; target?: string; /** 1..3 */ strength: number }

export type ConcernKind =
  | "sick_kid" | "sick_parent" | "debt" | "feud" | "contract_year" | "slump" | "grieving" | "injured_friend" | "newborn"
  | "divorce" | "secret_affair" | "hot_seat" | "trade_rumours" | "stalker" | "comeback" | "missing_time" | "hazing"
  | "curse" | "fame" | "holdout" | "shaving" | "marriage" | "mourning";
/** Something on a person's mind right now. */
export interface Concern {
  kind: ConcernKind;
  about?: string;
  since: number;
  /** world.day it stops weighing on them. */
  until: number;
  /** Mood pressure (-5..+5). */
  weight: number;
  storyline?: string;
  note?: string;
}

export interface Person {
  id: string;
  first: string;
  last: string;
  nickname?: string;
  /** Face-bank id: maps to a set of public-domain photos of one real person. */
  face: string;
  /** Players are always "M"; NPCs can be either. */
  sex: Sex;
  age: number;
  /** In-game calendar year of birth (age = world.year - born, give or take the birthday). */
  born?: number;
  /** Latent baseball talent (20–80) passed on to children. */
  talent?: number;
  /** Résumé of a former player (set when a player retires and becomes an NPC). */
  career?: CareerSummary;
  /** 0–100 popularity. Drives media attention, card value, scandal and affair odds. */
  fame?: number;
  quirks?: Quirk[];
  goals?: Goal[];
  fears?: Fear[];
  /** What's on their mind (comes and goes with events). */
  concerns?: Concern[];
  /** A recognisable long-dead historical figure, somehow playing ball. */
  historical?: { figure: string; era?: string };
  /** Id of the person this one is a clone of. */
  cloneOf?: string;
  traits: Trait[];
  /** -5..+5 day-to-day mood. */
  mood: number;
  family: Family;
  /** False once retired from baseball life or deceased. */
  active: boolean;
  dead?: boolean;
  /** Year of death, if dead. */
  died?: number;
}

export interface CareerSummary {
  pos: Pos;
  /** Years active as a player. */
  from: number;
  to: number;
  /** Major-league games played, seasons and clubs (ML team ids). */
  mlGames: number;
  mlSeasons: number;
  teams: string[];
  /** Best overall rating reached (20–80). */
  peak: number;
  /** Highlights for text generation: "3x champion", "1999 MVP". */
  honors: string[];
}

/** Crusader Kings-style family ties. Ids may point at players or NPCs. */
export interface Family {
  /** Surname line, e.g. "Dunphy". Children inherit the father's or mother's house. */
  house: string;
  parents: string[];
  spouse?: string;
  children: string[];
  /** Former spouses (divorced or widowed), most recent last. */
  exSpouses?: string[];
  /** Ongoing personal situations that colour mood and performance. */
  drama: Drama[];
}

export interface Drama {
  kind: "newborn" | "divorce" | "illness_in_family" | "affair" | "feud" | "debt" | "scandal" | "wedding" | "bereavement" | "holdout";
  with?: string;
  /** Game day it started; drama fades over time. */
  since: number;
  /** Mood pressure while active (-5..+5). */
  weight: number;
  /** Game days until it has fully faded (default by kind). */
  days?: number;
  /** Free text for news, e.g. "owes Bobby $700". */
  note?: string;
}

export interface Injury {
  kind: string;
  daysLeft: number;
}

export interface Player extends Person {
  kind: "player";
  bats: BatHand;
  throws: Hand;
  pos: Pos;
  teamId: string;
  batting: BattingRatings;
  fielding: FieldingRatings;
  pitching?: PitchingRatings;
  /** 20–80 ceiling for development. */
  potential: number;
  /** Rest tracking for pitchers: pitches thrown on recent days. */
  recentPitches: number[];
  injury?: Injury;
  /** Simple contract: years left (incl. the current season) and salary in $k/yr. */
  contract?: { years: number; salary: number };
  /** How he entered the league. */
  draft?: { year: number; round: number; pick: number; teamId: string };
  /** First major-league game. */
  debut?: { year: number; season: number; teamId: string; gameId: string };
  /** Best overall rating reached so far. */
  peak?: number;
  /** world.day of his last trade (clubs don't flip a man straight back). */
  tradedDay?: number;
  /** Recent form, an exponential average of game scores (≈ -2..+2, 0 = average). */
  form?: number;
  /** Enhanced powers (Ultra-style; see powers.ts). Normal leagues have none. */
  powers?: import("./powers.ts").Power[];
}

/** Free agents carry this teamId. */
export const FREE_AGENT = "FA";

export type Role = "owner" | "manager" | "umpire" | "crew" | "fixer" | "reporter" | "official" | "citizen" | "coach" | "scout" | "gm";

export interface Npc extends Person {
  kind: "npc";
  role: Role;
  factionId?: string;
  /** Freeform role-specific numbers, e.g. umpire zone width. */
  stats: Record<string, number>;
  /** What they do all day, for flavour: "barkeep", "town drunk", "insurance man". */
  occupation?: string;
}

export interface Umpire extends Npc {
  role: "umpire";
  stats: {
    zoneWidth: number;    // 20–80, wide zone = more called strikes on the edges
    consistency: number;  // 20–80
    temper: number;       // ejection propensity
    corruptible: number;  // bribe receptiveness
    /** 1 = major-league crew, 0 = minor leagues. */
    ml?: number;
  };
}

export interface Park {
  id: string;
  name: string;
  /** Wall distance in feet at spray angles -45 (LF line), -22.5, 0 (CF), 22.5, 45 (RF line). */
  fences: [number, number, number, number, number];
  walls: [number, number, number, number, number];
  altitudeFt: number;
  foulTerritory: number; // 20–80: big foul ground turns more pops into outs
  turf: boolean;
  /** Local climate: temperature shift (°F) and rain multiplier (desert parks: hot and dry). */
  climate?: { temp: number; rain: number };
  /** Flavour for the venue page. */
  note?: string;
}

export interface Weather {
  tempF: number;
  /** Wind toward this spray angle (deg, 0 = blowing out to CF), mph. */
  windDir: number;
  windMph: number;
  rain: number; // 0..1 chance-ish of delay
}

export interface Team {
  id: string;
  city: string;
  name: string;
  abbr: string;
  level: Level;
  parentId?: string; // the ML club for farm teams
  factionId: string;
  parkId: string;
  managerId: string;
  roster: string[]; // player ids (the active 26)
  /** Injured list: players under contract but off the active roster. */
  il?: string[];
  /** General manager (ML clubs). */
  gmId?: string;
  /** "enhanced" for Enhanced League clubs (level "EL"). */
  circuit?: "continental" | "enhanced";
}

export type FactionKind = "owner" | "church" | "trust" | "union" | "press" | "bookies" | "commissioner" | "umpires" | "crew" | "mob";

export interface Faction {
  id: string;
  name: string;
  kind: FactionKind;
  leaderId?: string;
  /** Ideology/flavour words used by text generation. */
  wants: string[];
}

export type RelKind = "friend" | "rival" | "mentor" | "lover" | "ex" | "family" | "grudge" | "hates_team" | "owes" | "faction" | "clone";

export interface Relationship {
  a: string; // person or faction id
  b: string;
  value: number; // -5..+5
  reason: string;
  /** What sort of tie (absent on old/plain entries). */
  kind?: RelKind;
  /** world.day it was formed or last changed. */
  since?: number;
}

export type StorylineKind =
  | "affair" | "feud" | "marriage_trouble" | "hot_seat" | "holdout" | "gambling_debt" | "slump" | "comeback"
  | "contract_year" | "rivalry" | "rookie_watch" | "stalker" | "curse" | "weird"
  /** An unexplained player (powers, clone, resurrected, historical) still in the Continental league. */
  | "enhanced_watch";

/** A drama arc with a beginning, escalation and a resolution; rumoured/public ones are bettable. */
export interface Storyline {
  id: string;
  kind: StorylineKind;
  people: string[];
  teams: string[];
  startedDay: number;
  season: number;
  visibility: "secret" | "rumoured" | "public";
  /** Kind-specific stage, e.g. affair "ongoing", gambling_debt "owes" → "leaned_on" → "shaving". */
  stage: string;
  /** world.day it first became rumoured or public (anchors prop questions). */
  bettableDay?: number;
  /** Outside pressure (crew ops, press). Multiplies hazards; decays daily. */
  nudges: { expose: number; inflame: number; soothe: number };
  data: Record<string, unknown>;
  /** Stage/visibility changes with the LifeEvent that announced them. */
  log: { day: number; stage: string; visibility: Storyline["visibility"]; eventId?: string }[];
  resolved?: { day: number; outcome: string; eventId: string };
}

/** A pari-mutuel prop question on a storyline. Days are world.day numbers. */
export interface PropQuestion {
  id: string;
  storylineId: string;
  question: string;
  type: "yesno" | "buckets";
  options: { key: string; label: string }[];
  /** Betting closes at the end of this world.day. */
  closesDay: number;
  /** The question settles no later than this world.day (or season end for "this season" buckets). */
  resolveBy: number;
}

/** A family line (Crusader Kings "dynasty"). Keyed by id; `name` is the surname. */
export interface House {
  id: string;
  name: string;
  /** Running prestige score: stars, titles and honours raise it, scandals lower it. */
  reputation: number;
  founded: number;
  founderId?: string;
  /** Championships won by members. */
  titles: number;
  /** Players the house has produced. */
  players: number;
}

export interface BatTotals {
  g: number; pa: number; ab: number; r: number; h: number; d: number; t: number; hr: number;
  rbi: number; bb: number; k: number; sb: number; cs: number; hbp: number; sf: number;
}
export interface PitchTotals {
  g: number; gs: number; w: number; l: number; sv: number; outs: number; h: number; r: number; er: number;
  bb: number; k: number; hr: number; hbp: number; bf: number; pitches: number;
}
export interface StatLine { bat?: BatTotals; pitch?: PitchTotals }
/** One player's season. `bat`/`pitch` are totals over every level he played at. */
export interface SeasonStats extends StatLine {
  /** Last team he played for and the highest level reached. */
  teamId: string;
  level: Level;
  /** Per-level split (only kept after the season if he played at more than one level). */
  byLevel?: Partial<Record<Level, StatLine>>;
  /** Postseason (Continental playoffs), kept apart from the regular-season totals. */
  post?: StatLine;
}

/** Dead or departed people, kept small so family trees and old box scores still resolve. */
export interface ArchivedPerson extends Person {
  kind: "player" | "npc";
  role?: Role;
  occupation?: string;
  gone: "dead" | "moved";
  goneYear: number;
}

export interface SeasonHistory {
  season: number;
  year: number;
  champion?: string;
  runnerUp?: string;
  /** "4-2" */
  finalScore?: string;
  /** Final ML standings [teamId, w, l]. */
  standings: [string, number, number][];
  /** Best record per farm level. */
  pennants: Partial<Record<Level, string>>;
  awards: { mvp?: string; pitcher?: string; rookie?: string };
  /** Short stat blurbs keyed by award, e.g. ".322, 41 HR, 118 RBI". */
  awardLines: Record<string, string>;
  leaders: Record<string, [string, number] | undefined>;
  /** Notable things that happened, scored for the history book. */
  headlines: { kind: string; text: string; weight: number; who?: string[] }[];
  /** The Enhanced League's season. */
  enhanced?: { champion?: string; runnerUp?: string; finalScore?: string; standings: [string, number, number][]; mvp?: string; mvpLine?: string };
}

/** Background (non-baseball) world effects, e.g. a fad or a strike. */
export interface WorldEffect {
  id: string;
  kind: string;
  title: string;
  /** Game day it began and ends (world.day). */
  from: number;
  until: number;
  /** Multipliers (1 = neutral) and additive mood/temperature shifts. */
  cardDemand?: number;
  attendance?: number;
  economy?: number;
  mood?: number;
  rain?: number;
  tempF?: number;
  /** Restrict attendance/mood effects to one club or city. */
  teamId?: string;
  factionId?: string;
}

export interface World {
  season: number;
  day: number;
  /** In-game calendar year (season 1 = 1996); people age on it. */
  year: number;
  factions: Record<string, Faction>;
  teams: Record<string, Team>;
  players: Record<string, Player>;
  npcs: Record<string, Npc>;
  parks: Record<string, Park>;
  relationships: Relationship[];
  /** world.stats[personId][season] */
  stats: Record<string, Record<number, SeasonStats>>;
  houses: Record<string, House>;
  /** Player ids without a club (their teamId is FREE_AGENT). */
  freeAgents: string[];
  /** Dead and departed people. */
  archive: Record<string, ArchivedPerson>;
  history: SeasonHistory[];
  /** Active background effects (fads, strikes, weather streaks). */
  effects: WorldEffect[];
  /** Id counters for deterministic id generation. */
  seq: Record<string, number>;
  /** Major-league average ratings captured at world creation; development is re-centred on them each winter. */
  norms: Record<string, number>;
  /** Drama arcs, open and recently resolved. */
  storylines: Storyline[];
}
