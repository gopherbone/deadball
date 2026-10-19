// One full game, pitch by pitch. Deterministic for a given (world, spec, seed).

import type { Park, Pitch, PitchKind, Player, Pos, Team, Umpire, Weather, World } from "./types.ts";
import { Rng } from "./rng.ts";
import { T } from "./tuning.ts";
import { ModSet, type Modifier } from "./modifiers.ts";
import { HALF_INNINGS_PER_GAME, INCIDENTS, type IncidentKind } from "./incidents.ts";
import { buildFielder, r, resolveBip, type BipKind, type BipResult, type Fielder, type Runner } from "./fielding.ts";
import { buildLineup, buildStaff, pickStarter, pitchCap, relieverAvailable, type Lineup, type Staff } from "./lineup.ts";
import { PITCH_POWERS, POWER_COST, TEAM_POINTS, USE_CAP, hyperEffect, pitchEffect, power as powerLevel, powersOf, shouldUse, type PitchPowerEffect, type PowerKind } from "./powers.ts";

export interface GameSpec {
  id: string;
  day: number;
  homeId: string;
  awayId: string;
  umpireId: string;
  weather: Weather;
  modifiers: Modifier[];
}

export type Zone = 0 | 1 | 2 | 3; // heart, edge-in, edge-out, waste
export type PitchResult = "B" | "C" | "S" | "F" | "X" | "H"; // ball, called K, swinging K, foul, in play, hit by pitch

/** A bunt's kind, logged on the bunt pitch (incl. a take while showing bunt: the fake) and on the bip:
 * the manager's sacrifice, a squeeze, or the batter bunting for a hit (a left-handed batter's drag
 * bunt). Only the Pennant engine (playdate/c/pdsim_core.c) bunts today; this simulator never does,
 * so its logs never carry it. BallCast reads it (ballcast/play.lua buntKind). */
export type BuntKind = "sac" | "sq" | "hit" | "drag";

export type LogEv =
  | { k: "half"; inn: number; top: boolean }
  | { k: "pa"; bat: string; pit: string }
  | { k: "p"; t: PitchKind; v: number; z: Zone; r: PitchResult; b: number; s: number; bunt?: boolean; bk?: BuntKind }
  | { k: "bip"; ev: number; la: number; sp: number; res: BipKind; f?: Pos; out?: string; path?: number[]; bunt?: boolean; bk?: BuntKind }
  | { k: "mv"; id: string; from: number; to: number }
  | { k: "sb"; id: string; base: number; ok: boolean }
  | { k: "wp"; pb: boolean }
  | { k: "sub"; side: "home" | "away"; out: string; in: string; pos: Pos; why: string }
  | { k: "inc"; kind: IncidentKind; team?: string; who?: string; note?: string }
  | { k: "ultra"; who: string; power: PowerKind; side: "home" | "away" }
  | { k: "end"; home: number; away: number };

export interface BatLine {
  id: string; pos: Pos; ab: number; r: number; h: number; d: number; t: number; hr: number;
  rbi: number; bb: number; k: number; sb: number; cs: number; hbp: number; sf: number;
}
export interface PitchLine {
  id: string; outs: number; h: number; r: number; er: number; bb: number; k: number; hr: number;
  hbp: number; pitches: number; bf: number;
}
export interface TeamBox {
  teamId: string;
  bat: BatLine[];
  pitch: PitchLine[];
  runs: number;
  hits: number;
  errors: number;
  lob: number;
  line: number[];
}

export interface GameResult {
  id: string;
  home: TeamBox;
  away: TeamBox;
  innings: number;
  winner: "home" | "away";
  decisions: { w: string; l: string; s?: string };
  log: LogEv[];
  /** Pitches per pitcher, to feed rest/fatigue tracking. */
  pitchCounts: Record<string, number>;
  injuries: { id: string; kind: string; days: number }[];
  ejections: string[];
  incidents: { kind: IncidentKind; team?: string; who?: string; inning: number; sources: string[] }[];
}

interface BaseRunner extends Runner {
  resp: string;       // pitcher charged if this runner scores
  unearned: boolean;  // reached on error
}

interface Side {
  key: "home" | "away";
  team: Team;
  lineup: Lineup;
  staff: Staff;
  idx: number;
  pitcher: Player;
  isStarter: boolean;
  enteredOuts: number; // team outs recorded when this pitcher came in
  plannedOuts: number;
  used: Set<string>;
  ejected: Set<string>;
  runsAllowedByPitcher: number;
  box: TeamBox;
  bat: Map<string, BatLine>;
  pit: Map<string, PitchLine>;
  outsRecorded: number; // defensive outs so far
  /** Enhanced-power points left this game (0 for teams without powers). */
  ultra: number;
  /** Uses this game per "playerId:power", capped by USE_CAP. */
  powerUses: Map<string, number>;
}

