// Batted-ball flight. Field coordinates in feet: home plate at the origin, +y toward
// center field, +x toward the first-base side, +z up. Spray angle in degrees:
// 0 = straight to CF, -45 = down the LF line, +45 = down the RF line.

import type { Park, Weather } from "./types.ts";

const MPH = 1.46667; // ft/s per mph
const G = 32.174;
const RHO0 = 0.0023769; // slug/ft^3 at 70°F, sea level
// 0.5 * rho0 * Cd * A / m with Cd≈0.35, A=0.0459 ft², m=0.00994 slug
const KD = (0.5 * RHO0 * 0.35 * 0.0459) / 0.00994;
const KL = (0.5 * RHO0 * 0.0459) / 0.00994;
const DT = 0.01;

export interface Flight {
  /** Horizontal distance from home where it would land (ignoring walls). */
  distance: number;
  hang: number;
  apex: number;
  landX: number;
  landY: number;
  /** Height when crossing the given horizontal distance, or -1 if it never gets there. */
  heightAt: (dist: number) => number;
  /** Coarse path samples every 0.1 s, [x, y, z], for replays. */
  path: [number, number, number][];
}

export function airDensityRatio(w: Weather, park: Park): number {
  return (529.67 / (459.67 + w.tempF)) * Math.exp(-park.altitudeFt / 27000);
}

function liftCoefficient(la: number): number {
  // backspin on lofted balls, topspin on choppers
  if (la < 0) return -0.06;
  if (la < 10) return 0.0;
  if (la < 20) return 0.1;
  if (la < 50) return 0.18;
  return 0.05; // pop-ups spin, but mostly go up
}

export function sprayDir(spray: number): [number, number] {
  const r = (spray * Math.PI) / 180;
  return [Math.sin(r), Math.cos(r)];
}

export function fly(evMph: number, la: number, spray: number, w: Weather, park: Park): Flight {
  const rho = airDensityRatio(w, park);
  const [dx, dy] = sprayDir(spray);
  const [wx, wy] = sprayDir(w.windDir);
  const wind = w.windMph * MPH;
  const v0 = evMph * MPH;
  const laR = (la * Math.PI) / 180;
  let h = 0; // horizontal distance along spray direction
  let z = 3;
  let vh = v0 * Math.cos(laR);
  let vz = v0 * Math.sin(laR);
  // wind component along the ball's direction (crosswind ignored for distance)
  const windAlong = wind * (wx * dx + wy * dy);
  const cl = liftCoefficient(la);
  let t = 0;
  let apex = z;
  const samples: { h: number; z: number }[] = [{ h, z }];
  const path: [number, number, number][] = [[0, 0, 3]];
  let nextSample = 0.1;
  while (z > 0 && t < 12) {
    const rh = vh - windAlong;
    const speed = Math.hypot(rh, vz);
    const drag = KD * rho * speed;
    const lift = KL * rho * cl * speed;
    // lift acts perpendicular to the relative velocity, in the vertical plane
    const ah = -drag * rh - lift * vz;
    const az = -drag * vz + lift * rh - G;
    vh += ah * DT;
    vz += az * DT;
    h += vh * DT;
    z += vz * DT;
    t += DT;
    if (z > apex) apex = z;
    samples.push({ h, z });
    if (t >= nextSample) {
      path.push([h * dx, h * dy, Math.max(0, z)]);
      nextSample += 0.1;
    }
  }
  const heightAt = (dist: number): number => {
    for (let i = 1; i < samples.length; i++) {
      if (samples[i].h >= dist) {
        const a = samples[i - 1], b = samples[i];
        const f = (dist - a.h) / (b.h - a.h || 1);
        return a.z + (b.z - a.z) * f;
      }
    }
    return -1;
  };
  path.push([h * dx, h * dy, 0]);
  return { distance: h, hang: t, apex, landX: h * dx, landY: h * dy, heightAt, path };
}

/** Wall distance and height at a given spray angle, interpolated across the 5 posts. */
export function fenceAt(park: Park, spray: number): { dist: number; height: number } {
  const s = Math.max(-45, Math.min(45, spray));
  const idx = (s + 45) / 22.5;
  const i = Math.min(3, Math.floor(idx));
  const f = idx - i;
  return {
    dist: park.fences[i] + (park.fences[i + 1] - park.fences[i]) * f,
    height: park.walls[i] + (park.walls[i + 1] - park.walls[i]) * f,
  };
}

/**
 * Ground ball: distance travelled along the spray line after t seconds.
 * Exponential slowdown from friction and bounces; turf plays faster.
 */
export function groundDistance(evMph: number, la: number, t: number, turf: boolean): number {
  // a chopper bleeds energy into the bounce; a 0-5° worm-burner keeps it
  const loss = la < -5 ? 0.62 : la < 3 ? 0.78 : 0.7;
  const v0 = evMph * MPH * loss;
  const c = turf ? 0.16 : 0.24;
  return (v0 * (1 - Math.exp(-c * t))) / c;
}
