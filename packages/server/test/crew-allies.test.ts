import { describe, expect, it } from "vitest";
import { api, register } from "./helpers.ts";

describe("GET /crew allies", () => {
  it("lists syndicate allies' free crew with their owner, and nothing for loners", async () => {
    const a = await register("Allies Anne");
    const b = await register("Allies Bob");
    expect((await api("GET", "/crew", undefined, a.token)).body.allies).toBeUndefined();

    await api("POST", "/syndicate", { name: "Hot Dog Ring" }, a.token);
    await api("POST", "/syndicate/invite", { accountName: "Allies Bob" }, a.token);
    const evs = await api("GET", "/events", undefined, b.token);
    const card = evs.body.events.find((e: { choices: { key: string }[] }) => e.choices.some(ch => ch.key === "accept"));
    await api("POST", `/events/${card.id}/choose`, { key: "accept" }, b.token);

    const cands = (await api("GET", "/crew/candidates", undefined, b.token)).body.candidates as { id: string; ask: number }[];
    const cheapest = [...cands].sort((x, y) => x.ask - y.ask)[0];
    expect((await api("POST", "/crew/recruit", { candidateId: cheapest.id }, b.token)).status).toBe(200);

    const mine = await api("GET", "/crew", undefined, a.token);
    expect(mine.status).toBe(200);
    expect(mine.body.allies).toHaveLength(1);
    expect(mine.body.allies[0]).toMatchObject({ owner: "Allies Bob", status: expect.any(String) });
    expect(mine.body.crew).toHaveLength(0);
  });
});
