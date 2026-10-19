// world.stats, stored per season (DO SQLite table `stats`, one row per (season, person)).
//
// world.stats[personId][season] grows by a season a year and was half the world blob after ten
// seasons, rewritten person by person every day. Now:
//   - the current season is HOT: in memory as world.stats[pid][season] and diffed on every save
//     (only the rows that changed today are written);
//   - older seasons are FROZEN when the season rolls over: never rewritten, not loaded at boot,
//     and read on demand: one person's seasons (personSeasons / hydrate, for person pages) or
//     every season (ensureArchive, for day ticks and card backs, which read career totals).
// Archived rows are only deleted (a forgotten minor-leaguer's lines) when the archive is in memory.

import type { World } from "./sim.ts";

type SeasonStats = World["stats"][string][number];

export class StatsStore {
  private readonly sql: SqlStorage;
  /** season the hot cache belongs to */
  hotSeason = 0;
  /** pid -> JSON of the hot season's row as last written */
  private hot = new Map<string, string>();
  /** archived rows currently in world.stats ("season|pid"): what deletions are checked against */
  private inMem = new Set<string>();
  /** pids whose archived seasons are in memory */
  private hydrated = new Set<string>();
  /** every archived season is in memory */
  archiveLoaded = false;
  /** what the last save wrote, by season (tests, /admin/status) */
  lastSave: { written: number; deleted: number; bytes: number; seasons: number[] } = { written: 0, deleted: 0, bytes: 0, seasons: [] };

  constructor(sql: SqlStorage) {
    this.sql = sql;
    sql.exec("CREATE TABLE IF NOT EXISTS stats (season INTEGER NOT NULL, pid TEXT NOT NULL, v TEXT NOT NULL, PRIMARY KEY (season, pid))");
    sql.exec("CREATE INDEX IF NOT EXISTS stats_pid ON stats (pid, season)");
  }

  /** Any rows at all (false on a fresh DO, or before the one-time migration). */
  hasRows(): boolean {
    return this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM (SELECT 1 FROM stats LIMIT 1)").one().n > 0;
  }

  clear() {
    this.sql.exec("DELETE FROM stats");
    this.hot.clear();
    this.inMem.clear();
    this.hydrated.clear();
    this.archiveLoaded = false;
    this.hotSeason = 0;
  }

  /** Boot: the hot season only. Returns a fresh world.stats. */
  loadHot(season: number): World["stats"] {
    this.hotSeason = season;
    this.hot.clear();
    this.inMem.clear();
    this.hydrated.clear();
    this.archiveLoaded = false;
    const out: World["stats"] = {};
    for (const r of this.sql.exec<{ pid: string; v: string }>("SELECT pid, v FROM stats WHERE season = ?", season)) {
      (out[r.pid] ??= {})[season] = JSON.parse(r.v) as SeasonStats;
      this.hot.set(r.pid, r.v);
    }
    return out;
  }

  /** Every archived season into world.stats (idempotent). Day ticks call this first. */
  ensureArchive(world: World) {
    if (this.archiveLoaded) return;
    for (const r of this.sql.exec<{ season: number; pid: string; v: string }>("SELECT season, pid, v FROM stats WHERE season < ?", this.hotSeason)) {
      const key = `${r.season}|${r.pid}`;
      if (this.inMem.has(key)) continue;
      (world.stats[r.pid] ??= {})[r.season] = JSON.parse(r.v) as SeasonStats;
      this.inMem.add(key);
    }
    this.archiveLoaded = true;
  }

  /** Archived seasons of a few people into world.stats (person pages, a card back or two). */
  hydrate(world: World, pids: string[]) {
    const want = this.archiveLoaded ? [] : [...new Set(pids)].filter(p => !this.hydrated.has(p));
    if (!want.length) return;
    for (const r of this.sql.exec<{ season: number; pid: string; v: string }>(
      "SELECT season, pid, v FROM stats WHERE season < ? AND pid IN (SELECT value FROM json_each(?))", this.hotSeason, JSON.stringify(want))) {
      const key = `${r.season}|${r.pid}`;
      if (this.inMem.has(key)) continue;
      (world.stats[r.pid] ??= {})[r.season] = JSON.parse(r.v) as SeasonStats;
      this.inMem.add(key);
    }
    for (const p of want) this.hydrated.add(p);
  }

