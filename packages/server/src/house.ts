// Bobby's regulars: house (NPC) money in every open pool, so a pool is never empty and the
// board looks alive. docs/API.md "House money", docs/DESIGN.md "Economy".
//
// - The regulars' stakes are minted: they come from no account and never touch `accounts` or
//   `ledger`. They live as wave schedules on the pool row (games.house / props.house) and are
//   counted once a wave's time has come (`visible`).
// - Each pool gets a baseline scaled by prominence (playoffs, Enhanced League, rivalries, juicy
//   storylines), split between sides by a fair-ish public estimate, bent by "square" bias and
//   noise, with a "sharp" share that grows in the later waves.
// - Settlement is pari-mutuel over the combined pool (`settleMath`). The house cut is taken on
//   player money only (HOUSE.npcCut = 0); winnings on house stakes are burned. House money lost
//   to winning players is the economy injection.
// - Prop seeding sees only `PublicStory` (kind, public stage, visibility, days on the board):
//   never nudges, hidden stages or storyline data, so the pools can't leak a secret.
//
// Every number worth tuning is in HOUSE. scripts/economy.ts simulates a season with it.

import { Rng, buildStaff, pickStarter, STORYLINE_KINDS, type Player, type Storyline, type World } from "./sim.ts";

export const HOUSE = {
  /** House cut on player money (unchanged). */
  cut: 0.1,
  /** House cut on the regulars' own money. 0: Bobby doesn't rake his regulars. */
  npcCut: 0,
  /** Every option of a pool gets at least this much house money (so somebody always backed the winner). */
  minOption: 5,
  game: {
    /** Total house money per regular-season Continental game, over all waves. */
    base: 1200,
    /** Prominence multipliers (they stack). */
    enhanced: 1.25,
    exhibition: 1.5,
    playoff: 2.2,
    /** Extra on top of `playoff` for the final round. */
    final: 1.5,
    /** A public rivalry or feud between the two clubs. */
    rivalry: 1.4,
    /** ± spread of the per-game size. */
    sizeJitter: 0.15,
    /**
     * Waves: `at` is the fraction of the pre-game window (dayStart -> first pitch) still to go when
     * the wave lands (1 = at day start), `share` its part of the total, `sharp` the part of the wave
     * bet by sharps (fair estimate, little noise) rather than squares.
     */
    waves: [
      { at: 1.0, share: 0.4, sharp: 0.1 },
      { at: 0.5, share: 0.35, sharp: 0.3 },
      { at: 0.1, share: 0.25, sharp: 0.6 },
    ],
    /** Squares overreact to the favourite: their logit is the fair one times (1 + this). */
    favOverreact: 0.35,
    /** Squares like the home team (logit). */
    homeBias: 0.15,
    /** Squares chase streaks: logit per game of streak difference, capped. */
    streakBias: 0.04,
    streakCap: 5,
    /** Crowd sentiment per game (logit sd), shared by every square wave of that game. */
    crowdNoise: 0.2,
    /** Extra per-wave jitter (logit sd). */
    waveNoise: 0.08,
    /** Sharps' noise (logit sd). */
    sharpNoise: 0.08,
  },
  prop: {
    /** Total house money per question kind over its whole betting window. */
    base: { yes: 1200, when: 1000, how: 1200 } as Record<string, number>,
    /** Share of a question's money that lands on its first day (the rest spread over the remaining days). */
    firstDay: 0.6,
    /** Juicy storylines get more. Unlisted kinds: 1. */
    kind: {
      affair: 1.6, gambling_debt: 1.5, enhanced_watch: 1.4, feud: 1.3, marriage_trouble: 1.3, weird: 1.3, hot_seat: 1.2, stalker: 1.2,
      curse: 1.0, rivalry: 1.0, holdout: 0.9, comeback: 0.8, slump: 0.7, contract_year: 0.6, rookie_watch: 0.6,
    } as Record<string, number>,
    /** Public (printed) storylines draw more money than rumoured ones. */
    public: 1.2,
    /** Stages the public reads as "about to blow" (more money, more drama bias). */
    hotStages: ["public_spat", "boiling", "hot", "separated", "leaned_on", "investigation"],
    hotStage: 1.3,
    /** Waves per world day the question is open: `at` = fraction into the day. */
    waves: [
      { at: 0.1, share: 0.55, sharp: 0.3 },
      { at: 0.6, share: 0.45, sharp: 0.6 },
    ],
    /** Squares overreact to drama: odds on the blow-up answers times (1 + this) (more on hot stages). */
    drama: 0.5,
    /** ... and expect it soon: odds on "≤5 days" times (1 + this). */
    soon: 0.3,
    /** Square noise per option (log-odds sd), per question. */
    noise: 0.25,
    sharpNoise: 0.1,
  },
  /** Fair game line: logistic over home-minus-away public form (fitted on simulated seasons, scripts/economy.ts --fit). */
  line: { home: 0.03, bat: 0.09, sp: 0.022, pen: 0, pyth: 0.55, wp: 0.15 },
};

