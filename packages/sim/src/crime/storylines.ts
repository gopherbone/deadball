// Storyline targets for crew ops. A crew can push an open drama arc (life/storylines.ts):
// expose it, inflame it or soothe it. Public and rumoured arcs are open to everyone; secret
// ones only to accounts that learned of them from a tip (MailItem.storylineId).

import type { Storyline, World } from "../types.ts";
import { OP_KINDS, storylineNudge } from "./ops.ts";
import type { CrewNudge } from "./types.ts";

export interface StorylineTarget {
  storylineId: string;
  kind: string;
  stage: string;
  visibility: "secret" | "rumoured" | "public";
  people: string[];
  teams: string[];
  /** Plain label for the planner: "Mullane: affair (rumoured)". */
  label: string;
  /** Op kinds that can aim at it, with what each would do. */
  ops: { kind: string; nudge: CrewNudge | "choice" }[];
}

const KIND_LABEL: Record<string, string> = {
  affair: "affair", marriage_trouble: "marriage trouble", feud: "feud", rivalry: "rivalry", gambling_debt: "gambling debt",
  hot_seat: "job in danger", holdout: "holdout", slump: "slump", curse: "curse", comeback: "comeback", contract_year: "contract year",
  rookie_watch: "rookie watch", stalker: "stalker", weird: "missing",
};

const nameOf = (world: World, id: string | undefined) => {
  const p = id ? world.players[id] ?? world.npcs[id] : undefined;
  return p ? `${p.first} ${p.last}` : "Unknown";
};

/**
 * Storylines an account can aim crew ops at. `known` = secret storyline ids this account has
 * been tipped about (the server keeps them from tip mail's storylineId).
 */
export function storylineTargets(world: World, known: string[] = []): StorylineTarget[] {
  const k = new Set(known);
  const out: StorylineTarget[] = [];
  for (const s of (world.storylines ?? []) as Storyline[]) {
    if (s.resolved) continue;
    if (s.visibility === "secret" && !k.has(s.id)) continue;
    const ops = OP_KINDS.filter(d => d.storyline && storylineNudge({ kind: d.kind, storylineId: s.id }, s.kind))
      .map(d => ({ kind: d.kind, nudge: d.storyline!.nudge }));
    if (!ops.length) continue;
    out.push({
      storylineId: s.id, kind: s.kind, stage: s.stage, visibility: s.visibility, people: [...s.people], teams: [...s.teams],
      label: `${nameOf(world, s.people[0])}: ${KIND_LABEL[s.kind] ?? s.kind.replace(/_/g, " ")} (${s.visibility})`, ops,
    });
  }
  return out;
}

/** Is this storyline a legal target for this account? */
export function storylineAllowed(world: World, storylineId: string, known: string[] = []): boolean {
  return storylineTargets(world, known).some(t => t.storylineId === storylineId);
}
