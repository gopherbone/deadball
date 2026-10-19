// The Wire: telegraph-style play-by-play keyed to log indices. All caps, ≤36 chars.

import type { GameResult, LogEv } from "../game.ts";
import type { IncidentKind } from "../incidents.ts";
import type { World } from "../types.ts";
import { ordinal } from "./util.ts";
import { WIRE_MAX, type WireLine } from "./types.ts";

const DIR: Record<string, string> = { P: "THE MOUND", C: "CATCHER", "1B": "FIRST", "2B": "SECOND", "3B": "THIRD", SS: "SHORT", LF: "LEFT", CF: "CENTER", RF: "RIGHT" };
const NUM: Record<string, number> = { P: 1, C: 2, "1B": 3, "2B": 4, "3B": 5, SS: 6, LF: 7, CF: 8, RF: 9 };
const BASE = ["HOME", "FIRST", "SECOND", "THIRD", "HOME"];

function clean(s: string): string {
  return s.toUpperCase().replace(/[^A-Z0-9 \-',.&!?:]/g, "").replace(/\s+/g, " ").trim();
}

/** Pick the first variant that fits; add STOP when there's room. */
function tele(...variants: string[]): string {
  const vs = variants.map(clean).filter(Boolean);
  for (const v of vs) if (v.length + 5 <= WIRE_MAX) return `${v} STOP`;
  for (const v of vs) if (v.length <= WIRE_MAX) return v;
  return vs[vs.length - 1].slice(0, WIRE_MAX).trim();
}

function sprayDir(sp: number): string {
  if (sp < -32) return "DOWN LEFT LINE";
  if (sp < -14) return "TO LEFT";
  if (sp < -5) return "TO LEFT CENTER";
  if (sp <= 5) return "TO CENTER";
  if (sp <= 14) return "TO RIGHT CENTER";
  if (sp <= 32) return "TO RIGHT";
  return "DOWN RIGHT LINE";
}

const INC: Record<IncidentKind, (team: string, who: string) => string[]> = {
  RACCOONS_BULLPEN: t => [`RACCOONS FOUND IN ${t} PEN`, `RACCOONS IN ${t} PEN`, "RACCOONS IN BULLPEN"],
  RACCOON_ON_FIELD: () => ["RACCOON ON FIELD PLAY HALTED", "RACCOON ON FIELD"],
  FOOD_POISONING: t => [`${t} PLAYERS ILL IN DUGOUT`, `${t} ILL`, "PLAYERS ILL"],
  FAN_ON_FIELD: () => ["FAN ON FIELD TACKLED BY USHER", "FAN ON FIELD"],
  LASER_POINTER: t => [`LASER AIMED AT ${t} FROM STANDS`, "LASER FROM STANDS"],
  RAIN_DELAY: () => ["RAIN DELAY TARP ON FIELD", "RAIN DELAY"],
  EJECTION: (_t, w) => [`${w} EJECTED BY UMP`, `${w} EJECTED`, "EJECTION"],
  BRAWL: (_t, w) => [`BENCHES CLEAR ${w} TRADE BLOWS`, `BRAWL ${w}`, "BENCHES CLEAR"],
  BALL_TAMPERING: () => ["UMP REMOVES BALL FROM PLAY", "BALL REMOVED"],
  BLACKOUT: () => ["POWER OUT AT PARK PLAY SUSPENDED", "POWER OUT"],
};

export function wireLines(world: World, res: GameResult): WireLine[] {
  const out: WireLine[] = [];
  // two players in one game with the same surname get an initial
  const inGame = [...res.home.bat, ...res.away.bat, ...res.home.pitch, ...res.away.pitch].map(l => l.id);
  const lastCount = new Map<string, Set<string>>();
  for (const id of inGame) {
    const l = world.players[id]?.last;
    if (l) lastCount.set(l, (lastCount.get(l) ?? new Set()).add(id));
  }
  const nm = (id: string | undefined) => {
    const p = id ? world.players[id] ?? world.npcs[id] : undefined;
    if (!p) return "BATTER";
    return clean((lastCount.get(p.last)?.size ?? 0) > 1 ? `${p.first[0]}. ${p.last}` : p.last);
  };
  const homeId = res.home.teamId, awayId = res.away.teamId;
  const abbr = (id: string) => world.teams[id]?.abbr ?? id;
  const tname = (id: string | undefined) => clean((id && world.teams[id]?.name) || "HOME");
  const push = (i: number, text: string) => out.push({ i, text });
  const log = res.log;
  let top = true;
  let score = { home: 0, away: 0 };
  let batter = "";
  const seenPitcher = { home: "", away: "" };
  let runsThisPa = 0;

  const scoreLine = (i: number) => {
    const a = `${abbr(awayId)} ${score.away} ${abbr(homeId)} ${score.home}`;
    push(i, tele(`SCORE ${a}`, a));
  };

  for (let i = 0; i < log.length; i++) {
    const e: LogEv = log[i];
    switch (e.k) {
      case "half":
        top = e.top;
        push(i, tele(`${e.top ? "TOP" : "BOTTOM"} ${ordinal(e.inn)} ${abbr(e.top ? awayId : homeId)} BATS`, `${e.top ? "TOP" : "BOT"} ${ordinal(e.inn)}`));
        break;
      case "pa": {
        batter = e.bat;
        runsThisPa = 0;
        const defKey = top ? "home" : "away";
        if (seenPitcher[defKey] !== e.pit) {
          if (!seenPitcher[defKey]) push(i, tele(`${nm(e.pit)} ON MOUND FOR ${abbr(top ? homeId : awayId)}`, `${nm(e.pit)} PITCHING`));
          seenPitcher[defKey] = e.pit;
        }
        break;
      }
      case "p": {
        const b = nm(batter);
        if ((e.r === "S" || e.r === "C") && e.s >= 3) push(i, e.r === "S" ? tele(`${b} STRIKES OUT SWINGING`, `${b} FANS`, `${b} K`) : tele(`${b} CALLED OUT ON STRIKES`, `${b} LOOKS AT STRIKE THREE`, `${b} CALLED K`));
        else if (e.r === "B" && e.b >= 4) push(i, tele(`${b} WALKS`, `${b} BB`));
        else if (e.r === "H") push(i, tele(`${b} HIT BY PITCH`, `${b} HBP`));
        break;
      }
      case "bip": {
        const b = nm(batter);
        const f = e.f ?? "";
        const where = f ? DIR[f] : sprayDir(e.sp);
        let runs = 0;
        for (let j = i + 1; j < log.length; j++) {
          const n = log[j];
          if (n.k === "mv") { if (n.to === 4) runs++; continue; }
          break;
        }
        runsThisPa = runs;
        const hard = e.ev >= 100 ? "SHARP " : e.ev < 75 ? "SOFTLY " : "";
        switch (e.res) {
          case "HR": {
            const kind = runs >= 4 ? "GRAND SLAM" : runs === 3 ? "3-RUN HOMER" : runs === 2 ? "2-RUN HOMER" : "SOLO HOMER";
            push(i, tele(`${b} ${kind} ${sprayDir(e.sp)}`, `${b} ${kind}`, `${b} HOMERS`));
            break;
          }
          case "1B":
            push(i, tele(
              e.la > 25 && e.ev < 85 ? `${b} BLOOPS SINGLE ${sprayDir(e.sp)}` : f && NUM[f] <= 6 && e.ev < 90 ? `${b} INFIELD SINGLE TO ${DIR[f]}` : `${b} SINGLES ${hard}${sprayDir(e.sp)}`,
              `${b} SINGLES ${sprayDir(e.sp)}`, `${b} SINGLES`));
            break;
          case "2B": push(i, tele(`${b} DOUBLES ${sprayDir(e.sp)}`, `${b} DOUBLES`)); break;
          case "3B": push(i, tele(`${b} TRIPLES ${sprayDir(e.sp)}`, `${b} TRIPLES`)); break;
          case "OUT": {
            const t = e.out === "GO" ? `GROUNDS OUT TO ${where}` : e.out === "LO" ? `LINES OUT TO ${where}` : e.out === "PO" ? `POPS UP TO ${where}` : `FLIES OUT TO ${where}`;
            push(i, tele(`${b} ${t}`, `${b} OUT ${f}`));
            break;
          }
          case "DP": push(i, tele(`${b} GROUNDS INTO DOUBLE PLAY`, `${b} INTO DP`, `${b} DP`)); break;
          case "FC": push(i, tele(`${b} FIELDERS CHOICE ${f}`, `${b} FC`)); break;
          case "ROE": push(i, tele(`${b} SAFE ON ERROR E${NUM[f] ?? ""}`, `${b} SAFE ON E${NUM[f] ?? ""}`)); break;
          case "FOUL_OUT": push(i, tele(`${b} FOULS OUT TO ${where}`, `${b} FOUL OUT`)); break;
          case "SF": push(i, tele(`${b} SAC FLY TO ${where}`, `${b} SAC FLY`)); break;
          default: push(i, tele(`${b} BALL IN PLAY`));
        }
        break;
      }
      case "mv": {
        if (e.to !== 4) break;
        if (top) score.away++; else score.home++;
        // homers already said who scored; everyone else gets a line
        const prevBip = (() => { for (let j = i - 1; j >= 0; j--) { const n = log[j]; if (n.k === "bip") return n; if (n.k !== "mv") return undefined; } return undefined; })();
        if (!(prevBip && prevBip.res === "HR")) push(i, tele(`${nm(e.id)} SCORES`));
        const next = log[i + 1];
        if (!next || next.k !== "mv" || next.to !== 4) {
          if (runsThisPa >= 0) scoreLine(i);
        }
        break;
      }
      case "sb":
        push(i, e.ok ? tele(`${nm(e.id)} STEALS ${BASE[e.base]}`) : tele(`${nm(e.id)} CAUGHT STEALING ${BASE[e.base]}`, `${nm(e.id)} CAUGHT STEALING`));
        break;
      case "wp":
        push(i, e.pb ? tele("PASSED BALL RUNNERS MOVE UP", "PASSED BALL") : tele("WILD PITCH RUNNERS MOVE UP", "WILD PITCH"));
        break;
      case "sub":
        if (e.pos === "P") {
          seenPitcher[e.side] = e.in;
          const why = e.why === "save situation" ? "FOR SAVE" : e.why === "shelled" ? "SHELLED" : e.why === "tired" ? "TIRES" : e.why === "ejection" ? "TOSSED" : "";
          push(i, tele(why === "FOR SAVE" ? `${nm(e.in)} IN FOR SAVE` : why ? `${nm(e.out)} ${why} ${nm(e.in)} IN` : `${nm(e.in)} RELIEVES ${nm(e.out)}`, `${nm(e.in)} RELIEVES`, `${nm(e.in)} PITCHING`));
        } else push(i, tele(`${nm(e.in)} IN FOR ${nm(e.out)} AT ${e.pos}`, `${nm(e.in)} FOR ${nm(e.out)}`, `${nm(e.in)} SUBS IN`));
        break;
      case "inc": {
        let who = "";
        if (e.who) who = e.who.split(",").map(id => nm(id)).join(" AND ");
        const variants = INC[e.kind]?.(tname(e.team), who) ?? [String(e.kind).replace(/_/g, " ")];
        push(i, tele(...variants));
        break;
      }
      case "ultra": {
        const n = nm(e.who);
        const v: Record<string, string[]> = {
          FIREBALL: [`${n} THROWS FIREBALL`, `${n} FIREBALL`], STOPPER: [`${n} PITCH STOPS IN MIDAIR`, `${n} STOPPER`],
          WARP_PITCH: [`${n} PITCH WARPS INTO ZONE`, `${n} WARP PITCH`], CLOUD_BALL: [`${n} PITCH VANISHES IN CLOUD`, `${n} CLOUD BALL`],
          HYPER_HIT: [`${n} HYPER SWING`, `${n} HYPER`], LEAP_CATCH: [`${n} LEAPS AT WALL`, `${n} LEAPS`],
          LASER_ARM: [`${n} LASER THROW`, `${n} LASER`], WARP_RUN: [`${n} WARPS TO NEXT BASE`, `${n} WARPS`],
        };
        push(i, tele(...(v[e.power] ?? [`${n} USES ${String(e.power).replace(/_/g, " ")}`, `${n} POWER`])));
        break;
      }
      case "end": {
        score = { home: e.home, away: e.away };
        const a = `${abbr(awayId)} ${e.away} ${abbr(homeId)} ${e.home}`;
        push(i, tele(`FINAL ${a}${res.innings > 9 ? ` IN ${res.innings}` : ""}`, `FINAL ${a}`));
        const w = res.decisions.w, l = res.decisions.l;
        push(i, tele(`WP ${nm(w)} LP ${nm(l)}${res.decisions.s ? ` SV ${nm(res.decisions.s)}` : ""}`, `WP ${nm(w)} LP ${nm(l)}`));
        break;
      }
    }
  }
  return out;
}
