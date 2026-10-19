import { describe, expect, it } from "vitest";
import { parseBody } from "../src/http.ts";

describe("request bodies", () => {
  it("treats the Playdate's empty-table encoding ([]) as no fields", () => {
    expect(parseBody("[]")).toEqual({});
    expect(parseBody("")).toEqual({});
    expect(parseBody('{"a":1}')).toEqual({ a: 1 });
    expect(() => parseBody("[1]")).toThrow();
  });
});
