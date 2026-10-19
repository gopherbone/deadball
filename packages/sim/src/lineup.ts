// Manager AI: who plays where, who bats when, who pitches.

import type { Player, Pos, Team, World } from "./types.ts";

export interface Lineup {
  order: { player: Player; pos: Pos }[]; // 9 batters incl. DH
  defense: Partial<Record<Exclude<Pos, "DH">, Player>>;
  bench: Player[];
}

export interface Staff {
  rotation: Player[];
  closer?: Player;
  setup: Player[];
  middle: Player[];
}

const isPitcher = (p: Player) => p.pos === "P";
const healthy = (p: Player) => !p.injury || p.injury.daysLeft <= 0;

export function offense(p: Player): number {
  const b = p.batting;
  return b.contact * 0.32 + b.power * 0.3 + b.eye * 0.22 + b.gap * 0.08 + b.speed * 0.08;
}

function defenseAt(p: Player, pos: Exclude<Pos, "DH">): number {
  const fam = p.fielding.positions[pos] ?? 0;
  const f = p.fielding;
  const skill = pos === "C"
    ? f.arm * 0.3 + f.hands * 0.3 + f.framing * 0.4
    : pos === "1B"
      ? f.hands * 0.7 + f.range * 0.3
      : pos === "LF" || pos === "RF"
        ? f.range * 0.5 + f.arm * 0.3 + f.hands * 0.2
        : f.range * 0.45 + f.hands * 0.3 + f.arm * 0.25;
  return skill * (0.4 + 0.6 * fam) - (fam < 0.3 ? 25 : 0);
}

// harder positions get filled first
const FILL: Exclude<Pos, "DH" | "P">[] = ["C", "SS", "CF", "2B", "3B", "RF", "LF", "1B"];
const DEF_WEIGHT: Record<string, number> = { C: 0.9, SS: 0.8, CF: 0.7, "2B": 0.6, "3B": 0.5, RF: 0.4, LF: 0.35, "1B": 0.25 };

export function buildLineup(world: World, team: Team, exclude: Set<string> = new Set()): Lineup {
  const hitters = team.roster.map(id => world.players[id]).filter(p => p && !isPitcher(p) && healthy(p) && !exclude.has(p.id));
  const used = new Set<string>();
  const defense: Lineup["defense"] = {};
  for (const pos of FILL) {
    let best: Player | undefined;
    let bestV = -Infinity;
    for (const p of hitters) {
      if (used.has(p.id)) continue;
      const v = offense(p) + defenseAt(p, pos) * DEF_WEIGHT[pos];
      if (v > bestV) { bestV = v; best = p; }
    }
    if (best) { defense[pos] = best; used.add(best.id); }
  }
  const remaining = hitters.filter(p => !used.has(p.id)).sort((a, b) => offense(b) - offense(a));
  const dh = remaining.shift();
  const nine: { player: Player; pos: Pos }[] = FILL.filter(pos => defense[pos]).map(pos => ({ player: defense[pos]!, pos }));
  if (dh) nine.push({ player: dh, pos: "DH" });

  // batting order: OBP-and-speed leadoff, best hitters 2-4, then descending
  const byOff = [...nine].sort((a, b) => offense(b.player) - offense(a.player));
  const leadoffIdx = byOff.slice(0, 5).reduce((bi, x, i, arr) => {
    const s = (q: Player) => q.batting.eye + q.batting.contact + q.batting.speed;
    return s(x.player) > s(arr[bi].player) ? i : bi;
  }, 0);
  const leadoff = byOff.splice(leadoffIdx, 1)[0];
  const order = [leadoff, ...byOff];
  return { order, defense, bench: remaining };
}

export function pitchCap(p: Player): number {
  const s = p.pitching?.stamina ?? 30;
  return 30 + (s - 20) * 1.4;
}

function pitchValue(p: Player): number {
  const r = p.pitching!;
  return r.stuff * 0.4 + r.control * 0.25 + r.command * 0.15 + r.movement * 0.2;
}

export function buildStaff(world: World, team: Team): Staff {
  const arms = team.roster.map(id => world.players[id]).filter(p => p && isPitcher(p) && p.pitching && healthy(p));
  const starters = [...arms].sort((a, b) => (pitchValue(b) + b.pitching!.stamina * 0.6) - (pitchValue(a) + a.pitching!.stamina * 0.6)).slice(0, 5);
  const pen = arms.filter(p => !starters.includes(p)).sort((a, b) => pitchValue(b) - pitchValue(a));
  return { rotation: starters, closer: pen[0], setup: pen.slice(1, 3), middle: pen.slice(3) };
}

/** Pitches thrown in the last `days` days. */
export function recentLoad(p: Player, days: number): number {
  return p.recentPitches.slice(0, days).reduce((a, b) => a + b, 0);
}

export function pickStarter(staff: Staff): Player {
  // most rested member of the rotation
  let best = staff.rotation[0];
  let bestRest = -1;
  for (const p of staff.rotation) {
    const idx = p.recentPitches.findIndex(x => x > 40);
    const rest = idx === -1 ? 99 : idx;
    if (rest > bestRest) { bestRest = rest; best = p; }
  }
  return best;
}

export function relieverAvailable(p: Player): boolean {
  return (p.recentPitches[0] ?? 0) < 25 && recentLoad(p, 3) < 55;
}
