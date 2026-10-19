import type { Ctx } from "../router.ts";
import { decCursor, encCursor, fail, int, newId, str } from "../http.ts";
import { Rng, sim, type Card, type CardDef } from "../sim.ts";
import { cardView, type CardView } from "../views.ts";
import { accountView, gate, limitParam, moneyMove, page } from "./common.ts";
import { runBatch } from "../league.ts";

type CardRow = { id: string; def_id: string; owner_id: string; serial: number | null; print_run: number | null; data: string; created_at: number };

const PACK_BLURBS: Record<string, string> = {
  starter: "Five cards, on the house. Smells like gum.",
};

function starterKind(): string {
  const s = sim.PACKS.find(p => p.kind === "starter");
  if (s) return s.kind;
  return [...sim.PACKS].sort((a, b) => a.price - b.price)[0].kind;
}

export function shop(c: Ctx) {
  const packs = sim.PACKS.filter(p => p.price > 0 || (p.kind === "starter" && c.acct.free_packs > 0))
    .map(p => ({ kind: p.kind, name: p.name, price: p.price, count: p.count, blurb: String(p.blurb ?? PACK_BLURBS[p.kind] ?? `${p.count} cards. No refunds.`) }));
  if (c.acct.free_packs > 0 && !packs.some(p => p.kind === "starter")) {
    const base = sim.PACKS.find(p => p.kind === starterKind())!;
    packs.unshift({ kind: "starter", name: "Starter Pack", price: 0, count: base.count, blurb: PACK_BLURBS.starter });
  }
  return { packs };
}

/** The season's card set: loaded from D1 once (stable numbering as rosters move), else built and stored. */
export async function ensureDefs(c: Ctx, season: number): Promise<CardDef[]> {
  const L = c.L;
  if (L.defsSeason === season && L.defs.length) return L.defs;
  const stored = (await c.db.prepare("SELECT data FROM card_defs WHERE season = ?").bind(season).all<{ data: string }>()).results.map(r => JSON.parse(r.data) as CardDef);
  let defs = stored.sort((a, b) => a.number - b.number);
  if (!defs.length) {
    defs = sim.setFor(L.world, season);
    await runBatch(c.db, defs.map(d => c.db.prepare("INSERT OR IGNORE INTO card_defs (id, season, data) VALUES (?,?,?)").bind(d.id, season, JSON.stringify(d))));
  }
  L.defs = defs;
  L.defsSeason = season;
  return defs;
}

export async function buyPack(c: Ctx) {
  const kind = str(c.body, "kind", 40);
  const L = c.L;
  const pack = sim.PACKS.find(p => p.kind === kind);
  const isStarter = kind === "starter" || (pack?.price === 0);
  if (!pack && kind !== "starter") fail("bad_request", "no such pack");
  if (isStarter && c.acct.free_packs < 1) fail("bad_request", "you've already opened your free pack");
  const price = isStarter ? 0 : pack!.price;
  if (price > c.acct.money) fail("insufficient_funds", `a ${pack!.name} costs $${price}`);
  const season = L.state.season;
  const defs = await ensureDefs(c, season);
  const retired = new Set((await c.db.prepare("SELECT person_id FROM retired_people").all<{ person_id: string }>()).results.map(r => r.person_id));
  const { ok, tx } = await moneyMove(c, {
    delta: -price, reason: isStarter ? "starter_pack" : "pack",
    ...(isStarter ? { cond: "a.free_packs >= 1" } : {}),
    then: t => (isStarter ? [c.db.prepare(`UPDATE accounts SET free_packs = free_packs - 1 WHERE id = ? AND ${gate()}`).bind(c.acct.id, t)] : []),
  });
  if (!ok) fail(isStarter ? "bad_request" : "insufficient_funds", isStarter ? "you've already opened your free pack" : "not enough money");

  // open it: serial numbers come from the DO's authoritative counters
  const minted = new Map<string, number>();
  const cards: Card[] = sim.openPack(L.world, season, isStarter ? (pack?.kind ?? starterKind()) : kind, new Rng(`${L.seed}:pack:${tx}`), defId => {
    const n = (L.serials.get(defId) ?? 0) + 1;
    L.serials.set(defId, n);
    minted.set(defId, n);
    return n;
  }, defs);
  // pulls of players retired by a redeemed card are Final Season editions
  for (const card of cards) if (retired.has(card.personId)) card.finalSeason = true;
  const rows = cards.map(card => ({ id: newId("k"), card }));
  try {
    await c.db.batch([
      ...rows.map(r => c.db.prepare("INSERT INTO cards (id, def_id, owner_id, serial, print_run, data, created_at) VALUES (?,?,?,?,?,?,?)")
        .bind(r.id, r.card.id, c.acct.id, r.card.serial ?? null, r.card.printRun ?? null, JSON.stringify(r.card), c.now)),
      ...[...minted].map(([d, n]) => c.db.prepare("INSERT INTO serials (def_id, n) VALUES (?, ?) ON CONFLICT (def_id) DO UPDATE SET n = MAX(n, excluded.n)").bind(d, n)),
    ]);
  } catch (e) {
    // refund
    await c.db.batch([
      c.db.prepare("INSERT INTO ledger (id, account_id, delta, reason, at, season) VALUES (?,?,?,?,?,?)").bind(`refund:${tx}`, c.acct.id, price, "pack_refund", c.now, season),
      c.db.prepare(`UPDATE accounts SET money = money + ?, free_packs = free_packs + ? WHERE id = ?`).bind(price, isStarter ? 1 : 0, c.acct.id),
    ]);
    throw e;
  }
  return { cards: rows.map(r => cardView(L.world, r.id, r.card)), account: await accountView(c) };
}

const view = (c: Ctx, r: CardRow): CardView => cardView(c.L.world, r.id, JSON.parse(r.data) as Card);

export async function binder(c: Ctx) {
  const cur = decCursor<[number, string]>(c.q.get("cursor"));
  const limit = limitParam(c, 12, 30);
  const rows = (await c.db.prepare(`SELECT * FROM cards WHERE owner_id = ? ${cur ? "AND (created_at < ? OR (created_at = ? AND id < ?))" : ""} ORDER BY created_at DESC, id DESC LIMIT ?`)
    .bind(c.acct.id, ...(cur ? [cur[0], cur[0], cur[1]] : []), limit + 1).all<CardRow>()).results;
  const p = page(rows, limit, l => [l.created_at, l.id]);
  const out: { cards: CardView[]; next?: string } = { cards: p.items.map(r => view(c, r)) };
  if (p.next) out.next = encCursor(p.next);
  return out;
}

export async function one(c: Ctx) {
  const r = await c.db.prepare("SELECT * FROM cards WHERE id = ?").bind(c.params[0]).first<CardRow>();
  if (!r) fail("not_found", "no such card");
  return { card: view(c, r!) };
}
