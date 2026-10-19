import { describe, expect, it } from "vitest";
import { encodeLogC } from "../src/routes/games.ts";

describe("compact replay log (?fmt=c)", () => {
  it("encodes one event per line, typed values, escapes ambiguous strings", () => {
    const s = encodeLogC([
      { k: "p", t: "FB", v: 93, z: 3, r: "B", b: 1, s: 0 },
      { k: "bip", ev: 38, la: -29, res: "1B", path: [0, 0, 3, 6, 13, 9] },
      { k: "inc", kind: "BRAWL", who: "p107,p19", note: "tab\there" },
      { k: "sb", id: "p3", base: 2, ok: true },
      { k: "half", inn: 1, top: false, x: "12", y: "", w: { a: 1 } },
      { k: "bip", ev: 0, la: 0, sp: 0, res: "OUT", f: "C", out: "GO", bunt: true, bk: "sq" },
    ]);
    expect(s.split("\n")).toEqual([
      "p\tt=FB\tv=93\tz=3\tr=B\tb=1\ts=0",
      "bip\tev=38\tla=-29\tres='1B\tpath=#0,0,3,6,13,9",
      "inc\tkind=BRAWL\twho=p107,p19\tnote=tab here",
      "sb\tid=p3\tbase=2\tok=!1",
      "half\tinn=1\ttop=!0\tx='12\ty='\tw=@{\"a\":1}",
      "bip\tev=0\tla=0\tsp=0\tres=OUT\tf=C\tout=GO\tbunt=!1\tbk=sq",
    ]);
  });
});