/** A house wave: lands `off` ms before the pool's anchor (games: first pitch; props: closing time). `a` is per option. */
export interface HouseWave { k: string; off: number; a: number[] }

const sig = (x: number) => 1 / (1 + Math.exp(-x));
const logit = (p: number) => Math.log(p / (1 - p));
const clamp = (x: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, x));
const avg = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 50);

// ------------------------------------------------------------------ pools

/** Parse a stored schedule (NULL / bad JSON = none). */
export function parseWaves(json: string | null | undefined): HouseWave[] {
  if (!json) return [];
  try {
    const v = JSON.parse(json);
    return Array.isArray(v) ? (v as HouseWave[]) : [];
  } catch {
    return [];
  }
}

/** House money per option that has landed by `now` (anchor - off <= now), times `scale`. */
export function visible(waves: HouseWave[], n: number, anchor: number, now: number, scale = 1): number[] {
  const out = new Array<number>(n).fill(0);
  if (scale <= 0) return out;
  for (const w of waves) if (anchor - w.off <= now) for (let i = 0; i < n; i++) out[i] += w.a[i] ?? 0;
  return scale === 1 ? out : out.map(x => Math.floor(x * scale));
}

/** What a pool pays per $1 on each option right now (0 = nobody on it). */
export function paysFor(player: number[], house: number[]): number[] {
  const net = netPool(player, house);
  return player.map((p, i) => (p + house[i] > 0 ? Math.floor((net * 100) / (p + house[i])) / 100 : 0));
}

const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0);
/** What the winners split: player money less the cut, plus the regulars' money less theirs. */
export const netPool = (player: number[], house: number[]) => Math.floor(sum(player) * (1 - HOUSE.cut) + sum(house) * (1 - HOUSE.npcCut));

export interface PoolSettlement {
  /** Everybody gets their stake back (no result, or nobody at all on the winner). */
  refund: boolean;
  /** Pool the winners split; each winning stake gets floor(stake * net / winPool). */
  net: number;
  winPool: number;
  /** Paid to the house's own winning stakes, i.e. burned. */
  burned: number;
  /** Player money paid back to players minus player money staked (the injection when positive). */
  playerNet: number;
  /** The house cut. */
  take: number;
}

/**
 * Pari-mutuel settlement of a mixed pool. `win` is the winning option's index (undefined: called off).
 * Refund rule: no result, or nobody (player or house) backed the winner. With house money on every
 * option the second case only happens with the house switched off.
 */
export function settleMath(player: number[], house: number[], win: number | undefined): PoolSettlement {
  const P = sum(player), H = sum(house);
  const winPool = win === undefined ? 0 : (player[win] ?? 0) + (house[win] ?? 0);
  if (win === undefined || winPool <= 0) return { refund: true, net: P, winPool: 0, burned: 0, playerNet: 0, take: 0 };
  const net = netPool(player, house);
  // integer division per bet, like the SQL; approximate the per-bet floors with one floor here
  const paid = Math.floor(((player[win] ?? 0) * net) / winPool);
  const burned = Math.floor(((house[win] ?? 0) * net) / winPool);
  return { refund: false, net, winPool, burned, playerNet: paid - P, take: P + H - net };
}

/** Make every option carry at least HOUSE.minOption over the whole schedule (added to the first wave). */
function floorOptions(waves: HouseWave[], n: number) {
  if (!waves.length) return waves;
  const tot = new Array<number>(n).fill(0);
  for (const w of waves) for (let i = 0; i < n; i++) tot[i] += w.a[i] ?? 0;
  for (let i = 0; i < n; i++) if (tot[i] < HOUSE.minOption) waves[0].a[i] = (waves[0].a[i] ?? 0) + HOUSE.minOption - tot[i];
  return waves;
}

/** Split `amount` by shares into whole dollars that add up. */
function split(amount: number, shares: number[]): number[] {
  const t = sum(shares) || 1;
  const raw = shares.map(s => (amount * s) / t);
  const out = raw.map(Math.floor);
  let left = Math.round(amount) - sum(out);
  const order = raw.map((r, i) => [r - Math.floor(r), i] as const).sort((a, b) => b[0] - a[0]);
  for (let j = 0; left > 0 && j < order.length; j++, left--) out[order[j][1]]++;
  return out;
}

