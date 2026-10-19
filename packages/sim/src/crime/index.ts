// Crew, recruitment, operations, heat, arrests, mail and event cards.
// Flow per game day (server): leakTips (when orders are placed / at day start) →
// resolveOps (first pitch: modifiers into GameSpec) → simulateGame → afterGame
// (exposure, arrests, mail, cards, stories) → resolveChoice (when the player answers).

export * from "./types.ts";
export { OP_KINDS, GEAR, opKind, opChance, opModifiers, opPlannerView, groupSkill, pickVictim, storylineNudge, RISK_EXPOSURE, RISK_HEAT, type PlannerCtx } from "./ops.ts";
export { ROLES, roleDef, makeCitizen, citizenName, type RoleDef } from "./npcs.ts";
export { recruitPool, hireCandidate, tickCrew, crewName, crewRoleLabel, CANDIDATES_PER_DAY } from "./recruit.ts";
export { resolveOps, participants, splitCost, splitHeat, crewAllowed, SECURITY_KIND } from "./resolve.ts";
export { afterGame, settleOps, exposureChance, type AfterGameResult } from "./after.ts";
export { resolveChoice, arrestCard, snitchCard, hospitalCard, heatCard, namedCard, turfCard, type ChoiceResult } from "./events.ts";
export { leakTips, dramaTips, secretTips, type TipOpts } from "./tips.ts";
export { storylineTargets, storylineAllowed, type StorylineTarget } from "./storylines.ts";
export { cardPhoto, mailPhoto, cardTags, mailTags } from "./photos.ts";
export { syndicateStandings, canJoin, SYNDICATE_MAX, type Syndicate, type SyndicateStanding } from "./syndicate.ts";
export {
  grudge, hostility, teamHostility, angerFaction, securityDetail, guardNote, bleacherBan, grudgeParties, grudgesAgainst, coolGrudges, grudgeMail, leanOnPress,
  GRUDGE_COOL_DAYS, GRUDGE_MAX, BAN_AT, PRESS_AT, type GrudgeChange, type PressParty, type PressResult,
} from "./hostility.ts";
