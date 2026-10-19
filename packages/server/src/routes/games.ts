import type { Ctx } from "../router.ts";
import { pubGameId, type GameRow } from "../league.ts";
import { fail } from "../http.ts";
import { sim } from "../sim.ts";
import { partialLine, teamRef, type GameSummaryRow } from "../views.ts";
import { airedPitches, gameRow, gameStatus, slateGames, slateGame } from "./common.ts";

export async function today(c: Ctx) {
  const d = c.L.shownDay(c.now);
  // the shown day's games, plus yesterday's still on the air first (first pitches are staggered, so
  // the last few broadcasts run into the next day); Continental games, then exhibitions, then the
  // Enhanced League's (firstPitchAt says when each one goes)
  const rows = (await c.db.prepare(`SELECT * FROM games WHERE level IN ('ML', 'EL')
      AND ((season = ? AND day = ?) OR (first_pitch_at > ? AND first_pitch_at <= ? AND simmed = 1 AND first_pitch_at + air_ms > ?))
      ORDER BY CASE WHEN season = ? AND day = ? THEN 1 ELSE 0 END, CASE WHEN level = 'EL' THEN 2 WHEN id LIKE '%EX%' THEN 1 ELSE 0 END, slot, id`)
    .bind(d.season, d.day, c.now - 2 * c.L.dayMs, c.now, c.now, d.season, d.day).all<GameRow>()).results;
  return { day: d.day, games: await slateGames(c, rows) };
}

export async function detail(c: Ctx) {
  const row = await gameRow(c, c.params[0]);
  const [g] = await slateGames(c, [row]);
  const status = gameStatus(row, c.now);
  // ?lite=1: just what the BallCast replay needs (teams, status, your bet, payouts); skips the
  // box score so a Playdate decodes a few hundred bytes instead of ~8 KB
  if (c.q.get("lite") === "1") {
    c.L.noteSeen(c.acct.id, `log:${row.id}`, c.now);  // BallCast's first fetch (odd jobs: replay reports)
    const gl = g as Record<string, unknown>;
    return { id: gl.id, status, home: gl.home, away: gl.away, myBet: gl.myBet, pool: gl.pool };
  }
  const out: Record<string, unknown> = { ...g, incidents: [] };
  if (row.summary && status !== "scheduled") {
    const sum = JSON.parse(row.summary) as GameSummaryRow;
    if (status === "final") {
      out.box = sum.box;
      out.line = sum.line;
      out.decisions = sum.decisions;
      out.incidents = sum.inc.map(i => ({ inning: i.inning, text: i.text }));
      if (sum.notes?.length) out.notes = sum.notes;
      if (row.story_id) out.storyId = row.story_id;
    } else {
      const k = airedPitches(row, sum, c.now);
      out.line = partialLine(sum, k);
      out.incidents = sum.inc.filter(i => i.i <= k).map(i => ({ inning: i.inning, text: i.text }));
    }
  }
  return out;
}

/** events per /log page: keeps a page well under the ~48 KB Playdate budget */
const LOG_PAGE = 400;

/** Index into the log up to which events have aired (exclusive). */
function cutIndex(log: { k: string }[], pitches: number): number {
  let seen = 0;
  for (let i = 0; i < log.length; i++) {
    if (log[i].k === "p") {
      if (seen === pitches) return i;
      seen++;
    }
  }
  return log.length;
}

async function loadLog(c: Ctx) {
  const row = await gameRow(c, c.params[0]);
  if (!row.has_log) fail("not_found", "no replay for this game (box score only)");
  const status = gameStatus(row, c.now);
  const doc = status === "scheduled" ? undefined : await c.L.getLog(row.id);
  if (status !== "scheduled" && !doc) fail("not_found", "replay missing");
  let cut = doc ? doc.log.length : 0;
  if (status === "live" && row.summary && doc) cut = cutIndex(doc.log as { k: string }[], airedPitches(row, JSON.parse(row.summary) as GameSummaryRow, c.now));
  return { row, status, doc, cut };
}

/**
 * Compact log ("?fmt=c"): the events as ONE string, so a Playdate's JSON decoder makes one
 * string instead of ~600 tables (the client parses events lazily, a few per frame).
 * One event per line: `k` then tab-separated `key=value`. Values: number as is; `!1`/`!0`
 * boolean; `#a,b,c` number array; `@<json>` anything else nested; a string that would read
 * as one of those (or is empty) gets a leading `'`. Tabs/newlines in strings become spaces.
 * Decoder: BallCast.Timeline.decodeC (playdate/source/ballcast/timeline.lua).
 */
