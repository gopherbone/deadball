// Drama props: pari-mutuel markets on rumoured/public storylines (docs/DRAMA.md "Prop markets").
//
// Lifecycle (driven by the League DO):
//   close() -> propSyncStmts: open rows for every question of bettableStorylines(world), re-time
//              their closing estimate, close questions past closesDay or whose storyline resolved
//   dayFinal() -> settleProps: resolveProps(world, storyline) settles whatever is decided; pools are
//              paid through the ledger exactly like game bets (house money included, 10% cut on player money, refunds if called off)
// Bobby's regulars (src/house.ts) add house money to every open question each day (props.house),
// seeded from the storyline's public facts only.
// Secret storylines never get rows (bettableStorylines filters them), so nothing here can name one.

import type { Ctx } from "../router.ts";
import type { League } from "../league.ts";
import { runBatch } from "../league.ts";
import { decCursor, encCursor, fail, int, newId, str } from "../http.ts";
import { bettableStorylines, resolveProps, rumorLine, type Storyline, type World } from "../sim.ts";
import { personRef, teamRef, type PersonRef, type TeamRef } from "../views.ts";
import { accountView, gate, limitParam, moneyMove, page } from "./common.ts";
import { paysFor, parseWaves, propWaves, publicFacts, publicStageKey, settleMath, visible } from "../house.ts";

export const MIN_PROP_BET = 5;

export type PropRow = {
  id: string; storyline_id: string; season: number; kind: string; type: string; question: string; options: string;
  closes_day: number; resolve_by: number; closes_at: number; status: string; outcome: string | null; settled_at: number | null; created_at: number;
  /** house (NPC) waves, JSON HouseWave[] (src/house.ts) */
  house?: string | null;
};
export type PropBetRow = { id: string; account_id: string; prop_id: string; option: string; amount: number; status: string; payout: number; placed_at: number; settled_at: number | null };
type Opt = { key: string; label: string };

export type PropView = {
  id: string; storylineId: string; question: string; type: "yesno" | "buckets";
  /** pool includes the house's money (house, Bobby's regulars) */
  options: { key: string; label: string; pool: number; pays: number; house: number }[];
  pool: number; house: number; closesAt: number; closesDay: number;
  /** forced resolution: the world day the question gets an answer even if the storyline lingers */
  resolveByDay: number; resolveByAt: number;
  status: "open" | "closed" | "settled" | "refunded";
  outcome?: string; myBet?: { option: string; amount: number };
};
export type GossipItem = {
  id: string; kind: string; headline: string; blurb: string; stage: string; visibility: "rumoured" | "public" | "secret";
  who: PersonRef; team?: TeamRef; props: PropView[];
  /** A secret arc this account was tipped about: no markets until it leaks; shown to nobody else. */
  heard?: true;
};

// ------------------------------------------------------------------ tabloid copy

const last = (w: World, id: string | undefined) => {
  const p = id ? w.players[id] ?? w.npcs[id] ?? w.archive?.[id] : undefined;
  return p ? p.last : "Somebody";
};

/** Deadpan tabloid headline for a storyline row. */
export function gossipHeadline(w: World, s: Storyline): string {
  const A = last(w, s.people[0]), B = last(w, s.people[1]);
  const pitcher = w.players[s.people[0]]?.pos === "P";
  switch (s.kind) {
    case "affair": return `${A} Seen at Motel on Route 9`;
    case "marriage_trouble": return s.stage === "separated" ? `${A}, Wife Living Apart` : `${A} Sleeping at the Ballpark`;
    case "feud": return s.data.withPress ? `${A} Not Speaking to the Press` : `${A}, ${B} Not Speaking`;
    case "rivalry": return `${A} and ${B}: Bad Blood`;
    case "gambling_debt": return `${A} Owes Money to a Bookmaker`;
    case "hot_seat": return `${A}'s Desk Is Being Measured`;
    case "holdout": return `${A} Will Not Report`;
    case "slump": return pitcher ? `${A} Getting Shelled` : `${A} Can't Buy a Hit`;
    case "curse": return `${A} Says He Is Cursed`;
    case "comeback": return `${A} Wants Back In`;
    case "contract_year": return `${A} Playing for a Contract`;
    case "rookie_watch": return `${A}: Rookie of the Year?`;
    case "stalker": return `Someone Is Following ${A}`;
    case "weird": return `${A} Still Missing`;
    case "enhanced_watch": return s.stage === "investigation" ? `League Has Questions About ${A}` : `${A} Feels Normal, He Says`;
    default: return `${A}: Developing`;
  }
}

