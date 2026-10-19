// GET /v1/digest?sinceDay=<n>[&since=<cursor>]: "While You Were Out". One small summary of
// what settled for this account since a world day: bets, props, jobs (only once their game
// has left the air, so nothing is spoiled), cards, arrests, and the net: bet and prop
// winnings less stakes, card sales, less the cost of the jobs that came out.
// The client keeps `cursor` (an opaque string) and sends it back as `since` next time, so a
// second visit on the same day only shows what's new; `sinceDay` alone covers whole days.

import type { Ctx } from "../router.ts";
import type { OpRow } from "../league.ts";
import { fail } from "../http.ts";
import { sim } from "../sim.ts";
import { personRef, teamRef } from "../views.ts";

const MAX_DAYS = 7;          // never look back further than a week of game days
const MAX_JOBS = 6;
const MAX_PROPS = 3;

type Window = { since: number; sinceDay: number; day: number };

/** Start time of world day `d` (days run back to back, `dayMs` apart). */
function window(c: Ctx): Window {
  const L = c.L;
  const shown = L.shownDay(c.now);
  const raw = c.q.get("sinceDay");
  const sinceDay = raw === null || raw === "" ? shown.day : Math.floor(Number(raw));
  if (!Number.isFinite(sinceDay) || sinceDay < 0) fail("bad_request", "sinceDay must be a day number");
  const oldest = c.now - MAX_DAYS * L.dayMs;
  // a day from last season (days restart at 1) or from the future: the last two days
  let since = sinceDay > shown.day ? c.now - 2 * L.dayMs : shown.startAt - (shown.day - sinceDay) * L.dayMs;
  const cur = c.q.get("since");
  if (cur && /^\d{1,16}$/.test(cur)) since = Math.max(since, Number(cur));
  return { since: Math.max(oldest, Math.min(since, c.now)), sinceDay, day: shown.day };
}

