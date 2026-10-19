import type { Ctx } from "../router.ts";
import type { GameRow, OpRow } from "../league.ts";
import { decCursor, encCursor, fail, newId, oneOf, str, strArray } from "../http.ts";
import { Rng, sim, gearInfo, bleacherBan, storylineAllowed, storylineNudge, storylineTargets, type CrewMember, type Candidate, type OpOrder, type World } from "../sim.ts";
import { candidateInfo, crewView, personRef, rankFor, teamRef } from "../views.ts";
import { accountView, gate, gameRow, limitParam, moneyMove, page, slateGames } from "./common.ts";
import { allyShares, chipInFor, proposeStmts } from "./chipin.ts";

type CrewRow = { id: string; account_id: string; person_id: string; role: string; note: string; status: string; data: string; created_at: number };

const MAX_BY_RANK: Record<string, number> = { Rube: 3, Regular: 4, Sharpie: 5, Operator: 6, Bigwig: 7, Kingpin: 8 };
export const crewMax = (money: number) => MAX_BY_RANK[rankFor(money)] ?? 3;

async function myCrew(c: Ctx): Promise<CrewRow[]> {
  return (await c.db.prepare("SELECT * FROM crew WHERE account_id = ? AND status NOT IN ('gone', 'dead') ORDER BY created_at").bind(c.acct.id).all<CrewRow>()).results;
}

export async function list(c: Ctx) {
  const out: { crew: ReturnType<typeof crewView>[]; max: number; allies?: (ReturnType<typeof crewView> & { owner: string })[] } =
    { crew: (await myCrew(c)).map(r => crewView(c.L.world, r)), max: crewMax(c.acct.money) };
  if (c.acct.syndicate_id) {
    // allies' free crew, so the op planner can staff joint jobs
    const rows = (await c.db.prepare(`SELECT cr.*, a.name AS owner_name FROM crew cr JOIN accounts a ON a.id = cr.account_id
      WHERE cr.status = 'free' AND a.syndicate_id = ? AND a.id != ? ORDER BY a.name, cr.created_at`)
      .bind(c.acct.syndicate_id, c.acct.id).all<CrewRow & { owner_name: string }>()).results;
    out.allies = rows.map(r => ({ ...crewView(c.L.world, r), owner: r.owner_name }));
  }
  return out;
}

function pool(c: Ctx): { day: number; cands: Candidate[]; refreshesAt: number } {
  const L = c.L;
  const d = L.shownDay(c.now);
  const cands = sim.recruitPool(L.world, c.acct.id, d.day, new Rng(`${L.seed}:cand:${c.acct.id}:${L.state.season}:${d.day}`));
  return { day: d.day, cands, refreshesAt: d.nextDayAt };
}

export async function candidates(c: Ctx) {
  const { cands, refreshesAt } = pool(c);
  const hired = new Set((await c.db.prepare("SELECT candidate_id FROM hired WHERE candidate_id IN (SELECT value FROM json_each(?))")
    .bind(JSON.stringify(cands.map(x => x.id))).all<{ candidate_id: string }>()).results.map(r => r.candidate_id));
  return {
    candidates: cands.filter(x => !hired.has(x.id)).map(x => {
      const { personId: _p, npc: _n, ...v } = candidateInfo(c.L.world, x);
      return v;
    }),
    refreshesAt,
  };
}

export async function recruit(c: Ctx) {
  const id = str(c.body, "candidateId", 120);
  const { cands } = pool(c);
  const cand = cands.find(x => x.id === id);
  if (!cand) fail("not_found", "that candidate isn't on the board today");
  const info = candidateInfo(c.L.world, cand!);
  const mine = await myCrew(c);
  if (mine.length >= crewMax(c.acct.money)) fail("bad_request", "your crew is full");
  const w = c.L.world;
  const had = !!w.npcs[info.personId];
  const member = sim.hireCandidate(w, { ...cand!, ownerId: c.acct.id } as Candidate) as CrewMember;
  member.ownerId = c.acct.id;
  const crewId = member.id && !member.id.startsWith("crew-undefined") ? `${member.id}` : newId("cr");
  const role = String(cand!.roleLabel ?? info.role);
  const { ok } = await moneyMove(c, {
    delta: -info.ask, reason: "recruit",
    cond: `NOT EXISTS (SELECT 1 FROM hired WHERE candidate_id = ?) AND (SELECT COUNT(*) FROM crew WHERE account_id = a.id AND status NOT IN ('gone', 'dead')) < ?`,
    condArgs: [id, crewMax(c.acct.money)],
    then: tx => [
      c.db.prepare(`INSERT INTO hired (candidate_id, account_id) SELECT ?, ? WHERE ${gate()}`).bind(id, c.acct.id, tx),
      c.db.prepare(`INSERT INTO crew (id, account_id, person_id, role, note, status, data, created_at) SELECT ?,?,?,?,?, 'free', ?, ? WHERE ${gate()}`)
        .bind(crewId, c.acct.id, member.personId, role, info.pitch, JSON.stringify({ ...member, id: crewId }), c.now, tx),
    ],
  });
  if (!ok) {
    if (!had) delete w.npcs[info.personId];
    if (await c.db.prepare("SELECT 1 FROM hired WHERE candidate_id = ?").bind(id).first()) fail("bad_request", "already hired");
    fail("insufficient_funds", `they want $${info.ask} up front`);
  }
  c.L.store.saveField("world", w, "npcs");
  return { crew: (await myCrew(c)).map(r => crewView(w, r)), account: await accountView(c) };
}