/** Public stage label. Point shaving is a hidden stage: the public only knows he's being leaned on. */
export function publicStage(s: Storyline): string {
  return publicStageKey(s).replace(/_/g, " ");
}

/** One deadpan line about the storyline (the newsroom's rumour line, else cause and stakes). */
export function gossipBlurb(w: World, s: Storyline): string {
  const ev = { id: `${s.id}:blurb`, day: w.day, kind: "drama", who: s.people.slice(0, 2), teams: s.teams,
    data: { ...s.data, sub: s.kind, kind: s.kind, storyline: s.id, stage: s.stage === "shaving" ? "leaned_on" : s.stage, visibility: s.visibility, secret: false } };
  let line: string | undefined;
  try { line = rumorLine(w, ev); } catch { line = undefined; }
  if (line) return line;
  const cause = typeof s.data.cause === "string" ? s.data.cause : undefined;
  const stakes = typeof s.data.stakes === "string" ? s.data.stakes : undefined;
  const parts = [cause ? `Reason given: ${cause}.` : "Nobody will say how it started.", stakes ? `At stake: ${stakes}.` : ""];
  return parts.join(" ").trim();
}

// ------------------------------------------------------------------ League hooks

/** Epoch-ms estimate for the end of world day `closesDay`, given the next play time (which plays world.day). */
const closesAtFor = (nextPlayAt: number, worldDay: number, closesDay: number, dayMs: number) => nextPlayAt + (closesDay - worldDay) * dayMs;

/**
 * Statements to run with a day's play (after the world advanced): open new prop rows, re-time open
 * ones, and close questions past their closing day or whose storyline just resolved.
 */
export function propSyncStmts(L: League, nextPlayAt: number, now: number): D1PreparedStatement[] {
  const w = L.world, db = L.db, day = w.day;
  const out: D1PreparedStatement[] = [];
  for (const { storyline: s, props } of bettableStorylines(w)) {
    if (s.visibility === "secret") continue; // belt and braces
    for (const q of props) {
      out.push(db.prepare(`INSERT OR IGNORE INTO props (id, storyline_id, season, kind, type, question, options, closes_day, resolve_by, closes_at, status, created_at)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`)
        .bind(q.id, s.id, s.season ?? L.state.season, s.kind, q.type, q.question, JSON.stringify(q.options), q.closesDay, q.resolveBy,
          closesAtFor(nextPlayAt, day, q.closesDay, L.dayMs), q.closesDay >= day ? "open" : "closed", now));
      out.push(...houseWaveStmts(L, s, q, day));
    }
  }
  out.push(...propRetimeStmts(L, nextPlayAt));
  const resolved = (w.storylines ?? []).filter(s => s.resolved && s.bettableDay !== undefined && s.resolved.day >= day - 3).map(s => s.id);
  out.push(db.prepare(`UPDATE props SET status = 'closed' WHERE status = 'open' AND (closes_day < ? OR storyline_id IN (SELECT value FROM json_each(?)))`)
    .bind(day, JSON.stringify(resolved)));
  return out;
}

/**
 * Today's house waves on an open question (Bobby's regulars). Idempotent per (question, day): the
 * first day's waves (with the per-option minimum) set the schedule, later days append theirs.
 * Seeded from publicFacts(s) only, never the storyline itself.
 */
