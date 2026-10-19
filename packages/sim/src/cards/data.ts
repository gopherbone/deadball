// Static card data: set names, rarities, print runs, misprints, packs.

export type Rarity = "common" | "uncommon" | "rare" | "gilded" | "misprint" | "original";
export const RARITIES: readonly Rarity[] = ["common", "uncommon", "rare", "gilded", "misprint", "original"];
export const RARITY_LABEL: Record<Rarity, string> = {
  common: "Common", uncommon: "Uncommon", rare: "Rare", gilded: "Gilded", misprint: "Misprint", original: "Original",
};

/** Rarities that are serial-numbered, and how many of each card exist. */
export const PRINT_RUNS: Partial<Record<Rarity, number>> = { gilded: 50, misprint: 25, original: 1 };

/** If a numbered print run is sold out, the pull falls back to this rarity. */
export const SOLD_OUT_FALLBACK: Partial<Record<Rarity, Rarity>> = { original: "gilded", gilded: "rare", misprint: "uncommon" };

export type CardKind = "player" | "prospect" | "manager" | "umpire" | "owner" | "figure" | "moment";

export const SET_NAMES = [
  "Smoke & Mirrors", "Raccoon Season", "The Great Swindle", "Hot Dogs & Hot Tempers", "Under the Table",
  "Rain Check", "The Long Con", "Pennant Fever", "Dial-Up Dynasty", "Allegedly", "Foul Territory", "Grease Fire",
  "The Bullpen Papers", "Box Score Babylon", "Nickel Beer Night", "Extra Innings", "Spitball Summer", "Laser Show",
  "Off the Books", "Y2K Compliant",
];

export interface MisprintDef { id: string; label: string; blurb: string; mult: number }
export const MISPRINTS: MisprintDef[] = [
  { id: "wrong-name", label: "Wrong Name", blurb: "Printed with somebody else's name.", mult: 1.2 },
  { id: "upside-down", label: "Upside-Down Photo", blurb: "Photo printed upside down.", mult: 1.25 },
  { id: "raccoon-photobomb", label: "Raccoon Photobomb", blurb: "A raccoon is in the photo. Nobody noticed.", mult: 1.5 },
  { id: "no-ink", label: "Missing Ink", blurb: "The press ran dry halfway.", mult: 1.1 },
  { id: "double-print", label: "Double Print", blurb: "Ghosted twice, like his ex.", mult: 1.15 },
  { id: "wrong-team", label: "Wrong Team", blurb: "Captioned with a rival club.", mult: 1.1 },
  { id: "batboy", label: "Batboy Photo", blurb: "That's the batboy. He is thrilled.", mult: 1.3 },
  { id: "printers-thumb", label: "Printer's Thumb", blurb: "A giant thumbprint. Probably Earl's.", mult: 1.1 },
  { id: "ham-stain", label: "Ham Stain", blurb: "Smells faintly of ham. Authenticated.", mult: 1.2 },
  { id: "stats-typo", label: "Stats Typo", blurb: "The back lists a batting average of 9.999.", mult: 1.15 },
  { id: "mirrored", label: "Mirrored", blurb: "Printed backwards. Lefties are righties now.", mult: 1.2 },
  { id: "blank-back", label: "Blank Back", blurb: "The printer ran out of words.", mult: 1.25 },
];

export interface OriginalDef { id: string; label: string; mult: number }
export const ORIGINAL_FLAIRS: OriginalDef[] = [
  { id: "hand-tinted", label: "Hand-Tinted Proof", mult: 1.2 },
  { id: "signed", label: "Signed (Smudged)", mult: 1.4 },
  { id: "printers-proof", label: "Printer's Proof", mult: 1.0 },
  { id: "test-stock", label: "Test Stock", mult: 1.1 },
  { id: "gold-leaf", label: "Real Gold Leaf (Maybe)", mult: 1.3 },
];

export interface PackDef {
  kind: string;
  name: string;
  price: number;
  count: number;
  /** Per-card rarity odds (sum to 1). */
  odds: Record<Rarity, number>;
  blurb: string;
  /** The last card in the pack is at least this rarity. */
  guarantee?: Rarity;
  /** Relative pull weights by card kind. */
  kinds: Record<CardKind, number>;
  /** Only Major League player cards (the starter pack). */
  mlOnly?: boolean;
  /** Chance each slot is drawn from the Moments pool (when the set has any). */
  momentShare?: number;
}

const BASE_KINDS: Record<CardKind, number> = { player: 1, prospect: 0.6, manager: 0.35, umpire: 0.35, owner: 0.25, figure: 0.25, moment: 0.3 };

