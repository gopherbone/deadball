import { describe, expect, it } from "vitest";
import { api, register, advance } from "./helpers.ts";

describe("crew -> op order -> outcome mail", () => {
  it("recruits, orders a job, and gets the outcome by mail", async () => {
    const a = await register("Boss Hogg");
    const cands = await api("GET", "/crew/candidates", undefined, a.token);
    expect(cands.body.candidates.length).toBeGreaterThan(0);
    expect(cands.body.refreshesAt).toBeGreaterThan(Date.now() - 1000);
    const cheapest = [...cands.body.candidates].sort((x: { ask: number }, y: { ask: number }) => x.ask - y.ask)[0];
    const rec = await api("POST", "/crew/recruit", { candidateId: cheapest.id }, a.token);
    expect(rec.status).toBe(200);
    expect(rec.body.crew).toHaveLength(1);
    expect(rec.body.account.money).toBe(1000 - cheapest.ask);
    expect((await api("POST", "/crew/recruit", { candidateId: cheapest.id }, a.token)).status).toBeGreaterThanOrEqual(400);
    const crewId = rec.body.crew[0].id;

    const today = await api("GET", "/today", undefined, a.token);
    const g = today.body.games[0];
    const cat = await api("GET", `/ops/catalog?game=${g.id}`, undefined, a.token);
    expect(cat.body.targets).toHaveLength(2);
    const kind = cat.body.kinds.find((k: { cost: number; kind: string }) => k.kind !== "security" && k.cost <= 400) ?? cat.body.kinds[0];
    expect(kind).toMatchObject({ successPct: expect.any(Number), needs: expect.any(String), gear: expect.any(Array) });

    expect((await api("POST", "/ops", { kind: kind.kind, gameId: g.id, targetTeamId: "XXX", crew: [crewId], gear: [] }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/ops", { kind: "made_up", gameId: g.id, targetTeamId: g.home.id, crew: [crewId], gear: [] }, a.token)).body.error).toBe("bad_request");
    const op = await api("POST", "/ops", { kind: kind.kind, gameId: g.id, targetTeamId: g.home.id, crew: [crewId], gear: [] }, a.token);
    expect(op.status).toBe(200);
    expect(op.body.op).toMatchObject({ status: "planned", target: { id: g.home.id }, game: { id: g.id } });
    // crew is now busy: can't double-book or dismiss
    expect((await api("POST", "/ops", { kind: kind.kind, gameId: g.id, targetTeamId: g.home.id, crew: [crewId], gear: [] }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", `/crew/${crewId}/dismiss`, undefined, a.token)).body.error).toBe("bad_request");

    await advance(1);
    const ops = await api("GET", "/ops", undefined, a.token);
    expect(["done", "blown"]).toContain(ops.body.ops[0].status);
    expect(ops.body.ops[0].result).toBeTruthy();
    const mail = await api("GET", "/mail", undefined, a.token);
    const opMail = mail.body.mail.filter((m: { kind: string }) => m.kind === "op");
    expect(opMail.length).toBeGreaterThan(0);
    expect(opMail[0]).toMatchObject({ from: expect.any(String), subject: expect.any(String), body: expect.any(Array), read: false });
    const read = await api("POST", `/mail/${opMail[0].id}/read`, undefined, a.token);
    expect(read.body).toEqual({ ok: true });
    const ev = await api("GET", "/events", undefined, a.token);
    expect(Array.isArray(ev.body.events)).toBe(true);
    for (const card of ev.body.events) {
      const free = card.choices.find((c: { cost?: number }) => !c.cost) ?? card.choices[0];
      const r = await api("POST", `/events/${card.id}/choose`, { key: free.key }, a.token);
      expect(r.status).toBe(200);
      expect(typeof r.body.result).toBe("string");
    }
  });

  it("orders lock at first pitch", async () => {
    const a = await register("Late Larry");
    const today = await api("GET", "/today", undefined, a.token);
    await advance(1);
    const r = await api("POST", "/ops", { kind: "security", gameId: today.body.games[0].id, targetTeamId: today.body.games[0].home.id, crew: ["x"], gear: [] }, a.token);
    expect(r.body.error).toBe("window_closed");
  });
});

describe("syndicates", () => {
  it("create, invite via event card, joint op with ally crew, treasury, leaderboard", async () => {
    const a = await register("Founder Fran");
    const b = await register("Ally Al");
    const c = await register("Outsider Ollie");
    const syn = await api("POST", "/syndicate", { name: "Night Owls" }, a.token);
    expect(syn.status).toBe(200);
    expect(syn.body.syndicate).toMatchObject({ name: "Night Owls", board: expect.stringMatching(/^bbs:syn:/), members: [{ name: "Founder Fran", founder: true }] });
    expect((await api("POST", "/syndicate", { name: "night owls" }, c.token)).body.error).toBe("name_taken");
    const inv = await api("POST", "/syndicate/invite", { accountName: "ally al" }, a.token);
    expect(inv.status).toBe(200);
    const evs = await api("GET", "/events", undefined, b.token);
    const card = evs.body.events.find((e: { choices: { key: string }[] }) => e.choices.some(ch => ch.key === "accept"));
    expect(card).toBeTruthy();
    const acc = await api("POST", `/events/${card.id}/choose`, { key: "accept" }, b.token);
    expect(acc.status).toBe(200);
    const mine = await api("GET", "/syndicate", undefined, b.token);
    expect(mine.body.syndicate.members).toHaveLength(2);

    // private board
    const board = mine.body.syndicate.board;
    expect((await api("GET", `/threads/${board}`, undefined, a.token)).status).toBe(200);
    expect((await api("GET", `/threads/${board}`, undefined, c.token)).status).toBe(403);

    // treasury: deposit by anyone, withdraw by founder only
    expect((await api("POST", "/syndicate/treasury", { amount: 200 }, b.token)).body.syndicate.treasury).toBe(200);
    expect((await api("POST", "/syndicate/treasury", { amount: -50 }, b.token)).status).toBe(403);
    expect((await api("POST", "/syndicate/treasury", { amount: -500 }, a.token)).body.error).toBe("insufficient_funds");
    const w = await api("POST", "/syndicate/treasury", { amount: -50 }, a.token);
    expect(w.body.syndicate.treasury).toBe(150);
    expect(w.body.account.money).toBe(1050);

    // joint op: A orders with B's crew
    const cb = (await api("GET", "/crew/candidates", undefined, b.token)).body.candidates.sort((x: { ask: number }, y: { ask: number }) => x.ask - y.ask)[0];
    const recB = await api("POST", "/crew/recruit", { candidateId: cb.id }, b.token);
    const allyCrew = recB.body.crew[0].id;
    const g = (await api("GET", "/today", undefined, a.token)).body.games[0];
    expect((await api("POST", "/ops", { kind: "security", gameId: g.id, targetTeamId: g.home.id, crew: [allyCrew], gear: [] }, c.token)).body.error).toBe("bad_request"); // not an ally
    const op = await api("POST", "/ops", { kind: "security", gameId: g.id, targetTeamId: g.home.id, crew: [allyCrew], gear: [] }, a.token);
    expect(op.status).toBe(200);
    await advance(1);
    const lb = await api("GET", "/syndicates/leaderboard", undefined, c.token);
    expect(lb.body.rows[0]).toMatchObject({ name: "Night Owls", members: ["Founder Fran", "Ally Al"], ops: 1 });

    // leave: founder passes to the next member
    await api("POST", "/syndicate/leave", undefined, a.token);
    const after = await api("GET", "/syndicate", undefined, b.token);
    expect(after.body.syndicate.founder).toBe("Ally Al");
  });
});