export async function dismiss(c: Ctx) {
  const r = await c.db.prepare(`UPDATE crew SET status = 'gone', data = json_set(data, '$.status', 'gone') WHERE id = ? AND account_id = ? AND status NOT IN ('busy', 'gone', 'dead')`)
    .bind(c.params[0], c.acct.id).run();
  if (!r.meta.changes) {
    const row = await c.db.prepare("SELECT status FROM crew WHERE id = ? AND account_id = ?").bind(c.params[0], c.acct.id).first<{ status: string }>();
    if (!row || row.status === "gone") fail("not_found", "no such crew member");
    fail("bad_request", "they're on a job; dismiss them after the game");
  }
  return { crew: (await myCrew(c)).map(x => crewView(c.L.world, x)) };
}

/** Crew usable for jobs: mine plus syndicate allies', free only. */
async function usableCrew(c: Ctx): Promise<CrewRow[]> {
  return (await c.db.prepare(`SELECT * FROM crew WHERE status = 'free' AND (account_id = ? OR (? IS NOT NULL AND account_id IN (SELECT id FROM accounts WHERE syndicate_id = ?)))`)
    .bind(c.acct.id, c.acct.syndicate_id, c.acct.syndicate_id).all<CrewRow>()).results;
}

export async function catalog(c: Ctx) {
  const gid = c.q.get("game");
  let targets: ReturnType<typeof teamRef>[] = [];
  let umpireId: string | undefined;
  let homeTeamId: string | undefined;
  let target = c.q.get("target") ?? "";
  if (gid) {
    const g = await gameRow(c, gid);
    targets = [teamRef(c.L.world, g.away_id), teamRef(c.L.world, g.home_id)];
    umpireId = g.umpire_id;
    homeTeamId = g.home_id;
    if (!target) target = g.home_id;
  }
  const crew = (await usableCrew(c)).filter(r => r.account_id === c.acct.id).map(r => JSON.parse(r.data) as CrewMember);
  // hostile owners: guards on their clubs, bans from their bleachers (you and your syndicate)
  const ctx = { parties: [c.acct.id, c.acct.syndicate_id ?? undefined], homeTeamId };
  const kinds = sim.OP_KINDS.map(k => {
    const v = sim.opPlannerView(c.L.world, k.kind, target, crew, [], umpireId, ctx);
    const gear = k.gear.map(id => ({ id, ...gearInfo(id) }));
    const needs = Object.entries(k.needs).map(([s, n]) => `${s[0].toUpperCase()}${s.slice(1)}${n}`).join(" ");
    const base = { kind: k.kind, name: k.name, blurb: k.blurb, cost: k.cost, risk: k.risk, slots: k.slots, needs, gear, successPct: 50 };
    if (!v) return base;
    const { kind, name, blurb, risk, slots, needs: vn, successPct, ...extra } = v;
    return { ...extra, kind, name, blurb, cost: k.cost, risk, slots, needs: vn || needs, gear: v.gear ?? gear, successPct };
  });
  // storyline ops: public/rumoured arcs, plus secret ones this account was tipped about
  const known = await c.L.knownStorylines(c.acct.id);
  const w = c.L.world;
  const storylines = storylineTargets(w, known).map(t => ({
    storylineId: t.storylineId, kind: t.kind, stage: t.stage === "shaving" && t.visibility !== "secret" ? "leaned_on" : t.stage, visibility: t.visibility,
    people: t.people.filter(id => w.players[id] || w.npcs[id]).slice(0, 3).map(id => personRef(w, id)),
    teams: t.teams.filter(id => w.teams[id]).map(id => teamRef(w, id)), label: t.label, ops: t.ops,
  }));
  return { kinds, targets, storylines };
}

/** "Mullane: affair" style label for an op's storyline (only ever shown to the orderer). */
function storylineLabel(w: World, id: string): string {
  const s = (w.storylines ?? []).find(x => x.id === id);
  if (!s) return "an old story";
  const p = w.players[s.people[0]] ?? w.npcs[s.people[0]] ?? w.archive?.[s.people[0]];
  return `${p ? p.last : "Somebody"}: ${s.kind.replace(/_/g, " ")}`;
}

