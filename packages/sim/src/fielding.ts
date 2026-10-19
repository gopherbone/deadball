// Turning a batted ball into an outcome by racing ball, fielders and runners.

import type { Park, Player, Pos, Weather } from "./types.ts";
import type { Rng } from "./rng.ts";
import { fenceAt, fly, groundDistance, sprayDir, type Flight } from "./physics.ts";
import { T } from "./tuning.ts";
import { leapRobChance, power, type PowerKind } from "./powers.ts";

export const r = (x: number) => (x - 50) / 10;

type Vec = [number, number];
const BASES: Vec[] = [[0, 0], [63.64, 63.64], [0, 127.28], [-63.64, 63.64]]; // home, 1B, 2B, 3B
const dist = (a: Vec, b: Vec) => Math.hypot(a[0] - b[0], a[1] - b[1]);

function polar(d: number, spray: number): Vec {
  const [x, y] = sprayDir(spray);
  return [x * d, y * d];
}

const ALIGN: Record<Exclude<Pos, "DH">, Vec> = {
  P: [0, 58],
  C: [0, -3],
  "1B": polar(108, 36),
  "2B": polar(150, 13),
  SS: polar(150, -14),
  "3B": polar(106, -36),
  LF: polar(285, -27),
  CF: polar(315, 0),
  RF: polar(285, 27),
};

export interface Fielder {
  pos: Exclude<Pos, "DH">;
  player: Player;
  at: Vec;
  speed: number;    // ft/s
  reaction: number; // s
  hands: number;    // rating
  arm: number;      // throw speed ft/s
  accuracy: number; // rating
  /** Multiplier from incidents/sabotage on this fielder's catching. */
  shaky: number;
  /** LEAP_CATCH power level (0 = none): can climb the wall to rob home runs. */
  leap: number;
}

export function buildFielder(pos: Exclude<Pos, "DH">, p: Player, shaky = 1): Fielder {
  const f = p.fielding;
  const fam = f.positions[pos] ?? 0.3;
  const adj = (x: number) => 50 + (x - 50) * (0.6 + 0.4 * fam) - (1 - fam) * 12;
  const outfield = pos === "LF" || pos === "CF" || pos === "RF";
  return {
    pos,
    player: p,
    at: ALIGN[pos],
    // infielders move laterally (shuffle/dive), outfielders sprint
    speed: (outfield ? 22 : 14) + 0.9 * r(adj(f.range)) + 0.5 * r(p.batting.speed) + 3 * power(p, "WARP_RUN"),
    // pitchers are still finishing their follow-through
    reaction: (pos === "P" ? 0.62 : outfield ? 0.6 : 0.26) - 0.035 * r(adj(f.reaction)),
    hands: adj(f.hands),
    // average horizontal throw speed incl. crow hop and arc
    arm: ((outfield ? 92 : 112) + 6 * r(adj(f.arm))) * (1 + 0.45 * power(p, "LASER_ARM")),
    accuracy: adj(f.accuracy),
    shaky,
    leap: power(p, "LEAP_CATCH"),
  };
}

export interface Runner {
  player: Player;
  base: 1 | 2 | 3;
}

export type BipKind = "HR" | "1B" | "2B" | "3B" | "OUT" | "DP" | "FC" | "ROE" | "FOUL" | "FOUL_OUT" | "SF";

export interface BipResult {
  kind: BipKind;
  fielder?: Pos;
  /** Out description for box/log: GO, FO, LO, PO, DP etc. */
  outType?: "GO" | "FO" | "LO" | "PO" | "DP" | "FC";
  outs: number;
  /** Where each runner (and the batter as base 0) ends: 1..3 on base, 4 scored, -1 out. */
  moves: { player: Player; from: 0 | 1 | 2 | 3; to: number }[];
  error?: { pos: Pos; kind: "fielding" | "throwing" };
  land: Vec;
  hang: number;
  path?: [number, number, number][];
  dist: number;
  /** An enhanced power decided the play (for the log, the wire and BallCast). */
  ultra?: { who: string; power: PowerKind };
}

