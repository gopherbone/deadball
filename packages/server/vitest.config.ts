import { defineConfig } from "vitest/config";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: { TEST_MIGRATIONS: migrations, ADMIN_TOKEN: "test-admin", GAME_DAY_MS: "600000", WORLD_SEED: "test-world", BATCH_MAX_BYTES: "65536" },
        },
      }),
    ],
    test: { setupFiles: ["./test/setup.ts"], testTimeout: 60_000, hookTimeout: 60_000 },
  };
});