export async function digest(c: Ctx) {
  const w = window(c);
  const db = c.db;
  const me = c.acct.id;
  const world = c.L.world;

  // bets settled in the window
  const bets = (await db.prepare(`SELECT COUNT(*) AS n, COALESCE(SUM(CASE WHEN payout > 0 THEN 1 ELSE 0 END), 0) AS won,
      COALESCE(SUM(amount), 0) AS staked, COALESCE(SUM(payout), 0) AS paid
    FROM bets WHERE account_id = ? AND status = 'settled' AND settled_at >= ? AND settled_at <= ?`)
    .bind(me, w.since, c.now).first<{ n: number; won: number; staked: number; paid: number }>())!;

  // prop bets settled in the window (refunds: the question was refunded)
  const propRows = (await db.prepare(`SELECT pb.amount, pb.payout, pb.option, p.question, p.status AS pstatus, p.outcome, p.storyline_id, p.options
    FROM prop_bets pb JOIN props p ON p.id = pb.prop_id
    WHERE pb.account_id = ? AND pb.status = 'settled' AND pb.settled_at >= ? AND pb.settled_at <= ?
    ORDER BY ABS(pb.payout - pb.amount) DESC`)
    .bind(me, w.since, c.now).all<{ amount: number; payout: number; option: string; question: string; pstatus: string; outcome: string | null; storyline_id: string; options: string }>()).results;
  const label = (opts: string, key: string | null) => {
    if (!key) return undefined;
    try {
      const o = (JSON.parse(opts) as { key: string; label: string }[]).find(x => x.key === key);
      return o?.label ?? key;
    } catch { return key; }
  };
  const props = { won: 0, lost: 0, refunded: 0, net: 0, items: [] as { storylineId: string; question: string; pick: string; outcome?: string; net: number; refunded?: true }[] };
  for (const r of propRows) {
    const refunded = r.pstatus === "refunded";
    if (refunded) props.refunded++;
    else if (r.payout > 0) props.won++;
    else props.lost++;
    props.net += r.payout - r.amount;
    if (props.items.length < MAX_PROPS) {
      props.items.push({ storylineId: r.storyline_id, question: r.question, pick: label(r.options, r.option) ?? r.option,
        ...(r.outcome ? { outcome: label(r.options, r.outcome) } : {}), net: r.payout - r.amount, ...(refunded ? { refunded: true as const } : {}) });
    }
  }

  // jobs that came out in the window: game jobs once their game has left the air,
  // storyline-only jobs once they've run
  const ops = (await db.prepare(`SELECT o.*, g.home_id, g.away_id FROM ops o LEFT JOIN games g ON g.id = o.game_id
    WHERE o.account_id = ? AND o.status IN ('done', 'blown', 'cancelled') AND (
      (o.game_id != '' AND g.first_pitch_at + g.air_ms >= ? AND g.first_pitch_at + g.air_ms <= ?)
      OR (o.game_id = '' AND o.created_at >= ?))
    ORDER BY o.created_at DESC LIMIT 20`)
    .bind(me, w.since, c.now, w.since - c.L.dayMs).all<OpRow & { home_id: string | null; away_id: string | null }>()).results;
  const arrestIds: string[] = [];
  const jobs = ops.slice(0, MAX_JOBS).map(o => {
    const where = o.game_id ? `@ ${teamRef(world, o.home_id ?? o.target_team_id).abbr}` : "story job";
    let arrested: string[] = [];
    try { arrested = ((o.outcome ? JSON.parse(o.outcome) : {}) as { arrests?: string[] }).arrests ?? []; } catch { /* old rows */ }
    arrestIds.push(...arrested);
    return {
      id: o.id, name: sim.OP_KINDS.find(k => k.kind === o.kind)?.name ?? o.kind, where,
      target: teamRef(world, o.target_team_id).abbr, gameId: o.game_id || undefined,
      status: o.status as "done" | "blown" | "cancelled", result: o.result ?? "", arrests: o.arrests,
      cost: o.status === "cancelled" ? 0 : o.cost,
    };
  });

  // arrests: crew members picked up on those jobs (ids are crew ids or person ids)
  const arrests: { name: string; face?: string; status: string }[] = [];
  if (arrestIds.length) {
    const crew = (await db.prepare("SELECT id, person_id, status FROM crew WHERE id IN (SELECT value FROM json_each(?))")
      .bind(JSON.stringify(arrestIds)).all<{ id: string; person_id: string; status: string }>()).results;
    for (const id of arrestIds.slice(0, 4)) {
      const row = crew.find(r => r.id === id);
      const p = personRef(world, row ? row.person_id : id);
      arrests.push({ name: p.name, ...(p.face ? { face: p.face } : {}), status: row?.status ?? "jailed" });
    }
  }

  // money, cards and the rest from the ledger
  const led = (await db.prepare(`SELECT reason, COUNT(*) AS n, COALESCE(SUM(delta), 0) AS total FROM ledger
    WHERE account_id = ? AND at >= ? AND at <= ? GROUP BY reason`)
    .bind(me, w.since, c.now).all<{ reason: string; n: number; total: number }>()).results;
  const by = (r: string) => led.find(x => x.reason === r) ?? { n: 0, total: 0 };
  // every money move except the new-account grant (what the bankroll actually did)
  const moneyChange = led.reduce((s, x) => s + (x.reason === "grant" ? 0 : x.total), 0);
  const sold = { n: by("market_sale").n + by("auction_sale").n, total: by("market_sale").total + by("auction_sale").total };
  const cards = { sold: sold.n, soldFor: sold.total, won: by("escrow_refund").n, outbid: by("bid_release").n };

  // the haul: what came back from bets, props and card sales, less what the jobs cost
  const jobCost = jobs.reduce((s, j) => s + j.cost, 0);
  const net = (bets.paid - bets.staked) + props.net + cards.soldFor - jobCost;
  const empty = bets.n === 0 && propRows.length === 0 && jobs.length === 0 && cards.sold + cards.won + cards.outbid === 0;
  return {
    sinceDay: w.sinceDay, day: w.day, cursor: String(c.now), empty,
    bets: { won: bets.won, lost: bets.n - bets.won, staked: bets.staked, paid: bets.paid, net: bets.paid - bets.staked },
    props, jobs, arrests, cards, net, moneyChange, money: c.acct.money,
  };
}