  /** One person's every season, straight from storage plus the hot season (doesn't touch world.stats). */
  personSeasons(world: World, pid: string): Record<number, SeasonStats> {
    const out: Record<number, SeasonStats> = {};
    for (const r of this.sql.exec<{ season: number; v: string }>("SELECT season, v FROM stats WHERE pid = ? AND season < ?", pid, this.hotSeason)) out[r.season] = JSON.parse(r.v);
    for (const [s, v] of Object.entries(world.stats[pid] ?? {})) out[Number(s)] = v;
    return out;
  }

  /**
   * Persist: diff the hot season; on a season rollover, give the old season one last diff and
   * freeze it; drop archived rows whose people were removed from world.stats (only checkable for
   * rows in memory). Returns rows written/deleted and bytes.
   */
  save(world: World): { written: number; deleted: number; bytes: number } {
    let written = 0, deleted = 0, bytes = 0;
    const seasons = new Set<number>();
    const put = (season: number, pid: string, v: string) => { this.sql.exec("INSERT OR REPLACE INTO stats (season, pid, v) VALUES (?, ?, ?)", season, pid, v); written++; bytes += v.length; seasons.add(season); };
    const del = (season: number, pid: string) => { this.sql.exec("DELETE FROM stats WHERE season = ? AND pid = ?", season, pid); deleted++; };
    const diffHot = (season: number) => {
      const seen = new Set<string>();
      for (const [pid, by] of Object.entries(world.stats)) {
        const s = by[season];
        if (!s) continue;
        seen.add(pid);
        const v = JSON.stringify(s);
        if (this.hot.get(pid) !== v) { put(season, pid, v); this.hot.set(pid, v); }
      }
      for (const pid of [...this.hot.keys()]) if (!seen.has(pid)) { del(season, pid); this.hot.delete(pid); }
    };
    if (this.hotSeason && world.season !== this.hotSeason) {
      // rollover: the finished season gets its last write, then joins the archive (still in memory)
      const old = this.hotSeason;
      diffHot(old);
      for (const pid of this.hot.keys()) this.inMem.add(`${old}|${pid}`);
      this.hot.clear();
      // the archive in memory is complete only if it was before
      this.hotSeason = world.season;
    }
    if (!this.hotSeason) this.hotSeason = world.season;
    diffHot(this.hotSeason);
    for (const key of [...this.inMem]) {
      const i = key.indexOf("|");
      const season = Number(key.slice(0, i)), pid = key.slice(i + 1);
      if (!world.stats[pid]?.[season]) { del(season, pid); this.inMem.delete(key); }
    }
    this.lastSave = { written, deleted, bytes, seasons: [...seasons].sort((a, b) => a - b) };
    return { written, deleted, bytes };
  }

  /** One-time migration from the old layout (stats inside the world blob): write every season. */
  importAll(world: World) {
    this.clear();
    this.hotSeason = world.season;
    for (const [pid, by] of Object.entries(world.stats ?? {})) {
      for (const [s, st] of Object.entries(by)) {
        const season = Number(s), v = JSON.stringify(st);
        this.sql.exec("INSERT OR REPLACE INTO stats (season, pid, v) VALUES (?, ?, ?)", season, pid, v);
        if (season === world.season) this.hot.set(pid, v);
        else this.inMem.add(`${season}|${pid}`);
      }
    }
    this.archiveLoaded = true;
  }

  /** Rows and bytes per season, for /admin/status and tests. */
  info(): { hotSeason: number; archiveLoaded: boolean; seasons: { season: number; rows: number; bytes: number }[] } {
    const seasons = this.sql.exec<{ season: number; rows: number; bytes: number }>("SELECT season, COUNT(*) AS rows, SUM(LENGTH(v)) AS bytes FROM stats GROUP BY season ORDER BY season").toArray();
    return { hotSeason: this.hotSeason, archiveLoaded: this.archiveLoaded, seasons };
  }
}