function houseWaveStmts(L: League, s: Storyline, q: { id: string; options: { key: string }[]; closesDay: number; resolveBy: number }, day: number): D1PreparedStatement[] {
  const f = publicFacts(s);
  if (!f || q.closesDay < day) return [];
  const pq = { id: q.id, options: q.options.map(o => o.key), closesDay: q.closesDay, resolveBy: q.resolveBy };
  const first = propWaves(L.seed, f, pq, day, L.dayMs, true);
  const later = propWaves(L.seed, f, pq, day, L.dayMs, false);
  if (!first.length) return [];
  return [
    L.db.prepare("UPDATE props SET house = ? WHERE id = ? AND status = 'open' AND house IS NULL").bind(JSON.stringify(first), q.id),
    L.db.prepare(`UPDATE props SET house = json_insert(house${later.map(() => ", '$[#]', json(?)").join("")}) WHERE id = ? AND status = 'open' AND house IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM json_each(props.house) WHERE json_extract(value, '$.k') = ?)`).bind(...later.map(w => JSON.stringify(w)), q.id, later[0].k),
  ];
}

/** House money per option of a prop that has landed by `now`. */
export function propHouse(L: League, r: PropRow, now: number): number[] {
  const n = (JSON.parse(r.options) as Opt[]).length;
  return visible(parseWaves(r.house), n, r.closes_at, now, L.houseScale);
}

/** Re-time open props when the clock moves (admin fast-forward, catch-up). */
export function propRetimeStmts(L: League, nextPlayAt: number): D1PreparedStatement[] {
  return [L.db.prepare("UPDATE props SET closes_at = ? + (closes_day - ?) * ? WHERE status = 'open'").bind(nextPlayAt, L.world.day, L.dayMs)];
}

/** Settle every prop question that resolveProps can decide now. Idempotent (bets: open -> paying -> settled). */
export async function settleProps(L: League, now: number): Promise<number> {
  const db = L.db, w = L.world;
  const rows = (await db.prepare("SELECT * FROM props WHERE status IN ('open', 'closed')").all<PropRow>()).results;
  if (!rows.length) return 0;
  const bySl = new Map<string, PropRow[]>();
  for (const r of rows) (bySl.get(r.storyline_id) ?? bySl.set(r.storyline_id, []).get(r.storyline_id)!).push(r);
  const due: { row: PropRow; outcome?: string }[] = [];
  for (const [sid, list] of bySl) {
    const s = (w.storylines ?? []).find(x => x.id === sid);
    if (!s) { for (const row of list) due.push({ row }); continue; } // pruned from the world: refund
    const res = resolveProps(w, sid);
    for (const row of list) if (res[row.id] !== undefined) due.push({ row, outcome: res[row.id] });
  }
  if (!due.length) return 0;
  const ids = JSON.stringify(due.map(d => d.row.id));
  // stop taking bets first, then read the final pools
  await db.prepare("UPDATE props SET status = 'closed' WHERE status = 'open' AND id IN (SELECT value FROM json_each(?))").bind(ids).run();
  const pools = (await db.prepare("SELECT prop_id, option, SUM(amount) AS amt FROM prop_bets WHERE prop_id IN (SELECT value FROM json_each(?)) GROUP BY prop_id, option")
    .bind(ids).all<{ prop_id: string; option: string; amt: number }>()).results;
  const stmts: D1PreparedStatement[] = [];
  for (const d of due) {
    const mine = pools.filter(p => p.prop_id === d.row.id);
    const keys = (JSON.parse(d.row.options) as Opt[]).map(o => o.key);
    const player = keys.map(k => mine.find(p => p.option === k)?.amt ?? 0);
    const idx = d.outcome === undefined ? -1 : keys.indexOf(d.outcome);
    stmts.push(...settlePropStmts(L, d.row, d.outcome, player, propHouse(L, d.row, now), idx < 0 ? undefined : idx, now));
  }
  await runBatch(db, stmts);
  return due.length;
}

/**
 * Pari-mutuel settlement of one question over player + house money (src/house.ts settleMath). The
 * house's own winnings are burned; only player bets get payouts, ledger rows and mail. Refund when
 * there's no answer, or nobody (player or house) had it.
 */
