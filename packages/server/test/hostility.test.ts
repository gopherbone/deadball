import { describe, expect, it } from "vitest";
import { advance, api, register } from "./helpers.ts";

const BLEACHERS = ["heckle", "laser", "steal_signs"];

async function hire(token: string) {
  const cands = (await api("GET", "/crew/candidates", undefined, token)).body.candidates as { id: string; ask: number }[];
  const cheapest = [...cands].sort((x, y) => x.ask - y.ask)[0];
  const r = await api("POST", "/crew/recruit", { candidateId: cheapest.id }, token);
  expect(r.status).toBe(200);
  return r.body.crew[r.body.crew.length - 1].id as string;
}
const grudge = (body: Record<string, unknown>) => api("POST", "/admin/grudge", body, undefined, true);

describe("hostile owners", () => {
  it("ban grudge-holders from their bleachers, guard their clubs, and keep it off the team page", async () => {
    const a = await register("Banned Barney");
    const crew = await hire(a.token);
    const g = (await api("GET", "/today", undefined, a.token)).body.games.find((x: { circuit: string }) => x.circuit === "continental");
    const before = await api("GET", `/ops/catalog?game=${g.id}`, undefined, a.token);
    expect(before.body.kinds.filter((k: { blocked?: string }) => k.blocked)).toEqual([]);

    const set = await grudge({ account: "Banned Barney", team: g.home.id, level: 3 });
    expect(set.body.level).toBe(3);
    const cat = await api("GET", `/ops/catalog?game=${g.id}`, undefined, a.token);
    const blocked = cat.body.kinds.filter((k: { blocked?: string }) => k.blocked);
    expect(blocked.map((k: { kind: string }) => k.kind).sort()).toEqual(BLEACHERS);
    expect(blocked[0].blocked).toMatch(/^Banned from the .+ bleachers by /);
    // guards on their club: the home team (the default target) is harder to hit
    const pct = (b: { kinds: { kind: string; successPct: number }[] }, kind: string) => b.kinds.find(k => k.kind === kind)!.successPct;
    expect(pct(cat.body, "grease_mound")).toBeLessThan(pct(before.body, "grease_mound"));
    expect(cat.body.kinds.find((k: { kind: string }) => k.kind === "grease_mound").notes.join(" ")).toMatch(/guards out for you/);

    const no = await api("POST", "/ops", { kind: "laser", gameId: g.id, targetTeamId: g.away.id, crew: [crew], gear: [] }, a.token);
    expect(no.status).toBe(403);
    expect(no.body.message).toMatch(/bleachers/);
    expect((await api("POST", "/ops", { kind: "grease_mound", gameId: g.id, targetTeamId: g.home.id, crew: [crew], gear: [] }, a.token)).status).toBe(200);

    const team = await api("GET", `/teams/${g.home.id}`, undefined, a.token);
    expect(JSON.stringify(team.body.relations)).not.toContain(a.account.id);
  });

  it("a syndicate grudge covers every member", async () => {
    const a = await register("Grudge Gail");
    const b = await register("Grudge Gus");
    await api("POST", "/syndicate", { name: "Bad Apples" }, a.token);
    await api("POST", "/syndicate/invite", { accountName: "Grudge Gus" }, a.token);
    const inv = (await api("GET", "/syndicate", undefined, b.token)).body.invites[0];
    await api("POST", `/syndicate/invites/${inv.id}/accept`, undefined, b.token);
    const g = (await api("GET", "/today", undefined, b.token)).body.games[0];
    await grudge({ syndicate: "Bad Apples", team: g.home.id, level: 2 });
    const cat = await api("GET", `/ops/catalog?game=${g.id}`, undefined, b.token);
    expect(cat.body.kinds.find((k: { kind: string }) => k.kind === "heckle").blocked).toBeTruthy();
  });

  it("a ban that lands after the order calls the job off at the turnstiles and refunds it", async () => {
    const a = await register("Late Ban Lou");
    const crew = await hire(a.token);
    const g = (await api("GET", "/today", undefined, a.token)).body.games[0];
    const op = await api("POST", "/ops", { kind: "laser", gameId: g.id, targetTeamId: g.away.id, crew: [crew], gear: [] }, a.token);
    expect(op.status).toBe(200);
    const paid = op.body.account.money;
    await grudge({ account: "Late Ban Lou", team: g.home.id, level: 2 });
    await advance(1);
    const ops = await api("GET", "/ops", undefined, a.token);
    expect(ops.body.ops[0]).toMatchObject({ status: "cancelled", blocked: expect.stringMatching(/bleachers/) });
    expect(ops.body.ops[0].result).toMatch(/turnstiles/i);
    const me = await api("GET", "/me", undefined, a.token);
    expect(me.body.account.money).toBe(paid + 50); // laser costs $50
    const mail = await api("GET", "/mail", undefined, a.token);
    expect(mail.body.mail.some((m: { subject: string }) => /turned away/.test(m.subject))).toBe(true);
    const crewNow = await api("GET", "/crew", undefined, a.token);
    expect(crewNow.body.crew[0].status).toBe("free");
  });
});
