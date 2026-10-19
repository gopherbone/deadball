// Bobby's regulars: house (NPC) money in every bettable pool (src/house.ts).

import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import type { GameRow, League } from "../src/league.ts";
import { HOUSE, gameWaves, parseWaves, paysFor, propWaves, publicFacts, settleMath, visible, type GameFacts, type HouseWave } from "../src/house.ts";
import { propHouse, propSyncStmts, type PropRow } from "../src/routes/props.ts";
import { sim, type Storyline } from "../src/sim.ts";
import { api, register, advance, houseScale } from "./helpers.ts";

const E = env as unknown as { DB: D1Database; LEAGUE: DurableObjectNamespace };
const DB = E.DB;
const inLeague = <R>(fn: (L: League) => R | Promise<R>) => runInDurableObject(E.LEAGUE.get(E.LEAGUE.idFromName("league")), (L: League) => fn(L));
const money = async (t: string) => (await api("GET", "/me", undefined, t)).body.account.money as number;
const tot = (ws: HouseWave[], i: number) => ws.reduce((a, w) => a + (w.a[i] ?? 0), 0);

const facts = (o: Partial<GameFacts> = {}): GameFacts => ({ id: "S1D3ML0", level: "ML", homeId: "HCL", awayId: "BRK", pHome: 0.55, ...o });

describe("house waves (pure)", () => {
  it("are deterministic per seed, land in order before first pitch, scale with prominence", () => {
    const pre = 450_000;
    const a = gameWaves("seed-1", facts(), pre), b = gameWaves("seed-1", facts(), pre), c = gameWaves("seed-2", facts(), pre);
    expect(a).toEqual(b);
    expect(a).not.toEqual(c);
    expect(a.map(w => w.k)).toEqual(["w0", "w1", "w2"]);
    expect(a.map(w => w.off)).toEqual(HOUSE.game.waves.map(w => Math.round(w.at * pre)));
    for (const ws of [a, c]) for (const i of [0, 1]) expect(tot(ws, i)).toBeGreaterThanOrEqual(HOUSE.minOption);
    const size = (f: GameFacts) => { const ws = gameWaves("seed-1", f, pre); return tot(ws, 0) + tot(ws, 1); };
    const base = size(facts());
    expect(base).toBeGreaterThan(HOUSE.game.base * (1 - HOUSE.game.sizeJitter) - 2);
    expect(base).toBeLessThan(HOUSE.game.base * (1 + HOUSE.game.sizeJitter) + 2);
    expect(size(facts({ level: "EL" }))).toBeGreaterThan(base);
    expect(size(facts({ playoff: true }))).toBeGreaterThan(base * 1.5);
    expect(size(facts({ playoff: true, final: true }))).toBeGreaterThan(size(facts({ playoff: true })));
    expect(gameWaves("seed-1", facts({ level: "AA" }), pre)).toEqual([]); // farm games aren't bettable: no house money
    // the stronger side draws more money, but not all of it
    let fav = 0, n = 0;
    for (let i = 0; i < 40; i++) {
      const ws = gameWaves("s", facts({ id: `g${i}`, pHome: 0.65 }), pre);
      fav += tot(ws, 0) / (tot(ws, 0) + tot(ws, 1)); n++;
    }
    expect(fav / n).toBeGreaterThan(0.6);
    expect(fav / n).toBeLessThan(0.85);
  });

  it("only counts waves that have landed", () => {
    const ws = gameWaves("seed-1", facts(), 100_000);
    const fp = 1_000_000;
    expect(visible(ws, 2, fp, fp - 100_001)).toEqual([0, 0]);
    expect(visible(ws, 2, fp, fp - 100_000)).toEqual(ws[0].a);
    expect(visible(ws, 2, fp, fp - 50_000)).toEqual([ws[0].a[0] + ws[1].a[0], ws[0].a[1] + ws[1].a[1]]);
    expect(visible(ws, 2, fp, fp)).toEqual([tot(ws, 0), tot(ws, 1)]);
    expect(visible(ws, 2, fp, fp, 0)).toEqual([0, 0]);
    expect(visible(ws, 2, fp, fp, 0.5)).toEqual([Math.floor(tot(ws, 0) * 0.5), Math.floor(tot(ws, 1) * 0.5)]);
    expect(parseWaves("not json")).toEqual([]);
  });

  it("settles mixed pools: winners split players + house less the cut on player money, house winnings burn", () => {
    const player = [100, 50], house = [500, 300];
    const m = settleMath(player, house, 0);
    const net = Math.floor(150 * (1 - HOUSE.cut) + 800 * (1 - HOUSE.npcCut));
    expect(m).toMatchObject({ refund: false, net, winPool: 600 });
    expect(m.burned).toBe(Math.floor((500 * net) / 600));
    expect(m.playerNet).toBe(Math.floor((100 * net) / 600) - 150);
    expect(m.take).toBe(950 - net);
    // the house lost 300 to the winners, kept nothing of its own (npcCut 0): players come out ahead
    expect(m.playerNet).toBeGreaterThan(0);
    // pays per $1 match the settlement
    expect(paysFor(player, house)[0]).toBe(Math.floor((net * 100) / 600) / 100);
    // the player side lost: their money goes to the house's winning stake (burned)
    const lost = settleMath(player, house, 1);
    expect(lost.playerNet).toBe(Math.floor((50 * lost.net) / 350) - 150);
    // only the house in the pool: nothing to pay
    expect(settleMath([0, 0], house, 0)).toMatchObject({ refund: false, playerNet: 0 });
    // refunds: no result, or nobody at all on the winner (house switched off)
    expect(settleMath(player, house, undefined)).toMatchObject({ refund: true, playerNet: 0 });
    expect(settleMath([100, 0], [0, 0], 1)).toMatchObject({ refund: true, playerNet: 0 });
    // with house money on every option, somebody always backed the winner
    expect(settleMath([100, 0], [5, 5], 1)).toMatchObject({ refund: false, winPool: 5 });
    // player-only pools are the old rules exactly
    expect(settleMath([150, 300], [0, 0], 0)).toMatchObject({ net: Math.floor(450 * 0.9), winPool: 150 });
  });

  it("seeds props from public facts only: secrets, nudges and hidden stages change nothing", () => {
    const base: Storyline = {
      id: "slX", kind: "gambling_debt", people: ["p1"], teams: ["HCL"], startedDay: 10, season: 1, visibility: "rumoured", stage: "leaned_on",
      bettableDay: 12, nudges: { expose: 0, inflame: 0, soothe: 0 }, data: { amount: 4000 }, log: [],
    };
    const twin: Storyline = {
      ...base, people: ["p9", "p8"], teams: ["BRK"], startedDay: 3, stage: "shaving", nudges: { expose: 5, inflame: 4, soothe: 0 },
      data: { amount: 99999, shaved: 3, fixer: "x" }, log: [{ day: 11, stage: "shaving", visibility: "secret" }],
    };
    expect(publicFacts(twin)).toEqual(publicFacts(base));
    const q = { id: "slX:how", options: ["paid_off", "exposed", "ejected_from_league", "leg_broken", "went_to_commissioner", "death"], closesDay: 17, resolveBy: 200 };
    for (const day of [12, 13, 17]) {
      for (const first of [true, false]) expect(propWaves("seed", publicFacts(twin)!, q, day, 600_000, first)).toEqual(propWaves("seed", publicFacts(base)!, q, day, 600_000, first));
    }
    expect(publicFacts({ ...base, visibility: "secret" })).toBeUndefined();
    expect(publicFacts({ ...base, bettableDay: undefined })).toBeUndefined();
    // every answer gets money on the first day; none after the book closes
    const first = propWaves("seed", publicFacts(base)!, q, 12, 600_000, true);
    for (let i = 0; i < q.options.length; i++) expect(tot(first, i)).toBeGreaterThanOrEqual(HOUSE.minOption);
    expect(propWaves("seed", publicFacts(base)!, q, 18, 600_000, false)).toEqual([]);
  });
});

