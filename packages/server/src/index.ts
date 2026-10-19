// Worker entry: every /v1 request goes to the single League Durable Object, which owns
// the world and serves the API. The cron trigger just makes sure the DO is awake and
// its alarm is armed.

import type { Env } from "./http.ts";
export { League } from "./league.ts";

const leagueStub = (env: Env) => env.LEAGUE.get(env.LEAGUE.idFromName("league"));

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type, x-admin-token", "access-control-allow-methods": "GET, POST, DELETE" } });
    if (!url.pathname.startsWith("/v1")) return new Response("DEADBALL league server. See /v1/clock.\n", { status: 200 });
    return leagueStub(env).fetch(req);
  },
  async scheduled(_c: ScheduledController, env: Env): Promise<void> {
    await leagueStub(env).fetch("https://league/v1/clock");
  },
} satisfies ExportedHandler<Env>;