const PITCH_FB: PitchKind[] = ["FB", "SI", "CT"];

function canUse(side: Side, who: string, kind: PowerKind): boolean {
  return (side.powerUses.get(who + ":" + kind) ?? 0) < USE_CAP[kind];
}

function markUse(side: Side, who: string, kind: PowerKind): void {
  const k = who + ":" + kind;
  side.powerUses.set(k, (side.powerUses.get(k) ?? 0) + 1);
}

export function simulateGame(world: World, spec: GameSpec, seed: string): GameResult {
  const rng = new Rng(seed);
  const homeTeam = world.teams[spec.homeId];
  const awayTeam = world.teams[spec.awayId];
  const park: Park = world.parks[homeTeam.parkId];
  const ump = world.npcs[spec.umpireId] as Umpire;
  const mods = new ModSet([...spec.modifiers]);
  const log: LogEv[] = [];
  const incidents: GameResult["incidents"] = [];
  const injuries: GameResult["injuries"] = [];
  const ejections: string[] = [];
  const pitchCounts: Record<string, number> = {};
  const incidentFired = new Set<IncidentKind>();
  // per-game "shaky" multipliers on fielders, per team
  const shaky: Record<string, number> = { [homeTeam.id]: 1, [awayTeam.id]: 1 };
  const halfMods: Modifier[] = []; // modifiers that expire at the end of the half inning

  const mkSide = (key: "home" | "away", team: Team): Side => {
    const lineup = buildLineup(world, team);
    const staff = buildStaff(world, team);
    const starter = pickStarter(staff);
    const box: TeamBox = { teamId: team.id, bat: [], pitch: [], runs: 0, hits: 0, errors: 0, lob: 0, line: [] };
    const bat = new Map<string, BatLine>();
    for (const { player, pos } of lineup.order) {
      const l = { id: player.id, pos, ab: 0, r: 0, h: 0, d: 0, t: 0, hr: 0, rbi: 0, bb: 0, k: 0, sb: 0, cs: 0, hbp: 0, sf: 0 };
      bat.set(player.id, l);
      box.bat.push(l);
    }
    const pit = new Map<string, PitchLine>();
    const side: Side = {
      key, team, lineup, staff, idx: 0, pitcher: starter, isStarter: true, enteredOuts: 0, plannedOuts: 27,
      used: new Set([starter.id]), ejected: new Set(), runsAllowedByPitcher: 0, box, bat, pit, outsRecorded: 0, powerUses: new Map(),
      ultra: team.roster.some(id => world.players[id] && powersOf(world.players[id]).length > 0) ? TEAM_POINTS : 0,
    };
    addPitchLine(side, starter);
    return side;
  };

  const home = mkSide("home", homeTeam);
  const away = mkSide("away", awayTeam);

  // --- effective ratings -------------------------------------------------------
  const teamOf = (p: Player) => p.teamId;
  const bat = (p: Player, key: "contact" | "power" | "eye" | "speed") =>
    p.batting[key] + mods.rating(key, p.id, teamOf(p)) + p.mood * 0.6;
  const fatigue = (side: Side) => {
    const pc = pitchCounts[side.pitcher.id] ?? 0;
    const cap = pitchCap(side.pitcher) + mods.rating("stamina", side.pitcher.id, side.team.id);
    const tired = (side.pitcher.recentPitches[0] ?? 0) > 0 ? 8 : 0;
    return Math.max(0, (pc + tired - cap) / T.fatigueRamp);
  };

  function defenders(side: Side): Fielder[] {
    const out: Fielder[] = [];
    const d = side.lineup.defense;
    for (const pos of ["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF"] as const) {
      const p = d[pos];
      if (p) out.push(buildFielder(pos, p, shaky[side.team.id] * (1 + mods.rating("fielding", p.id, side.team.id) / 100)));
    }
    out.push(buildFielder("P", side.pitcher, shaky[side.team.id]));
    return out;
  }

  function addPitchLine(side: Side, p: Player) {
    if (side.pit.has(p.id)) return;
    const l = { id: p.id, outs: 0, h: 0, r: 0, er: 0, bb: 0, k: 0, hr: 0, hbp: 0, pitches: 0, bf: 0 };
    side.pit.set(p.id, l);
    side.box.pitch.push(l);
  }

  // --- manager: pitching changes -------------------------------------------------
  function changePitcher(side: Side, next: Player, why: string) {
    log.push({ k: "sub", side: side.key, out: side.pitcher.id, in: next.id, pos: "P", why });
    side.pitcher = next;
    side.isStarter = false;
    side.used.add(next.id);
    side.enteredOuts = side.outsRecorded;
    side.runsAllowedByPitcher = 0;
    side.plannedOuts = side.staff.closer === next ? 3 : rng.chance(0.6) ? 3 : 6;
    addPitchLine(side, next);
  }

  function availablePen(side: Side): Player[] {
    const all = [side.staff.closer, ...side.staff.setup, ...side.staff.middle, ...side.staff.rotation.filter(p => p !== side.staff.rotation[0])]
      .filter((p): p is Player => !!p && !side.used.has(p.id) && relieverAvailable(p) && !side.ejected.has(p.id));
    return all;
  }

  function considerPitchingChange(def: Side, off: Side, inning: number, newInning: boolean) {
    const f = fatigue(def);
    const lead = def.box.runs - off.box.runs;
    const pen = availablePen(def);
    if (pen.length === 0) return;
    const closer = def.staff.closer && pen.includes(def.staff.closer) ? def.staff.closer : undefined;
    const outsHere = def.outsRecorded - def.enteredOuts;

    if (newInning && inning >= 9 && lead > 0 && lead <= 3 && closer && def.pitcher !== closer) {
      changePitcher(def, closer, "save situation");
      return;
    }
    if (newInning && inning === 8 && lead > 0 && lead <= 3 && def.isStarter && f > 0.15) {
      const setup = def.staff.setup.find(p => pen.includes(p));
      if (setup) { changePitcher(def, setup, "setup"); return; }
    }
    const shelled = def.isStarter && def.runsAllowedByPitcher >= 5 && inning <= 6;
    const gassed = f > (def.isStarter ? 0.2 : 0.5);
    const doneRelieving = !def.isStarter && newInning && outsHere >= def.plannedOuts;
    if (shelled || gassed || doneRelieving) {
      const middle = pen.filter(p => p !== closer && !def.staff.setup.includes(p));
      const next = (inning >= 8 && lead > 0 && lead <= 3 ? def.staff.setup.find(p => pen.includes(p)) : undefined) ?? middle[0] ?? pen[pen.length - 1];
      changePitcher(def, next, shelled ? "shelled" : gassed ? "tired" : "matchup");
    }
  }

  // --- incidents -----------------------------------------------------------------
  function fireIncident(kind: IncidentKind, inning: number, off: Side, def: Side, forTeam?: string, who?: string, note?: string) {
    const sources = mods.sources(kind);
    incidents.push({ kind, team: forTeam, who, inning, sources });
    log.push({ k: "inc", kind, team: forTeam, who, note });
    incidentFired.add(kind);
  }

  function rollClockIncidents(inning: number, off: Side, def: Side) {
    for (const def_ of Object.values(INCIDENTS)) {
      if (def_.triggered) continue;
      if (def_.once && incidentFired.has(def_.kind)) continue;
      let p = def_.perGame / HALF_INNINGS_PER_GAME;
      if (def_.kind === "RAIN_DELAY") p = (spec.weather.rain * 0.25) / HALF_INNINGS_PER_GAME;
      p *= mods.incidentMult(def_.kind, [home.team.id, away.team.id]);
      if (!rng.chance(Math.min(0.9, p))) continue;
      const targets = mods.incidentTargets(def_.kind);
      const target = targets.length ? targets[0] : rng.pick([home.team.id, away.team.id]);
      const tSide = target === home.team.id ? home : away;
      switch (def_.kind) {
        case "RACCOONS_BULLPEN":
          for (const p of [...tSide.staff.setup, ...tSide.staff.middle, ...(tSide.staff.closer ? [tSide.staff.closer] : [])])
            mods.add({ id: `inc-rb-${p.id}`, source: "incident", target: { kind: "player", id: p.id }, effect: "stamina", value: -40 });
          fireIncident(def_.kind, inning, off, def, target);
          break;
        case "RACCOON_ON_FIELD": {
          // the raccoon is on the defensive side's field
          shaky[def.team.id] *= 0.9;
          halfMods.push({ id: "inc-rof", source: "incident", target: { kind: "team", id: def.team.id }, effect: "fielding", value: 0 });
          fireIncident(def_.kind, inning, off, def, def.team.id);
          break;
        }
        case "FOOD_POISONING":
          mods.add({ id: "inc-fp-c", source: "incident", target: { kind: "team", id: target }, effect: "contact", value: -6 });
          mods.add({ id: "inc-fp-p", source: "incident", target: { kind: "team", id: target }, effect: "power", value: -6 });
          mods.add({ id: "inc-fp-s", source: "incident", target: { kind: "team", id: target }, effect: "stamina", value: -20 });
          fireIncident(def_.kind, inning, off, def, target);
          break;
        case "LASER_POINTER": {
          // aimed at whichever team's hitters the job named; only matters while they bat
          const m: Modifier = { id: "inc-laser", source: "incident", target: { kind: "team", id: target }, effect: "contact", value: -12 };
          mods.add(m);
          halfMods.push(m);
          fireIncident(def_.kind, inning, off, def, target);
          break;
        }
        case "BALL_TAMPERING":
          mods.add({ id: "inc-bt", source: "incident", target: { kind: "team", id: target }, effect: "stuff", value: 6 });
          fireIncident(def_.kind, inning, off, def, target);
          break;
        case "RAIN_DELAY":
        case "BLACKOUT":
          // a long delay ends both pitchers' days
          for (const s of [home, away]) pitchCounts[s.pitcher.id] = (pitchCounts[s.pitcher.id] ?? 0) + 60;
          fireIncident(def_.kind, inning, off, def);
          break;
        case "FAN_ON_FIELD":
          fireIncident(def_.kind, inning, off, def);
          break;
      }
    }
  }

  function endHalf() {
    for (const m of halfMods) {
      if (m.id === "inc-rof") shaky[m.target.id] = Math.min(1, shaky[m.target.id] / 0.9);
      if (m.id === "inc-laser") m.value = 0;
    }
    halfMods.length = 0;
  }

  // --- the half inning ------------------------------------------------------------
  let bases: (BaseRunner | null)[] = [null, null, null, null]; // index 1..3

  function runners(): Runner[] {
    const out: Runner[] = [];
    for (const b of [1, 2, 3] as const) if (bases[b]) out.push({ player: bases[b]!.player, base: b });
    return out;
  }

  function score(off: Side, def: Side, br: BaseRunner, rbiTo?: BatLine) {
    off.box.runs++;
    const line = off.bat.get(br.player.id);
    if (line) line.r++;
    if (rbiTo) rbiTo.rbi++;
    const pl = def.pit.get(br.resp);
    if (pl) {
      pl.r++;
      if (!br.unearned) pl.er++;
    }
    if (br.resp === def.pitcher.id) def.runsAllowedByPitcher++;
    log.push({ k: "mv", id: br.player.id, from: 0, to: 4 });
  }

  function playHalf(inning: number, off: Side, def: Side, walkoffPossible: boolean): void {
    bases = [null, null, null, null];
    let outs = 0;
    log.push({ k: "half", inn: inning, top: off.key === "away" });
    rollClockIncidents(inning, off, def);
    considerPitchingChange(def, off, inning, true);
    const runsBefore = off.box.runs;

    const recordOut = (n: number) => {
      outs += n;
      def.outsRecorded += n;
      const pl = def.pit.get(def.pitcher.id)!;
      pl.outs += n;
    };

    while (outs < 3) {
      if (walkoffPossible && off.box.runs > def.box.runs) break;
      considerPitchingChange(def, off, inning, false);
      const slot = off.lineup.order[off.idx % 9];
      const batter = slot.player;
      const pitcher = def.pitcher;
      const pl = def.pit.get(pitcher.id)!;
      const bl = off.bat.get(batter.id)!;
      log.push({ k: "pa", bat: batter.id, pit: pitcher.id });
      pl.bf++;

      let balls = 0, strikes = 0;
      let paOver = false;
      const fielders = defenders(def);
      const catcher = def.lineup.defense.C;

      while (!paOver) {
        // --- stolen base attempts happen between pitches
        const runnerOn1 = bases[1];
        if (runnerOn1 && !bases[2] && outs < 2) {
          const spd = bat(runnerOn1.player, "speed");
          if (spd > 52) {
            const tryP = T.stealAttempt * Math.max(0, (spd - 50) / 15) * (runnerOn1.player.traits.includes("SHOWBOAT") ? 1.5 : 1);
            if (rng.chance(tryP)) {
              const arm = catcher ? catcher.fielding.arm : 50;
              const succ = 0.72 + 0.05 * r(spd) - 0.05 * r(arm) - 0.04 * r(pitcher.pitching?.hold ?? 50);
              const ok = rng.chance(Math.max(0.3, Math.min(0.95, succ)));
              const sbl = off.bat.get(runnerOn1.player.id);
              log.push({ k: "sb", id: runnerOn1.player.id, base: 2, ok });
              if (ok) {
                bases[2] = runnerOn1;
                if (sbl) sbl.sb++;
              } else {
                if (sbl) sbl.cs++;
                recordOut(1);
              }
              bases[1] = null;
              if (outs >= 3) break;
            }
          }
        }

        // --- the pitch
        const pr = pitcher.pitching!;
        const f = fatigue(def);
        const pitch = choosePitch(rng, pr.pitches, balls, strikes);
        const stuff = 0.55 * pr.stuff + 0.45 * pitch.quality + mods.rating("stuff", pitcher.id, def.team.id) - f * 8;
        const control = pr.control + mods.rating("control", pitcher.id, def.team.id) - f * 9;
        const command = pr.command - f * 9;
        let velo = Math.round(pitch.velo - f * 2 + rng.normal(0, 0.8));

        let zp = T.zoneBase + 0.03 * r(control) + countZoneAdj(balls, strikes) + (PITCH_FB.includes(pitch.kind) ? 0.04 : -0.04);
        zp = Math.max(0.25, Math.min(0.8, zp));
        let zone: Zone;
        if (rng.chance(zp)) zone = rng.chance(T.heartShare - 0.03 * r(command) + 0.05 * f) ? 0 : 1;
        else zone = rng.chance(T.edgeOutShare + 0.03 * r(command)) ? 2 : 3;

        // enhanced pitch (only teams with powers ever draw extra random numbers here)
        let pp: PitchPowerEffect | undefined;
        const lev = () => (Math.abs(off.box.runs - def.box.runs) <= 2 && inning >= 7) || !!(bases[2] || bases[3]) || strikes === 2;
        if (def.ultra > 0) {
          const kinds = PITCH_POWERS.filter(k => powerLevel(pitcher, k) > 0 && canUse(def, pitcher.id, k)).sort((a, b) => powerLevel(pitcher, b) - powerLevel(pitcher, a));
          if (kinds.length && shouldUse(def.ultra, POWER_COST[kinds[0]], inning, lev(), rng.float())) {
            pp = pitchEffect(kinds[0], powerLevel(pitcher, kinds[0]));
            def.ultra -= POWER_COST[kinds[0]];
            markUse(def, pitcher.id, kinds[0]);
            log.push({ k: "ultra", who: pitcher.id, power: kinds[0], side: def.key });
            velo = Math.max(30, velo + Math.round(pp.velo));
            if (pp.forceZone !== undefined) zone = pp.forceZone;
          }
        }

        pitchCounts[pitcher.id] = (pitchCounts[pitcher.id] ?? 0) + 1;
        pl.pitches++;

        // hit by pitch
        // grudges and retaliation (drama) raise the odds of plunking someone
        const hbpMult = Math.max(0, 1 + mods.rating("hbp", pitcher.id, def.team.id));
        if (zone === 3 && !pp && rng.chance((T.hbpPerPitch / 0.3) * (1 - 0.15 * r(control)) * hbpMult)) {
          log.push({ k: "p", t: pitch.kind, v: velo, z: zone, r: "H", b: balls, s: strikes });
          bl.hbp++;
          pl.hbp++;
          walkBatter(off, def, batter, pitcher, false);
          paOver = true;
          if (rng.chance(0.03)) injuries.push({ id: batter.id, kind: "bruised " + rng.pick(["wrist", "ribs", "elbow", "hand"]), days: 2 + rng.int(9) });
          maybeBrawl(inning, off, def, batter, pitcher);
          break;
        }

        // platoon + situational batting
        const platoon = platoonAdj(batter, pitcher);
        const clutch = clutchAdj(batter, inning, off, def, outs);
        const timesThrough = Math.floor((pl.bf - 1) / 9);
        const contact = bat(batter, "contact") + platoon + clutch + (timesThrough >= 2 ? 2 : 0);
        const eye = bat(batter, "eye");
        const power = bat(batter, "power") + platoon * 0.7 + clutch;

        const swingP = Math.max(0.02, Math.min(0.97, swingProb(zone, balls, strikes, eye, stuff) + (pp ? pp.swingAdd : 0)));
        const swung = rng.chance(swingP);

        if (!swung) {
          // wild pitch / passed ball with runners on
          if ((zone === 3 || zone === 2) && runners().length > 0) {
            const hands = catcher ? catcher.fielding.hands : 50;
            if (rng.chance((T.wildPitch / 0.45) * (1 - 0.12 * r(hands)) * (1 - 0.08 * r(control)))) {
              log.push({ k: "wp", pb: rng.chance(0.25) });
              advanceAllRunners(off, def, 1);
            }
          }
          const lean = mods.zoneLean(ump.id, def.team.id, off.team.id);
          const framing = catcher ? 0.025 * r(catcher.fielding.framing) : 0;
          const umpWide = 0.03 * r(ump.stats.zoneWidth);
          const noise = rng.normal(0, 0.02 * (1 + (50 - ump.stats.consistency) / 30));
          let strike: boolean;
          if (zone === 0) strike = true;
          else if (zone === 1) strike = !rng.chance(Math.max(0, T.edgeBallCall - umpWide - framing - lean + noise));
          else if (zone === 2) strike = rng.chance(Math.max(0, T.edgeStrikeCall + umpWide + framing + lean + noise));
          else strike = rng.chance(Math.max(0, lean * 0.3));
          if (strike) {
            strikes++;
            log.push({ k: "p", t: pitch.kind, v: velo, z: zone, r: "C", b: balls, s: strikes });
            if (strikes >= 3) {
              bl.ab++; bl.k++; pl.k++;
              recordOut(1);
              paOver = true;
              maybeEject(inning, off, def, batter, zone);
            }
          } else {
            balls++;
            log.push({ k: "p", t: pitch.kind, v: velo, z: zone, r: "B", b: balls, s: strikes });
            if (balls >= 4) {
              bl.bb++; pl.bb++;
              walkBatter(off, def, batter, pitcher, false);
              paOver = true;
            }
          }
          continue;
        }

        // two strikes: shorten up, protect the plate, spoil pitches
        // enhanced swing: the batter barrels it up
        let hyper: ReturnType<typeof hyperEffect> | undefined;
        if (off.ultra > 0 && powerLevel(batter, "HYPER_HIT") > 0 && canUse(off, batter.id, "HYPER_HIT") && shouldUse(off.ultra, POWER_COST.HYPER_HIT, inning, lev(), rng.float())) {
          hyper = hyperEffect(powerLevel(batter, "HYPER_HIT"));
          off.ultra -= POWER_COST.HYPER_HIT;
          markUse(off, batter.id, "HYPER_HIT");
          log.push({ k: "ultra", who: batter.id, power: "HYPER_HIT", side: off.key });
        }
        const cP = (contactProb(zone, contact, stuff, velo, pitch.kind) + (strikes === 2 ? T.twoStrikeContact : 0) + (hyper ? hyper.contactAdd : 0)) * (pp ? pp.contactMult : 1);
        if (!rng.chance(cP)) {
          strikes++;
          log.push({ k: "p", t: pitch.kind, v: velo, z: zone, r: "S", b: balls, s: strikes });
          if (strikes >= 3) {
            bl.ab++; bl.k++; pl.k++;
            recordOut(1);
            paOver = true;
          }
          continue;
        }
        const foulP = (zone === 0 ? T.foulHeart : zone === 1 || zone === 2 ? T.foulEdge : T.foulOut) + (strikes === 2 ? T.twoStrikeFoul : 0);
        if (rng.chance(foulP)) {
          if (strikes < 2) strikes++;
          log.push({ k: "p", t: pitch.kind, v: velo, z: zone, r: "F", b: balls, s: strikes });
          continue;
        }

        // ball in play
        log.push({ k: "p", t: pitch.kind, v: velo, z: zone, r: "X", b: balls, s: strikes });
        const zoneEv = zone === 0 ? 3 : zone === 1 ? 0 : zone === 2 ? -4 : -8;
        // exit velocity is left-skewed: a long tail of mis-hits, a hard ceiling on the top end
        const z = rng.normal(0, 1);
        const evMean = T.evMean + 2.3 * r(power) + zoneEv - 1.2 * r(pr.movement) - 0.8 * r(stuff) + f * 2;
        const la = hyper ? rng.normal(hyper.la, hyper.laSd) : rng.normal(T.laMean + 4 * r(batter.batting.lift) - 4 * r(pr.groundball), T.laSd);
        // squared-up contact lives around 15°; pop-ups and chops are mostly mis-hits
        const offSweet = Math.min(T.laPenaltyCap, T.laPenalty * (la - 15) ** 2);
        const ev = Math.max(25, Math.min(hyper ? 135 : 120, evMean - offSweet + T.evSd * (z > 0 ? z * T.evUpper : z * T.evLower) + (hyper ? hyper.evAdd : 0) + (pp ? pp.evAdd : 0)));
        const pullSign = effectiveSide(batter, pitcher) === "R" ? -1 : 1;
        const spray = rng.normal(pullSign * (T.sprayPull + 4 * r(batter.batting.pull)) * (la < 10 ? 1.4 : 0.8), T.spraySd);
        const res = resolveBip(ev, la, spray, {
          batter, runners: runners(), outs, fielders, park, weather: spec.weather, rng,
          canLeap: def.ultra >= POWER_COST.LEAP_CATCH,
        });
        if (res.ultra) {
          def.ultra -= POWER_COST[res.ultra.power];
          log.push({ k: "ultra", who: res.ultra.who, power: res.ultra.power, side: def.key });
        }
        if (res.kind === "FOUL") {
          // physics said foul after all
          if (strikes < 2) strikes++;
          log.pop();
          log.push({ k: "p", t: pitch.kind, v: velo, z: zone, r: "F", b: balls, s: strikes });
          continue;
        }
        log.push({
          k: "bip", ev: Math.round(ev), la: Math.round(la), sp: Math.round(spray), res: res.kind, f: res.fielder, out: res.outType,
          path: res.path ? res.path.flatMap(([x, y, z]) => [Math.round(x), Math.round(y), Math.round(z)]) : undefined,
        });
        applyBip(res, off, def, batter, pitcher, bl, pl, (n) => recordOut(n), outs);
        paOver = true;
      }
      // a caught-stealing third out ends the inning mid-PA: the batter leads off next time
      if (paOver) off.idx++;
      if (outs >= 3) break;
    }
    off.box.line.push(off.box.runs - runsBefore);
    off.box.lob += runners().length;
    endHalf();
  }

  function walkBatter(off: Side, def: Side, batter: Player, pitcher: Player, unearned: boolean) {
    // force runners along
    const br: BaseRunner = { player: batter, base: 1, resp: pitcher.id, unearned };
    if (bases[1]) {
      if (bases[2]) {
        if (bases[3]) score(off, def, bases[3]!, off.bat.get(batter.id));
        bases[3] = bases[2];
        bases[3]!.base = 3;
      }
      bases[2] = bases[1];
      bases[2]!.base = 2;
    }
    bases[1] = br;
    log.push({ k: "mv", id: batter.id, from: 0, to: 1 });
  }

  /** Wild pitches and the like: everyone moves up, nobody gets an RBI. */
  function advanceAllRunners(off: Side, def: Side, n: number) {
    for (const b of [3, 2, 1] as const) {
      const br = bases[b];
      if (!br) continue;
      const to = b + n;
      bases[b] = null;
      if (to >= 4) score(off, def, br);
      else {
        br.base = to as 1 | 2 | 3;
        bases[to] = br;
        log.push({ k: "mv", id: br.player.id, from: b, to });
      }
    }
  }

  function applyBip(res: BipResult, off: Side, def: Side, batter: Player, pitcher: Player, bl: BatLine, pl: PitchLine, recordOut: (n: number) => void, outsBefore: number) {
    const isHit = res.kind === "1B" || res.kind === "2B" || res.kind === "3B" || res.kind === "HR";
    const noRbi = res.kind === "DP" || res.kind === "ROE";
    if (res.kind !== "SF") bl.ab++;
    else bl.sf++;
    if (isHit) {
      bl.h++; pl.h++; off.box.hits++;
      if (res.kind === "2B") bl.d++;
      if (res.kind === "3B") bl.t++;
      if (res.kind === "HR") { bl.hr++; pl.hr++; }
    }
    if (res.error) def.box.errors++;
    const old = bases.slice();
    const next: (BaseRunner | null)[] = [null, null, null, null];
    // runners first, lead runner first
    const moves = [...res.moves].sort((a, b) => b.from - a.from);
    for (const m of moves) {
      const br: BaseRunner = m.from === 0
        ? { player: batter, base: 1, resp: pitcher.id, unearned: res.kind === "ROE" }
        : old[m.from]!;
      if (!br) continue;
      if (m.to === -1) continue;
      if (m.to >= 4) {
        if (outsBefore + res.outs >= 3 && res.kind !== "HR" && !isHit) continue; // inning ended first
        score(off, def, br, noRbi ? undefined : bl);
        continue;
      }
      if (m.from !== 0 || m.to !== 0) log.push({ k: "mv", id: br.player.id, from: m.from, to: m.to });
      br.base = m.to as 1 | 2 | 3;
      next[m.to] = br;
    }
    bases = next;
    if (res.outs) recordOut(res.outs);
  }

  function maybeEject(inning: number, off: Side, def: Side, batter: Player, zone: Zone) {
    if (zone < 2 || !batter.traits.includes("HOTHEAD")) return;
    // hecklers and other sabotage can raise the odds of a blow-up
    const mult = mods.incidentMult("EJECTION", [home.team.id, away.team.id]);
    if (!rng.chance(Math.min(0.9, (0.03 + 0.03 * r(ump.stats.temper)) * mult))) return;
    eject(off, batter, inning, def);
  }

  function eject(side: Side, p: Player, inning: number, other: Side) {
    ejections.push(p.id);
    side.ejected.add(p.id);
    fireIncident("EJECTION", inning, side, other, side.team.id, p.id);
    const slot = side.lineup.order.find(s => s.player.id === p.id);
    if (slot) {
      const sub = side.lineup.bench.shift();
      if (sub) {
        log.push({ k: "sub", side: side.key, out: p.id, in: sub.id, pos: slot.pos, why: "ejection" });
        slot.player = sub;
        if (slot.pos !== "DH") side.lineup.defense[slot.pos as Exclude<Pos, "DH">] = sub;
        const l = { id: sub.id, pos: slot.pos, ab: 0, r: 0, h: 0, d: 0, t: 0, hr: 0, rbi: 0, bb: 0, k: 0, sb: 0, cs: 0, hbp: 0, sf: 0 };
        side.bat.set(sub.id, l);
        side.box.bat.push(l);
      }
    }
  }

  function maybeBrawl(inning: number, off: Side, def: Side, batter: Player, pitcher: Player) {
    const hot = batter.traits.includes("HOTHEAD") || pitcher.traits.includes("HOTHEAD");
    const grudge = world.relationships.some(x => ((x.a === batter.id && x.b === pitcher.id) || (x.b === batter.id && x.a === pitcher.id)) && x.value <= -3);
    const p = (hot ? 0.06 : 0.004) + (grudge ? 0.25 : 0);
    if (incidentFired.has("BRAWL") || !rng.chance(p * mods.incidentMult("BRAWL", [home.team.id, away.team.id]))) return;
    fireIncident("BRAWL", inning, off, def, undefined, `${batter.id},${pitcher.id}`);
    eject(off, batter, inning, def);
    // pitcher ejected too: forced change
    const pen = availablePen(def);
    if (pen.length) {
      ejections.push(pitcher.id);
      def.ejected.add(pitcher.id);
      changePitcher(def, pen[0], "ejection");
    }
  }

  function clutchAdj(b: Player, inning: number, off: Side, def: Side, outs: number): number {
    const close = Math.abs(off.box.runs - def.box.runs) <= 2;
    const late = inning >= 7;
    const risp = !!(bases[2] || bases[3]);
    if (!(close && (late || risp))) return 0;
    if (b.traits.includes("CLUTCH")) return 4;
    if (b.traits.includes("CHOKER")) return -5;
    return 0;
  }

  // --- play ball ---------------------------------------------------------------------
  let inning = 1;
  for (;;) {
    playHalf(inning, away, home, false);
    if (inning >= 9 && home.box.runs > away.box.runs) {
      home.box.line.push(NaN); // home didn't bat (shown as "x")
      break;
    }
    playHalf(inning, home, away, inning >= 9);
    if (inning >= 9 && home.box.runs !== away.box.runs) break;
    inning++;
    if (inning > 30) break;
  }
  log.push({ k: "end", home: home.box.runs, away: away.box.runs });

  const winner: "home" | "away" = home.box.runs > away.box.runs ? "home" : "away";
  const decisions = decide(winner === "home" ? home : away, winner === "home" ? away : home);

  return {
    id: spec.id, home: home.box, away: away.box, innings: inning, winner, decisions, log,
    pitchCounts, injuries, ejections, incidents,
  };
}

