// Worker entry: every /v1 request goes to the single League Durable Object, which owns
// the world and serves the API. The cron trigger just makes sure the DO is awake and
// its alarm is armed. Every /v1 request first passes the build gate (version.ts).

import type { Env } from "./http.ts";
import { buildGate } from "./version.ts";
export { League } from "./league.ts";

const leagueStub = (env: Env) => env.LEAGUE.get(env.LEAGUE.idFromName("league"));

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type, x-admin-token, x-build", "access-control-allow-methods": "GET, POST, DELETE" } });
    if (!url.pathname.startsWith("/v1")) return new Response("DEADBALL league server. See /v1/clock.\n", { status: 200 });
    // old builds stop here (426), before the League wakes up; GET /v1/version answers here too
    const gate = buildGate(req, url, env);
    if (gate) return gate;
    return leagueStub(env).fetch(req);
  },
  async scheduled(_c: ScheduledController, env: Env): Promise<void> {
    await leagueStub(env).fetch("https://league/v1/clock");
  },
} satisfies ExportedHandler<Env>;
