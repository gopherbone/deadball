import type { Ctx } from "../router.ts";
import { decCursor, encCursor, fail } from "../http.ts";
import { houseName, moodNote, type Player, type Story, type World } from "../sim.ts";
import {
  dramaLines, houseNote, moodStr, personRef, personStatus, playerLine, scouting, statOf, teamRef, tiesOf, traitStr, avgStr, eraStr, ipStr,
} from "../views.ts";
import { latestComments, limitParam, page } from "./common.ts";

type StoryRow = { id: string; season: number; day: number; kind: string; headline: string; publish_at: number; game_id: string | null; data: string; comments: number; prominence: number };

/** Story.prominence (base + fame/25) from which a story is an EXTRA. */
export const EXTRA_PROMINENCE = 5;

const summary = (r: StoryRow) => {
  const s = JSON.parse(r.data) as Story;
  return {
    id: r.id, day: r.day, kind: r.kind, headline: r.headline, dek: s.dek, ...(s.faceIds?.[0] ? { face: s.faceIds[0] } : {}),
    ...(s.photo ? { photo: s.photo } : {}), ...(s.photoCaption ? { photoCaption: s.photoCaption } : {}), ...(s.section ? { section: s.section } : {}), at: r.publish_at,
    ...(r.game_id ? { gameId: r.game_id } : {}), comments: r.comments ?? 0,
    // EXTRA! EXTRA!: the weird tier, plane crashes, the famous (the client slams it in once)
    ...(r.prominence >= EXTRA_PROMINENCE ? { extra: true as const } : {}),
  };
};

/** The front page: newest edition first; within an edition the most prominent story leads (Story.prominence). */
export async function list(c: Ctx) {
  const raw = decCursor<(number | string)[]>(c.q.get("cursor"));
  const cur = raw ? (raw.length === 3 ? raw : [raw[0], -1e9, raw[1]]) as [number, number, string] : undefined;
  const limit = limitParam(c, 15, 40);
  const kind = c.q.get("kind");
  const rows = (await c.db.prepare(`SELECT s.*, COALESCE(t.comment_count, 0) AS comments FROM stories s LEFT JOIN threads t ON t.id = 'story:' || s.id
      WHERE s.publish_at <= ? ${kind ? "AND s.kind = ?" : ""}
      ${cur ? "AND (s.publish_at < ? OR (s.publish_at = ? AND (s.prominence < ? OR (s.prominence = ? AND s.id < ?))))" : ""}
      ORDER BY s.publish_at DESC, s.prominence DESC, s.id DESC LIMIT ?`)
    .bind(c.now, ...(kind ? [kind] : []), ...(cur ? [cur[0], cur[0], cur[1], cur[1], cur[2]] : []), limit + 1).all<StoryRow>()).results;
  const p = page(rows, limit, l => [l.publish_at, l.prominence, l.id]);
  const out: { stories: unknown[]; next?: string } = { stories: p.items.map(summary) };
  if (p.next) out.next = encCursor(p.next);
  return out;
}

export async function story(c: Ctx) {
  const r = await c.db.prepare("SELECT *, 0 AS comments FROM stories WHERE id = ? AND publish_at <= ?").bind(c.params[0], c.now).first<StoryRow>();
  if (!r) fail("not_found", "no such story");
  const s = JSON.parse(r!.data) as Story;
  return { story: { ...s, id: r!.id, gameId: r!.game_id ?? undefined, at: r!.publish_at }, comments: await latestComments(c, `story:${r!.id}`, 20) };
}