// ---------------------------------------------------------------------------------------

function choosePitch(rng: Rng, pitches: Pitch[], balls: number, strikes: number): Pitch {
  const behind = balls - strikes >= 2 || balls === 3;
  return rng.weighted(pitches, p => {
    let w = p.usage;
    if (behind && PITCH_FB.includes(p.kind)) w *= 1.7;
    if (strikes === 2 && !PITCH_FB.includes(p.kind)) w *= 1.35;
    return w;
  });
}

function countZoneAdj(b: number, s: number): number {
  const key = `${b}${s}`;
  const t: Record<string, number> = {
    "30": 0.2, "31": 0.1, "20": 0.07, "21": 0.05, "32": 0.08, "10": 0.02, "00": 0.08,
    "11": 0, "22": -0.05, "12": -0.1, "02": -0.17, "01": -0.04,
  };
  return t[key] ?? 0;
}

function swingProb(zone: Zone, b: number, s: number, eye: number, stuff: number): number {
  let p = zone === 0 ? T.swingHeart : zone === 1 ? T.swingEdgeIn : zone === 2 ? T.swingEdgeOut : T.swingWaste;
  if (zone <= 1) p += 0.012 * r(eye);
  else p -= 0.035 * r(eye) - 0.02 * r(stuff);
  if (s === 2) p += zone <= 1 ? 0.13 : 0.1;
  if (b === 3 && s === 0) p -= 0.45;
  else if (b === 3) p -= zone <= 1 ? 0 : 0.06;
  if (b === 0 && s === 0) p -= 0.16;
  return Math.max(0.02, Math.min(0.97, p));
}

