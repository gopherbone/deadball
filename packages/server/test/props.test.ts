import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import type { League } from "../src/league.ts";
import { propSyncStmts, settleProps } from "../src/routes/props.ts";
import { moodModifiers, sim, type Storyline } from "../src/sim.ts";
import { dramaModifiers } from "@deadball/sim";
import { api, register, advance, houseScale } from "./helpers.ts";

const E = env as unknown as { DB: D1Database; LEAGUE: DurableObjectNamespace };
const DB = E.DB;
const inLeague = <R>(fn: (L: League) => R | Promise<R>) => runInDurableObject(E.LEAGUE.get(E.LEAGUE.idFromName("league")), (L: League) => fn(L));

/** Two different major-league players (different teams). */
const twoPlayers = (L: League) => {
  const ml = Object.values(L.world.teams).filter(t => t.level === "ML");
  const pick = (i: number) => ml[i].roster.find(id => L.world.players[id] && L.world.players[id].pos !== "P")!;
  return [pick(0), pick(1), ml[0].id, ml[1].id] as const;
};

/** Plant a storyline in the world and sync the prop markets (what the day close does every day). */
async function plant(L: League, s: Partial<Storyline> & Pick<Storyline, "id" | "kind" | "people" | "visibility" | "stage">) {
  const full: Storyline = {
    teams: [], startedDay: L.world.day, season: L.world.season, nudges: { expose: 0, inflame: 0, soothe: 0 }, data: { cause: "a motel receipt", stakes: "his marriage" }, log: [],
    ...(s.visibility !== "secret" ? { bettableDay: L.world.day } : {}), ...s,
  } as Storyline;
  (L.world.storylines ??= []).push(full);
  await sync(L);
  return full;
}
const sync = async (L: League) => {
  const next = L.timesFor(L.state.day).closeAt;
  await L.db.batch(propSyncStmts(L, next, Date.now()));
};

/** Every 13-digit number must sit under `at` or `*At` (http.ts adds the relative twins). */
function epochKeys(v: unknown, path = ""): string[] {
  if (Array.isArray(v)) return v.flatMap((x, i) => epochKeys(x, `${path}[${i}]`));
  if (!v || typeof v !== "object") return [];
  return Object.entries(v as Record<string, unknown>).flatMap(([k, x]) =>
    typeof x === "number" && x >= 1e12 && k !== "at" && !k.endsWith("At") ? [`${path}.${k}`] : epochKeys(x, `${path}.${k}`));
}

