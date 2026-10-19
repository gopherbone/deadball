// What a finished game does to people: form and fame, hurt friends turning on the club that hurt
// them, retaliation beanballs, brawls, point-shaving tallies, slumps, rookie and comeback arcs.

import { Rng } from "../rng.ts";
import type { GameResult } from "../game.ts";
import type { Level, Player, World } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { baseballKin, hasT, living, relation, relsOf, setRelation, shiftRelation, shortName } from "./people.ts";
import { addConcern, fameOf, gainFame, goalOf, achieveGoal } from "./inner.ts";
import { fight, findOpen, involving, nudgeStoryline, openStorylines, resolveStoryline, startStoryline } from "./storylines.ts";
import { shavesGame } from "./context.ts";
import { poweredInPublic } from "./enhanced.ts";

export interface GameInfo { id: string; level: Level; homeId: string; awayId: string; series?: string; exhibition?: boolean }

const orgOf = (w: World, teamId: string) => w.teams[teamId]?.parentId ?? teamId;

/** Called by recordResult for every game. Events go out with the next day rollover. */
export function lifeAfterGame(world: World, game: GameInfo, res: GameResult, events: LifeEvent[]) {
  const rng = new Rng(`life:${game.id}`);
  const ml = game.level === "ML";
  const fameMult = ml ? (game.series ? 2 : game.exhibition ? 1.5 : 1) : game.level === "EL" ? 0.5 : 0.15;

  // powers used in a Continental (or exhibition) game: everybody saw it
  if (game.level !== "EL") {
    for (const ev of res.log) {
      const u = ev as { k: string; who?: string };
      if (u.k === "ultra" && u.who) {
        const p = world.players[u.who];
        if (p && world.teams[p.teamId]?.level !== "EL") poweredInPublic(world, u.who);
      }
    }
  }

  // who hit whom
  const hbps: { bat: string; pit: string }[] = [];
  let pa: { bat: string; pit: string } | undefined;
  for (const ev of res.log) {
    if (ev.k === "pa") pa = { bat: ev.bat, pit: ev.pit };
    else if (ev.k === "p" && ev.r === "H" && pa) hbps.push(pa);
  }

  // form and fame
  for (const box of [res.home, res.away]) {
    for (const l of box.bat) {
      const p = world.players[l.id];
      if (!p || p.pos === "P") continue;
      const score = l.h + l.d + 2 * l.t + 3 * l.hr + l.bb + l.hbp - 0.3 * (l.ab - l.h) - 0.2 * l.k - 0.95;
      p.form = Math.round(((p.form ?? 0) * 0.85 + score * 0.12) * 100) / 100;
      const f = (l.hr * 0.5 + (l.h >= 3 ? 0.6 : l.h * 0.08) + (l.hr >= 2 ? 1.5 : 0)) * fameMult;
      if (f > 0) gainFame(world, rng, p, f, events, l.hr >= 2 ? "multi-homer game" : "big game");
    }
    box.pitch.forEach((l, i) => {
      const p = world.players[l.id];
      if (!p) return;
      const score = Math.max(-3, Math.min(3, ((l.outs * 4.3) / 27 - l.er) * 0.7));
      p.form = Math.round(((p.form ?? 0) * 0.85 + score * 0.15) * 100) / 100;
      const won = res.decisions.w === l.id, saved = res.decisions.s === l.id;
      const f = ((won ? 0.4 : 0) + (saved ? 0.3 : 0) + (l.k >= 10 ? 1 : 0) + (i === 0 && l.outs >= 27 && l.r === 0 ? 2.5 : 0)) * fameMult;
      if (f > 0) gainFame(world, rng, p, f, events, "pitching");
    });
  }
  if (ml) {
    for (const [box, opp] of [[res.home, res.away], [res.away, res.home]] as const) {
      if (opp.hits === 0 && res.innings >= 9) for (const l of box.pitch) { const p = world.players[l.id]; if (p) gainFame(world, rng, p, 12, events, "no-hitter"); }
    }
  }

  // injuries: friends take it personally
  for (const inj of res.injuries) {
    const hbp = hbps.find(h => h.bat === inj.id);
    propagateInjury(world, rng, inj.id, hbp?.pit, events, hbp ? "hit by a pitch" : inj.kind);
    const p = world.players[inj.id];
    if (p && ml && inj.days >= 45 && !findOpen(world, "comeback", p.id)) {
      startStoryline(world, "comeback", [p.id], [p.teamId], { visibility: "public", stage: "rehab", cause: inj.kind, stakes: "his career", data: { days: inj.days } }, events);
    }
  }

  // retaliation beanballs (a pitcher with a grudge against the batter or his club)
  for (const h of hbps) {
    const pit = world.players[h.pit], bat = world.players[h.bat];
    if (!pit || !bat) continue;
    const grudge = Math.min(relation(world, pit.id, bat.id), relation(world, pit.id, orgOf(world, bat.teamId)));
    const friendHurt = pit.concerns?.some(c => c.kind === "injured_friend" && (c.note === orgOf(world, bat.teamId) || c.note === bat.id));
    if (grudge > -3 && !friendHurt) continue;
    const injured = res.injuries.some(i => i.id === bat.id);
    events.push(mkEvent(world, "beanball", [pit.id, bat.id], [pit.teamId, bat.teamId], { sub: "retaliation", gameId: game.id, injured, why: friendHurt ? "payback for a hurt teammate" : "a grudge" }));
    setRelation(world, bat.id, pit.id, Math.min(-3, relation(world, bat.id, pit.id) - 2), "beaned him on purpose", "rival");
    const open = openStorylines(world).find(s => s.kind === "rivalry" && s.people.includes(pit.id) && s.people.includes(bat.id));
    if (open) nudgeStoryline(world, open.id, "inflame", 1.5);
    else if (ml && (hasT(bat, "HOTHEAD") || rng.chance(0.4))) {
      startStoryline(world, "rivalry", [bat.id, pit.id], [bat.teamId, pit.teamId], { visibility: "public", stage: "simmering", cause: "a beanball", stakes: "pride" }, events);
    }
  }

  // brawls on the field
  for (const inc of res.incidents) {
    if (inc.kind !== "BRAWL" || !inc.who) continue;
    const [a, b] = inc.who.split(",");
    if (!a || !b) continue;
    const fe = fight(world, rng, [a, b], "on_field", events);
    fe.data = { ...fe.data, gameId: game.id, inning: inc.inning };
    for (const s of openStorylines(world)) {
      if ((s.kind === "rivalry" || s.kind === "feud") && ((s.people.includes(a) && s.people.includes(b)) ||
        (s.people.some(x => x === a || x === b) && s.people.every(x => world.players[x] && [game.homeId, game.awayId].includes(world.players[x].teamId))))) {
        resolveStoryline(world, s, "brawl", events, { where: "on the field", gameId: game.id, fightEvent: fe.id });
      }
    }
    // the dugouts remember
    const [ta, tb] = [world.players[a]?.teamId, world.players[b]?.teamId];
    if (ta && tb && ta !== tb) for (const id of world.teams[ta]?.roster ?? []) if (rng.chance(0.15)) shiftRelation(world, id, orgOf(world, tb), -1, "the brawl", "hates_team");
  }

  // point shaving: count the games he dumped
  for (const s of openStorylines(world)) {
    if (s.kind !== "gambling_debt" || s.stage !== "shaving") continue;
    const id = s.people[0];
    const played = [res.home, res.away].some(b => b.bat.some(l => l.id === id) || b.pitch.some(l => l.id === id));
    if (!played || !shavesGame(s.id, game.id)) continue;
    s.data.shaved = Number(s.data.shaved ?? 0) + 1;
    const games = (s.data.games as string[] | undefined) ?? [];
    games.push(game.id);
    s.data.games = games.slice(-12);
  }

  if (!ml) return;
  // slumps, rookies
  for (const box of [res.home, res.away]) {
    for (const l of [...box.bat.map(x => x.id), ...box.pitch.map(x => x.id)]) {
      const p = world.players[l];
      if (!p) continue;
      if ((p.form ?? 0) < -1.0 && !findOpen(world, "slump", p.id)) {
        startStoryline(world, "slump", [p.id], [p.teamId], { visibility: "public", stage: "slump", cause: p.pos === "P" ? "getting shelled" : "can't buy a hit", stakes: "his job" }, events);
        addConcern(world, p, { kind: "slump", until: world.day + 30, weight: -1.5, note: "slumping" });
      }
      if (p.debut?.gameId === game.id) {
        const kin = baseballKin(world, p);
        if ((p.potential >= 58 || kin || fameOf(p) >= 20) && !findOpen(world, "rookie_watch", p.id)) {
          startStoryline(world, "rookie_watch", [p.id], [p.teamId], { visibility: "public", stage: "watch", cause: kin ? `${kin.relation} of ${shortName(living(world, kin.id) ?? world.archive[kin.id])}` : "top prospect", stakes: "Rookie of the Year" }, events);
        }
        if (goalOf(p, "make_majors")) achieveGoal(world, rng, p, "make_majors", events, "debuted");
      }
    }
  }
}