export function encodeLogC(events: Record<string, unknown>[]): string { return encodeLogLines(events).join("\n"); }

function encodeLogLines(events: Record<string, unknown>[]): string[] {
  const val = (v: unknown): string => {
    if (typeof v === "number") return String(v);
    if (typeof v === "boolean") return v ? "!1" : "!0";
    if (typeof v === "string") {
      const s = v.replace(/[\t\n\r]/g, " ");
      return s === "" || /^[!#@'-.0-9]/.test(s) ? "'" + s : s;
    }
    if (Array.isArray(v) && v.every(x => typeof x === "number")) return "#" + v.join(",");
    return "@" + JSON.stringify(v).replace(/[\t\n]/g, " ");
  };
  return events.map(e => {
    const parts = [String(e.k)];
    for (const [key, v] of Object.entries(e)) if (key !== "k" && v !== undefined && v !== null) parts.push(key + "=" + val(v));
    return parts.join("\t");
  });
}

/** compact pages stop before this many characters (a full 9 innings is ~35 KB) */
const LOGC_PAGE_CHARS = 36_000;

export async function log(c: Ctx) {
  const { row, status, doc, cut } = await loadLog(c);
  // odd jobs: a "watched to the final out" report must follow a real fetch of this log
  c.L.noteSeen(c.acct.id, `log:${row.id}`, c.now);
  const from = Math.max(0, Number(c.q.get("from") ?? 0) | 0);
  const compact = c.q.get("fmt") === "c";
  let to = Math.min(cut, from + LOG_PAGE);
  const out: Record<string, unknown> = {
    id: row.id, status, from, people: doc?.people ?? {}, park: doc?.park ?? null, total: status === "final" ? cut : undefined,
  };
  if (compact) {
    // a whole game usually fits one compact page (no paging round trips); cap by size
    const lines = encodeLogLines((doc ? doc.log.slice(from, cut) : []) as Record<string, unknown>[]);
    let n = 0, chars = 0;
    while (n < lines.length && (n === 0 || chars + lines[n].length + 1 <= LOGC_PAGE_CHARS)) chars += lines[n++].length + 1;
    out.logc = lines.slice(0, n).join("\n");
    out.n = n;
    to = from + n;
  } else {
    out.log = doc ? doc.log.slice(from, to) : [];
  }
  if (to < cut) out.next = to;
  return out;
}

export async function wire(c: Ctx) {
  const { doc, cut } = await loadLog(c);
  return { lines: (doc?.wire ?? []).filter(l => l.i < cut) };
}

export function standingsRoute(c: Ctx) {
  const level = (c.q.get("level") ?? "ML").toUpperCase();
  if (!["ML", "AA", "B", "D", "EL"].includes(level)) fail("bad_request", "level must be ML, AA, B, D or EL");
  const w = c.L.world;
  const rows = sim.standings(w, c.L.state, level as "ML").map(s => ({ ...s, team: teamRef(w, s.teamId) }));
  const out: Record<string, unknown> = { level, rows };
  // playoff brackets: the Continental Series (ML) and the Mirage Cup (EL)
  const po = level === "EL" ? c.L.state.enhancedPlayoff : level === "ML" ? c.L.state.playoff : undefined;
  if (po?.series?.length) {
    out.playoff = {
      name: level === "EL" ? "The Mirage Cup" : "The Continental Series",
      series: po.series.map(s => ({
        id: s.id, round: s.round, high: teamRef(w, s.high), low: teamRef(w, s.low), need: s.need,
        wins: { high: s.wins[s.high] ?? 0, low: s.wins[s.low] ?? 0 }, ...(s.winner ? { winner: s.winner } : {}),
      })),
      ...(po.champion ? { champion: teamRef(w, po.champion) } : {}), ...(po.finalScore ? { finalScore: po.finalScore } : {}),
    };
  }
  return out;
}

export async function schedule(c: Ctx) {
  const L = c.L, w = L.world;
  const q = c.q.get("team");
  const lv = (c.q.get("level") ?? "").toUpperCase();
  if (!q && lv === "EL") return levelSchedule(c, "EL");
  if (!q) fail("bad_request", "team is required (or level=EL for the Enhanced League slate)");
  const team = w.teams[q!] ?? Object.values(w.teams).find(t => t.abbr.toLowerCase() === q!.toLowerCase());
  if (!team) fail("not_found", "no such team");
  const cur = L.shownDay(c.now).day;
  const from = Number(c.q.get("from") || cur - 3), to = Number(c.q.get("to") || cur + 7);
  if (!Number.isInteger(from) || !Number.isInteger(to) || to < from || to - from > 30) fail("bad_request", "from/to must be days, at most 30 apart");
  const season = L.state.season;
  const rows = (await c.db.prepare("SELECT * FROM games WHERE season = ? AND day BETWEEN ? AND ? AND (home_id = ? OR away_id = ?) ORDER BY day, slot")
    .bind(season, from, to, team!.id, team!.id).all<GameRow>()).results;
  const have = new Set(rows.map(r => r.id));
  // future games not materialised in D1 yet: synthesise from the season schedule
  const extra: GameRow[] = L.state.schedule
    .filter(g => g.day >= from && g.day <= to && (g.homeId === team!.id || g.awayId === team!.id) && !have.has(pubGameId(season, g.id)))
    .map(g => ({
      id: pubGameId(season, g.id), season, day: g.day, level: g.level, slot: g.slot, home_id: g.homeId, away_id: g.awayId, umpire_id: g.umpireId,
      weather: JSON.stringify(g.weather), first_pitch_at: L.pitchFor(g).at, air_ms: L.pitchFor(g).air, simmed: 0, settled: 0,
      home_runs: null, away_runs: null, innings: null, winner: null, pool_home: 0, pool_away: 0, probables: null, summary: null, story_id: null, has_log: 0, house: null,
    }));
  const all = [...rows, ...extra].sort((a, b) => a.day - b.day || a.slot - b.slot);
  const views = await slateGames(c, rows);
  const byId = new Map(views.map(v => [v.id, v]));
  return { games: all.map(r => byId.get(r.id) ?? slateGame(L, r, c.now)) };
}

/** GET /schedule?level=EL[&from=&to=]: the Enhanced League's games (and exhibitions) day by day, default yesterday..+3. */
async function levelSchedule(c: Ctx, level: "EL") {
  const L = c.L, season = L.state.season;
  const cur = L.shownDay(c.now).day;
  const from = Number(c.q.get("from") || cur - 1), to = Number(c.q.get("to") || cur + 3);
  if (!Number.isInteger(from) || !Number.isInteger(to) || to < from || to - from > 7) fail("bad_request", "from/to must be days, at most 7 apart");
  const elTeams = Object.values(L.world.teams).filter(t => t.level === level).map(t => t.id);
  const rows = (await c.db.prepare(`SELECT * FROM games WHERE season = ? AND day BETWEEN ? AND ? AND (level = ? OR (id LIKE '%EX%' AND (home_id IN (SELECT value FROM json_each(?)) OR away_id IN (SELECT value FROM json_each(?)))))
      ORDER BY day, slot, id`).bind(season, from, to, level, JSON.stringify(elTeams), JSON.stringify(elTeams)).all<GameRow>()).results;
  const have = new Set(rows.map(r => r.id));
  const extra: GameRow[] = L.state.schedule
    .filter(g => g.day >= from && g.day <= to && (g.level === level || (g.exhibition && (elTeams.includes(g.homeId) || elTeams.includes(g.awayId)))) && !have.has(pubGameId(season, g.id)))
    .map(g => ({
      id: pubGameId(season, g.id), season, day: g.day, level: g.level, slot: g.slot, home_id: g.homeId, away_id: g.awayId, umpire_id: g.umpireId,
      weather: JSON.stringify(g.weather), first_pitch_at: L.pitchFor(g).at, air_ms: L.pitchFor(g).air, simmed: 0, settled: 0,
      home_runs: null, away_runs: null, innings: null, winner: null, pool_home: 0, pool_away: 0, probables: null, summary: null, story_id: null, has_log: 0, house: null,
    }));
  const views = new Map((await slateGames(c, rows)).map(v => [v.id, v]));
  const all = [...rows, ...extra].sort((a, b) => a.day - b.day || a.slot - b.slot);
  return { level, games: all.map(r => views.get(r.id) ?? slateGame(L, r, c.now)) };
}