export async function person(c: Ctx) {
  const w = c.L.world, id = c.params[0];
  const p = w.players[id] ?? w.npcs[id] ?? w.archive?.[id];
  if (!p) fail("not_found", "no such person");
  const pl = w.players[id];
  const season = c.L.state.season;
  const vis = await c.db.prepare("INSERT INTO visitors (page, n) VALUES (?, 1) ON CONFLICT (page) DO UPDATE SET n = n + 1 RETURNING n").bind(`person:${id}`).first<{ n: number }>();
  const ref = personRef(w, id);
  const known = (pid: string) => !!(w.players[pid] || w.npcs[pid] || w.archive?.[pid]);
  const stats: { season: number; team: string; line: string }[] = [];
  // older seasons come from storage on demand (stats.ts), just this person's
  c.L.stats.hydrate(w, [id]);
  for (let s = season; s >= Math.max(1, season - 9); s--) {
    const st = statOf(w, id, s);
    if (!st) continue;
    const raw = (w as unknown as { stats?: Record<string, Record<string, { teamId?: string; team?: string }>> }).stats?.[id]?.[s];
    const team = w.teams[raw?.teamId ?? raw?.team ?? ""]?.abbr ?? (s === season && pl ? w.teams[pl.teamId]?.abbr ?? "" : "");
    const line = pl?.pos === "P" || (st.outs > 0 && st.ab === 0)
      ? `${st.w}-${st.l}, ${eraStr(st.per, st.outs)} ERA, ${ipStr(st.outs)} IP, ${st.pk} K`
      : `${avgStr(st.h, st.ab)}, ${st.hr} HR, ${st.rbi} RBI, ${st.sb} SB`;
    stats.push({ season: s, team, line });
  }
  const fam = p!.family;
  const family = {
    parents: fam.parents.filter(known).map(x => personRef(w, x)),
    ...(fam.spouse && known(fam.spouse) ? { spouse: personRef(w, fam.spouse) } : {}),
    children: fam.children.filter(known).map(x => personRef(w, x)),
    house: houseName(w, fam.house), houseNote: houseNote(w, fam.house),
  };
  const out = {
    person: {
      ...ref, ...(p!.nickname ? { nickname: p!.nickname } : {}), age: p!.age, ...(pl ? { bats: pl.bats, throws: pl.throws } : {}),
      traits: p!.traits.map(traitStr), mood: moodStr(p!.mood), status: personStatus(w, id),
    },
    ...(pl && w.teams[pl.teamId] ? { team: teamRef(w, pl.teamId) } : {}),
    family, ties: tiesOf(w, id), drama: dramaLines(w, id), stats,
    ...(pl ? { scouting: scouting(pl) } : {}),
    notes: pl ? `${playerLine(w, id, season)} this season. Lately: ${publicMoodNote(w, pl)}.${pl.potential >= 65 && pl.age <= 24 ? " Scouts are drooling." : ""}` : `${p!.first} ${p!.last}, ${("role" in p! ? (p as { role: string }).role : "citizen")}.`,
    faces: [p!.face], visitors: vis?.n ?? 1, guestbook: await latestComments(c, `person:${id}`, 10),
  };
  return out;
}

export function team(c: Ctx) {
  const w = c.L.world, id = c.params[0];
  const t = w.teams[id] ?? Object.values(w.teams).find(x => x.abbr.toLowerCase() === id.toLowerCase());
  if (!t) fail("not_found", "no such team");
  const f = w.factions[t!.factionId];
  const season = c.L.state.season;
  const ml = t!.parentId ? w.teams[t!.parentId] : t!;
  const chainTeams = [ml!, ...Object.values(w.teams).filter(x => x.parentId === ml!.id)].sort((a, b) => "ML AA B D".indexOf(a.level) - "ML AA B D".indexOf(b.level));
  // factions and people only: grudges against accounts and syndicates stay private
  const known = (id: string) => !!(w.factions[id] || w.players[id] || w.npcs[id] || w.archive?.[id]);
  const relations = w.relationships.filter(r => (r.a === f?.id && known(r.b)) || (r.b === f?.id && known(r.a))).map(r => {
    const other = r.a === f?.id ? r.b : r.a;
    return { name: w.factions[other]?.name ?? personRef(w, other).name, value: r.value, reason: r.reason };
  });
  const roster = t!.roster.filter(pid => w.players[pid]).map(pid => ({ ...personRef(w, pid), line: playerLine(w, pid, season) }))
    .sort((a, b) => (a.pos === "P" ? 1 : 0) - (b.pos === "P" ? 1 : 0));
  void statOf;
  return {
    team: teamRef(w, t!.id),
    owner: { faction: f?.name ?? "", leader: personRef(w, f?.leaderId ?? ""), wants: f?.wants ?? [] },
    manager: personRef(w, t!.managerId), park: w.parks[t!.parkId]?.name ?? "",
    chain: chainTeams.map(x => ({ ...teamRef(w, x.id), record: c.L.records(x.level).get(x.id) ?? "0-0" })),
    roster, relations, moves: c.L.movesFor(t!.id),
  };
}

/** CONCERNS that come from hidden arcs (point shaving, a secret affair) are nobody's business. */
const HIDDEN_CONCERNS = new Set(["shaving", "secret_affair"]);
/** moodNote without concerns tied to secret storylines, so fan pages can't leak them. */
export function publicMoodNote(w: World, p: Player): string {
  const secret = new Set((w.storylines ?? []).filter(s => s.visibility === "secret" && !s.resolved).map(s => s.id));
  const concerns = (p.concerns ?? []).filter(c => !HIDDEN_CONCERNS.has(c.kind) && !(c.storyline && secret.has(c.storyline)));
  return moodNote(w, { ...p, concerns });
}
