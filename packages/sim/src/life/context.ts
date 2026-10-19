// Contextual per-game modifiers: mood, grudges against the opponent, a hurt friend, fears in
// the wrong situation, goals in the right one, contract years, clubhouse chemistry, quirks,
// and the hidden ones (point shaving). The server passes these into GameSpec.modifiers.

import type { Modifier } from "../modifiers.ts";
import type { Player, Team, World } from "../types.ts";
import { hasQ, hasT, relsOf } from "./people.ts";
import { openStorylines } from "./storylines.ts";

/** What we need to know about the game (a ScheduledGame works). */
export interface GameCtx {
  id: string;
  homeId: string;
  awayId: string;
  /** 0–3; 2 and 3 are night games. */
  slot?: number;
  /** Set for playoff games. */
  series?: string;
}

const r1 = (x: number) => Math.round(x * 10) / 10;
const orgOf = (w: World, teamId: string) => w.teams[teamId]?.parentId ?? teamId;

// --- chemistry -------------------------------------------------------------------------------------

const chemCache = new WeakMap<World, { day: number; byTeam: Map<string, number> }>();

/**
 * Clubhouse chemistry, -3..+3: friendships and mentors on the roster help; feuds, grudges and
 * affairs between teammates hurt. LONERs don't count either way; PRANKSTERs add a little fun.
 */
export function chemistry(world: World, teamId: string): number {
  let c = chemCache.get(world);
  if (!c || c.day !== world.day) { c = { day: world.day, byTeam: new Map() }; chemCache.set(world, c); }
  const hit = c.byTeam.get(teamId);
  if (hit !== undefined) return hit;
  const team = world.teams[teamId];
  if (!team) return 0;
  const onTeam = new Set(team.roster);
  let sum = 0;
  for (const id of team.roster) {
    const p = world.players[id];
    if (!p || hasQ(p, "LONER")) continue;
    for (const r of relsOf(world, id)) {
      const other = r.a === id ? r.b : r.a;
      if (other < id || !onTeam.has(other)) continue; // count each pair once
      sum += r.value;
    }
    if (hasQ(p, "PRANKSTER")) sum += 0.5;
    if (p.mood <= -3) sum -= 0.3;
  }
  const v = r1(Math.max(-3, Math.min(3, sum / 10)));
  c.byTeam.set(teamId, v);
  return v;
}

// --- per-game modifiers --------------------------------------------------------------------------------

/** Hostility (most negative tie, ≤ 0) of a player toward anyone on the other roster or that club. */
function hostility(world: World, p: Player, oppRoster: Set<string>, oppOrg: string): { v: number; target?: string; why?: string } {
  let v = 0, target: string | undefined, why: string | undefined;
  for (const r of relsOf(world, p.id)) {
    const other = r.a === p.id ? r.b : r.a;
    if (r.value >= v) continue;
    if (oppRoster.has(other) || other === oppOrg) { v = r.value; target = other; why = r.reason; }
  }
  return { v, target, why };
}

function hash01(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return (h >>> 0) / 4294967296;
}

/** Does the point-shaver dump this particular game? (deterministic per game) */
export function shavesGame(storylineId: string, gameId: string): boolean {
  return hash01(`${storylineId}:${gameId}`) < 0.5;
}

/**
 * All drama/mood modifiers for one game. `teamIds` are [home, away] (or any subset); pass the
 * game for game-specific context (night games, playoffs, point shaving).
 */