// WARP_RUN legs count as extra speed rating
const legs = (p: Player) => r(p.batting.speed) + 1.5 * power(p, "WARP_RUN");

function batterTimeTo(b: Player, bases: number): number {
  const s = legs(b);
  const first = T.homeToFirst - 0.11 * s + (b.bats === "L" ? -0.06 : 0);
  return first + (bases - 1) * (T.baseToBase - 0.1 * s);
}

function runnerTime(p: Player, fromBase: number, toBase: number, goingOnContact: boolean): number {
  const s = legs(p);
  const per = T.baseToBase - 0.1 * s;
  const lead = goingOnContact ? 0.45 : 0;
  return (toBase - fromBase) * per - lead;
}

function throwTime(from: Vec, to: Vec, f: Fielder): number {
  const d = dist(from, to);
  // long throws need a relay: slower average speed
  const relay = d > 220 ? 0.75 : 0;
  return d / f.arm + relay;
}

function aggression(p: Player): number {
  let a = T.sendMargin - 0.04 * r(p.batting.baserunning);
  if (p.traits.includes("HOTHEAD") || p.traits.includes("SHOWBOAT")) a -= 0.15;
  if (p.traits.includes("LAZY")) a += 0.2;
  return a;
}

interface Ctx {
  batter: Player;
  runners: Runner[];
  outs: number;
  fielders: Fielder[];
  park: Park;
  weather: Weather;
  rng: Rng;
  /** The defense has the ultra points to spend on a LEAP_CATCH. */
  canLeap?: boolean;
}

export function resolveBip(ev: number, la: number, spray: number, ctx: Ctx): BipResult {
  const { park, weather, rng } = ctx;
  const flight = fly(ev, la, spray, weather, park);
  const fair = Math.abs(spray) <= 45;
  const ground = la < T.groundLA || (flight.apex < 9 && flight.distance < 130);

  if (!fair) return foul(flight, ctx);
  if (ground) return groundBall(ev, la, spray, ctx);
  return airBall(flight, spray, ctx);
}

function foul(fl: Flight, ctx: Ctx): BipResult {
  const land: Vec = [fl.landX, fl.landY];
  // foul pops in play: catchable if the park has the room and someone gets there
  const room = 25 + 0.6 * (ctx.park.foulTerritory - 50);
  if (fl.hang > 2.6 && fl.distance < 260) {
    // distance beyond the nearer foul line (lines run at ±45°)
    const beyond = Math.abs(Math.abs(fl.landX) - fl.landY) * Math.SQRT1_2;
    if (beyond < room) {
      const best = bestCatcher(ctx.fielders, land, fl.hang);
      if (best && best.margin > 0 && ctx.rng.chance(catchProb(best.f, best.margin) * 0.92)) {
        // the batter is out; every runner holds (moves must list them or they vanish)
        const moves: BipResult["moves"] = [{ player: ctx.batter, from: 0, to: -1 }];
        for (const run of [...ctx.runners].sort((a, b) => b.base - a.base)) moves.push({ player: run.player, from: run.base, to: run.base });
        return { kind: "FOUL_OUT", fielder: best.f.pos, outType: "PO", outs: 1, moves, land, hang: fl.hang, dist: fl.distance, path: fl.path };
      }
    }
  }
  return { kind: "FOUL", outs: 0, moves: [], land, hang: fl.hang, dist: fl.distance, path: fl.path };
}

function bestCatcher(fielders: Fielder[], land: Vec, hang: number) {
  let best: { f: Fielder; margin: number } | null = null;
  for (const f of fielders) {
    const need = f.reaction + dist(f.at, land) / f.speed;
    const margin = hang - need;
    // prefer the outfielder/whoever has the most cushion
    if (!best || margin > best.margin) best = { f, margin };
  }
  return best;
}