export async function order(c: Ctx) {
  const kind = str(c.body, "kind", 40);
  const gameId = typeof c.body.gameId === "string" && c.body.gameId === "" ? "" : str(c.body, "gameId", 80);
  let targetTeamId = typeof c.body.targetTeamId === "string" && c.body.targetTeamId === "" ? "" : str(c.body, "targetTeamId", 40);
  const crewIds = strArray(c.body, "crew", 8, 80);
  const gear = strArray(c.body, "gear", 8, 40);
  const storylineId = c.body.storylineId === undefined || c.body.storylineId === "" ? undefined : str(c.body, "storylineId", 40);
  const nudge = c.body.nudge === undefined ? undefined : oneOf(c.body, "nudge", ["expose", "soothe"] as const);
  const def = sim.OP_KINDS.find(k => k.kind === kind);
  if (!def) fail("bad_request", "unknown job");
  const sdef = (def as { storyline?: { kinds: string[] | "any"; nudge: string; only?: boolean } }).storyline;
  const w = c.L.world;
  if (storylineId) {
    if (!sdef) fail("bad_request", "this job can't be aimed at a storyline");
    if (!storylineAllowed(w, storylineId, await c.L.knownStorylines(c.acct.id))) fail("not_found", "no such storyline (or you haven't heard about it)");
    const s = w.storylines.find(x => x.id === storylineId)!;
    if (!storylineNudge({ kind, storylineId, nudge }, s.kind)) fail("bad_request", `this job doesn't work on a ${s.kind.replace(/_/g, " ")}`);
  } else if (sdef?.only) fail("bad_request", "this job needs a storyline");
  if (!gameId && !storylineId) fail("bad_request", "a job needs a game or a storyline");
  let g: GameRow | undefined;
  if (gameId) {
    g = await gameRow(c, gameId);
    if (g.level !== "ML") fail("bad_request", "jobs run on major-league games only");
    if (g.simmed || c.now >= g.first_pitch_at) fail("window_closed", "orders lock at first pitch");
    if (targetTeamId !== g.home_id && targetTeamId !== g.away_id) fail("bad_request", "target must be one of the two teams");
    const banned = bleacherBan(w, kind, g.home_id, [c.acct.id, c.acct.syndicate_id ?? undefined]);
    if (banned) fail("forbidden", banned);
  } else if (targetTeamId && !w.teams[targetTeamId]) fail("bad_request", "no such team");
  if (!targetTeamId && storylineId) {
    // aim at the arc's lead player and his club
    const s = w.storylines.find(x => x.id === storylineId)!;
    targetTeamId = w.players[s.people[0]]?.teamId ?? s.teams.find(t => w.teams[t]) ?? "";
  }
  const minCrew = Number((def as { minCrew?: number }).minCrew ?? 1);
  if (crewIds.length < minCrew || crewIds.length > def!.slots || new Set(crewIds).size !== crewIds.length) fail("bad_request", `this job takes ${minCrew}-${def!.slots} crew`);
  if (gear.some(x => !def!.gear.includes(x)) || new Set(gear).size !== gear.length) fail("bad_request", `gear for this job: ${def!.gear.join(", ") || "none"}`);
  const usable = new Map((await usableCrew(c)).map(r => [r.id, r]));
  const rows = crewIds.map(id => usable.get(id));
  if (rows.some(r => !r)) fail("bad_request", "every crew member must be free and yours (or a syndicate ally's)");
  const members = rows.map(r => ({ ...(JSON.parse(r!.data) as CrewMember), ownerId: r!.account_id }));
  const syn = c.acct.syndicate_id;
  const owners = [...new Set([c.acct.id, ...members.map(m => m.ownerId)])];
  const ban = g ? bleacherBan(w, kind, g.home_id, [...owners, syn ?? undefined]) : undefined;
  if (ban) fail("forbidden", ban);
  const view = sim.opPlannerView(w, kind, targetTeamId, members, gear, g?.umpire_id);
  const cost = view?.cost ?? def!.cost + gear.reduce((a, x) => a + gearInfo(x).cost, 0);
  const id = newId("op");
  // chip in: ask the allies whose crew are on it for their share (sim splitCost)
  const chipIn = c.body.chipIn === true;
  const shares = chipIn && syn ? allyShares({ id, ownerId: c.acct.id, kind, gameId, targetTeamId, crew: crewIds, gear, placedDay: c.L.state.day } as OpOrder,
    Object.fromEntries(members.map(m => [m.id, m]))) : {};
  const { ok } = await moneyMove(c, {
    delta: -cost, reason: "op",
    cond: `${gameId ? "EXISTS (SELECT 1 FROM games g WHERE g.id = ? AND g.simmed = 0 AND g.first_pitch_at > ?)" : "(? = '' AND ? > 0)"} AND (SELECT COUNT(*) FROM crew WHERE status = 'free' AND id IN (SELECT value FROM json_each(?))) = ?`,
    condArgs: [gameId, c.now, JSON.stringify(crewIds), crewIds.length],
    then: tx => [
      c.db.prepare(`INSERT INTO ops (id, account_id, syndicate_id, kind, game_id, target_team_id, crew, gear, placed_day, season, cost, created_at, storyline_id, nudge) SELECT ?,?,?,?,?,?,?,?,?,?,?,?,?,? WHERE ${gate()}`)
        .bind(id, c.acct.id, syn, kind, gameId, targetTeamId, JSON.stringify(crewIds), JSON.stringify(gear), c.L.state.day, c.L.state.season, cost, c.now, storylineId ?? null, nudge ?? null, tx),
      // the row status reserves them; the CrewMember snapshot stays "free" for resolveOps
      c.db.prepare(`UPDATE crew SET status = 'busy' WHERE id IN (SELECT value FROM json_each(?)) AND ${gate()}`).bind(JSON.stringify(crewIds), tx),
      ...proposeStmts(c, tx, { id, kind, targetTeamId, cost, g, lockAt: g ? g.first_pitch_at : c.now + c.L.dayMs }, shares),
    ],
  });
  if (!ok) {
    if (gameId) {
      const fresh = await gameRow(c, gameId);
      if (fresh.simmed || c.now >= fresh.first_pitch_at) fail("window_closed", "orders lock at first pitch");
    }
    if (c.acct.money < cost) fail("insufficient_funds", `this job costs $${cost}`);
    fail("bad_request", "one of your crew just got busy");
  }
  const op = await c.db.prepare("SELECT * FROM ops WHERE id = ?").bind(id).first<OpRow>();
  return { op: (await opViews(c, [op!]))[0], account: await accountView(c) };
}

