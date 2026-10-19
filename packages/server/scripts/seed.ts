// npm run seed -w @deadball/server [days]
//
// Prepares the local dev state used by `npm run dev` (.wrangler/state): applies D1
// migrations, resets the world, plays a few days and creates demo accounts. Prints their
// tokens so you can curl the dev server.

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, startLocal } from "./local.ts";

const days = Number(process.argv[2] ?? 3);
const L = await startLocal({ persistTo: ".wrangler/state" });
try {
  await L.ok("POST", "/admin/reset", { seed: "deadball-dev" }, undefined, true);
  await L.ok("POST", "/admin/advance", { days }, undefined, true);
  const tokens: Record<string, string> = {};
  for (const name of ["Lefty Loot", "Dotty Dial", "Gus Gumshoe"]) {
    const r = await L.ok("POST", "/register", { name });
    tokens[name] = r.token;
    await L.ok("POST", "/packs/buy", { kind: "starter" }, r.token);
  }
  writeFileSync(join(ROOT, ".wrangler", "dev-tokens.json"), JSON.stringify(tokens, null, 2));
  console.log(`seeded: ${days} days played. tokens (also in .wrangler/dev-tokens.json):`);
  for (const [n, t] of Object.entries(tokens)) console.log(`  ${n}: ${t}`);
  console.log(`admin token: dev-admin-token (header x-admin-token)`);
} finally {
  await L.stop();
}