function catchProb(f: Fielder, margin: number): number {
  // margin in seconds: >0.5 routine, ~0 a dive
  const base = 1 / (1 + Math.exp(-(margin + T.catchBias) * 8));
  const hands = 0.985 + 0.004 * r(f.hands);
  return Math.min(0.998, base * hands * f.shaky);
}

function airBall(fl: Flight, spray: number, ctx: Ctx): BipResult {
  const { park, rng, batter } = ctx;
  const land: Vec = [fl.landX, fl.landY];
  const fence = fenceAt(park, spray);
  const base = { land, hang: fl.hang, dist: fl.distance, path: fl.path };

  if (fl.distance >= fence.dist) {
    const h = fl.heightAt(fence.dist);
    if (h > fence.height) {
      // an enhanced outfielder may climb the wall and take it back
      if (ctx.canLeap && h - fence.height < 6 + 5 * 3) {
        const [wx, wy] = sprayDir(spray);
        const wall: Vec = [wx * fence.dist, wy * fence.dist];
        for (const f of ctx.fielders) {
          if (!f.leap || h - fence.height > 6 + 5 * f.leap) continue;
          const t = f.reaction + Math.max(0, dist(f.at, wall) - 6) / f.speed;
          if (t <= fl.hang * 0.92 && rng.chance(leapRobChance(f.leap))) {
            const out = caughtFly(f, "FO", fl, ctx);
            return { ...out, ultra: { who: f.player.id, power: "LEAP_CATCH" } };
          }
        }
      }
      const moves = advanceAll(ctx, 4, 4);
      return { kind: "HR", outs: 0, moves, ...base };
    }
  }

  const best = bestCatcher(ctx.fielders, land, fl.hang);
  const la = Math.atan2(fl.apex, fl.distance / 2) * (180 / Math.PI);
  if (best && rng.chance(catchProb(best.f, best.margin))) {
    const outType = fl.apex > 60 && fl.distance < 200 ? "PO" : fl.apex < 25 ? "LO" : "FO";
    return caughtFly(best.f, outType, fl, ctx);
  }
  // dropped/near miss on a routine play is an error
  if (best && best.margin > 0.6 && rng.chance(0.5)) {
    const moves = advanceAll(ctx, 1, 1);
    return { kind: "ROE", fielder: best.f.pos, outs: 0, moves, error: { pos: best.f.pos, kind: "fielding" }, ...base };
  }

  // it's down: where does it end up and who gets it. In front of the outfielders it gets
  // cut off quickly; over their heads or in the gap it rolls to the wall.
  const [dx, dy] = sprayDir(spray);
  const ofs = ctx.fielders.filter(f => f.pos === "LF" || f.pos === "CF" || f.pos === "RF");
  const nearestOf = nearestTo(ofs, land);
  const ofDepth = Math.hypot(nearestOf.at[0], nearestOf.at[1]);
  const pastThem = fl.distance > ofDepth - 15 || dist(nearestOf.at, land) > 70;
  const roll = pastThem ? rollAfterLanding(fl, la) + 60 : 12;
  const wallDist = Math.min(fence.dist, fl.distance + roll);
  const rest: Vec = [dx * wallDist, dy * wallDist];
  const atWall = wallDist >= fence.dist - 1;
  const ballAt = fl.hang + Math.max(0, wallDist - fl.distance) / 55 + (atWall ? 1.3 : 0);
  const retriever = nearestTo(ctx.fielders.filter(f => f.pos !== "C" && f.pos !== "P"), rest);
  const fieldT = Math.max(ballAt, retriever.reaction + dist(retriever.at, rest) / retriever.speed) + 0.45;
  return hitWithAdvance(fieldT, rest, retriever, ctx, base);
}

function rollAfterLanding(fl: Flight, la: number): number {
  return Math.max(5, 70 - la * 1.6) * (fl.distance > 200 ? 1 : 0.5);
}

function nearestTo(fs: Fielder[], p: Vec): Fielder {
  let best = fs[0];
  let bt = Infinity;
  for (const f of fs) {
    const t = f.reaction + dist(f.at, p) / f.speed;
    if (t < bt) { bt = t; best = f; }
  }
  return best;
}