describe("Bobby's regulars on the server", () => {
  it("game pools: waves on the slate, mixed settlement through the ledger, NPC money never in accounts", async () => {
    await api("GET", "/clock");
    const st = await api("GET", "/admin/status", undefined, undefined, true);
    expect(st.body.house).toBe(1);
    const a = await register("Raincoat Ray");
    const b = await register("Parrot Pam");

    const today = (await api("GET", "/today", undefined, a.token)).body.games as { id: string; status: string; pool: { home: number; away: number; house: { home: number; away: number }; pays: { home: number; away: number } } }[];
    const g = today.find(x => x.status === "scheduled")!;
    // the first wave lands at day start: the pool is never empty
    expect(g.pool.house.home).toBeGreaterThan(0);
    expect(g.pool.house.away).toBeGreaterThan(0);
    expect(g.pool).toMatchObject({ home: g.pool.house.home, away: g.pool.house.away });
    expect(g.pool.pays.home).toBe(paysFor([0, 0], [g.pool.house.home, g.pool.house.away])[0]);

    // the stored schedule is what the server computes from the seed (deterministic), set once
    const row = (await DB.prepare("SELECT * FROM games WHERE id = ?").bind(g.id).first<GameRow>())!;
    const waves = parseWaves(row.house);
    expect(waves).toHaveLength(3);
    const again = await inLeague(L => {
      const sched = sim.slateFor(L.state, L.state.day).find(x => g.id.endsWith(x.id) || g.id === x.id)!;
      return L.houseWaves(sched, JSON.parse(row.probables!), L.recordTable());
    });
    expect(again).toEqual(waves);
    await inLeague(L => L.ensureGameRows());
    expect((await DB.prepare("SELECT house FROM games WHERE id = ?").bind(g.id).first<{ house: string }>())!.house).toBe(row.house);
    // waves land through the window: only the first so far, all of them by first pitch
    expect(visible(waves, 2, row.first_pitch_at, row.first_pitch_at - waves[0].off)).toEqual(waves[0].a);
    expect(visible(waves, 2, row.first_pitch_at, row.first_pitch_at).reduce((x, y) => x + y)).toBeGreaterThan(waves[0].a[0] + waves[0].a[1]);

    // bets: the pool view folds player money into the house money
    const ba = await api("POST", "/bets", { gameId: g.id, side: "home", amount: 100 }, a.token);
    expect(ba.status).toBe(200);
    expect(ba.body.pool.home).toBe(ba.body.pool.house.home + 100);
    await api("POST", "/bets", { gameId: g.id, side: "away", amount: 60 }, b.token);

    const ids = today.map(x => x.id);
    await advance(1);
    const fin = (await DB.prepare("SELECT * FROM games WHERE id = ?").bind(g.id).first<GameRow>())!;
    expect(fin.settled).toBe(1);
    const house = visible(parseWaves(fin.house), 2, fin.first_pitch_at, Infinity);
    const win = fin.winner === "home" ? 0 : 1;
    const m = settleMath([100, 60], house, win);
    expect(m.refund).toBe(false);
    const payA = win === 0 ? Math.floor((100 * m.net) / m.winPool) : 0;
    const payB = win === 1 ? Math.floor((60 * m.net) / m.winPool) : 0;
    expect(await money(a.token)).toBe(900 + payA);
    expect(await money(b.token)).toBe(940 + payB);
    // the winner beat the house's money, not just the other player's
    expect(Math.max(payA, payB)).toBeGreaterThan(160 * 0.9);
    const detail = (await api("GET", `/games/${g.id}`, undefined, a.token)).body;
    expect(detail.pool).toMatchObject({ home: 100 + house[0], away: 60 + house[1], house: { home: house[0], away: house[1] } });

    // NPC-only pools settle too, with nothing to pay
    const others = (await DB.prepare("SELECT id, settled, simmed FROM games WHERE id IN (SELECT value FROM json_each(?)) AND id != ?").bind(JSON.stringify(ids), g.id).all<{ id: string; settled: number; simmed: number }>()).results;
    for (const o of others) if (o.simmed) expect(o.settled).toBe(1);
    expect((await DB.prepare("SELECT COUNT(*) AS n FROM bets WHERE game_id != ?").bind(g.id).first<{ n: number }>())!.n).toBe(0);

    // ledger invariants: every account's money is its ledger sum, nobody negative, nothing for anybody else
    const accts = (await DB.prepare("SELECT id, money FROM accounts").all<{ id: string; money: number }>()).results;
    for (const acct of accts) {
      expect(acct.money).toBeGreaterThanOrEqual(0);
      const l = await DB.prepare("SELECT COALESCE(SUM(delta), 0) AS s FROM ledger WHERE account_id = ?").bind(acct.id).first<{ s: number }>();
      expect(l!.s).toBe(acct.money);
    }
    expect((await DB.prepare("SELECT COUNT(*) AS n FROM ledger WHERE account_id NOT IN (SELECT id FROM accounts)").first<{ n: number }>())!.n).toBe(0);
    expect((await DB.prepare("SELECT COUNT(*) AS n FROM bets WHERE account_id NOT IN (SELECT id FROM accounts)").first<{ n: number }>())!.n).toBe(0);
    expect(accts).toHaveLength(2);

    // the admin dial: 0 turns the regulars off everywhere at once, 1 brings them back
    expect((await houseScale(0)).body).toEqual({ scale: 0 });
    const off = (await api("GET", "/today", undefined, a.token)).body.games.find((x: { status: string }) => x.status === "scheduled");
    expect(off.pool.house).toEqual({ home: 0, away: 0 });
    expect((await houseScale(-1)).body.error).toBe("bad_request");
    await houseScale(1);
    const on = (await api("GET", "/today", undefined, a.token)).body.games.find((x: { id: string }) => x.id === off.id);
    expect(on.pool.house.home + on.pool.house.away).toBeGreaterThan(0);
  });

  it("prop pools: house money on every answer, mixed settlement, refunds when the story goes cold", async () => {
    await api("GET", "/clock");
    const a = await register("Tabloid Tim");
    const b = await register("Gossip Gail");
    const [pid, pid2, team] = await inLeague(L => {
      const ml = Object.values(L.world.teams).filter(t => t.level === "ML");
      const pick = (i: number) => ml[i].roster.find(id => L.world.players[id] && L.world.players[id].pos !== "P")!;
      return [pick(0), pick(1), ml[0].id] as const;
    });
    const plant = (s: Partial<Storyline> & Pick<Storyline, "id" | "kind" | "people" | "visibility" | "stage">) => inLeague(async L => {
      const full = { teams: [team], startedDay: L.world.day, season: L.world.season, nudges: { expose: 0, inflame: 0, soothe: 0 }, data: {}, log: [],
        ...(s.visibility !== "secret" ? { bettableDay: L.world.day } : {}), ...s } as Storyline;
      (L.world.storylines ??= []).push(full);
      // as if the day closes shortly (the first waves have landed)
      const next = Date.now() + L.preMs;
      await L.db.batch(propSyncStmts(L, next, Date.now()));
      // a second sync the same day adds nothing (idempotent per question and day)
      await L.db.batch(propSyncStmts(L, next, Date.now()));
    });
    await plant({ id: "slH", kind: "affair", people: [pid], visibility: "public", stage: "ongoing" });
    await plant({ id: "slSecret", kind: "gambling_debt", people: [pid2], visibility: "secret", stage: "shaving" });
    expect((await DB.prepare("SELECT COUNT(*) AS n FROM props WHERE storyline_id = 'slSecret'").first<{ n: number }>())!.n).toBe(0);

    const rows = (await DB.prepare("SELECT * FROM props WHERE storyline_id = 'slH' ORDER BY id").all<PropRow>()).results;
    const day = await inLeague(L => L.world.day);
    expect(rows).toHaveLength(3);
    for (const r of rows) expect(parseWaves(r.house).map(w => w.k)).toEqual(HOUSE.prop.waves.map((_, i) => `d${day}w${i}`));
    const item = (await api("GET", "/props?storyline=slH", undefined, a.token)).body.storylines[0];
    const yes = item.props.find((p: { id: string }) => p.id === "slH:yes");
    expect(yes.house).toBeGreaterThan(0);
    expect(yes.pool).toBe(yes.house);
    for (const p of item.props) for (const o of p.options) {
      expect(o.house).toBeGreaterThanOrEqual(HOUSE.minOption);
      expect(o.pays).toBeGreaterThan(0);
    }

    const pa = await api("POST", "/props/bets", { propId: "slH:yes", option: "yes", amount: 80 }, a.token);
    expect(pa.status).toBe(200);
    expect(pa.body.prop.options.find((o: { key: string }) => o.key === "yes").pool).toBe(pa.body.prop.options.find((o: { key: string }) => o.key === "yes").house + 80);
    await api("POST", "/props/bets", { propId: "slH:yes", option: "no", amount: 40 }, b.token);
    await api("POST", "/props/bets", { propId: "slH:how", option: "ended_quietly", amount: 30 }, b.token);

    await inLeague(L => {
      const s = L.world.storylines.find(x => x.id === "slH")!;
      s.resolved = { day: L.world.day, outcome: "discovered", eventId: "test" };
    });
    await advance(1);
    const settled = (await DB.prepare("SELECT * FROM props WHERE id = 'slH:yes'").first<PropRow>())!;
    expect(settled).toMatchObject({ status: "settled", outcome: "yes" });
    const house = await inLeague(L => propHouse(L, settled, settled.settled_at!));
    const m = settleMath([80, 40], house, 0);
    expect(await money(a.token)).toBe(920 + Math.floor((80 * m.net) / m.winPool));
    // b lost the yes/no and the "how" (somebody - the house - had "discovered"): no refund now
    const how = (await DB.prepare("SELECT status FROM props WHERE id = 'slH:how'").first<{ status: string }>())!;
    expect(how.status).toBe("settled");
    expect(await money(b.token)).toBe(930);

    // a story that vanishes is called off: refunds, house money or not
    await plant({ id: "slGone", kind: "feud", people: [pid, pid2], visibility: "rumoured", stage: "words" });
    await api("POST", "/props/bets", { propId: "slGone:yes", option: "yes", amount: 50 }, b.token);
    await inLeague(L => { L.world.storylines = L.world.storylines.filter(s => s.id !== "slGone"); });
    await advance(1);
    expect((await DB.prepare("SELECT status FROM props WHERE id = 'slGone:yes'").first<{ status: string }>())!.status).toBe("refunded");
    expect(await money(b.token)).toBe(930);
    for (const t of [a, b]) {
      const l = await DB.prepare("SELECT SUM(delta) AS s FROM ledger WHERE account_id = ?").bind(t.account.id).first<{ s: number }>();
      expect(l!.s).toBe(await money(t.token));
    }
  });
});