// ------------------------------------------------------------------ games

function overall(p: Player): number {
  if (p.pitching) {
    const r = p.pitching;
    return avg([r.stuff, r.stuff, r.control, r.command, r.movement]);
  }
  const b = p.batting, f = p.fielding;
  return avg([b.contact, b.contact, b.power, b.power, b.eye, b.gap, b.speed, (f.range + f.hands + f.arm + f.reaction) / 4]);
}

/** Season record as the standings show it. */
export interface TeamRecord { w: number; l: number; rs: number; ra: number; streak?: string }

/** Public form of a club: lineup, probable starter, bullpen, run differential, record, streak. */
export function teamForm(world: World, teamId: string, starterId: string | undefined, rec: TeamRecord | undefined) {
  const team = world.teams[teamId];
  if (!team) return { bat: 50, sp: 50, pen: 50, pyth: 0, wp: 0, streak: 0 };
  const healthy = (p: Player | undefined): p is Player => !!p && !(p.injury && p.injury.daysLeft > 0);
  const roster = team.roster.map(id => world.players[id]).filter(healthy);
  const bat = avg(roster.filter(p => p.pos !== "P").map(overall).sort((a, b) => b - a).slice(0, 9));
  let sp = starterId ? world.players[starterId] : undefined;
  let pen: number[] = [];
  try {
    const staff = buildStaff(world, team);
    sp ??= pickStarter(staff);
    pen = [staff.closer, ...staff.setup, ...staff.middle].filter((p): p is Player => !!p).slice(0, 6).map(overall);
  } catch { /* no staff: league average */ }
  const gp = rec ? rec.w + rec.l : 0;
  const pyth = rec && rec.rs + rec.ra > 0 ? Math.log((rec.rs + 20) / (rec.ra + 20)) : 0;
  const wp = gp ? (rec!.w + 5) / (gp + 10) - 0.5 : 0;
  const m = rec?.streak?.match(/^([WL])(\d+)$/);
  const streak = m ? (m[1] === "W" ? 1 : -1) * Number(m[2]) : 0;
  return { bat, sp: sp?.pitching ? overall(sp) : 50, pen: avg(pen), pyth, wp, streak };
}

/** The fair-ish public chance the home team wins. */
export function fairHome(world: World, homeId: string, awayId: string, probables: { home?: string; away?: string }, table: Map<string, TeamRecord>): number {
  const h = teamForm(world, homeId, probables.home, table.get(homeId));
  const a = teamForm(world, awayId, probables.away, table.get(awayId));
  const L = HOUSE.line;
  const z = L.home + L.bat * (h.bat - a.bat) + L.sp * (h.sp - a.sp) + L.pen * (h.pen - a.pen) + L.pyth * (h.pyth - a.pyth) + L.wp * (h.wp - a.wp);
  return clamp(sig(z), 0.15, 0.85);
}

export interface GameFacts {
  id: string; level: string; homeId: string; awayId: string;
  exhibition?: boolean; playoff?: boolean; final?: boolean; rivalry?: boolean;
  /** Fair public chance of a home win. */
  pHome: number;
  /** Streak difference (home minus away, games; + = home on the hotter run). */
  streakDiff?: number;
}

/** Bettable games only (Continental ML incl. exhibitions, Enhanced League); farm games get nothing. */
export const bettableLevel = (level: string) => level === "ML" || level === "EL";

/** Public rivalry/feud storylines between two clubs. */
export function rivals(world: World, a: string, b: string): boolean {
  return (world.storylines ?? []).some(s => !s.resolved && s.visibility !== "secret" && (s.kind === "rivalry" || s.kind === "feud") && s.teams.includes(a) && s.teams.includes(b));
}

/** Total house money for a game (before waves). */
export function gameSize(f: GameFacts, rng: Rng): number {
  const G = HOUSE.game;
  if (!bettableLevel(f.level)) return 0;
  let m = 1;
  if (f.level === "EL") m *= G.enhanced;
  if (f.exhibition) m *= G.exhibition;
  if (f.playoff) m *= G.playoff * (f.final ? G.final : 1);
  if (f.rivalry) m *= G.rivalry;
  return G.base * m * (1 + rng.range(-G.sizeJitter, G.sizeJitter));
}

/**
 * The regulars' waves for a game: [home, away] per wave, `off` ms before first pitch.
 * Deterministic per (seed, game id). `preMs` is the pre-game window (dayStart -> first pitch).
 */
