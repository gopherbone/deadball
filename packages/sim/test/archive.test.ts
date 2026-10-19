import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  ARCHIVE, ARCHIVE_SIZES, INCIDENT_TAGS, LIFE_TAGS, OP_TAGS, RECAP_TAGS, TEAM_TAGS, TROUBLE_TAGS, MAIL_TAGS,
  archiveItem, archivePath, illustrate, lifeTags, pickArchive,
} from "../src/archive.ts";
import { INCIDENTS } from "../src/incidents.ts";
import { OP_KINDS } from "../src/crime/ops.ts";
import { generateWorld } from "../src/worldgen.ts";
import { simulateGame, type GameSpec } from "../src/game.ts";
import { writeGameStories, writeLifeStories, writeScandalStory } from "../src/news/index.ts";
import { cardPhoto, mailPhoto } from "../src/crime/photos.ts";
import { heatCard } from "../src/crime/events.ts";

const IMG = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "playdate", "source", "images", "archive");

test("catalog: size, unique ids, complete records", () => {
  assert.ok(ARCHIVE.length >= 250, `only ${ARCHIVE.length} items`);
  const ids = new Set<string>();
  for (const a of ARCHIVE) {
    assert.match(a.id, /^[a-z0-9-]+$/);
    assert.ok(!ids.has(a.id), `duplicate ${a.id}`);
    ids.add(a.id);
    assert.ok(a.tags.length > 0 && a.caption && a.credit && a.license, a.id);
    assert.match(a.source, /^https:\/\//);
    assert.ok(!/-nc|-nd|sa\b|share/i.test(a.license), `${a.id}: ${a.license}`);
  }
});

test("catalog: image files on disk match the catalog", () => {
  if (!existsSync(IMG)) return; // images are built by tools/assets/archive/build.py
  for (const a of ARCHIVE) for (const w of ARCHIVE_SIZES) {
    if (w === 400 && !a.full) assert.ok(!existsSync(join(IMG, `${a.id}-400.png`)), `${a.id}-400.png should not exist`);
    else assert.ok(existsSync(join(IMG, `${a.id}-${w}.png`)), `${a.id}-${w}.png`);
  }
  assert.ok(ARCHIVE.filter(a => a.full).length >= 150);
  const f = pickArchive(["raccoon"], "x", [], { full: true });
  assert.ok(f && archiveItem(f)!.full);
  assert.equal(archivePath("raccoon-01", 96), "images/archive/raccoon-01-96");
});

test("pickArchive: deterministic, best overlap, exclude", () => {
  const a = pickArchive(["raccoon", "animal"], "seed-1");
  assert.ok(a);
  assert.equal(pickArchive(["raccoon", "animal"], "seed-1"), a);
  assert.ok(archiveItem(a)!.tags.includes("raccoon"));
  const seen = new Set<string>();
  for (let i = 0; i < 40; i++) seen.add(pickArchive(["raccoon"], `s${i}`)!);
  assert.ok(seen.size > 1, "seed should vary the choice");
  const b = pickArchive(["raccoon", "animal"], "seed-1", [a!]);
  assert.ok(b && b !== a);
  assert.equal(pickArchive([], "x"), undefined);
  assert.equal(pickArchive(["no-such-tag-anywhere"], "x"), undefined);
  // more overlap beats less
  const m = pickArchive(["baseball", "slide", "action"], "z")!;
  const best = Math.max(...ARCHIVE.map(x => ["baseball", "slide", "action"].filter(t => x.tags.includes(t)).length));
  assert.equal(["baseball", "slide", "action"].filter(t => archiveItem(m)!.tags.includes(t)).length, best);
});

test("coverage: incidents, ops, life events, world events, cities, recaps, trouble, mail", () => {
  for (const k of Object.keys(INCIDENTS)) assert.ok(pickArchive(INCIDENT_TAGS[k as keyof typeof INCIDENT_TAGS], k), `incident ${k}`);
  for (const k of OP_KINDS) assert.ok(OP_TAGS[k.kind] && pickArchive(OP_TAGS[k.kind], k.kind), `op ${k.kind}`);
  for (const [k, tags] of Object.entries({ ...LIFE_TAGS, ...TEAM_TAGS, ...RECAP_TAGS, ...TROUBLE_TAGS, ...MAIL_TAGS })) {
    // the first (most specific) tag must exist in the catalog
    assert.ok(ARCHIVE.some(a => a.tags.includes(tags[0])), `${k}: nothing tagged ${tags[0]}`);
  }
  assert.deepEqual(lifeTags("world", "heatwave"), LIFE_TAGS["world:heatwave"]);
  assert.deepEqual(lifeTags("drama", "debt"), LIFE_TAGS["drama:debt"]);
});

test("integration: stories, cards and mail carry archive photos", () => {
  const w = generateWorld("archive");
  const umps = Object.values(w.npcs).filter(n => n.role === "umpire");
  const game: GameSpec = { id: "g1", day: 3, homeId: "HCL", awayId: "STA", umpireId: umps[0].id, weather: { tempF: 70, windDir: 0, windMph: 5, rain: 0 }, modifiers: [] };
  const res = simulateGame(w, game, "arch");
  const stories = writeGameStories(w, res, game);
  assert.ok(stories[0].photo && archiveItem(stories[0].photo), "recap photo");
  assert.equal(writeGameStories(w, res, game)[0].photo, stories[0].photo, "deterministic");
  const life = writeLifeStories(w, [
    { id: "e1", day: 3, kind: "world", who: [], teams: ["MIL"], data: { sub: "strike", title: "Steel strike", text: "Steelworkers walk out" } },
  ]);
  if (life[0]) assert.ok(archiveItem(life[0].photo)?.tags.some(t => ["strike", "labor", "protest"].includes(t)));
  const crewNpc = Object.values(w.npcs)[0];
  const sc = writeScandalStory(w, { kind: "exposed", day: 3, opKind: "raccoons", people: [crewNpc.id], targetTeamId: "HCL", gameId: "g1" });
  if (sc) assert.ok(archiveItem(sc.photo)?.tags.includes("raccoon"), "scandal photo matches the op");
  const card = cardPhoto(heatCard(w, "acct", 6, "x"));
  assert.ok(archiveItem(card.photo), "card photo");
  const m = mailPhoto({ id: "m1", ownerId: "a", from: "x", subject: "s", body: [], day: 1, kind: "op" }, "bribe_ump");
  assert.ok(archiveItem(m.photo)?.tags.some(t => ["bribe", "cash", "envelope", "money"].includes(t)));
  assert.equal(illustrate(["raccoon"], "k").photo, illustrate(["raccoon"], "k").photo);
});