function caughtFly(f: Fielder, outType: "PO" | "LO" | "FO", fl: Flight, ctx: Ctx): BipResult {
  const land: Vec = [fl.landX, fl.landY];
  const moves: BipResult["moves"] = [{ player: ctx.batter, from: 0, to: -1 }];
  let outs = 1;
  let kind: BipKind = "OUT";
  const occupied = new Set(ctx.runners.map(x => x.base));
  // tag-ups, lead runner first
  for (const run of [...ctx.runners].sort((a, b) => b.base - a.base)) {
    let to: number = run.base;
    const target = run.base + 1;
    const open = target === 4 || !occupied.has(target as 1 | 2 | 3);
    if (ctx.outs + outs < 3 && outType === "FO" && open) {
      const runT = runnerTime(run.player, run.base, target, false);
      const ballT = 0.5 + throwTime(land, BASES[target % 4], f);
      const margin = ballT - runT;
      if (margin > aggression(run.player) + (target === 4 ? 0 : 0.5)) {
        const actual = margin + ctx.rng.normal(0, 0.3);
        if (actual > 0) {
          to = target;
          occupied.delete(run.base);
          if (target < 4) occupied.add(target as 1 | 2 | 3);
          if (target === 4) kind = "SF";
        } else {
          to = -1;
          outs++;
          occupied.delete(run.base);
        }
      }
    }
    moves.push({ player: run.player, from: run.base, to });
  }
  return { kind, fielder: f.pos, outType, outs, moves, land, hang: fl.hang, dist: fl.distance, path: fl.path };
}

/** Everyone advances at least `forced`, at most `max` bases (for HR/walk-like plays). */
function advanceAll(ctx: Ctx, batterTo: number, runnerAdv: number): BipResult["moves"] {
  const moves: BipResult["moves"] = [{ player: ctx.batter, from: 0, to: batterTo }];
  for (const run of ctx.runners) moves.push({ player: run.player, from: run.base, to: Math.min(4, run.base + runnerAdv) });
  return moves;
}

function hitWithAdvance(fieldT: number, at: Vec, f: Fielder, ctx: Ctx, base: Pick<BipResult, "land" | "hang" | "dist" | "path">): BipResult {
  const { batter, rng } = ctx;
  // batter: take as many bases as the race allows
  let batterBase = 1;
  for (let b = 2; b <= 4; b++) {
    const runT = batterTimeTo(batter, b);
    const ballT = fieldT + throwTime(at, BASES[b % 4], f);
    const margin = ballT - runT;
    if (margin > aggression(batter) + (b === 4 ? 0.6 : 0.1)) batterBase = b;
    else break;
  }
  const moves: BipResult["moves"] = [];
  let outs = 0;
  // runners: from the lead runner back, everyone moves at least one base on a hit
  const sorted = [...ctx.runners].sort((a, b) => b.base - a.base);
  const ends: { run: Runner; to: number }[] = [];
  let blockAt = 5; // a lead runner who stops blocks bases behind them
  for (const run of sorted) {
    const forcedTo = Math.min(4, run.base + 1);
    let to = forcedTo;
    for (let b = forcedTo + 1; b <= 4; b++) {
      if (b >= blockAt) break;
      const runT = runnerTime(run.player, run.base, b, true);
      const ballT = fieldT + throwTime(at, BASES[b % 4], f);
      const margin = ballT - runT;
      if (margin > aggression(run.player) + (b === 4 ? 0 : 0.25)) to = b;
      else break;
    }
    // occasionally thrown out stretching it
    if (to > forcedTo) {
      const runT = runnerTime(run.player, run.base, to, true);
      const ballT = fieldT + throwTime(at, BASES[to % 4], f);
      if (ballT - runT + rng.normal(0, 0.35) < 0) {
        to = -1;
        outs++;
      }
    }
    if (to !== -1 && to < 4) blockAt = to;
    ends.push({ run, to });
  }
  // the batter can't pass a runner who stopped
  for (const e of ends) if (e.to > 0 && e.to < 4 && batterBase >= e.to) batterBase = Math.max(1, e.to - 1);
  moves.push({ player: batter, from: 0, to: batterBase });
  for (const e of ends) moves.push({ player: e.run.player, from: e.run.base, to: e.to });
  const kind: BipKind = batterBase >= 4 ? "HR" : batterBase === 3 ? "3B" : batterBase === 2 ? "2B" : "1B";
  return { kind, fielder: f.pos, outs, moves, ...base };
}