export function gameWaves(seed: string, f: GameFacts, preMs: number): HouseWave[] {
  const G = HOUSE.game;
  const rng = new Rng(`${seed}:house:${f.id}`);
  const total = gameSize(f, rng);
  if (total <= 0) return [];
  const fair = logit(clamp(f.pHome, 0.05, 0.95));
  const crowd = rng.normal(0, G.crowdNoise);
  const streak = clamp(f.streakDiff ?? 0, -G.streakCap, G.streakCap) * G.streakBias;
  const square = fair * (1 + G.favOverreact) + G.homeBias + streak + crowd;
  const waves = G.waves.map((w, i) => {
    const pSq = sig(square + rng.normal(0, G.waveNoise));
    const pSh = sig(fair + rng.normal(0, G.sharpNoise));
    const pH = (1 - w.sharp) * pSq + w.sharp * pSh;
    return { k: `w${i}`, off: Math.round(w.at * preMs), a: split(total * w.share, [pH, 1 - pH]) };
  });
  return floorOptions(waves, 2);
}

// ------------------------------------------------------------------ props

/** Everything the regulars may know about a storyline: what's printed or rumoured. */
export interface PublicStory {
  id: string; kind: string; stage: string; visibility: "rumoured" | "public"; bettableDay: number;
}

/** Public stage label key. Point shaving is a hidden stage: the public only knows he's being leaned on. */
export const publicStageKey = (s: Pick<Storyline, "stage">) => (s.stage === "shaving" ? "leaned_on" : s.stage);

/** The public projection of a storyline, or undefined for secret / not-yet-bettable ones. */
export function publicFacts(s: Storyline): PublicStory | undefined {
  if (s.visibility === "secret" || s.bettableDay === undefined) return undefined;
  return { id: s.id, kind: s.kind, stage: publicStageKey(s), visibility: s.visibility, bettableDay: s.bettableDay };
}

/**
 * The form guide: how each kind of story has tended to end, at the time its markets open
 * (counts from simulated seasons, scripts/economy.ts --priors). Public knowledge, not this story.
 */
export const PRIORS: Record<string, { yes: [number, number]; when: Record<string, number>; how: Record<string, number> }> = {
  affair: { yes: [40, 39], when: { d5: 12, d15: 23, d30: 22, later: 20 }, how: { discovered: 71, ended_quietly: 6 } },
  feud: { yes: [67, 346], when: { d5: 42, d15: 97, d30: 92, later: 174 }, how: { brawl: 152, reconciled: 100, traded: 74, fizzled: 47, death: 10 } },
  rivalry: { yes: [10, 210], when: { d5: 10, d15: 26, d30: 34, later: 150 }, how: { brawl: 28, buried_hatchet: 68, season_over: 115 } },
  marriage_trouble: { yes: [19, 97], when: { d5: 8, d15: 19, d30: 25, later: 64 }, how: { divorced: 39, reconciled: 69 } },
  slump: { yes: [59, 445], when: { d5: 51, d15: 158, d30: 112, later: 167 }, how: { broke_out: 239, demoted: 117, season_over: 122 } },
  rookie_watch: { yes: [4, 106], when: { d15: 4, d30: 9, later: 114 }, how: { rookie_of_year: 4, solid: 76, sent_down: 30 } },
  hot_seat: { yes: [5, 30], when: { d5: 4, d15: 3, d30: 8, later: 17 }, how: { fired: 21, survived: 11 } },
  curse: { yes: [13, 13], when: { d5: 9, d15: 7, d30: 4, later: 5 }, how: { lifted: 19, season_over: 6 } },
  gambling_debt: { yes: [8, 35], when: { d5: 2, d15: 5, d30: 10, later: 26 }, how: { exposed: 11, paid_off: 15, leg_broken: 10, went_to_commissioner: 2 } },
  contract_year: { yes: [186, 29], when: { later: 328 }, how: { "re-signed": 166, walked: 19, big_payday: 20, traded: 10 } },
  weird: { yes: [4, 8], when: { d5: 2, d15: 10 }, how: { returned_changed: 12 } },
  holdout: { yes: [1, 10], when: { d5: 2, d30: 5, later: 4 }, how: { signed: 10, traded: 1 } },
  enhanced_watch: { yes: [6, 19], when: { d5: 2, d15: 3, d30: 1, later: 19 }, how: { transferred: 14, retired: 1 } },
  stalker: { yes: [1, 2], when: { d15: 1, later: 2 }, how: { arrested: 3 } },
};
/** Pseudo-count added to every option (unseen endings still get a little money). */
const PRIOR_SMOOTH = 0.5;

