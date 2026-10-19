import { describe, expect, it } from "vitest";
import { exports } from "cloudflare:workers";
import { hmacHex, signingString, SEQ_WINDOW } from "../src/auth.ts";
import { api, clientHeaders, register } from "./helpers.ts";

const fetchW = (r: Request) => (exports as any).default.fetch(r) as Promise<Response>;

async function sha256hex(s: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d), x => x.toString(16).padStart(2, "0")).join("");
}

/** A request signed the way the Playdate signs it, over plain HTTP by default. */
async function signed(method: string, target: string, acct: { id: string; key: string }, seq: number, body?: unknown, opts: { scheme?: string; sig?: string } = {}) {
  const text = body === undefined ? "" : JSON.stringify(body);
  const full = "/v1" + target;
  const sig = opts.sig ?? await hmacHex(acct.key, `${method}\n${full}\n${seq}\n${await sha256hex(text)}`);
  const res = await fetchW(new Request(`${opts.scheme ?? "http"}://deadball.test${full}`, {
    method, body: text || undefined,
    headers: clientHeaders({ "content-type": "application/json", "x-acct": acct.id, "x-seq": String(seq), "x-sig": sig }),
  }));
  const t = await res.text();
  return { status: res.status, body: t ? JSON.parse(t) : undefined };
}

async function newAcct(name: string) {
  const r = await register(name) as any;
  expect(r.key).toMatch(/^[0-9a-f]{64}$/);
  return { token: r.token as string, id: r.account.id as string, key: r.key as string };
}

