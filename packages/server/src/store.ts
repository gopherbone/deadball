// Incremental persistence of big JSON objects (World, SeasonState) in Durable Object
// SQLite. An object is exploded into rows:
//   "$"              root scalars + small fields
//   "r:<field>:<id>" one row per entry of a large record (players, npcs, results, stats...)
//   "a:<field>:<n>"  fixed-size chunks of large arrays (schedule, relationships...)
// We keep the last-written JSON of every row in memory and on save only write rows whose
// JSON changed (and delete rows that disappeared). So a day tick writes the players that
// changed plus a handful of results instead of the whole multi-MB world.

const REC_MIN = 16;    // records with at least this many object values get per-entry rows
const ARR_MIN = 300;   // arrays longer than this are chunked
const ARR_CHUNK = 250;

function isRecordOfObjects(v: unknown): v is Record<string, object> {
  if (!v || typeof v !== "object" || Array.isArray(v)) return false;
  const vals = Object.values(v);
  return vals.length >= REC_MIN && vals.every(x => x !== null && typeof x === "object");
}

export function explode(obj: Record<string, unknown>): Map<string, string> {
  const out = new Map<string, string>();
  const root: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (isRecordOfObjects(v)) {
      for (const [id, e] of Object.entries(v)) out.set(`r:${k}:${id}`, JSON.stringify(e));
      out.set(`m:${k}`, "{}"); // marker so an emptied-then-refilled record round-trips
    } else if (Array.isArray(v) && v.length > ARR_MIN) {
      for (let i = 0; i * ARR_CHUNK < v.length; i++) out.set(`a:${k}:${i}`, JSON.stringify(v.slice(i * ARR_CHUNK, (i + 1) * ARR_CHUNK)));
    } else {
      root[k] = v;
    }
  }
  out.set("$", JSON.stringify(root));
  return out;
}

export function implode(rows: Iterable<[string, string]>): Record<string, unknown> {
  let root: Record<string, unknown> = {};
  const recs: Record<string, Record<string, unknown>> = {};
  const arrs: Record<string, [number, unknown[]][]> = {};
  for (const [key, val] of rows) {
    if (key === "$") root = JSON.parse(val);
    else if (key.startsWith("m:")) recs[key.slice(2)] ??= {};
    else if (key.startsWith("r:")) {
      const i = key.indexOf(":", 2);
      (recs[key.slice(2, i)] ??= {})[key.slice(i + 1)] = JSON.parse(val);
    } else if (key.startsWith("a:")) {
      const i = key.lastIndexOf(":");
      (arrs[key.slice(2, i)] ??= []).push([Number(key.slice(i + 1)), JSON.parse(val)]);
    }
  }
  for (const [k, v] of Object.entries(recs)) root[k] = v;
  for (const [k, chunks] of Object.entries(arrs)) root[k] = chunks.sort((a, b) => a[0] - b[0]).flatMap(c => c[1]);
  return root;
}

export class BlobStore {
  private readonly cache = new Map<string, Map<string, string>>();
  private readonly storage: DurableObjectStorage;
  constructor(storage: DurableObjectStorage) {
    this.storage = storage;
    storage.sql.exec("CREATE TABLE IF NOT EXISTS blob (ns TEXT NOT NULL, k TEXT NOT NULL, v TEXT NOT NULL, PRIMARY KEY (ns, k))");
    storage.sql.exec("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)");
  }

  load<T>(ns: string): T | undefined {
    const rows = this.storage.sql.exec<{ k: string; v: string }>("SELECT k, v FROM blob WHERE ns = ?", ns).toArray();
    if (!rows.length) return undefined;
    const m = new Map(rows.map(r => [r.k, r.v] as [string, string]));
    this.cache.set(ns, m);
    return implode(m) as T;
  }

  /** Writes changed rows only. Returns how many rows were written/deleted. */
  save(ns: string, obj: object): { written: number; deleted: number; bytes: number } {
    const next = explode(obj as Record<string, unknown>);
    const prev = this.cache.get(ns) ?? new Map<string, string>();
    let written = 0, deleted = 0, bytes = 0;
    this.storage.transactionSync(() => {
      for (const [k, v] of next) {
        if (prev.get(k) === v) continue;
        this.storage.sql.exec("INSERT OR REPLACE INTO blob (ns, k, v) VALUES (?, ?, ?)", ns, k, v);
        written++; bytes += v.length;
      }
      for (const k of prev.keys()) {
        if (next.has(k)) continue;
        this.storage.sql.exec("DELETE FROM blob WHERE ns = ? AND k = ?", ns, k);
        deleted++;
      }
    });
    this.cache.set(ns, next);
    return { written, deleted, bytes };
  }

  /** Save one large record/array field only (e.g. world.npcs after a hire). */
  saveField(ns: string, obj: object, field: string): number {
    const v = (obj as Record<string, unknown>)[field];
    const next = explode({ [field]: v });
    next.delete("$");
    const prev = this.cache.get(ns) ?? new Map<string, string>();
    if (prev.get("$")?.includes(`"${field}":`)) { this.save(ns, obj); return -1; } // field lives in the root row
    let n = 0;
    this.storage.transactionSync(() => {
      for (const [k, val] of next) {
        if (prev.get(k) === val) continue;
        this.storage.sql.exec("INSERT OR REPLACE INTO blob (ns, k, v) VALUES (?, ?, ?)", ns, k, val);
        prev.set(k, val);
        n++;
      }
      for (const k of [...prev.keys()]) {
        if ((k.startsWith(`r:${field}:`) || k.startsWith(`a:${field}:`) || k === `m:${field}`) && !next.has(k)) {
          this.storage.sql.exec("DELETE FROM blob WHERE ns = ? AND k = ?", ns, k);
          prev.delete(k);
          n++;
        }
      }
    });
    this.cache.set(ns, prev);
    return n;
  }

  clear() {
    this.storage.sql.exec("DELETE FROM blob");
    this.storage.sql.exec("DELETE FROM meta");
    this.cache.clear();
  }

  getMeta<T>(k: string): T | undefined {
    const r = this.storage.sql.exec<{ v: string }>("SELECT v FROM meta WHERE k = ?", k).toArray()[0];
    return r ? (JSON.parse(r.v) as T) : undefined;
  }
  setMeta(k: string, v: unknown) {
    this.storage.sql.exec("INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)", k, JSON.stringify(v));
  }
  delMeta(k: string) {
    this.storage.sql.exec("DELETE FROM meta WHERE k = ?", k);
  }
  /** Meta keys starting with a prefix (e.g. pending redemption writes). */
  metaKeys(prefix: string): string[] {
    return this.storage.sql.exec<{ k: string }>("SELECT k FROM meta WHERE k >= ? AND k < ? ORDER BY k", prefix, prefix + "\uffff").toArray().map(r => r.k);
  }
}
