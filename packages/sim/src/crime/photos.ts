// Archive pictures for mail and event cards (see ../archive.ts). Deterministic: the picture is
// chosen from the item's tags with its id as the seed. Never overwrites a photo already set.

import { illustrate, MAIL_TAGS, OP_TAGS, TROUBLE_TAGS } from "../archive.ts";
import type { EventCard, MailItem } from "./types.ts";

export function cardTags(card: EventCard): string[] {
  const op = OP_TAGS[card.ctx?.opKind ?? ""] ?? [];
  const k = card.ctx?.rivalOrderId ? "turf" : card.kind ?? "syndicate";
  const trouble = TROUBLE_TAGS[k] ?? TROUBLE_TAGS.heat;
  return [...trouble, ...op];
}

export function mailTags(m: MailItem, opKind?: string): string[] {
  const op = OP_TAGS[opKind ?? ""] ?? [];
  const base = MAIL_TAGS[m.kind] ?? [];
  return m.kind === "op" ? [...op, ...base] : [...base, ...op];
}

export function cardPhoto(card: EventCard): EventCard {
  if (!card.photo) Object.assign(card, illustrate(cardTags(card), `card:${card.id}`));
  return card;
}

export function mailPhoto(m: MailItem, opKind?: string): MailItem {
  if (!m.photo) Object.assign(m, illustrate(mailTags(m, opKind), `mail:${m.id}`));
  return m;
}