export function contextModifiers(world: World, teamIds: string[], game?: GameCtx): Modifier[] {
  const out: Modifier[] = [];
  const add = (id: string, effect: Modifier["effect"], value: number, note: string, source = "drama", kind: "player" | "team" = "player") => {
    if (Math.abs(value) < 0.05) return;
    out.push({ id: `${source}-${id}-${effect}-${out.length}`, source, target: { kind, id }, effect, value: r1(value), note });
  };
  const night = (game?.slot ?? 0) >= 2;
  const playoffs = !!game?.series;
  const shavers = game ? openStorylines(world).filter(s => s.kind === "gambling_debt" && s.stage === "shaving") : [];
  let brawlHeat = 0;

  for (const tid of teamIds) {
    const team: Team | undefined = world.teams[tid];
    if (!team) continue;
    const oppId = teamIds.length === 2 ? (teamIds[0] === tid ? teamIds[1] : teamIds[0]) : undefined;
    const opp = oppId ? world.teams[oppId] : undefined;
    const oppRoster = new Set(opp?.roster ?? []);
    const oppOrg = oppId ? orgOf(world, oppId) : "";
    const away = game ? game.awayId === tid : false;
    const park = game ? world.parks[world.teams[game.homeId]?.parkId ?? ""] : undefined;

    const chem = chemistry(world, tid);
    if (chem) {
      add(tid, "contact", chem * 0.5, `clubhouse chemistry ${chem > 0 ? "+" : ""}${chem}`, "chemistry", "team");
      add(tid, "stuff", chem * 0.4, `clubhouse chemistry ${chem > 0 ? "+" : ""}${chem}`, "chemistry", "team");
    }

    for (const id of team.roster) {
      const p = world.players[id];
      if (!p) continue;
      const pitcher = p.pos === "P";
      // mood: hitters already get mood*0.6 in the engine; pitchers get it here
      if (pitcher && Math.abs(p.mood) >= 0.5) {
        add(id, "stuff", p.mood * 0.5, "mood", "mood");
        add(id, "control", p.mood * 0.4, "mood", "mood");
      }
      // contract year: playing for the next deal
      if (p.contract?.years === 1 && team.level === "ML") {
        const k = hasT(p, "GREEDY") ? 1.5 : 1;
        if (pitcher) add(id, "stuff", 1 * k, "contract year");
        else { add(id, "contact", 0.6 * k, "contract year"); add(id, "power", 0.6 * k, "contract year"); }
      }
      // grudges against the other side: angrier and tighter; pitchers come inside
      if (opp) {
        const h = hostility(world, p, oppRoster, oppOrg);
        const friendHurt = p.concerns?.find(c => c.kind === "injured_friend" && c.until >= world.day && c.note && (c.note === oppOrg || oppRoster.has(c.note)));
        const heat = Math.min(h.v, friendHurt ? -4 : 0);
        if (heat <= -3) {
          const k = (-heat - 2) / 3 * (hasT(p, "HOTHEAD") ? 1.6 : 1);
          const why = friendHurt ? `payback for ${friendHurt.about ?? "a friend"}` : `grudge: ${h.why ?? "bad blood"}`;
          if (pitcher) add(id, "hbp", 1.2 * k, why);
          else { add(id, "power", 1.2 * k, why); add(id, "eye", -1.4 * k, why); }
          brawlHeat += k;
        }
        // fear of a particular pitcher on the other side
        for (const f of p.fears ?? []) {
          if (f.kind === "pitcher" && f.target && oppRoster.has(f.target) && !pitcher) { add(id, "contact", -1 * f.strength, "fears that pitcher"); add(id, "power", -0.7 * f.strength, "fears that pitcher"); }
        }
        // revenge goals
        for (const g of p.goals ?? []) {
          if (g.kind === "revenge" && g.target && (oppRoster.has(g.target) || g.target === oppOrg)) {
            if (pitcher) add(id, "stuff", 1.5, "revenge"); else add(id, "power", 1.5, "revenge");
          }
        }
      }
      // fears and goals in the moment
      for (const f of p.fears ?? []) {
        if (f.kind === "the_dark" && night) {
          if (pitcher) add(id, "control", -1 * f.strength, "afraid of the dark");
          else { add(id, "contact", -1.2 * f.strength, "afraid of the dark"); add(id, "eye", -0.8 * f.strength, "afraid of the dark"); }
        }
        if (f.kind === "failure" && playoffs) add(id, pitcher ? "stuff" : "contact", -1.2 * f.strength, "big-game nerves");
        if (f.kind === "flying" && away) add(id, pitcher ? "stamina" : "contact", pitcher ? -3 * f.strength : -0.4 * f.strength, "white-knuckle flight");
        if (f.kind === "birds" && park && /wharf|harbor/i.test(park.name)) add(id, pitcher ? "control" : "contact", -0.8 * f.strength, "the gulls");
        if (f.kind === "ghosts" && park && /sanctuary|plymouth/i.test(park.name)) add(id, pitcher ? "control" : "eye", -0.7 * f.strength, "the old ballpark is haunted");
      }
      for (const g of p.goals ?? []) {
        if (g.kind === "win_title" && playoffs && g.intensity >= 2) add(id, pitcher ? "stuff" : "contact", g.intensity * 0.6, "wants the ring");
        if (g.kind === "make_majors" && team.level !== "ML" && g.intensity >= 2) add(id, pitcher ? "stuff" : "contact", 0.5, "hungry");
      }
      // what's on his mind
      let distraction = 0;
      for (const c of p.concerns ?? []) {
        if (c.until < world.day) continue;
        if (c.kind === "sick_kid" || c.kind === "sick_parent" || c.kind === "grieving" || c.kind === "missing_time") distraction += 0.6;
        if (c.kind === "debt" || c.kind === "stalker" || c.kind === "marriage") distraction += 0.4;
      }
      if (distraction) add(id, pitcher ? "control" : "eye", -Math.min(2.5, distraction), "distracted");
      // weird quirks
      if (hasQ(p, "KNOWS_THINGS")) { if (pitcher) add(id, "control", 3, "knows things"); else { add(id, "eye", 3, "knows things"); add(id, "contact", 1, "knows things"); } }
      if (hasQ(p, "GLOWS") && night) add(id, pitcher ? "stuff" : "eye", 2.5, "glows in the dark");
      if (hasQ(p, "NO_SHADOW") && !pitcher) add(id, "speed", 3, "casts no shadow");
      if (hasQ(p, "SPEAKS_TO_BIRDS") && park && /wharf|harbor/i.test(park.name)) add(id, pitcher ? "stuff" : "contact", 2, "the gulls are with him");
      if (hasQ(p, "RESURRECTED") && pitcher) add(id, "stamina", 8, "does not tire");
      if (hasQ(p, "TIME_DISPLACED")) { if (pitcher) add(id, "control", -1, "baffled by the modern game"); else { add(id, "eye", -1.5, "baffled by the modern game"); add(id, "power", 1.5, "old-world strength"); } }
      // hidden: point shaving in this game
      for (const s of shavers) {
        if (s.people[0] !== id || !game || !shavesGame(s.id, game.id)) continue;
        if (pitcher) { out.push({ id: `shave-${s.id}-stuff`, source: `shave:${s.id}`, target: { kind: "player", id }, effect: "stuff", value: -6, note: "hidden" }); out.push({ id: `shave-${s.id}-control`, source: `shave:${s.id}`, target: { kind: "player", id }, effect: "control", value: -5, note: "hidden" }); }
        else { out.push({ id: `shave-${s.id}-contact`, source: `shave:${s.id}`, target: { kind: "player", id }, effect: "contact", value: -7, note: "hidden" }); out.push({ id: `shave-${s.id}-power`, source: `shave:${s.id}`, target: { kind: "player", id }, effect: "power", value: -5, note: "hidden" }); }
      }
    }
  }
  // public feuds and rivalries between the two rosters, and raw grudges, make brawls likelier
  if (teamIds.length === 2) {
    const [a, b] = teamIds.map(t => new Set(world.teams[t]?.roster ?? []));
    for (const s of openStorylines(world)) {
      if (s.kind !== "rivalry" && s.kind !== "feud") continue;
      if ((a.has(s.people[0]) && b.has(s.people[1])) || (b.has(s.people[0]) && a.has(s.people[1]))) brawlHeat += s.stage === "boiling" || s.stage === "public_spat" ? 3 : 1.5;
    }
    if (brawlHeat > 0) out.push({ id: `brawl-heat`, source: "drama", target: { kind: "game", id: game?.id ?? "game" }, effect: "incident", incident: "BRAWL", value: r1(Math.min(4, 1 + brawlHeat * 0.35)), note: "bad blood" });
  }
  return out;
}

/** Everything the drama layer wants applied to this game (same as moodModifiers with the game). */
export function dramaModifiers(world: World, game: GameCtx): Modifier[] {
  return contextModifiers(world, [game.homeId, game.awayId], game);
}