/**
 * A player got hurt. His friends, mentors and family worry; if somebody did it (a pitch), they
 * hold it against the pitcher and his club, and the hotheads start a rivalry.
 */
export function propagateInjury(world: World, rng: Rng, injuredId: string, culpritId: string | undefined, events: LifeEvent[], cause: string) {
  const hurt = world.players[injuredId];
  if (!hurt) return;
  const culprit = culpritId ? world.players[culpritId] : undefined;
  const culpritOrg = culprit ? orgOf(world, culprit.teamId) : undefined;
  const close = new Set<string>();
  for (const r of relsOf(world, injuredId)) {
    if (r.value < 2) continue;
    if (r.kind && !["friend", "mentor", "family", "lover"].includes(r.kind)) continue;
    close.add(r.a === injuredId ? r.b : r.a);
  }
  for (const id of [...hurt.family.parents, ...hurt.family.children]) close.add(id);
  if (hurt.family.spouse) close.add(hurt.family.spouse);
  const turned: string[] = [];
  for (const id of close) {
    const f = living(world, id);
    if (!f || f.id === culpritId) continue;
    const loyal = hasT(f, "LOYAL") ? 1.5 : 1;
    addConcern(world, f, { kind: "injured_friend", about: injuredId, until: world.day + 25, weight: -1.2 * loyal, note: culpritOrg ?? cause });
    if (!culprit || f.kind !== "player") continue;
    setRelation(world, f.id, culprit.id, Math.min(-3, relation(world, f.id, culprit.id) - 3), `hurt ${hurt.first} ${hurt.last}`, "grudge");
    shiftRelation(world, f.id, culpritOrg!, -2, `hurt ${hurt.first} ${hurt.last}`, "hates_team");
    turned.push(f.id);
    const fp = f as Player;
    if (hasT(fp, "HOTHEAD") && world.teams[fp.teamId]?.level === "ML" && rng.chance(0.5) && !involving(world, f.id).some(s => s.kind === "rivalry" && s.people.includes(culprit.id))) {
      startStoryline(world, "rivalry", [f.id, culprit.id], [fp.teamId, culprit.teamId], { visibility: "public", stage: "boiling", cause: `${culprit.last} hurt ${hurt.last}`, stakes: "payback" }, events);
    }
  }
  if (turned.length && world.teams[hurt.teamId]?.level === "ML") {
    events.push(mkEvent(world, "drama", [injuredId, ...(culprit ? [culprit.id] : []), ...turned], [hurt.teamId, ...(culprit ? [culprit.teamId] : [])], {
      sub: "vendetta", injured: injuredId, culprit: culprit?.id, friends: turned, cause,
    }));
  }
}