/** Which answers count as the blow-up (squares overbet them). */
function dramatic(kind: string, qtype: string, key: string): boolean {
  if (qtype === "yes") return key === "yes";
  if (qtype === "when") return key === "d5" || key === "d15";
  const def = (STORYLINE_KINDS as Record<string, { hit: string[] } | undefined>)[kind];
  return key === "death" || !!def?.hit.includes(key);
}

export interface PropQ { id: string; options: string[]; closesDay: number; resolveBy: number }
const qtypeOf = (id: string) => (id.endsWith(":yes") ? "yes" : id.endsWith(":when") ? "when" : "how");

/** The form-guide chance of each option for a question, from public facts only (sharps also discount a yes window that's running out). */
export function propFair(f: PublicStory, q: PropQ, day: number): number[] {
  const t = qtypeOf(q.id);
  const pr = PRIORS[f.kind];
  let w = q.options.map(k => {
    if (t === "yes") return (pr ? (k === "yes" ? pr.yes[0] : pr.yes[1]) : 1) + PRIOR_SMOOTH;
    const tab = pr ? (t === "when" ? pr.when : pr.how) : {};
    return (tab[k] ?? 0) + PRIOR_SMOOTH;
  });
  if (t === "yes") {
    // the window is partly used up and nothing has happened yet
    const span = Math.max(1, q.resolveBy - f.bettableDay);
    const left = clamp((q.resolveBy - day) / span, 0.05, 1);
    const yi = q.options.indexOf("yes");
    if (yi >= 0) w = w.map((x, i) => (i === yi ? x * left : x));
  }
  const t2 = sum(w);
  return w.map(x => x / t2);
}

/** House money a question gets over its whole window. */
export function propSize(f: PublicStory, q: PropQ): number {
  const P = HOUSE.prop;
  const t = qtypeOf(q.id);
  let m = (P.base[t] ?? 150) * (P.kind[f.kind] ?? 1);
  if (f.visibility === "public") m *= P.public;
  if (P.hotStages.includes(f.stage)) m *= P.hotStage;
  return m;
}

/**
 * The regulars' waves on a prop question for world day `day` (one entry per HOUSE.prop.waves),
 * `off` ms before the question's closing time. Deterministic per (seed, question, day).
 * Sees `PublicStory` only. `first`: the question's first day of waves (carries the per-option minimum).
 */
export function propWaves(seed: string, f: PublicStory, q: PropQ, day: number, dayMs: number, first: boolean): HouseWave[] {
  const P = HOUSE.prop;
  if (day > q.closesDay) return [];
  const t = qtypeOf(q.id);
  const days = Math.max(1, q.closesDay - f.bettableDay + 1);
  const budget = propSize(f, q) * (days === 1 ? 1 : first ? P.firstDay : (1 - P.firstDay) / (days - 1));
  const fair = propFair(f, q, day);
  // crowd sentiment per question (same every day), plus a little daily drift
  const crowd = new Rng(`${seed}:house:${q.id}`);
  const bias = q.options.map(() => crowd.normal(0, P.noise));
  const rng = new Rng(`${seed}:house:${q.id}:${day}`);
  const hot = P.hotStages.includes(f.stage) ? 1.5 : 1;
  const square = fair.map((p, i) => {
    const k = q.options[i];
    let odds = p * Math.exp(bias[i] + rng.normal(0, P.noise * 0.25));
    if (dramatic(f.kind, t, k)) odds *= 1 + P.drama * hot;
    if (t === "when" && k === "d5") odds *= 1 + P.soon;
    return odds;
  });
  const sq = sum(square);
  const waves = P.waves.map((w, i) => {
    const sharp = fair.map(p => p * Math.exp(rng.normal(0, P.sharpNoise)));
    const sh = sum(sharp);
    const shares = fair.map((_, j) => (1 - w.sharp) * (square[j] / sq) + w.sharp * (sharp[j] / sh));
    const off = Math.round((q.closesDay - day + 1 - w.at) * dayMs);
    return { k: `d${day}w${i}`, off, a: split(budget * w.share, shares) };
  });
  // the minimum per option lands with the question's first wave
  return first ? floorOptions(waves, q.options.length) : waves;
}

// ------------------------------------------------------------------ flavour

const TEAM_WORDS = ["A man in a raincoat", "A dentist from Tulsa", "Somebody's uncle", "Two nuns", "A guy named Sal", "The mailman", "A woman with a parrot", "A retired umpire"];

/** One deadpan line about the day's biggest house wave on a game, for the rumours board. */
export function regularsLine(rng: Rng, amount: number, team: string): string {
  return `${rng.pick(TEAM_WORDS)} put $${amount} on the ${team}.`;
}
