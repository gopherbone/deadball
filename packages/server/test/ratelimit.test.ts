import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const reg = async (name: string, ip?: string) => {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (ip) headers["cf-connecting-ip"] = ip;
  const res = await (exports as any).default.fetch(new Request("https://deadball.test/v1/register", { method: "POST", headers, body: JSON.stringify({ name }) }));
  return { status: res.status, retry: res.headers.get("retry-after"), body: (await res.json()) as { error?: string; message?: string } };
};

describe("POST /register rate limit", () => {
  it("allows 5 attempts per IP per hour, counts bad names too, and keeps other IPs separate", async () => {
    for (let i = 0; i < 4; i++) expect((await reg(`Limit Larry ${"ABCD"[i]}`, "203.0.113.7")).status).toBe(200);
    expect((await reg("x", "203.0.113.7")).body.error).toBe("name_rejected"); // the 5th attempt, wasted
    const sixth = await reg("Limit Larry E", "203.0.113.7");
    expect(sixth.status).toBe(429);
    expect(sixth.body.error).toBe("rate_limited");
    expect(Number(sixth.retry)).toBeGreaterThan(0);
    expect(Number(sixth.retry)).toBeLessThanOrEqual(3600);
    expect((await reg("Limit Larry F", "198.51.100.2")).status).toBe(200);
    // no client IP (local scripts, tests): not limited here
    expect((await reg("Limit Larry G")).status).toBe(200);
  });
});