describe("signed plain-HTTP requests", () => {
  it("the signing string matches the documented format", async () => {
    expect(await signingString("GET", "/v1/me", 7, "")).toBe("GET\n/v1/me\n7\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    // RFC 4231 test case 2 (the C/Lua implementations are checked against the same vectors)
    expect(await hmacHex("Jefe", "what do ya want for nothing?")).toBe("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
  });

  it("accepts a valid signature over HTTP for GETs and POSTs", async () => {
    const a = await newAcct("Signer One");
    const me = await signed("GET", "/me", a, 1);
    expect(me.status).toBe(200);
    expect(me.body.account.name).toBe("Signer One");
    const today = (await signed("GET", "/today", a, 2)).body;
    const g = today.games.find((x: any) => x.status === "scheduled");
    const bet = await signed("POST", "/bets", a, 3, { gameId: g.id, side: "home", amount: 10 });
    expect(bet.status).toBe(200);
    // the body is covered: same seq+sig with a different amount is rejected
    const sig = await hmacHex(a.key, `POST\n/v1/bets\n4\n${await sha256hex(JSON.stringify({ gameId: g.id, side: "home", amount: 10 }))}`);
    const tampered = await signed("POST", "/bets", a, 4, { gameId: g.id, side: "home", amount: 500 }, { sig });
    expect(tampered.status).toBe(401);
    expect(tampered.body.error).toBe("bad_signature");
  });

  it("rejects bad signatures, wrong keys, unknown accounts and a tampered query", async () => {
    const a = await newAcct("Signer Two");
    expect((await signed("GET", "/me", { ...a, key: "0".repeat(64) }, 1)).body.error).toBe("bad_signature");
    expect((await signed("GET", "/me", { ...a, id: "anobody" }, 1)).body.error).toBe("bad_signature");
    const sig = await hmacHex(a.key, `GET\n/v1/bets?status=open\n5\n${await sha256hex("")}`);
    const r = await signed("GET", "/bets?status=settled", a, 5, undefined, { sig });
    expect(r.status).toBe(401);
    expect(r.body.error).toBe("bad_signature");
    expect((await signed("GET", "/me", a, 0)).body.error).toBe("bad_signature"); // seq must be >= 1
  });

  it("rejects replays but allows out-of-order seqs inside the window", async () => {
    const a = await newAcct("Signer Three");
    expect((await signed("GET", "/me", a, 10)).status).toBe(200);
    const again = await signed("GET", "/me", a, 10);
    expect(again.status).toBe(401);
    expect(again.body.error).toBe("replayed");
    expect((await signed("GET", "/me", a, 12)).status).toBe(200);
    expect((await signed("GET", "/me", a, 11)).status).toBe(200);   // late but unseen
    expect((await signed("GET", "/me", a, 11)).body.error).toBe("replayed");
    expect((await signed("GET", "/me", a, 12 + SEQ_WINDOW + 5)).status).toBe(200);
    expect((await signed("GET", "/me", a, 13)).body.error).toBe("replayed"); // fell out of the window
    // a bad signature doesn't burn the seq
    await signed("GET", "/me", a, 500, undefined, { sig: "f".repeat(64) });
    expect((await signed("GET", "/me", a, 500)).status).toBe(200);
  });

  it("never accepts a bearer token over plain HTTP (URL scheme or CF-Visitor)", async () => {
    const a = await newAcct("Bearer Plain");
    const viaHttp = await fetchW(new Request("http://deadball.test/v1/me", { headers: clientHeaders({ authorization: `Bearer ${a.token}` }) }));
    expect(viaHttp.status).toBe(403);
    expect((await viaHttp.json() as any).error).toBe("https_required");
    const viaVisitor = await fetchW(new Request("https://deadball.test/v1/me", { headers: clientHeaders({ authorization: `Bearer ${a.token}`, "cf-visitor": '{"scheme":"http"}' }) }));
    expect(viaVisitor.status).toBe(403);
    // HTTPS is fine, and public paths still work over HTTP unauthenticated
    expect((await api("GET", "/me", undefined, a.token)).status).toBe(200);
    expect((await fetchW(new Request("http://deadball.test/v1/clock", { headers: clientHeaders() }))).status).toBe(200);
    // registration and key issue are HTTPS-only
    const reg = await fetchW(new Request("http://deadball.test/v1/register", { method: "POST", headers: clientHeaders(), body: JSON.stringify({ name: "Plain Joe" }) }));
    expect(reg.status).toBe(403);
  });

  it("issues and rotates keys over HTTPS with the bearer token only", async () => {
    const a = await newAcct("Key Rotator");
    expect((await signed("GET", "/me", a, 100)).status).toBe(200);
    const k = await api("POST", "/auth/key", {}, a.token);
    expect(k.status).toBe(200);
    expect(k.body.accountId).toBe(a.id);
    expect(k.body.key).toMatch(/^[0-9a-f]{64}$/);
    expect(k.body.key).not.toBe(a.key);
    // old key dead, new key works, and the replay window restarted (seq 1 is fine again)
    expect((await signed("GET", "/me", a, 101)).body.error).toBe("bad_signature");
    expect((await signed("GET", "/me", { ...a, key: k.body.key }, 1)).status).toBe(200);
    // a signed request can't mint keys; neither can plain HTTP or no auth
    const bySig = await signed("POST", "/auth/key", { ...a, key: k.body.key }, 2, {}, { scheme: "https" });
    expect(bySig.status).toBe(401);
    expect((await api("POST", "/auth/key", {})).status).toBe(401);
    const plain = await fetchW(new Request("http://deadball.test/v1/auth/key", { method: "POST", headers: clientHeaders({ authorization: `Bearer ${a.token}` }) }));
    expect(plain.status).toBe(403);
  });

  it("signs a batch as one request: one seq, items run as that account", async () => {
    const a = await newAcct("Batch Signer");
    const target = "/batch?p=" + encodeURIComponent("/me") + "&p=" + encodeURIComponent("/bets?status=open") + "&p=%2Fclock";
    const b = await signed("GET", target, a, 7);
    expect(b.status).toBe(200);
    expect(b.body.results["/me"].body.account.name).toBe("Batch Signer");
    expect(b.body.results["/bets?status=open"].status).toBe(200);
    expect(b.body.results["/clock"].status).toBe(200);
    // replaying the batch fails as a whole
    const again = await signed("GET", target, a, 7);
    expect(again.status).toBe(401);
    expect(again.body.error).toBe("replayed");
    // a bad batch signature fails as a whole too
    expect((await signed("GET", target, a, 8, undefined, { sig: "0".repeat(64) })).status).toBe(401);
    // POST batches cover the body
    const pb = await signed("POST", "/batch", a, 9, ["/me"]);
    expect(pb.body.results["/me"].status).toBe(200);
  });
});
