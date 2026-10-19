import { describe, expect, it } from "vitest";
import { withRelativeTimes } from "../src/http.ts";
import { api, register } from "./helpers.ts";

describe("relative timestamps for the Playdate", () => {
  it("adds fooIn / ago next to epoch-ms fields, recursively, without clobbering", () => {
    const now = 1_800_000_000_000;
    const out = withRelativeTimes({ endsAt: now + 90_000, at: now - 5_000, day: 3, list: [{ firstPitchAt: now - 1_000 }], endsIn: 7 }, now) as Record<string, any>;
    expect(out.ago).toBe(5);
    expect(out.endsIn).toBe(7); // existing field kept
    expect(out.list[0].firstPitchIn).toBe(-1);
    expect(out.day).toBe(3);
  });
  it("is applied to real responses", async () => {
    const a = await register("Clock Watcher");
    const clock = await api("GET", "/clock", undefined, a.token);
    expect(typeof clock.body.nextDayIn).toBe("number");
    expect(Math.abs(clock.body.nextDayIn)).toBeLessThan(10 * 24 * 3600);
  });
});