export const PACK_DEFS: PackDef[] = [
  {
    kind: "wax", name: "Wax Pack", price: 50, count: 5, guarantee: "uncommon",
    blurb: "Five cards and a stick of gum older than you.",
    odds: { common: 0.70, uncommon: 0.21, rare: 0.065, gilded: 0.016, misprint: 0.008, original: 0.001 },
    kinds: BASE_KINDS,
  },
  {
    kind: "cigar", name: "Cigar Box", price: 250, count: 10, guarantee: "rare",
    blurb: "Ten cards in a real cigar box. Do not smoke the cards.",
    odds: { common: 0.48, uncommon: 0.30, rare: 0.15, gilded: 0.045, misprint: 0.02, original: 0.005 },
    kinds: BASE_KINDS,
  },
  {
    kind: "starter", name: "Starter", price: 0, count: 8,
    blurb: "Free for new members. Eight commons, zero dignity.",
    odds: { common: 1, uncommon: 0, rare: 0, gilded: 0, misprint: 0, original: 0 },
    kinds: { player: 1, prospect: 0, manager: 0, umpire: 0, owner: 0, figure: 0, moment: 0 }, mlOnly: true,
  },
  {
    kind: "scandal", name: "Scandal Pack", price: 120, count: 6, guarantee: "uncommon",
    blurb: "Six cards, mostly Moments. Ripped from the headlines.",
    odds: { common: 0.55, uncommon: 0.26, rare: 0.12, gilded: 0.035, misprint: 0.03, original: 0.005 },
    kinds: { player: 0.5, prospect: 0.1, manager: 0.3, umpire: 0.4, owner: 0.5, figure: 0.6, moment: 1 }, momentShare: 0.6,
  },
];

export const MAX_MOMENTS = 16;

// --- redeemable cards ----------------------------------------------------------------
/** Gilded prints of players whose serial is a multiple of this carry BOOST (1 in 5: #5, #10 ... #50). */
export const GILDED_REDEEM_EVERY = 5;
export const GILDED_BOOST = { boost: 12, days: 7 };
export const ORIGINAL_BOOST = { boost: 20, days: 15 };
/** Share of player Originals printed with RETIRE instead of BOOST (staff Originals are always RETIRE). */
export const ORIGINAL_RETIRE_SHARE = 0.4;
/** Remaining cards of a player retired by redemption ("Final Season" editions) are worth this much more. */
export const FINAL_SEASON_MULT = 2.5;

export const MOMENT_TITLES: Record<string, string> = {
  RACCOONS_BULLPEN: "Night of the Raccoons",
  RACCOON_ON_FIELD: "Rally Raccoon",
  FOOD_POISONING: "Bad Clams",
  FAN_ON_FIELD: "Fan on the Field",
  LASER_POINTER: "Seeing Red Dots",
  RAIN_DELAY: "The Long Wait",
  EJECTION: "Thrown Out!",
  BRAWL: "Benches Clear",
  BALL_TAMPERING: "Doctored",
  BLACKOUT: "Lights Out",
  FEUD: "Bad Blood",
  SCANDAL: "Front Page",
};

export const MOMENT_BLURBS: Record<string, string[]> = {
  RACCOONS_BULLPEN: ["Raccoons took the bullpen. The bullpen did not take it back.", "Three relievers, one raccoon, zero survivors (of dignity)."],
  RACCOON_ON_FIELD: ["A raccoon ran the bases. Better OBP than the leadoff man.", "Play stopped for a raccoon. The raccoon did not stop."],
  FOOD_POISONING: ["The clubhouse clams were a bad idea, in hindsight.", "Half the lineup spent the 5th inning indisposed."],
  FAN_ON_FIELD: ["A fan ran onto the field. Security ran slower.", "One fan, one dream, one very long tackle."],
  LASER_POINTER: ["A red dot found the batter's eyes. The league found nobody.", "Someone in the bleachers has a laser and a grudge."],
  RAIN_DELAY: ["It rained. Then it rained more. The tarp crew wept.", "Four hours of rain. The organist played everything twice."],
  EJECTION: ["Words were exchanged. Most of them were not printable.", "The ump threw him out. He threw a base. Fair trade."],
  BRAWL: ["Benches cleared. A hot dog vendor got a few licks in.", "A brawl so big the bullpens jogged in late just to watch."],
  BALL_TAMPERING: ["The baseball came back sticky and smelling of pine tar.", "The ball had a thumbtack in it. Nobody knows anything."],
  BLACKOUT: ["The lights went out. When they came on, second base was gone.", "Total blackout. Volta Power & Light declined to comment."],
  FEUD: ["Two grown men, one grudge, zero chill.", "This beef is older than the ballpark."],
  SCANDAL: ["It was in every paper. Twice in some.", "A scandal so juicy SportsWire ran it above the box scores."],
};
