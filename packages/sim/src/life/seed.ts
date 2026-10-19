// Seeds a fresh world with history: retired stars (and their houses), the sons, nephews and
// sons-in-law they have in the league today, wives, children, and the staff's households.

import type { Rng } from "../rng.ts";
import { OCCUPATIONS, SPOUSE_JOBS } from "../names.ts";
import type { Npc, Person, Player, Pos, World } from "../types.ts";
import {
  archivePerson, createNpc, ensureHouse, linkChild, makeChild, makeSpouse, marry,
} from "./people.ts";

const STAR_COUNT = 26;

export function seedFamilies(world: World, rng: Rng, usedNames: Set<string>) {
  const year = world.year;
  const mlIds = Object.values(world.teams).filter(t => t.level === "ML").map(t => t.id);
  const players = Object.values(world.players);
  const taken = new Set<string>(); // players already given a parent / wife here

  /** Turn a current player into someone's son: surname, house, parents. */
  const adoptAsSon = (pl: Player, father: Person, mother: Person | undefined): boolean => {
    if (pl.last !== father.last) {
      if (usedNames.has(pl.first + father.last)) return false;
      usedNames.add(pl.first + father.last);
      pl.last = father.last;
    }
    world.houses[pl.family.house] && world.houses[pl.family.house].players--;
    if (world.houses[pl.family.house]?.players === 0) delete world.houses[pl.family.house];
    pl.family.house = father.family.house;
    const h = ensureHouse(world, father.family.house, father);
    h.players++;
    linkChild(father, pl);
    if (mother) linkChild(mother, pl);
    pl.talent = Math.round((pl.potential * 2 + (father.talent ?? 50)) / 3);
    taken.add(pl.id);
    return true;
  };

  const findPlayer = (minAge: number, maxAge: number, pred: (p: Player) => boolean = () => true) => {
    const c = players.filter(p => !taken.has(p.id) && p.age >= minAge && p.age <= maxAge && p.family.parents.length === 0 && pred(p));
    return c.length ? rng.pick(c) : undefined;
  };

  // --- retired stars ---------------------------------------------------------------------
  const stars: Npc[] = [];
  for (let i = 0; i < STAR_COUNT; i++) {
    const age = 46 + rng.int(32);
    const star = createNpc(world, rng, { sex: "M", age, traits: 2 });
    const pitcher = rng.chance(0.4);
    const pos: Pos = pitcher ? "P" : rng.pick(["C", "1B", "2B", "SS", "3B", "LF", "CF", "RF"] as Pos[]);
    const seasons = 9 + rng.int(10);
    const from = year - age + 21 + rng.int(3);
    const to = Math.min(from + seasons - 1, year - 2, year - age + 41);
    const peak = 60 + rng.int(17);
    const honors: string[] = [];
    if (peak >= 68) honors.push(`${pitcher ? "Pitcher of the Year" : "MVP"} ${from + rng.int(Math.max(1, to - from))}`);
    if (rng.chance(0.5)) honors.push(`${1 + rng.int(3)}x champion`);
    if (peak >= 72 && rng.chance(0.5)) honors.push(pitcher ? `${250 + rng.int(80)} career wins` : `${380 + rng.int(200)} career home runs`);
    star.career = {
      pos, from, to, mlGames: Math.round((to - from + 1) * (pitcher ? 34 : 135) * rng.range(0.85, 1.05)), mlSeasons: to - from + 1,
      teams: rng.shuffle([...mlIds]).slice(0, 1 + rng.int(3)), peak, honors,
    };
    star.talent = peak - rng.int(5);
    star.occupation = star.traits.includes("DRUNK") ? "town drunk" : rng.pick(OCCUPATIONS);
    const house = ensureHouse(world, star.family.house, star);
    house.reputation = Math.round(12 + (peak - 58) * 2.5 + rng.int(10));
    house.players = 1;
    house.titles = honors.some(h => h.includes("champion")) ? 1 : 0;
    house.founded = from;
    stars.push(star);

    // the old man who started it all (long dead) and maybe a brother
    let brother: Npc | undefined;
    if (rng.chance(0.55)) {
      const founder = createNpc(world, rng, { sex: "M", age: age + 26 + rng.int(8), last: star.last, house: star.family.house, talent: star.talent - 6 });
      linkChild(founder, star);
      if (rng.chance(0.6)) {
        const bAge = Math.max(30, age + rng.int(13) - 6);
        brother = createNpc(world, rng, { sex: "M", age: bAge, last: star.last, house: star.family.house, occupation: rng.pick(OCCUPATIONS), talent: star.talent - 10 });
        linkChild(founder, brother);
      }
      house.founderId = founder.id;
      archivePerson(world, founder.id, "dead");
    }

    // wife (sometimes late)
    const wife = makeSpouse(world, rng, star, rng.pick(SPOUSE_JOBS));
    // children: sons in the league if we can find them, daughters married to players, other kids
    const nKids = 1 + rng.int(4);
    for (let k = 0; k < nKids; k++) {
      const kidAge = Math.max(0, wife.age - 21 - rng.int(18));
      const wantSon = rng.chance(0.55);
      if (wantSon && k === 0 || (wantSon && rng.chance(0.4))) {
        const pl = findPlayer(Math.max(17, kidAge - 6), kidAge + 6);
        if (pl && adoptAsSon(pl, star, wife)) continue;
      }
      const kid = makeChild(world, rng, star, wife, kidAge, wantSon ? "M" : "F");
      if (kid.sex === "F" && kid.age >= 20 && rng.chance(0.45)) {
        const husband = findPlayer(kid.age - 4, kid.age + 8, p => !p.family.spouse);
        if (husband) { marry(world, husband, kid); taken.add(husband.id); kid.occupation = rng.pick(SPOUSE_JOBS); continue; }
      }
      if (kid.age >= 24) seedHousehold(world, rng, kid, 0.6);
    }
    if (age > 66 && rng.chance(0.5)) archivePerson(world, wife.id, "dead");

    // a nephew in the league
    if (brother && rng.chance(0.7)) {
      const pl = findPlayer(Math.max(17, brother.age - 42), brother.age - 20);
      if (pl) {
        const sil = makeSpouse(world, rng, brother, rng.pick(SPOUSE_JOBS));
        adoptAsSon(pl, brother, sil);
      }
    }
    if (brother && brother.age > 70 && rng.chance(0.6)) archivePerson(world, brother.id, "dead");
  }

  // a few retired stars run clubs now
  const mlTeams = Object.values(world.teams).filter(t => t.level === "ML");
  for (const t of rng.shuffle([...mlTeams]).slice(0, 4)) {
    const star = stars.find(s => s.role === "citizen" && s.age < 68 && !s.traits.includes("DRUNK"));
    if (!star) break;
    const old = world.npcs[t.managerId];
    if (old) { old.role = "coach"; }
    star.role = "manager";
    star.factionId = t.factionId;
    star.occupation = undefined;
    t.managerId = star.id;
  }
  for (const star of stars) {
    if (star.role !== "citizen") continue;
    if (rng.chance(0.25)) { star.role = rng.chance(0.5) ? "coach" : "scout"; star.factionId = rng.pick(mlTeams).factionId; star.occupation = undefined; }
  }

  // --- players' households ------------------------------------------------------------------
  for (const pl of players) {
    if (!pl.family.spouse) {
      const p = Math.max(0, Math.min(0.8, (pl.age - 21) * 0.075));
      if (rng.chance(p)) makeSpouse(world, rng, pl, rng.pick(SPOUSE_JOBS));
    }
    const wife = pl.family.spouse ? world.npcs[pl.family.spouse] : undefined;
    if (wife) addKids(world, rng, pl, wife, Math.max(0, pl.age - 23));
    // some players' parents are still around (and fall ill, and worry)
    if (pl.family.parents.length === 0 && rng.chance(0.3)) {
      const pa = createNpc(world, rng, { sex: "M", age: pl.age + 24 + rng.int(12), last: pl.last, house: pl.family.house, occupation: rng.pick(OCCUPATIONS) });
      const ma = makeSpouse(world, rng, pa, rng.pick(SPOUSE_JOBS));
      linkChild(pa, pl); linkChild(ma, pl);
      if (pa.age > 62 && rng.chance(0.4)) archivePerson(world, pa.id, "dead");
    }
  }

  // --- staff households (owners have heirs) ---------------------------------------------------
  for (const n of Object.values(world.npcs)) {
    if (n.role === "citizen" || n.career || n.family.spouse) continue;
    seedHousehold(world, rng, n, n.role === "owner" ? 0.9 : 0.7);
  }
}

function seedHousehold(world: World, rng: Rng, p: Npc, marriedP: number) {
  if (p.family.spouse || !rng.chance(marriedP)) return;
  const sp = makeSpouse(world, rng, p, rng.pick(SPOUSE_JOBS));
  const father = p.sex === "M" ? p : sp, mother = p.sex === "M" ? sp : p;
  addKids(world, rng, father, mother, Math.max(0, Math.min(mother.age - 20, p.age - 23)));
}

function addKids(world: World, rng: Rng, father: Person, mother: Person, yearsMarried: number) {
  let n = father.family.children.filter(id => mother.family.children.includes(id)).length;
  for (let y = 0; y < yearsMarried && n < 4; y++) {
    if (!rng.chance(0.17)) continue;
    const age = y;
    if (mother.age - age < 18) continue;
    makeChild(world, rng, father, mother, age);
    n++;
  }
}