function settlePropStmts(L: League, p: PropRow, outcome: string | undefined, player: number[], house: number[], win: number | undefined, now: number): D1PreparedStatement[] {
  const db = L.db;
  const opts = JSON.parse(p.options) as Opt[];
  const m = settleMath(player, house, outcome === undefined ? undefined : win);
  const refund = m.refund;
  const net = m.net, winPool = m.winPool;
  const answer = outcome === undefined ? "Called off (the story went cold)." : `Answer: ${opts.find(o => o.key === outcome)?.label ?? outcome}.`;
  const payExpr = refund ? "amount" : "CASE WHEN option = ? THEN (amount * CAST(? AS INTEGER)) / CAST(? AS INTEGER) ELSE 0 END";
  const payArgs = refund ? [] : [outcome, net, winPool];
  const label = "COALESCE((SELECT json_extract(o.value, '$.label') FROM json_each(?) o WHERE json_extract(o.value, '$.key') = option), option)";
  return [
    db.prepare(`UPDATE prop_bets SET status = 'paying', settled_at = ?, payout = ${payExpr} WHERE prop_id = ? AND status = 'open'`).bind(now, ...payArgs, p.id),
    db.prepare(`INSERT OR IGNORE INTO ledger (id, account_id, delta, reason, at, season, syndicate_id)
        SELECT 'ppay:' || b.id, b.account_id, b.payout, ?, ?, ?, a.syndicate_id FROM prop_bets b JOIN accounts a ON a.id = b.account_id WHERE b.prop_id = ? AND b.status = 'paying' AND b.payout > 0`)
      .bind(refund ? "prop_refund" : "prop_payout", now, L.state.season, p.id),
    db.prepare(`UPDATE accounts SET money = money + (SELECT COALESCE(SUM(payout), 0) FROM prop_bets b WHERE b.account_id = accounts.id AND b.prop_id = ? AND b.status = 'paying')
        WHERE id IN (SELECT account_id FROM prop_bets WHERE prop_id = ? AND status = 'paying')`).bind(p.id, p.id),
    db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data)
        SELECT 'mp:' || id, account_id, ?, 0, 'bank', json_object('from', 'Bets By Bobby',
          'subject', ${refund ? "'Prop refunded'" : "CASE WHEN payout > 0 THEN 'Prop won: $' || payout ELSE 'Prop lost' END"},
          'body', json_array(?, ?, 'You had $' || amount || ' on "' || ${label} || '".',
            ${refund ? "'Nobody had it. Your $' || amount || ' is back.'" : "CASE WHEN payout > 0 THEN 'Paid out: $' || payout || '.' ELSE 'Bobby thanks you for your business.' END"}))
        FROM prop_bets WHERE prop_id = ? AND status = 'paying'`).bind(now, p.question, answer, p.options, p.id),
    db.prepare("UPDATE prop_bets SET status = 'settled' WHERE prop_id = ? AND status = 'paying'").bind(p.id),
    db.prepare("UPDATE props SET status = ?, outcome = ?, settled_at = ? WHERE id = ?").bind(refund ? "refunded" : "settled", outcome ?? null, now, p.id),
  ];
}

// ------------------------------------------------------------------ views

async function poolsFor(c: Ctx, ids: string[]) {
  const pools = new Map<string, Map<string, number>>();
  const mine = new Map<string, { option: string; amount: number }>();
  if (!ids.length) return { pools, mine };
  const j = JSON.stringify(ids);
  const [pr, mr] = await c.db.batch([
    c.db.prepare("SELECT prop_id, option, SUM(amount) AS amt FROM prop_bets WHERE prop_id IN (SELECT value FROM json_each(?)) GROUP BY prop_id, option").bind(j),
    c.db.prepare("SELECT prop_id, option, amount FROM prop_bets WHERE account_id = ? AND prop_id IN (SELECT value FROM json_each(?))").bind(c.acct.id, j),
  ]);
  for (const r of pr.results as { prop_id: string; option: string; amt: number }[]) (pools.get(r.prop_id) ?? pools.set(r.prop_id, new Map()).get(r.prop_id)!).set(r.option, r.amt);
  for (const r of mr.results as { prop_id: string; option: string; amount: number }[]) mine.set(r.prop_id, { option: r.option, amount: r.amount });
  return { pools, mine };
}

/** Player money per option (in `options` order), house money landed by `now`, and what each pays. */
function propPools(L: League, r: PropRow, pool: Map<string, number> | undefined, now: number) {
  const opts = JSON.parse(r.options) as Opt[];
  const player = opts.map(o => pool?.get(o.key) ?? 0);
  // a settled/refunded question shows what it settled on: every wave that had landed
  const house = propHouse(L, r, r.settled_at ?? now);
  return { opts, player, house, pays: paysFor(player, house) };
}

export function propView(L: League, r: PropRow, pool: Map<string, number> | undefined, now: number, my?: { option: string; amount: number }): PropView {
  const { opts, player, house, pays } = propPools(L, r, pool, now);
  const hs = house.reduce((a, b) => a + b, 0);
  const v: PropView = {
    id: r.id, storylineId: r.storyline_id, question: r.question, type: r.type === "yesno" ? "yesno" : "buckets",
    options: opts.map((o, i) => ({ key: o.key, label: o.label, pool: player[i] + house[i], pays: pays[i], house: house[i] })),
    pool: player.reduce((a, b) => a + b, 0) + hs, house: hs, closesAt: r.closes_at, closesDay: r.closes_day,
    resolveByDay: r.resolve_by, resolveByAt: r.closes_at + Math.max(0, r.resolve_by - r.closes_day) * L.dayMs,
    status: r.status as PropView["status"],
  };
  if (r.outcome) v.outcome = r.outcome;
  if (my) v.myBet = my;
  return v;
}

/** Storylines with open (or closed, awaiting a result) props, as tabloid rows. Never secret ones. */
export async function gossipItems(c: Ctx, limit = 20, storyline?: string): Promise<GossipItem[]> {
  const w = c.L.world;
  const rows = (await c.db.prepare(`SELECT * FROM props WHERE status IN ('open', 'closed') ${storyline ? "AND storyline_id = ?" : ""} ORDER BY closes_at, id`)
    .bind(...(storyline ? [storyline] : [])).all<PropRow>()).results;
  const bySl = new Map<string, PropRow[]>();
  for (const r of rows) (bySl.get(r.storyline_id) ?? bySl.set(r.storyline_id, []).get(r.storyline_id)!).push(r);
  const items: { s: Storyline; rows: PropRow[]; open: number }[] = [];
  for (const [sid, list] of bySl) {
    const s = (w.storylines ?? []).find(x => x.id === sid);
    if (!s || s.visibility === "secret" || s.bettableDay === undefined) continue;
    const open = list.filter(r => r.status === "open" && r.closes_at > c.now);
    items.push({ s, rows: list, open: open.length ? Math.min(...open.map(r => r.closes_at)) : Infinity });
  }
  // open markets first (soonest closing), then the ones waiting on a result
  items.sort((a, b) => a.open - b.open || b.s.bettableDay! - a.s.bettableDay! || a.s.id.localeCompare(b.s.id));
  const pick = items.slice(0, limit);
  const { pools, mine } = await poolsFor(c, pick.flatMap(i => i.rows.map(r => r.id)));
  const order = (id: string) => (id.endsWith(":yes") ? 0 : id.endsWith(":when") ? 1 : 2);
  // secret arcs this account heard about from a tip: listed first, never to anyone else
  const known = storyline ? [] : await c.L.knownStorylines(c.acct.id);
  const heard: GossipItem[] = (w.storylines ?? []).filter(s => known.includes(s.id) && s.visibility === "secret" && !s.resolved).slice(0, 5).map(s => {
    const team = s.teams.find(t => w.teams[t]);
    return {
      id: s.id, kind: s.kind, headline: gossipHeadline(w, s), blurb: "You heard it from a source. It has not been printed anywhere. Markets open the day it leaks.",
      stage: publicStage(s), visibility: "secret", who: personRef(w, s.people[0]), ...(team ? { team: teamRef(w, team) } : {}), props: [], heard: true,
    };
  });
  return [...heard, ...pick.map(({ s, rows: list }) => {
    const team = s.teams.find(t => w.teams[t]);
    const status = (r: PropRow): PropRow => (r.status === "open" && r.closes_at <= c.now ? { ...r, status: "closed" } : r);
    return {
      id: s.id, kind: s.kind, headline: gossipHeadline(w, s), blurb: gossipBlurb(w, s), stage: publicStage(s), visibility: s.visibility as "rumoured" | "public",
      who: personRef(w, s.people[0]), ...(team ? { team: teamRef(w, team) } : {}),
      props: [...list].sort((a, b) => order(a.id) - order(b.id)).map(r => propView(c.L, status(r), pools.get(r.id), c.now, mine.get(r.id))),
    } as GossipItem;
  })];
}

type PropBetView = {
  id: string; propId: string; storylineId: string; headline: string; question: string; option: string; optionLabel: string; amount: number;
  status: "open" | "settled"; placedAt: number; pays?: number; payout?: number; won?: boolean; refunded?: boolean; outcome?: string; outcomeLabel?: string;
};

async function betViews(c: Ctx, bets: PropBetRow[]): Promise<PropBetView[]> {
  if (!bets.length) return [];
  const w = c.L.world;
  const ids = [...new Set(bets.map(b => b.prop_id))];
  const props = new Map((await c.db.prepare("SELECT * FROM props WHERE id IN (SELECT value FROM json_each(?))").bind(JSON.stringify(ids)).all<PropRow>()).results.map(r => [r.id, r]));
  const { pools } = await poolsFor(c, ids.filter(id => props.get(id)?.status === "open" || props.get(id)?.status === "closed"));
  return bets.map(b => {
    const p = props.get(b.prop_id);
    const opts = p ? (JSON.parse(p.options) as Opt[]) : [];
    const lbl = (k: string) => opts.find(o => o.key === k)?.label ?? k;
    const s = p ? (w.storylines ?? []).find(x => x.id === p.storyline_id) : undefined;
    const v: PropBetView = {
      id: b.id, propId: b.prop_id, storylineId: p?.storyline_id ?? "", headline: s && s.visibility !== "secret" ? gossipHeadline(w, s) : "(old news)",
      question: p?.question ?? "", option: b.option, optionLabel: lbl(b.option), amount: b.amount, status: b.status === "settled" ? "settled" : "open", placedAt: b.placed_at,
    };
    if (b.status === "settled") {
      v.payout = b.payout;
      v.won = p?.status === "settled" && p.outcome === b.option;
      if (p?.status === "refunded") v.refunded = true;
      if (p?.outcome) { v.outcome = p.outcome; v.outcomeLabel = lbl(p.outcome); }
    } else {
      if (p) {
        const pp = propPools(c.L, p, pools.get(b.prop_id), c.now);
        v.pays = pp.pays[pp.opts.findIndex(o => o.key === b.option)] ?? 0;
      } else v.pays = 0;
    }
    return v;
  });
}

async function myBets(c: Ctx, status: "open" | "settled", limit: number, cur?: [number, string]) {
  const rows = (await c.db.prepare(`SELECT * FROM prop_bets WHERE account_id = ? AND status ${status === "open" ? "!= 'settled'" : "= 'settled'"}
      ${cur ? "AND (placed_at < ? OR (placed_at = ? AND id < ?))" : ""} ORDER BY ${status === "open" ? "placed_at" : "settled_at"} DESC, id DESC LIMIT ?`)
    .bind(c.acct.id, ...(cur ? [cur[0], cur[0], cur[1]] : []), limit + 1).all<PropBetRow>()).results;
  return page(rows, limit, l => [l.placed_at, l.id]);
}

// ------------------------------------------------------------------ routes

/** GET /props[?storyline=<id>]: open prop markets grouped by storyline. */
export async function list(c: Ctx) {
  const sl = c.q.get("storyline") ?? undefined;
  return { day: c.L.shownDay(c.now).day, storylines: await gossipItems(c, limitParam(c, 20, 30), sl ? sl.slice(0, 40) : undefined) };
}

/** GET /gossip: the Gossip Board page doc (props + BBS rumour chatter + your prop bets). */
export async function gossip(c: Ctx) {
  const chatter = (await c.db.prepare(`SELECT author_id, text, at FROM comments WHERE thread = 'bbs:rumors' AND author_id LIKE 'npc:%' AND at <= ? ORDER BY at DESC, id LIMIT 6`)
    .bind(c.now).all<{ author_id: string; text: string; at: number }>()).results.map(r => ({ author: r.author_id.slice(4), text: r.text, at: r.at }));
  const open = await myBets(c, "open", 10);
  const settled = await myBets(c, "settled", 6);
  return {
    day: c.L.shownDay(c.now).day, storylines: await gossipItems(c, 12), chatter,
    my: await betViews(c, open.items), recent: await betViews(c, settled.items),
  };
}

/** GET /props/bets?status=open|settled */
export async function bets(c: Ctx) {
  const status = c.q.get("status") ?? "open";
  if (status !== "open" && status !== "settled") fail("bad_request", "status must be open or settled");
  const p = await myBets(c, status as "open" | "settled", limitParam(c, 20, 50), decCursor<[number, string]>(c.q.get("cursor")));
  const out: { bets: PropBetView[]; next?: string } = { bets: await betViews(c, p.items) };
  if (p.next) out.next = encCursor(p.next);
  return out;
}

/** POST /props/bets { propId, option, amount } */
export async function place(c: Ctx) {
  const propId = str(c.body, "propId", 80);
  const option = str(c.body, "option", 40);
  const amount = int(c.body, "amount", MIN_PROP_BET, 10_000_000);
  const row = await c.db.prepare("SELECT * FROM props WHERE id = ?").bind(propId).first<PropRow>();
  const w = c.L.world;
  const s = row ? (w.storylines ?? []).find(x => x.id === row.storyline_id) : undefined;
  if (!row || !s || s.visibility === "secret") return fail("not_found", "no such prop");
  const opts = JSON.parse(row.options) as Opt[];
  if (!opts.some(o => o.key === option)) fail("bad_request", `option must be one of ${opts.map(o => o.key).join(", ")}`);
  const closed = () => fail("window_closed", "Bobby closed the book on that one");
  if (row.status !== "open" || c.now >= row.closes_at || w.day > row.closes_day || s.resolved) closed();
  if (amount * 2 > c.acct.money) {
    if (amount > c.acct.money) fail("insufficient_funds", "you don't have that kind of money");
    fail("bad_request", `max bet is 50% of your money ($${Math.floor(c.acct.money / 2)})`);
  }
  const existing = await c.db.prepare("SELECT option FROM prop_bets WHERE account_id = ? AND prop_id = ?").bind(c.acct.id, propId).first<{ option: string }>();
  if (existing && existing.option !== option) fail("bad_request", "you already took another answer on this one");
  const { ok } = await moneyMove(c, {
    delta: -amount, reason: "prop_bet",
    cond: `a.money >= ? * 2 AND EXISTS (SELECT 1 FROM props p WHERE p.id = ? AND p.status = 'open' AND p.closes_at > ?) AND NOT EXISTS (SELECT 1 FROM prop_bets WHERE account_id = a.id AND prop_id = ? AND option != ?)`,
    condArgs: [amount, propId, c.now, propId, option],
    then: tx => [
      c.db.prepare(`INSERT INTO prop_bets (id, account_id, prop_id, option, amount, placed_at) SELECT ?, ?, ?, ?, ?, ? WHERE ${gate()}
          ON CONFLICT (account_id, prop_id) DO UPDATE SET amount = amount + excluded.amount, placed_at = excluded.placed_at`)
        .bind(newId("pb"), c.acct.id, propId, option, amount, c.now, tx),
    ],
  });
  if (!ok) {
    const fresh = await c.db.prepare("SELECT status, closes_at FROM props WHERE id = ?").bind(propId).first<{ status: string; closes_at: number }>();
    if (!fresh || fresh.status !== "open" || c.now >= fresh.closes_at) closed();
    fail("insufficient_funds", "not enough money for that bet (max 50% of what you have)");
  }
  const bet = await c.db.prepare("SELECT * FROM prop_bets WHERE account_id = ? AND prop_id = ?").bind(c.acct.id, propId).first<PropBetRow>();
  const { pools, mine } = await poolsFor(c, [propId]);
  const [view] = await betViews(c, [bet!]);
  return { bet: view, prop: propView(c.L, row, pools.get(propId), c.now, mine.get(propId)), account: await accountView(c) };
}
