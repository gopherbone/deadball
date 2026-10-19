import { describe, expect, it } from "vitest";
import { advance, api, register } from "./helpers.ts";

async function hire(token: string) {
  const cands = (await api("GET", "/crew/candidates", undefined, token)).body.candidates as { id: string; ask: number }[];
  const cheapest = [...cands].sort((x, y) => x.ask - y.ask)[0];
  const r = await api("POST", "/crew/recruit", { candidateId: cheapest.id }, token);
  expect(r.status).toBe(200);
  return r.body.crew[r.body.crew.length - 1].id as string;
}
const money = async (token: string) => (await api("GET", "/me", undefined, token)).body.account.money as number;

async function syndicate(names: [string, string, string], synName: string) {
  const a = await register(names[0]);
  const b = await register(names[1]);
  const c = await register(names[2]);
  await api("POST", "/syndicate", { name: synName }, a.token);
  await api("POST", "/syndicate/invite", { accountName: names[1] }, a.token);
  const inv = (await api("GET", "/syndicate", undefined, b.token)).body.invites[0];
  await api("POST", `/syndicate/invites/${inv.id}/accept`, undefined, b.token);
  return { a, b, c };
}

describe("syndicate chip in", () => {
  it("asks allies for their share; accepting moves it to the orderer; cancelling refunds everybody", async () => {
    const { a, b, c } = await syndicate(["Chip Charlie", "Chip Dolores", "Chip Outsider"], "Split Checks");
    const ca = await hire(a.token), cb = await hire(b.token);
    const g = (await api("GET", "/today", undefined, a.token)).body.games[0];
    const a0 = await money(a.token), b0 = await money(b.token);
    // grease_mound: $40 split two ways
    const op = await api("POST", "/ops", { kind: "grease_mound", gameId: g.id, targetTeamId: g.home.id, crew: [ca, cb], gear: ["vaseline"], chipIn: true }, a.token);
    expect(op.status).toBe(200);
    expect(op.body.account.money).toBe(a0 - 50); // the orderer fronts all of it (job $40 + vaseline $10)
    expect(op.body.op.chipIn).toMatchObject({ total: 50, yours: 50, shares: [{ name: "Chip Dolores", amount: 20, status: "proposed" }] });
    expect(op.body.op.chipIn.line).toMatch(/Chip Dolores asked \$20/);
    const id = op.body.op.id;

    // the ally sees the ask on the syndicate page, as an event card and in the mail
    const syn = await api("GET", "/syndicate", undefined, b.token);
    expect(syn.body.chipIns).toEqual([expect.objectContaining({ opId: id, from: "Chip Charlie", share: 20, total: 50, status: "proposed", job: "Grease the mound" })]);
    const ev = (await api("GET", "/events", undefined, b.token)).body.events.find((e: { id: string }) => e.id === syn.body.chipIns[0].eventId);
    expect(ev.choices.map((x: { key: string }) => x.key)).toEqual(["accept", "decline"]);
    expect((await api("GET", "/mail", undefined, b.token)).body.mail.some((m: { subject: string }) => /^Chip in\?/.test(m.subject))).toBe(true);

    // outsiders can't answer; the orderer has nothing to answer
    expect((await api("POST", `/ops/${id}/chipin`, { accept: true }, c.token)).status).toBe(404);
    expect((await api("POST", `/ops/${id}/chipin`, { accept: true }, a.token)).status).toBe(404);

    const yes = await api("POST", `/ops/${id}/chipin`, { accept: true }, b.token);
    expect(yes.status).toBe(200);
    expect(yes.body.chipIn).toMatchObject({ status: "paid", share: 20 });
    expect(yes.body.account.money).toBe(b0 - 20);
    expect(await money(a.token)).toBe(a0 - 30);
    expect((await api("POST", `/ops/${id}/chipin`, { accept: true }, b.token)).body.error).toBe("bad_request");
    expect((await api("GET", "/syndicate", undefined, b.token)).body.chipIns).toEqual([]);
    const view = (await api("GET", "/ops", undefined, a.token)).body.ops[0];
    expect(view.chipIn).toMatchObject({ yours: 30, shares: [{ status: "paid" }] });
    expect((await api("GET", "/events", undefined, b.token)).body.events.some((e: { id: string }) => e.id === ev.id)).toBe(false);

    // only the orderer can call it off; then everybody gets their money back and the crew is free
    expect((await api("DELETE", `/ops/${id}`, undefined, b.token)).status).toBe(404);
    const off = await api("DELETE", `/ops/${id}`, undefined, a.token);
    expect(off.status).toBe(200);
    expect(off.body.op).toMatchObject({ status: "cancelled", chipIn: { shares: [{ status: "refunded" }] } });
    expect(off.body.account.money).toBe(a0);
    expect(await money(b.token)).toBe(b0);
    expect((await api("DELETE", `/ops/${id}`, undefined, a.token)).body.error).toBe("bad_request");
    expect((await api("GET", "/crew", undefined, a.token)).body.crew[0].status).toBe("free");
    expect((await api("GET", "/mail", undefined, b.token)).body.mail.some((m: { subject: string }) => m.subject === "Refund: $20")).toBe(true);
  });

  it("declining (via the event card) leaves the orderer paying; unanswered asks lapse at first pitch", async () => {
    const { a, b } = await syndicate(["Chip Ed", "Chip Flo", "Chip Nobody"], "Dutch Treat");
    const ca1 = await hire(a.token), cb1 = await hire(b.token);
    const ca2 = await hire(a.token), cb2 = await hire(b.token);
    const games = (await api("GET", "/today", undefined, a.token)).body.games;
    const b0 = await money(b.token);
    const one = await api("POST", "/ops", { kind: "grease_mound", gameId: games[0].id, targetTeamId: games[0].home.id, crew: [ca1, cb1], gear: [], chipIn: true }, a.token);
    const two = await api("POST", "/ops", { kind: "sprinklers", gameId: games[1].id, targetTeamId: games[1].home.id, crew: [ca2, cb2], gear: [], chipIn: true }, a.token);
    // one ally on the job: one ask
    expect(one.body.op.chipIn.shares).toHaveLength(1);
    const card = (await api("GET", "/events", undefined, b.token)).body.events.find((e: { id: string }) => e.id === `ev-chip-${one.body.op.id}-${b.account.id}`);
    const no = await api("POST", `/events/${card.id}/choose`, { key: "decline" }, b.token);
    expect(no.status).toBe(200);
    expect(no.body.result).toMatch(/Chip Ed pays/);
    expect(await money(b.token)).toBe(b0);
    expect((await api("GET", "/mail", undefined, a.token)).body.mail.some((m: { subject: string }) => m.subject === "Chip Flo won't chip in")).toBe(true);

    await advance(1);
    const ops = (await api("GET", "/ops", undefined, a.token)).body.ops as { id: string; chipIn: { shares: { status: string }[] } }[];
    expect(ops.find(o => o.id === one.body.op.id)!.chipIn.shares[0].status).toBe("declined");
    expect(ops.find(o => o.id === two.body.op.id)!.chipIn.shares[0].status).toBe("expired");
    expect((await api("POST", `/ops/${two.body.op.id}/chipin`, { accept: true }, b.token)).body.error).toBe("bad_request");
  });
});