function contactProb(zone: Zone, contact: number, stuff: number, velo: number, kind: PitchKind): number {
  let p = zone === 0 ? T.contactHeart : zone === 1 ? T.contactEdgeIn : zone === 2 ? T.contactEdgeOut : T.contactWaste;
  p += 0.035 * r(contact) - 0.04 * r(stuff);
  if (PITCH_FB.includes(kind)) p -= (velo - 93) * 0.004;
  return Math.max(0.2, Math.min(0.98, p));
}

function effectiveSide(b: Player, p: Player): "L" | "R" {
  if (b.bats === "S") return p.throws === "R" ? "L" : "R";
  return b.bats;
}

function platoonAdj(b: Player, p: Player): number {
  const side = effectiveSide(b, p);
  let adj = side !== p.throws ? 2.5 : -2.5;
  if (p.throws === "L") adj += b.batting.vsL;
  return adj;
}

function decide(win: Side, lose: Side): GameResult["decisions"] {
  // simplified decisions: winning pitcher = most outs on the winning side among those
  // who were in when the lead was taken is not tracked; use workload heuristics
  const starterW = win.box.pitch[0];
  const w = starterW.outs >= 15 ? starterW.id : [...win.box.pitch].slice(1).sort((a, b) => b.outs - a.outs)[0]?.id ?? starterW.id;
  const l = [...lose.box.pitch].sort((a, b) => b.r - a.r || b.er - a.er)[0].id;
  const last = win.box.pitch[win.box.pitch.length - 1];
  const margin = win.box.runs - lose.box.runs;
  const s = last.id !== w && margin <= 3 && last.outs >= 3 ? last.id : undefined;
  return { w, l, s };
}