export async function opViews(c: Ctx, rows: OpRow[]) {
  if (!rows.length) return [];
  const games = (await c.db.prepare("SELECT * FROM games WHERE id IN (SELECT value FROM json_each(?))").bind(JSON.stringify(rows.map(r => r.game_id))).all<GameRow>()).results;
  const views = new Map((await slateGames(c, games)).map(g => [g.id, g]));
  const crewIds = rows.flatMap(r => JSON.parse(r.crew) as string[]);
  const crewRows = new Map((await c.db.prepare("SELECT id, person_id FROM crew WHERE id IN (SELECT value FROM json_each(?))").bind(JSON.stringify(crewIds)).all<{ id: string; person_id: string }>()).results.map(r => [r.id, r.person_id]));
  const w = c.L.world;
  const chips = await chipInFor(c, rows);
  return rows.map(r => {
    const chip = chips.get(r.id);
    const outcome = r.outcome ? (JSON.parse(r.outcome) as { nudge?: { kind: string; strength: number; applied: boolean }; blocked?: string }) : undefined;
    return {
      id: r.id, kind: r.kind, name: sim.OP_KINDS.find(k => k.kind === r.kind)?.name ?? r.kind, game: views.get(r.game_id), target: teamRef(w, r.target_team_id),
      crew: (JSON.parse(r.crew) as string[]).map(id => personRef(w, crewRows.get(id) ?? id)), status: (r.status === "cancelling" ? "planned" : r.status) as "planned" | "done" | "blown" | "cancelled",
      ...(r.result && r.status !== "planned" ? { result: r.result } : {}),
      ...(r.storyline_id ? { storyline: { id: r.storyline_id, label: storylineLabel(w, r.storyline_id) } } : {}),
      ...(chip ? { chipIn: chip } : {}),
      ...(outcome?.blocked ? { blocked: outcome.blocked } : {}),
      ...(outcome?.nudge ? { nudge: { kind: outcome.nudge.kind, strength: Math.round(outcome.nudge.strength * 10) / 10, applied: outcome.nudge.applied } } : {}),
    };
  });
}

export async function ops(c: Ctx) {
  const cur = decCursor<[number, string]>(c.q.get("cursor"));
  const limit = limitParam(c, 20, 50);
  const rows = (await c.db.prepare(`SELECT * FROM ops WHERE account_id = ? ${cur ? "AND (created_at < ? OR (created_at = ? AND id < ?))" : ""} ORDER BY created_at DESC, id DESC LIMIT ?`)
    .bind(c.acct.id, ...(cur ? [cur[0], cur[0], cur[1]] : []), limit + 1).all<OpRow>()).results;
  const p = page(rows, limit, l => [l.created_at, l.id]);
  const out: { ops: unknown[]; next?: string } = { ops: await opViews(c, p.items) };
  if (p.next) out.next = encCursor(p.next);
  return out;
}
