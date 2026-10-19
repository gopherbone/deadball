// League bulletin for a redeemed card: plain, factual, public. Names the redeemer.

import type { World, Person } from "../types.ts";
import type { Story } from "../news/types.ts";
import { DEK_MAX, HEADLINE_MAX } from "../news/types.ts";
import { fit } from "../news/util.ts";
import { personById } from "../life/people.ts";
import { RARITY_LABEL } from "../cards/data.ts";
import type { Card } from "../cards/model.ts";
import type { RedeemResult } from "./index.ts";
import { illustrate, lifeTags } from "../archive.ts";

const nameOf = (p: Person | undefined) => (p ? `${p.first} ${p.last}` : "an unidentified person");

function cardName(card: Card): string {
  if (card.rarity === "original") return "the Original 1/1";
  const serial = card.serial && card.printRun ? ` #${String(card.serial).padStart(String(card.printRun).length, "0")}/${card.printRun}` : "";
  return `a ${RARITY_LABEL[card.rarity]}${serial}`;
}

export function writeRedeemBulletin(world: World, r: RedeemResult, card: Card, redeemer = "A collector"): Story {
  const p = personById(world, r.personId);
  const last = p?.last ?? "Somebody";
  const t = r.teamIds[0] ? world.teams[r.teamIds[0]] : undefined;
  const where = t ? `${t.city} ${t.name}` : "";
  const pos = (p as { pos?: string } | undefined)?.pos ?? (p as { role?: string } | undefined)?.role;
  const body: string[] = [];
  let headline: string, dek: string;
  if (r.kind === "boost") {
    const hitter = !(world.players[r.personId]?.pitching);
    const what = hitter ? "contact, power and eye" : "stuff and control";
    headline = fit([`Card Redeemed: ${last} Boosted +${r.boost} for ${r.days} Days`, `Redeemed: ${last} +${r.boost} for ${r.days} Days`, `Redeemed: ${last} Boosted`], HEADLINE_MAX);
    dek = fit([`${redeemer} redeemed ${cardName(card)} ${nameOf(p)} card: +${r.boost} ${what} through day ${r.untilDay}`, `+${r.boost} ${what} for ${r.days} game days`], DEK_MAX);
    body.push(`${redeemer} redeemed ${cardName(card)} card of ${nameOf(p)}${where ? ` (${where}${pos ? `, ${pos}` : ""})` : ""}.`);
    body.push(`Effect: +${r.boost} ${what} for ${r.days} game days, days ${r.fromDay} through ${r.untilDay}. It applies in every game ${last} plays in that window.`);
    body.push("The card has been taken out of circulation.");
  } else {
    headline = fit([`Card Redeemed: ${last} Retired`, `Redeemed: ${last} Retires`], HEADLINE_MAX);
    dek = fit([`${nameOf(p)}${where ? ` (${t!.abbr})` : ""} retires from baseball after ${redeemer} redeemed ${cardName(card)} card`, `${nameOf(p)} retires from baseball, effective immediately`], DEK_MAX);
    body.push(`${nameOf(p)}${where ? ` (${where}${pos ? `, ${pos}` : ""}${p ? `, age ${p.age}` : ""})` : ""} has retired from baseball, effective immediately. ${redeemer} redeemed ${cardName(card)} card.`);
    const callups = r.life.filter(e => e.kind === "callup" && (!t || (e.teams ?? []).includes(t.id)));
    if (callups.length) body.push(`To fill the spot: ${callups.map(e => { const c = personById(world, e.who[0]); const from = world.teams[String(e.data?.from ?? "")]; return `${nameOf(c)} called up${from ? ` from ${from.city}` : ""}`; }).join("; ")}.`);
    const hire = r.life.find(e => e.kind === "hire" || e.kind === "succession");
    if (hire) body.push(`Replacement: ${nameOf(personById(world, hire.who[0]))}.`);
    body.push(`Remaining ${last} cards are now Final Season editions.`);
  }
  const faceIds = p?.face ? [p.face] : [];
  const tags = r.kind === "retire" ? lifeTags("retirement") : lifeTags("milestone");
  const pic = illustrate(tags.length ? tags : ["baseball"], `redeem:${r.id}`);
  return {
    id: `redeem-${r.id}`, day: world.day, kind: "brief", headline, dek, body, faceIds, people: [r.personId], teams: r.teamIds, section: "Bulletin", ...pic,
  };
}
