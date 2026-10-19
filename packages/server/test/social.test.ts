import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { api, register, advance } from "./helpers.ts";

const DB = (env as unknown as { DB: D1Database }).DB;

async function validDraft(token: string, seed = 0) {
  const words = (await api("GET", "/words", undefined, token)).body;
  for (let k = 0; k < words.templates.length; k++) {
    const t = words.templates[(k + seed) % words.templates.length];
    if (t.slots.every((s: string) => words.slots[s]?.length)) return { template: t.id, words: t.slots.map((s: string, i: number) => words.slots[s][(seed + i) % words.slots[s].length]) };
  }
  throw new Error("no usable template");
}

describe("comments", () => {
  it("validates mad-libs, rate limits, reacts and pages threads", async () => {
    const a = await register("Chatty Cathy");
    const b = await register("Grumpy Gus");
    await advance(1);
    const words = await api("GET", "/words", undefined, a.token);
    expect(words.body.templates.length).toBeGreaterThan(0);
    expect(typeof words.body.version).toBe("string");

    const news = await api("GET", "/news", undefined, a.token);
    const thread = `story:${news.body.stories[0].id}`;
    const draft = await validDraft(a.token);
    // validation
    expect((await api("POST", "/comments", { thread, template: draft.template, words: ["definitely not a word"] }, a.token)).body.error).toBe("invalid_comment");
    expect((await api("POST", "/comments", { thread, template: "nope", words: [] }, a.token)).body.error).toBe("invalid_comment");
    expect((await api("POST", "/comments", { thread: "story:nope", ...draft }, a.token)).status).toBe(404);
    expect((await api("POST", "/comments", { thread: "garbage", ...draft }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/comments", { thread: "bbs:syn:someone-else", ...draft }, a.token)).status).toBe(403);

    const c1 = await api("POST", "/comments", { thread, ...draft }, a.token);
    expect(c1.status).toBe(200);
    expect(c1.body.comment).toMatchObject({ author: "Chatty Cathy", text: expect.any(String), reactions: { agree: 0, lol: 0, rat: 0 } });

    // 1 per 20 s
    const again = await api("POST", "/comments", { thread, ...(await validDraft(a.token, 1)) }, a.token);
    expect(again.status).toBe(429);
    expect(again.body.error).toBe("rate_limited");
    // 30 per day
    await DB.prepare("UPDATE accounts SET last_comment_at = 0, comments_today = 30 WHERE id = ?").bind(a.account.id).run();
    expect((await api("POST", "/comments", { thread, ...draft }, a.token)).body.error).toBe("rate_limited");
    // gap elapsed and under the cap: ok again
    await DB.prepare("UPDATE accounts SET last_comment_at = 0, comments_today = 3 WHERE id = ?").bind(a.account.id).run();
    expect((await api("POST", "/comments", { thread, ...(await validDraft(a.token, 2)) }, a.token)).status).toBe(200);

    // reactions: once per kind per account, not on your own
    const r1 = await api("POST", `/comments/${c1.body.comment.id}/react`, { kind: "lol" }, b.token);
    expect(r1.body.comment.reactions.lol).toBe(1);
    const r2 = await api("POST", `/comments/${c1.body.comment.id}/react`, { kind: "lol" }, b.token);
    expect(r2.body.comment.reactions.lol).toBe(1);
    expect((await api("POST", `/comments/${c1.body.comment.id}/react`, { kind: "lol" }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", `/comments/${c1.body.comment.id}/react`, { kind: "meh" }, b.token)).body.error).toBe("bad_request");

    await api("POST", "/comments", { thread, ...(await validDraft(b.token, 3)) }, b.token);
    const page1 = await api("GET", `/threads/${thread}?limit=2`, undefined, a.token);
    expect(page1.body.comments).toHaveLength(2);
    expect(page1.body.next).toBeTruthy();
    const page2 = await api("GET", `/threads/${thread}?limit=2&cursor=${page1.body.next}`, undefined, a.token);
    expect(page2.body.comments).toHaveLength(1);
    const story = await api("GET", `/news/${news.body.stories[0].id}`, undefined, a.token);
    expect(story.body.comments).toHaveLength(3);
  });
});