describe("drama props", () => {
  it("opens pools for public storylines, takes bets, settles through the ledger, refunds dead pools", async () => {
    await houseScale(0); // player-only pools (house money: house.test.ts)
    await api("GET", "/clock");
    const a = await register("Prop Pete");
    const b = await register("Prop Polly");
    const c = await register("Prop Paco");
    const [pid, secretPid, team] = await inLeague(L => twoPlayers(L));
    await inLeague(L => plant(L, { id: "sltA", kind: "affair", people: [pid], teams: [team], visibility: "rumoured", stage: "ongoing" }));
    await inLeague(L => plant(L, { id: "sltS", kind: "gambling_debt", people: [secretPid], visibility: "secret", stage: "shaving", data: { amount: 4000 } }));

    const list = await api("GET", "/props", undefined, a.token);
    expect(list.status).toBe(200);
    const item = (await api("GET", "/props?storyline=sltA", undefined, a.token)).body.storylines[0];
    expect(item).toMatchObject({ kind: "affair", visibility: "rumoured", stage: "ongoing", who: { id: pid }, headline: expect.stringMatching(/Motel/) });
    expect(item.props.map((p: { id: string }) => p.id)).toEqual(["sltA:yes", "sltA:when", "sltA:how"]);
    const yes = item.props[0];
    expect(yes).toMatchObject({ type: "yesno", status: "open", pool: 0, options: [{ key: "yes", pool: 0 }, { key: "no", pool: 0 }] });
    expect(typeof yes.closesIn).toBe("number");
    expect(yes.closesAt).toBeGreaterThan(Date.now());
    // secret storylines never show, anywhere
    const gossip0 = await api("GET", "/gossip", undefined, a.token);
    for (const body of [list.body, gossip0.body]) {
      expect(JSON.stringify(body)).not.toContain("sltS");
      expect(JSON.stringify(body)).not.toContain(secretPid);
    }
    expect((await api("POST", "/props/bets", { propId: "sltS:yes", option: "yes", amount: 10 }, a.token)).status).toBe(404);
    expect((await DB.prepare("SELECT COUNT(*) AS n FROM props WHERE storyline_id = 'sltS'").first<{ n: number }>())!.n).toBe(0);

    // validation
    expect((await api("POST", "/props/bets", { propId: "sltA:yes", option: "maybe", amount: 10 }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/props/bets", { propId: "sltA:yes", option: "yes", amount: 4 }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/props/bets", { propId: "sltA:yes", option: "yes", amount: 600 }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/props/bets", { propId: "nope:yes", option: "yes", amount: 10 }, a.token)).status).toBe(404);

    const p1 = await api("POST", "/props/bets", { propId: "sltA:yes", option: "yes", amount: 60 }, a.token);
    expect(p1.status).toBe(200);
    expect(p1.body.account.money).toBe(940);
    await api("POST", "/props/bets", { propId: "sltA:yes", option: "yes", amount: 40 }, a.token); // tops up
    expect((await api("POST", "/props/bets", { propId: "sltA:yes", option: "no", amount: 10 }, a.token)).body.error).toBe("bad_request"); // no hedging
    await api("POST", "/props/bets", { propId: "sltA:yes", option: "no", amount: 300 }, b.token);
    const pc = await api("POST", "/props/bets", { propId: "sltA:yes", option: "yes", amount: 50 }, c.token);
    expect(pc.body.prop.options).toEqual([
      { key: "yes", label: "Yes", pool: 150, pays: Math.floor((450 * 0.9 * 100) / 150) / 100, house: 0 },
      { key: "no", label: "No", pool: 300, pays: Math.floor((450 * 0.9 * 100) / 300) / 100, house: 0 },
    ]);
    expect(pc.body.prop.myBet).toEqual({ option: "yes", amount: 50 });
    // a lonely bet on an ending nobody else picks: refunded when it doesn't happen
    await api("POST", "/props/bets", { propId: "sltA:how", option: "ended_quietly", amount: 20 }, b.token);

    const open = await api("GET", "/props/bets?status=open", undefined, a.token);
    expect(open.body.bets).toHaveLength(1);
    expect(open.body.bets[0]).toMatchObject({ propId: "sltA:yes", option: "yes", optionLabel: "Yes", amount: 100, status: "open", headline: expect.any(String) });
    const g = await api("GET", "/gossip", undefined, a.token);
    expect(g.body.my).toHaveLength(1);
    expect(g.body.storylines.find((s: { id: string }) => s.id === "sltA").props[0].myBet).toEqual({ option: "yes", amount: 100 });

    // park the secret arc outside the world while days pass, so the life engine can't move it
    const parked = await inLeague(L => {
      const i = L.world.storylines.findIndex(x => x.id === "sltS");
      return L.world.storylines.splice(i, 1)[0];
    });
    // the affair is discovered: the market closes and pays at the end of the day
    await inLeague(L => {
      const s = L.world.storylines.find(x => x.id === "sltA")!;
      s.visibility = "public";
      s.resolved = { day: L.world.day, outcome: "discovered", eventId: "test" };
    });
    expect((await api("POST", "/props/bets", { propId: "sltA:yes", option: "yes", amount: 10 }, c.token)).body.error).toBe("window_closed");
    expect((await advance(1)).status).toBe(200);

    const net = Math.floor(450 * 0.9);
    const money = async (t: string) => (await api("GET", "/me", undefined, t)).body.account.money as number;
    expect(await money(a.token)).toBe(900 + Math.floor((100 * net) / 150));
    expect(await money(c.token)).toBe(950 + Math.floor((50 * net) / 150));
    expect(await money(b.token)).toBe(700); // lost 300 on "no", got the 20 back
    const rows = (await DB.prepare("SELECT id, status, outcome FROM props WHERE storyline_id = 'sltA' ORDER BY id").all<{ id: string; status: string; outcome: string }>()).results;
    expect(rows).toEqual([
      { id: "sltA:how", status: "refunded", outcome: "discovered" },
      { id: "sltA:when", status: "refunded", outcome: "d5" }, // nobody bet: nothing to pay
      { id: "sltA:yes", status: "settled", outcome: "yes" },
    ]);
    const settled = await api("GET", "/props/bets?status=settled", undefined, a.token);
    expect(settled.body.bets[0]).toMatchObject({ status: "settled", won: true, payout: Math.floor((100 * net) / 150), outcome: "yes", outcomeLabel: "Yes" });
    const sb = await api("GET", "/props/bets?status=settled", undefined, b.token);
    expect(sb.body.bets.map((x: { propId: string; won: boolean; refunded?: boolean }) => [x.propId, x.won, !!x.refunded]).sort()).toEqual([["sltA:how", false, true], ["sltA:yes", false, false]]);
    const mail = (await api("GET", "/mail", undefined, a.token)).body.mail;
    expect(mail.find((m: { subject: string }) => m.subject === `Prop won: $${Math.floor((100 * net) / 150)}`)).toMatchObject({ kind: "bank", from: "Bets By Bobby" });
    const mailB = (await api("GET", "/mail", undefined, b.token)).body.mail.map((m: { subject: string }) => m.subject);
    expect(mailB).toContain("Prop lost");
    expect(mailB).toContain("Prop refunded");

    // idempotent: a second settlement pass pays nothing more; the ledger matches the money
    const before = await money(a.token);
    await DB.prepare("UPDATE props SET status = 'closed' WHERE storyline_id = 'sltA'").run();
    await inLeague(L => settleProps(L, Date.now()));
    expect(await money(a.token)).toBe(before);
    for (const t of [a, b, c]) {
      const l = await DB.prepare("SELECT SUM(delta) AS s FROM ledger WHERE account_id = ?").bind(t.account.id).first<{ s: number }>();
      expect(l!.s).toBe(await money(t.token));
    }
    // settled markets drop off the board
    expect((await api("GET", "/props?storyline=sltA", undefined, a.token)).body.storylines).toEqual([]);

    // the secret arc leaks into the rumour mill: only now does it get markets
    await inLeague(async L => {
      const s = { ...parked, visibility: "rumoured" } as Storyline;
      L.world.storylines.push(s);
      s.bettableDay = L.world.day;
      await sync(L);
    });
    const leaked = (await api("GET", "/props?storyline=sltS", undefined, a.token)).body.storylines.find((s: { id: string }) => s.id === "sltS");
    expect(leaked).toMatchObject({ visibility: "rumoured", stage: "leaned on" }); // shaving stays hidden
    expect(leaked.props).toHaveLength(3);
  });

  it("closes at closesDay and expires the yes/no question as NO", async () => {
    const a = await register("Late Larry");
    const [pid, other, team] = await inLeague(L => twoPlayers(L));
    // became public 40 days ago: every question is past its closing day
    await inLeague(L => plant(L, { id: "sltOld", kind: "slump", people: [pid], teams: [team], visibility: "public", stage: "slump", bettableDay: L.world.day - 40 }));
    const rows = (await DB.prepare("SELECT id, status FROM props WHERE storyline_id = 'sltOld' ORDER BY id").all<{ id: string; status: string }>()).results;
    expect(rows.every(r => r.status === "closed")).toBe(true);
    expect((await api("POST", "/props/bets", { propId: "sltOld:yes", option: "no", amount: 10 }, a.token)).body.error).toBe("window_closed");
    await inLeague(L => settleProps(L, Date.now()));
    const out = (await DB.prepare("SELECT id, outcome FROM props WHERE storyline_id = 'sltOld' AND outcome IS NOT NULL ORDER BY id").all<{ id: string; outcome: string }>()).results;
    expect(out).toEqual([{ id: "sltOld:when", outcome: "later" }, { id: "sltOld:yes", outcome: "no" }]);

    // a fresh one closes on schedule: open today, closed once world.day passes closesDay
    await inLeague(L => plant(L, { id: "sltNew", kind: "feud", people: [pid, other], teams: [team], visibility: "public", stage: "words" }));
    const when = await DB.prepare("SELECT closes_day, status FROM props WHERE id = 'sltNew:when'").first<{ closes_day: number; status: string }>();
    expect(when!.status).toBe("open");
    const day0 = await inLeague(L => L.world.day);
    await advance(when!.closes_day - day0 + 1);
    expect((await DB.prepare("SELECT status FROM props WHERE id = 'sltNew:when'").first<{ status: string }>())!.status).not.toBe("open");
    expect((await api("POST", "/props/bets", { propId: "sltNew:when", option: "d5", amount: 10 }, a.token)).body.error).toBe("window_closed");
  });

  it("serves fixture-ready docs: small, epoch fields only as *At/at", async () => {
    const a = await register("Fixture Fran");
    const [pid, , team] = await inLeague(L => twoPlayers(L));
    await inLeague(L => plant(L, { id: "sltFx", kind: "contract_year", people: [pid], teams: [team], visibility: "public", stage: "playing_for_a_deal" }));
    await api("POST", "/props/bets", { propId: "sltFx:how", option: "big_payday", amount: 25 }, a.token);
    for (const path of ["/gossip", "/props", "/props/bets?status=open", "/props/bets?status=settled"]) {
      const r = await api("GET", path, undefined, a.token);
      expect(r.status).toBe(200);
      expect(epochKeys(r.body)).toEqual([]);
      expect(JSON.stringify(r.body).length).toBeLessThan(48 * 1024);
    }
    const g = (await api("GET", "/gossip", undefined, a.token)).body;
    expect(g).toMatchObject({ day: expect.any(Number), storylines: expect.any(Array), chatter: expect.any(Array), my: expect.any(Array), recent: expect.any(Array) });
    expect(g.my[0]).toMatchObject({ propId: "sltFx:how", optionLabel: "big payday", placedAt: expect.any(Number), placedIn: expect.any(Number) });
  });
});

describe("storyline ops and tips", () => {
  it("tips make a secret arc known to one account: Gossip Board row, op target, gameless job", async () => {
    const a = await register("Tipped Tina");
    const b = await register("Clueless Carl");
    const [pid, other, team] = await inLeague(L => twoPlayers(L));
    await inLeague(L => plant(L, { id: "sltK", kind: "affair", people: [pid, other], teams: [team], visibility: "secret", stage: "ongoing" }));
    // a tip mail carrying storylineId (what dramaTips / secretTips send)
    await inLeague(L => L.db.batch(L.mailStmts([{ id: "tip:test:K", ownerId: a.account.id, from: "A Friend", subject: "Not in the papers", body: ["He has been seeing someone."], kind: "tip", day: L.world.day, storylineId: "sltK" } as never], Date.now() - 1000)));

    const ga = (await api("GET", "/gossip", undefined, a.token)).body;
    expect(ga.storylines[0]).toMatchObject({ id: "sltK", heard: true, visibility: "secret", props: [] });
    const gb = await api("GET", "/gossip", undefined, b.token);
    const pb = await api("GET", "/props", undefined, b.token);
    for (const body of [gb.body, pb.body]) expect(JSON.stringify(body)).not.toContain("sltK");
    const mail = (await api("GET", "/mail", undefined, a.token)).body.mail;
    expect(mail.find((m: { id: string }) => m.id === "tip:test:K")).toMatchObject({ kind: "tip", storylineId: "sltK" });

    const ca = (await api("GET", "/ops/catalog", undefined, a.token)).body;
    const target = ca.storylines.find((t: { storylineId: string }) => t.storylineId === "sltK");
    expect(target).toMatchObject({ kind: "affair", visibility: "secret", people: [{ id: pid }, { id: other }] });
    expect(target.ops.map((o: { kind: string }) => o.kind)).toEqual(expect.arrayContaining(["love_letter", "tip_wire", "blackmail", "smooth_over"]));
    expect(ca.kinds.find((k: { kind: string }) => k.kind === "smooth_over").storyline).toMatchObject({ required: true });
    expect((await api("GET", "/ops/catalog", undefined, b.token)).body.storylines.some((t: { storylineId: string }) => t.storylineId === "sltK")).toBe(false);

    // hire someone cheap, then run a storyline-only job
    const cands = (await api("GET", "/crew/candidates", undefined, a.token)).body.candidates as { id: string; ask: number }[];
    const hire = await api("POST", "/crew/recruit", { candidateId: [...cands].sort((x, y) => x.ask - y.ask)[0].id }, a.token);
    expect(hire.status).toBe(200);
    const crewId = hire.body.crew[0].id;
    const job = { kind: "blackmail", gameId: "", targetTeamId: "", crew: [crewId], gear: [], storylineId: "sltK", nudge: "soothe" };
    expect((await api("POST", "/ops", job, b.token)).status).toBe(404); // b never heard of it
    expect((await api("POST", "/ops", { ...job, kind: "smooth_over", storylineId: undefined }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/ops", { ...job, kind: "steal_signs" }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/ops", { ...job, gameId: "", storylineId: undefined, kind: "tip_wire" }, a.token)).body.error).toBe("bad_request");
    const placed = await api("POST", "/ops", job, a.token);
    expect(placed.status).toBe(200);
    expect(placed.body.op).toMatchObject({ kind: "blackmail", status: "planned", storyline: { id: "sltK" }, target: { id: team } });
    expect(placed.body.op.game).toBeUndefined();

    await advance(1);
    const op = (await api("GET", "/ops", undefined, a.token)).body.ops.find((o: { id: string }) => o.id === placed.body.op.id);
    expect(op.status).not.toBe("planned");
    expect(op.result).toBeTruthy();
    if (op.status === "done") expect(op.nudge).toMatchObject({ kind: expect.stringMatching(/soothe|expose/), applied: expect.any(Boolean) });
    expect((await api("GET", "/mail", undefined, a.token)).body.mail.some((m: { kind: string; subject: string }) => m.kind === "op" && /Blackmail/i.test(m.subject))).toBe(true);
  });
});

describe("newsroom and game wiring", () => {
  it("BBS rumour chatter, front page by prominence, contextual drama modifiers", async () => {
    const a = await register("News Nellie");
    await advance(2);
    const t = await api("GET", "/threads/bbs:rumors", undefined, a.token);
    expect(t.body.comments.length).toBeGreaterThan(0);
    expect(t.body.comments.every((x: { author: string }) => x.author && x.author !== "(gone)")).toBe(true);
    expect((await api("GET", "/gossip", undefined, a.token)).body.chatter.length).toBeGreaterThan(0);

    const news = (await api("GET", "/news?limit=40", undefined, a.token)).body.stories as { at: number; id: string }[];
    const prom = new Map((await DB.prepare("SELECT id, prominence FROM stories").all<{ id: string; prominence: number }>()).results.map(r => [r.id, r.prominence]));
    expect(new Set(prom.values()).size).toBeGreaterThan(1);
    for (let i = 1; i < news.length; i++) {
      if (news[i].at === news[i - 1].at) expect(prom.get(news[i].id)!).toBeLessThanOrEqual(prom.get(news[i - 1].id)!);
    }
    const page2 = await api("GET", `/news?limit=5`, undefined, a.token);
    if (page2.body.next) {
      const more = (await api("GET", `/news?limit=5&cursor=${page2.body.next}`, undefined, a.token)).body.stories;
      expect(more[0].id).not.toBe(page2.body.stories[4].id);
    }

    // the server hands the scheduled game to the drama layer (night games, grudges, shaving...)
    await inLeague(L => {
      const g = sim.slateFor(L.state, L.state.day)[0];
      expect(moodModifiers(L.world, g)).toEqual(dramaModifiers(L.world, g));
    });
  });
});