function groundBall(ev: number, la: number, spray: number, ctx: Ctx): BipResult {
  const { rng, batter, park } = ctx;
  const [dx, dy] = sprayDir(spray);
  const infielders = ctx.fielders.filter(f => f.pos === "1B" || f.pos === "2B" || f.pos === "SS" || f.pos === "3B" || f.pos === "P");
  let pick: { f: Fielder; t: number; p: Vec } | null = null;
  for (let t = 0.05; t < 4; t += 0.05) {
    const d = groundDistance(ev, la, t, park.turf);
    const p: Vec = [dx * d, dy * d];
    if (d > 170) break; // through the infield
    for (const f of infielders) {
      if (f.pos === "P" && d > 70) continue;
      const reach = f.pos === "P" ? 1.5 : T.infieldReach;
      const need = f.reaction + Math.max(0, dist(f.at, p) - reach) / f.speed;
      if (need <= t && (!pick || t < pick.t)) pick = { f, t, p };
    }
    if (pick) break;
  }
  const landD = groundDistance(ev, la, 0.6, park.turf);
  const land: Vec = [dx * landD, dy * landD];
  const base = { land, hang: 0.6, dist: landD };

  if (!pick) {
    // through to the outfield
    const downTheLine = Math.abs(spray) > 37;
    const reachD = downTheLine ? Math.min(fenceAt(park, spray).dist, 300) : 220;
    const at: Vec = [dx * reachD, dy * reachD];
    const of = nearestTo(ctx.fielders.filter(f => f.pos === "LF" || f.pos === "CF" || f.pos === "RF"), at);
    const ballAt = downTheLine ? 4.2 : 2.3;
    const fieldT = Math.max(ballAt, of.reaction + dist(of.at, at) / of.speed) + 0.4 + (downTheLine ? 0.9 : 0);
    return hitWithAdvance(fieldT, at, of, ctx, base);
  }

  const { f, t, p } = pick;
  const ballSpeed = Math.max(10, (groundDistance(ev, la, t + 0.05, park.turf) - groundDistance(ev, la, t, park.turf)) / 0.05);
  const lateral = Math.max(0, dist(f.at, p) - 2);
  const difficulty = lateral / 25 + Math.max(0, ballSpeed - 80) / 60;
  const cleanP = (T.groundCleanBase + 0.006 * r(f.hands) - 0.03 * difficulty) * f.shaky;
  const outs = ctx.outs;
  if (!rng.chance(cleanP)) {
    // bobble: usually just an infield hit, sometimes an error
    if (difficulty > 0.6 || rng.chance(0.45)) return infieldSingle(f, ctx, base);
    return { kind: "ROE", fielder: f.pos, outs: 0, moves: advanceForced(ctx, 1), error: { pos: f.pos, kind: "fielding" }, ...base };
  }
  const transfer = T.transfer - 0.05 * r(f.hands) + Math.min(0.5, lateral / 40);
  const tReady = t + transfer;
  const runnerOn1 = ctx.runners.find(x => x.base === 1);
  const batterT = batterTimeTo(batter, 1);

  // double play / force at second
  if (runnerOn1 && outs < 2) {
    const toSecond = tReady + throwTime(p, BASES[2], f);
    const runT = runnerTime(runnerOn1.player, 1, 2, true) + 0.25;
    if (toSecond + 0.1 < runT) {
      const pivot = ctx.fielders.find(x => x.pos === (spray < 0 ? "2B" : "SS")) ?? f;
      const toFirst = toSecond + T.pivot - 0.04 * r(pivot.hands) + throwTime(BASES[2], BASES[1], pivot);
      const dp = toFirst + rng.normal(0, 0.12) < batterT;
      const moves: BipResult["moves"] = [
        { player: batter, from: 0, to: dp ? -1 : 1 },
        { player: runnerOn1.player, from: 1, to: -1 },
      ];
      for (const run of ctx.runners) {
        if (run.base === 1) continue;
        // runner on first is always present here, so second is forced, and third is
        // forced only if second is occupied too
        const on2 = ctx.runners.some(x => x.base === 2);
        const forced = run.base === 2 ? 3 : run.base === 3 && on2 ? 4 : run.base;
        let to: number = forced;
        if (outs + (dp ? 2 : 1) < 3 && to < 4) {
          if (run.base === 3 && rng.chance(0.65 + 0.05 * r(run.player.batting.speed))) to = 4;
          else if (run.base === 2) to = 3;
        }
        moves.push({ player: run.player, from: run.base, to });
      }
      return { kind: dp ? "DP" : "FC", fielder: f.pos, outType: dp ? "DP" : "FC", outs: dp ? 2 : 1, moves, ...base };
    }
  }

  // throw to first (or 1B unassisted)
  const toFirst = f.pos === "1B" && dist(p, BASES[1]) < 30
    ? tReady + dist(p, BASES[1]) / 22
    : tReady + throwTime(p, BASES[1], f);
  const throwErrP = (T.throwErr - 0.002 * r(f.accuracy)) * (toFirst > batterT - 0.25 ? 2 : 1);
  if (rng.chance(throwErrP)) {
    return { kind: "ROE", fielder: f.pos, outs: 0, moves: advanceForced(ctx, 2), error: { pos: f.pos, kind: "throwing" }, ...base };
  }
  if (toFirst + rng.normal(0, 0.1) < batterT) {
    const moves: BipResult["moves"] = [{ player: batter, from: 0, to: -1 }];
    // lead runner first, so the runner from second knows whether third is still occupied
    let to3 = 0;
    for (const run of [...ctx.runners].sort((a, b) => b.base - a.base)) {
      let to: number = run.base;
      const forced = isForced(run.base, ctx.runners);
      if (forced) to = run.base + 1;
      else if (outs + 1 < 3) {
        if (run.base === 3) to = rng.chance(0.45 + 0.08 * r(run.player.batting.speed) + (spray > 0 ? 0.1 : -0.1)) ? 4 : 3;
        else if (run.base === 2 && spray > -10) to = 3; // ball to the right side
      }
      // the runner from third held: the runner from second can't take third
      if (run.base === 2 && to === 3 && to3 === 3) to = 2;
      if (run.base === 3) to3 = to;
      moves.push({ player: run.player, from: run.base, to });
    }
    return { kind: "OUT", fielder: f.pos, outType: "GO", outs: 1, moves, ...base };
  }
  return infieldSingle(f, ctx, base);
}

function isForced(base: number, runners: Runner[]): boolean {
  for (let b = 1; b <= base; b++) if (!runners.some(x => x.base === b) && b !== base) return false;
  return runners.some(x => x.base === base) && (base === 1 || isForced(base - 1, runners));
}

function advanceForced(ctx: Ctx, batterTo: number): BipResult["moves"] {
  const moves: BipResult["moves"] = [{ player: ctx.batter, from: 0, to: batterTo }];
  for (const run of ctx.runners) {
    const forced = isForced(run.base, ctx.runners);
    moves.push({ player: run.player, from: run.base, to: Math.min(4, forced || batterTo > 1 ? run.base + (batterTo > 1 ? 2 : 1) : run.base) });
  }
  return moves;
}

function infieldSingle(f: Fielder, ctx: Ctx, base: Pick<BipResult, "land" | "hang" | "dist">): BipResult {
  return { kind: "1B", fielder: f.pos, outs: 0, moves: advanceForced(ctx, 1), ...base };
}
