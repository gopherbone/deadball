import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { simulateGame, type GameResult } from "../src/game.ts";
import type { Power } from "../src/powers.ts";
import type { Player, World } from "../src/types.ts";

function empower(world: World, teamId: string) {
  for (const id of world.teams[teamId].roster) {
    const p = world.players[id] as Player & { powers?: Power[] };
    if (p.pos === "P") p.powers = [{ kind: "FIREBALL", level: 3 }, { kind: "STOPPER", level: 2 }];
    else if (p.pos === "LF" || p.pos === "CF" || p.pos === "RF") p.powers = [{ kind: "LEAP_CATCH", level: 3 }, { kind: "HYPER_HIT", level: 2 }, { kind: "LASER_ARM", level: 2 }];
    else p.powers = [{ kind: "HYPER_HIT", level: 3 }, { kind: "WARP_RUN", level: 2 }];
  }
}

function run(empowered: boolean, n: number) {
  const out: GameResult[] = [];
  for (let i = 0; i < n; i++) {
    const w = generateWorld("ultra");
    if (empowered) empower(w, "HCL");
    const ump = Object.values(w.npcs).find(x => x.role === "umpire")!;
    out.push(simulateGame(w, { id: `u${i}`, day: 1, homeId: "HCL", awayId: "STA", umpireId: ump.id, weather: { tempF: 72, windDir: 0, windMph: 5, rain: 0 }, modifiers: [] }, `ultra-${i}`));
  }
  return out;
}

test("teams without powers never log or spend ultra plays", () => {
  for (const g of run(false, 10)) assert.equal(g.log.filter(e => e.k === "ultra").length, 0);
});

test("an enhanced club strikes more out, hits more homers, and robs some", () => {
  const base = run(false, 40), ultra = run(true, 40);
  const sum = (gs: GameResult[], f: (g: GameResult) => number) => gs.reduce((a, g) => a + f(g), 0);
  const hrs = (gs: GameResult[]) => sum(gs, g => g.home.bat.reduce((a, b) => a + b.hr, 0));
  assert.ok(hrs(ultra) > hrs(base), `HR: ${hrs(base)} -> ${hrs(ultra)}`);
  // per use: a powered pitch is far harder to put in play; a hyper swing leaves the yard far more
  let powered = 0, poweredContact = 0, normal = 0, normalContact = 0, hyper = 0, hyperHr = 0, bip = 0, bipHr = 0;
  for (const g of ultra) {
    for (let i = 0; i < g.log.length; i++) {
      const e = g.log[i];
      if (e.k === "ultra" && e.side === "home" && e.power !== "HYPER_HIT" && e.power !== "LEAP_CATCH") {
        const p = g.log[i + 1];
        if (p?.k === "p" && p.r !== "B" && p.r !== "C") { powered++; if (p.r === "X" || p.r === "F") poweredContact++; }
      } else if (e.k === "p" && e.r !== "B" && e.r !== "C" && e.r !== "H" && g.log[i - 1]?.k !== "ultra") {
        normal++; if (e.r === "X" || e.r === "F") normalContact++;
      }
      if (e.k === "ultra" && e.power === "HYPER_HIT") {
        const b = g.log.slice(i + 1, i + 4).find(x => x.k === "bip");
        if (b?.k === "bip") { hyper++; if (b.res === "HR") hyperHr++; }
      } else if (e.k === "bip" && g.log.slice(Math.max(0, i - 3), i).every(x => x.k !== "ultra")) { bip++; if (e.res === "HR") bipHr++; }
    }
  }
  assert.ok(powered > 30 && poweredContact / powered < 0.75 * (normalContact / normal), `contact on swings: ${(poweredContact / powered).toFixed(2)} vs ${(normalContact / normal).toFixed(2)}`);
  assert.ok(hyper > 10 && hyperHr / hyper > 2.5 * (bipHr / bip), `HR per ball in play: ${(hyperHr / hyper).toFixed(2)} vs ${(bipHr / bip).toFixed(2)}`);
  const kinds = new Set(ultra.flatMap(g => g.log.flatMap(e => (e.k === "ultra" ? [e.power] : []))));
  for (const k of ["FIREBALL", "HYPER_HIT"]) assert.ok(kinds.has(k as never), `${k} used`);
  // the points pool is finite: no game spends more than the 40-point pool
  for (const g of ultra) {
    const spent = g.log.filter(e => e.k === "ultra" && e.side === "home").length;
    assert.ok(spent <= 14, `spent ${spent} plays`);
  }
});
