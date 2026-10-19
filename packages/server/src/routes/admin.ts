import type { Ctx } from "../router.ts";
import { fail, int, newId, oneOf, str } from "../http.ts";
import { ensureDefs } from "./cards.ts";
import { Rng, redeemFor, angerFaction, grudge as grudgeOf, type Card, type SimCard, type Redeem } from "../sim.ts";

export function status(c: Ctx) {
  return c.L.status();
}

/** POST /v1/admin/advance { days } — play and settle N game days right now. */
export async function advance(c: Ctx) {
  const days = c.body.days === undefined ? 1 : int(c.body, "days", 1, 200);
  const ticks = await c.L.advance(days);
  return { ...c.L.status(), ticks };
}

/**
 * POST /v1/admin/house { scale } — multiplier on Bobby's regulars' money (0 = off, 1 = as tuned in
 * src/house.ts). Applies at once to every unsettled pool (it scales the stored waves when read).
 */
export function house(c: Ctx) {
  const v = c.body.scale;
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > 10) fail("bad_request", "scale must be a number from 0 to 10");
  c.L.setHouseScale(v as number);
  return { scale: c.L.houseScale };
}

/** POST /v1/admin/reset { seed? } — wipe D1, R2 logs and the DO, and generate a new world. */
export async function reset(c: Ctx) {
  const seed = typeof c.body.seed === "string" && c.body.seed ? c.body.seed.slice(0, 64) : `deadball-${Date.now().toString(36)}`;
  await c.L.reset(seed);
  return c.L.status();
}

/**
 * POST /v1/admin/card { account, rarity, personId?, kind?, redeem? } — put a card in an account's binder
 * (dev, tests and fixtures). Numbered rarities get the next serial. The printed redeemable effect
 * follows the normal rules unless `redeem` forces "boost" / "retire" / "none".
 */
export async function grantCard(c: Ctx) {
  const name = str(c.body, "account", 64);
  const rarity = oneOf(c.body, "rarity", ["common", "uncommon", "rare", "gilded", "misprint", "original"] as const);
  const acct = await c.db.prepare("SELECT id FROM accounts WHERE name = ?").bind(name).first<{ id: string }>();
  if (!acct) return fail("not_found", "no such account");
  const defs = await ensureDefs(c, c.L.state.season);
  const want = typeof c.body.personId === "string" ? c.body.personId : undefined;
  const kind = typeof c.body.kind === "string" ? c.body.kind : "player";
  const def = want ? defs.find(d => d.personId === want) : defs.find(d => (d as Card & { kind?: string }).kind === kind && (c.L.world.players[d.personId]?.active || c.L.world.npcs[d.personId]?.active));
  if (!def) return fail("not_found", "no matching card in this season's set");
  const card: Card = { ...def, rarity };
  const runs: Record<string, number> = { gilded: 50, misprint: 25, original: 1 };
  if (runs[rarity]) {
    const key = `${def.id}:${rarity}`;
    const n = (c.L.serials.get(key) ?? 0) + 1;
    c.L.serials.set(key, n);
    card.serial = n;
    card.printRun = runs[rarity];
    if (rarity === "misprint") card.variant = "raccoon-photobomb";
    if (rarity === "original") card.variant = "signed";
    await c.db.prepare("INSERT INTO serials (def_id, n) VALUES (?, ?) ON CONFLICT (def_id) DO UPDATE SET n = MAX(n, excluded.n)").bind(key, n).run();
  }
  const force = c.body.redeem;
  let redeem: Redeem | undefined;
  if (force === "boost") redeem = rarity === "original" ? { kind: "boost", boost: 20, days: 15 } : { kind: "boost", boost: 12, days: 7 };
  else if (force === "retire") redeem = { kind: "retire" };
  else if (force !== "none") redeem = redeemFor(c.L.world, card as SimCard, rarity, card.serial, new Rng(`admin:${def.id}:${card.serial ?? 0}`));
  if (redeem) card.redeem = redeem;
  const id = newId("k");
  await c.db.prepare("INSERT INTO cards (id, def_id, owner_id, serial, print_run, data, created_at) VALUES (?,?,?,?,?,?,?)")
    .bind(id, card.id, acct.id, card.serial ?? null, card.printRun ?? null, JSON.stringify(card), c.now).run();
  return { id, card };
}

/**
 * POST /v1/admin/grudge { account? | syndicate?, team, level } — set how much a club's owners hate an
 * account (by name) or a syndicate (by name), 0..5 (dev, tests and fixtures). Returns the new level.
 */
export async function grudge(c: Ctx) {
  const w = c.L.world;
  const tid = str(c.body, "team", 40);
  const team = w.teams[tid] ?? Object.values(w.teams).find(t => t.abbr.toLowerCase() === tid.toLowerCase());
  if (!team) return fail("not_found", "no such team");
  const level = int(c.body, "level", 0, 5);
  let party: string | undefined;
  if (typeof c.body.account === "string") party = (await c.db.prepare("SELECT id FROM accounts WHERE name = ?").bind(c.body.account).first<{ id: string }>())?.id;
  else if (typeof c.body.syndicate === "string") party = (await c.db.prepare("SELECT id FROM syndicates WHERE name = ?").bind(c.body.syndicate).first<{ id: string }>())?.id;
  if (!party) return fail("not_found", "no such account or syndicate");
  const now = grudgeOf(w, team.factionId, party);
  if (level !== now) angerFaction(w, team.factionId, party, level - now, "admin");
  c.L.store.saveField("world", w, "relationships");
  return { faction: team.factionId, party, level: grudgeOf(w, team.factionId, party) };
}
