// npm run fixtures -w @deadball/server
//
// Boots the Worker locally with a fast clock (40 s game days), plays a few days, has three
// test accounts bet, run crew jobs, comment, trade cards and form a syndicate, then writes
// a real response for every client-facing endpoint to playdate/source/fixtures/<name>.json.
// Drama props: bets on the Gossip Board's open markets, then more days until some settle.

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, sleep, startLocal } from "./local.ts";

// FIXTURES_OUT=<dir> writes somewhere else (e.g. to regenerate a few files by hand)
const OUT = process.env.FIXTURES_OUT ?? join(ROOT, "..", "..", "playdate", "source", "fixtures");
const STATE = ".wrangler/fixtures-state";
const DAY_MS = 40_000;

const written: string[] = [];
function save(name: string, body: unknown) {
  // replays are written compact (as served); everything else pretty for humans
  writeFileSync(join(OUT, `${name}.json`), (name.startsWith("game-log") || name === "game-lite" ? JSON.stringify(body) : JSON.stringify(body, null, 1)) + "\n");
  written.push(name);
}

async function main() {
  rmSync(join(ROOT, STATE), { recursive: true, force: true });
  mkdirSync(OUT, { recursive: true });
  const L = await startLocal({ persistTo: STATE, vars: { GAME_DAY_MS: String(DAY_MS), COMMENT_GAP_MS: "1000" } });
  try {
    await run(L);
  } finally {
    await L.stop();
  }
  console.log(`wrote ${written.length} fixtures to ${OUT}`);
}

async function run(L: Awaited<ReturnType<typeof startLocal>>) {
  const { ok, call } = L;
  await ok("POST", "/admin/reset", { seed: "fixtures-1" }, undefined, true);

  // --- accounts
  const reg = await ok("POST", "/register", { name: "Lefty Loot" });
  save("register", reg);
  const A = reg.token as string;
  const B = (await ok("POST", "/register", { name: "Dotty Dial" })).token as string;
  const C = (await ok("POST", "/register", { name: "Gus Gumshoe" })).token as string;
  save("error-name-taken", (await call("POST", "/register", { name: "LEFTY LOOT" })).body);
  save("error-name-rejected", (await call("POST", "/register", { name: "x" })).body);

  // --- cards: starter packs, a bought pack
  save("shop", await ok("GET", "/shop", undefined, A));
  save("pack-open", await ok("POST", "/packs/buy", { kind: "starter" }, A));
  await ok("POST", "/packs/buy", { kind: "starter" }, B);
  await ok("POST", "/packs/buy", { kind: "starter" }, C);
  const shop = await ok("GET", "/shop", undefined, A);
  const paid = shop.packs.find((p: { price: number }) => p.price > 0);
  if (paid) save("pack-open-paid", await ok("POST", "/packs/buy", { kind: paid.kind }, A));

  // --- play a few days so there are stats, standings, news
  await ok("POST", "/admin/advance", { days: 4 }, undefined, true);

  // --- crew
  save("candidates", await ok("GET", "/crew/candidates", undefined, A));
  const candsA = (await ok("GET", "/crew/candidates", undefined, A)).candidates as { id: string; ask: number }[];
  for (const cand of [...candsA].sort((x, y) => x.ask - y.ask).slice(0, 2)) {
    const r = await call("POST", "/crew/recruit", { candidateId: cand.id }, A);
    if (r.status === 200) save("recruit", r.body);
  }
  const candsB = (await ok("GET", "/crew/candidates", undefined, B)).candidates as { id: string; ask: number }[];
  await call("POST", "/crew/recruit", { candidateId: [...candsB].sort((x, y) => x.ask - y.ask)[0].id }, B);
  const candsC = (await ok("GET", "/crew/candidates", undefined, C)).candidates as { id: string; ask: number }[];
  await call("POST", "/crew/recruit", { candidateId: [...candsC].sort((x, y) => x.ask - y.ask)[0].id }, C);
  save("crew", await ok("GET", "/crew", undefined, A));

  // --- syndicate: A founds, invites B (event card), B accepts
  await ok("POST", "/syndicate", { name: "Night Owls" }, A);
  save("syndicate-invite", await ok("POST", "/syndicate/invite", { accountName: "Dotty Dial" }, A));
  save("events-invite", await ok("GET", "/events", undefined, B));
  const inv = (await ok("GET", "/syndicate", undefined, B)).invites[0];
  save("syndicate-accept", await ok("POST", `/syndicate/invites/${inv.id}/accept`, undefined, B));
  save("syndicate-treasury", await ok("POST", "/syndicate/treasury", { amount: 100 }, B));

  // --- comments & market (before the games, so there's a story to comment on)
  const news0 = await ok("GET", "/news", undefined, A);
  const words = await ok("GET", "/words", undefined, A);
  save("words", words);
  const story0 = news0.stories[0];
  const draft = (seed: number) => {
    const t = words.templates[seed % words.templates.length];
    return { template: t.id, words: t.slots.map((s: string, i: number) => words.slots[s][(seed * 7 + i * 3) % words.slots[s].length]) };
  };
  const c1 = await ok("POST", "/comments", { thread: `story:${story0.id}`, ...draft(1) }, A);
  save("comment-post", c1);
  await ok("POST", "/comments", { thread: `story:${story0.id}`, ...draft(2) }, B);
  await ok("POST", "/comments", { thread: `story:${story0.id}`, ...draft(3) }, C);
  save("error-rate-limited", (await call("POST", "/comments", { thread: `story:${story0.id}`, ...draft(4) }, A)).body);
  save("error-invalid-comment", (await call("POST", "/comments", { thread: "bbs:general", template: draft(1).template, words: ["not a real word"] }, B)).body);
  await sleep(1100);
  save("comment-react", await ok("POST", `/comments/${c1.comment.id}/react`, { kind: "lol" }, B));
  await ok("POST", `/comments/${c1.comment.id}/react`, { kind: "agree" }, C);
  await ok("POST", "/comments", { thread: "bbs:general", ...draft(5) }, B);
  await sleep(1100);
  await ok("POST", "/comments", { thread: `bbs:syn:${(await ok("GET", "/me", undefined, A)).account.syndicateId}`, ...draft(6) }, B);

  // --- redeemable cards: C redeems a Gilded BOOST; A redeems an Original RETIRE (A keeps a copy -> Final Season)
  // boost and retire two different players so the demos read sensibly side by side
  const slate = await ok("GET", "/today", undefined, A);
  const boostTarget = slate.games[0]?.probables?.home?.id;
  const retireTarget = slate.games[1]?.probables?.away?.id ?? slate.games[0]?.probables?.away?.id;
  const boostCard = await ok("POST", "/admin/card", { account: "Gus Gumshoe", rarity: "gilded", redeem: "boost", ...(boostTarget ? { personId: boostTarget } : {}) }, undefined, true);
  save("redeem-boost", await ok("POST", `/cards/${boostCard.id}/redeem`, { confirm: true }, C));
  const retireCard = await ok("POST", "/admin/card", { account: "Lefty Loot", rarity: "original", kind: "player", redeem: "retire", ...(retireTarget ? { personId: retireTarget } : {}) }, undefined, true);
  await ok("POST", "/admin/card", { account: "Lefty Loot", rarity: "rare", personId: retireCard.card.personId }, undefined, true);
  save("redeem-retire", await ok("POST", `/cards/${retireCard.id}/redeem`, { confirm: true }, A));
  save("bulletins", await ok("GET", "/bulletins", undefined, B));

  const binderA = await ok("GET", "/cards", undefined, A);
  save("cards", binderA);
  save("card", await ok("GET", `/cards/${binderA.cards[0].id}`, undefined, A));
  // --- market: fixed-price listings and auctions
  save("market-list", await ok("POST", "/market", { cardId: binderA.cards[0].id, price: 45 }, A));
  await ok("POST", "/market", { cardId: binderA.cards[1].id, price: 120 }, A);
  const binderB = await ok("GET", "/cards", undefined, B);
  await ok("POST", "/market", { cardId: binderB.cards[0].id, price: 15 }, B);
  await ok("POST", "/market", { cardId: binderB.cards[2].id, price: 300 }, B);
  const market0 = await ok("GET", "/market", undefined, C);
  const fixedA = market0.listings.find((l: { seller: string }) => l.seller === "Lefty Loot");
  save("market-buy", await ok("POST", `/market/${fixedA.id}/buy`, undefined, C));
  save("price-history", await ok("GET", `/market/history?def=${fixedA.card.defId}`, undefined, B));
  const auctionCard = await ok("POST", "/admin/card", { account: "Lefty Loot", rarity: "gilded", redeem: "boost" }, undefined, true);
  const auctionA = (await ok("POST", "/market", { cardId: auctionCard.id, kind: "auction", startBid: 60, hours: 24, reserve: 200, buyNow: 600 }, A)).listing;
  await ok("POST", "/market", { cardId: binderB.cards[3].id, kind: "auction", startBid: 10, hours: 6 }, B);
  save("market-bid", await ok("POST", `/market/${auctionA.id}/bid`, { max: 150 }, C));
  await ok("POST", `/market/${auctionA.id}/bid`, { max: 110 }, B); // outbid at once by C's proxy
  save("market-auction", await ok("GET", `/market/${auctionA.id}`, undefined, C));
  const auctionB = (await ok("GET", "/market?kind=auction&sort=ending", undefined, C)).listings.find((l: { seller: string }) => l.seller === "Dotty Dial");
  await ok("POST", `/market/${auctionB.id}/watch`, undefined, C);
  save("watchlist", await ok("GET", "/watchlist", undefined, C));
  save("market", await ok("GET", "/market", undefined, A));

  // --- drama props: play on until the Gossip Board has a few open markets, then bet them
  type PropFx = { id: string; status: string; options: { key: string }[] };
  type ItemFx = { id: string; props: PropFx[] };
  const openItems = (b: { storylines: ItemFx[] }) => b.storylines.filter(s => s.props.some(p => p.status === "open"));
  let board = await ok("GET", "/props", undefined, A);
  for (let i = 0; i < 15 && openItems(board).length < 3; i++) {
    await ok("POST", "/admin/advance", { days: 1 }, undefined, true);
    board = await ok("GET", "/props", undefined, A);
  }
  const items = openItems(board);
  if (!items.length) console.warn("no open prop markets for the fixtures");
  let placedProp = false;
  for (const [i, it] of items.slice(0, 5).entries()) {
    for (const p of it.props.filter(q => q.status === "open")) {
      const q = p.id.slice(p.id.lastIndexOf(":") + 1);
      // A spreads small bets; B and C take the other side so the pools have two sides
      // ":when" questions all settle within 31 days, so A wins some ("later") and loses some
      const pickA = q === "yes" ? "yes" : q === "when" ? (i % 2 ? "d15" : "later") : p.options[0].key;
      const r = await call("POST", "/props/bets", { propId: p.id, option: pickA, amount: 10 + 5 * i }, A);
      if (r.status === 200 && !placedProp) { save("prop-bet-place", r.body); placedProp = true; }
      const other = q === "when" && pickA !== "later" ? "later" : p.options.find(o => o.key !== pickA)?.key;
      if (other) await call("POST", "/props/bets", { propId: p.id, option: other, amount: 35 }, i % 2 ? B : C);
    }
  }
  const closedProp = board.storylines.flatMap((s: ItemFx) => s.props).find((p: PropFx) => p.status === "closed");
  if (closedProp) save("error-prop-closed", (await call("POST", "/props/bets", { propId: closedProp.id, option: closedProp.options[0].key, amount: 10 }, A)).body);
  save("props", await ok("GET", "/props", undefined, A));
  if (items[0]) save("props-storyline", await ok("GET", `/props?storyline=${items[0].id}`, undefined, A));
  save("props-bets-open", await ok("GET", "/props/bets?status=open", undefined, A));

  // fresh day: the clock restarts with ~10 s of betting window before first pitch
  await ok("POST", "/admin/advance", { days: 1 }, undefined, true);

  // --- today's slate (scheduled): bets + an op
  const today = await ok("GET", "/today", undefined, A);
  const g0 = today.games[0], g1 = today.games[1], g2 = today.games[2];
  save("bet-place", await ok("POST", "/bets", { gameId: g0.id, side: "home", amount: 100 }, A));
  await ok("POST", "/bets", { gameId: g0.id, side: "away", amount: 150 }, B);
  await ok("POST", "/bets", { gameId: g1.id, side: "away", amount: 60 }, A);
  await ok("POST", "/bets", { gameId: g1.id, side: "home", amount: 40 }, C);
  await ok("POST", "/bets", { gameId: g2.id, side: "home", amount: 25 }, C);
  // an Enhanced League game too (three a day, their own pools)
  const gel = today.games.find((g: { circuit: string }) => g.circuit === "enhanced");
  if (gel) {
    await ok("POST", "/bets", { gameId: gel.id, side: "away", amount: 30 }, A);
    await ok("POST", "/bets", { gameId: gel.id, side: "home", amount: 45 }, B);
  } else console.warn("no Enhanced League game on the fixture slate");
  save("error-bad-bet", (await call("POST", "/bets", { gameId: g0.id, side: "away", amount: 10 }, A)).body);
  save("ops-catalog", await ok("GET", `/ops/catalog?game=${g0.id}`, undefined, A));
  const catalog = await ok("GET", `/ops/catalog?game=${g0.id}`, undefined, A);
  const crewA = (await ok("GET", "/crew", undefined, A)).crew as { id: string }[];
  const crewB = (await ok("GET", "/crew", undefined, B)).crew as { id: string }[];
  const crewC = (await ok("GET", "/crew", undefined, C)).crew as { id: string }[];
  const kind = catalog.kinds.find((k: { slots: number; kind: string }) => k.slots >= 2 && k.kind !== "security") ?? catalog.kinds[0];
  const joint = [crewA[0]?.id, crewB[0]?.id].filter(Boolean).slice(0, kind.slots);
  // a joint job with B's crew; A asks B to chip in
  const op = await call("POST", "/ops", { kind: kind.kind, gameId: g0.id, targetTeamId: g0.away.id, crew: joint, gear: [], chipIn: true }, A);
  if (op.status === 200) save("op-order", op.body);
  else console.warn("op order failed", op.body);
  let second: string | undefined;
  if (crewA[1]) {
    const k2 = catalog.kinds.find((k: { kind: string }) => k.kind !== kind.kind && k.kind !== "security") ?? kind;
    second = (await call("POST", "/ops", { kind: k2.kind, gameId: g1.id, targetTeamId: g1.home.id, crew: [crewA[1].id], gear: [] }, A)).body?.op?.id;
  }
  // a rival defends the target
  const sec = catalog.kinds.find((k: { kind: string }) => k.kind === "security");
  if (sec && crewC[0]) await call("POST", "/ops", { kind: "security", gameId: g0.id, targetTeamId: g0.away.id, crew: [crewC[0].id], gear: [] }, C);
  // chip in: B sees the ask on the syndicate page and pays; A calls the second job off (refunded)
  save("syndicate-chipin", await ok("GET", "/syndicate", undefined, B));
  if (op.status === 200) {
    const yes = await call("POST", `/ops/${op.body.op.id}/chipin`, { accept: true }, B);
    if (yes.status === 200) save("chipin-accept", yes.body);
    else console.warn("chip in failed", yes.body);
  }
  if (second) {
    const off = await call("DELETE", `/ops/${second}`, undefined, A);
    if (off.status === 200) save("op-cancel", off.body);
    else console.warn("cancel failed", off.body);
  }
  save("ops", await ok("GET", "/ops", undefined, A));
  save("today", await ok("GET", "/today", undefined, A));
  save("bets-open", await ok("GET", "/bets?status=open", undefined, A));
  save("schedule", await ok("GET", `/schedule?team=${g0.home.abbr}`, undefined, A));

  save("thread-guestbook-post", await ok("POST", "/comments", { thread: `person:${g0.probables.home.id}`, ...draft(7) }, C));

  // --- wait for the first pitch: live snapshots (g0 live, later games still taking bets)
  const first = g0.firstPitchAt as number;
  const clockNow = (await ok("GET", "/clock")).now as number;
  await sleep(Math.max(0, first - clockNow) + 9_000);
  save("today-live", await ok("GET", "/today", undefined, A));
  save("game-live", await ok("GET", `/games/${g0.id}`, undefined, A));
  save("game-log-live", await ok("GET", `/games/${g0.id}/log`, undefined, A));
  save("game-logc-live", await ok("GET", `/games/${g0.id}/log?fmt=c`, undefined, A));
  save("game-wire-live", await ok("GET", `/games/${g0.id}/wire`, undefined, A));
  save("clock", await ok("GET", "/clock"));

  // --- wait for the finals + settlement. First pitches are staggered, so the day's last games
  // are still on the air after the next day has started (and /today has moved on to it)
  const dayIds = (today.games as { id: string; day: number }[]).filter(g => g.day === today.day).map(g => g.id);
  for (let i = 0; i < 60; i++) {
    await sleep(2_000);
    const b = await ok("GET", "/bets?status=settled", undefined, A);
    const st = await Promise.all(dayIds.map(id => ok("GET", `/games/${id}?lite=1`, undefined, A)));
    if (b.bets.length >= 2 && st.every((g: { status: string }) => g.status === "final")) break;
  }
  // the betting day as it ended: every game's slate view (a game detail minus the box score)
  const finals: Record<string, unknown>[] = [];
  for (const id of dayIds) {
    const d = await ok("GET", `/games/${id}`, undefined, A);
    save(`game-${id}`, d);
    const { box: _b, line: _l, decisions: _d, incidents: _i, notes: _n, storyId: _s, ...slateView } = d;
    finals.push(slateView);
  }
  save("today-final", { day: today.day, games: finals });
  save("game", await ok("GET", `/games/${g0.id}`, undefined, A));
  save("game-lite", await ok("GET", `/games/${g0.id}?lite=1`, undefined, A));
  // full replay: concatenate pages
  const page0 = await ok("GET", `/games/${g0.id}/log`, undefined, A);
  const full = { ...page0, log: [...page0.log] };
  let next = page0.next;
  while (next !== undefined) {
    const p = await ok("GET", `/games/${g0.id}/log?from=${next}`, undefined, A);
    full.log.push(...p.log);
    next = p.next;
  }
  delete full.next;
  full.from = 0;
  save("game-log", full);
  save("game-logc", await ok("GET", `/games/${g0.id}/log?fmt=c`, undefined, A));
  save("game-log-page", page0);
  save("game-wire", await ok("GET", `/games/${g0.id}/wire`, undefined, A));
  save("bets", await ok("GET", "/bets?status=settled", undefined, A));
  save("ops-done", await ok("GET", "/ops", undefined, A));
  // While You Were Out: everything that settled since the betting day (bets, the jobs, net)
  save("digest", await ok("GET", `/digest?sinceDay=${today.day}`, undefined, A));
  save("mail", await ok("GET", "/mail", undefined, A));
  const mailA = await ok("GET", "/mail", undefined, A);
  if (mailA.mail[0]) save("mail-read", await ok("POST", `/mail/${mailA.mail[0].id}/read`, undefined, A));
  save("mail-b", await ok("GET", "/mail", undefined, B));
  save("mail-c", await ok("GET", "/mail", undefined, C));

  const detail0 = await ok("GET", `/games/${g0.id}`, undefined, A);

  // event cards: run risky jobs until somebody gets one (arrests, snitches, reporters...)
  const findEvent = async () => {
    for (const tok of [A, B, C]) {
      const ev = await ok("GET", "/events", undefined, tok);
      if (ev.events.length) return { tok, ev };
    }
    return undefined;
  };
  let found = await findEvent();
  for (let round = 0; !found && round < 6; round++) {
    const slate = (await ok("GET", "/today", undefined, A)).games.filter((g: { status: string }) => g.status === "scheduled");
    const risky = catalog.kinds.filter((k: { risk: string; kind: string }) => k.kind !== "security" && (k.risk === "high" || k.risk === "lol"));
    let gi = 0;
    for (const tok of [A, B, C]) {
      const free = ((await ok("GET", "/crew", undefined, tok)).crew as { id: string; status: string }[]).filter(x => x.status === "free");
      for (const m of free) {
        const g = slate[gi++ % Math.max(1, slate.length)];
        const k = risky[gi % Math.max(1, risky.length)] ?? kind;
        if (g) await call("POST", "/ops", { kind: k.kind, gameId: g.id, targetTeamId: g.home.id, crew: [m.id], gear: [] }, tok);
      }
    }
    await ok("POST", "/admin/advance", { days: 1 }, undefined, true);
    found = await findEvent();
  }
  if (found) {
    save("events", found.ev);
    const card = found.ev.events[0];
    const choice = card.choices.find((ch: { cost?: number }) => !ch.cost) ?? card.choices[0];
    const r = await call("POST", `/events/${card.id}/choose`, { key: choice.key }, found.tok);
    if (r.status === 200) save("event-choose", r.body);
    else console.warn("choose failed", r.body);
    save("mail-after-events", await ok("GET", "/mail", undefined, found.tok));
  } else {
    console.warn("no event cards were produced");
    save("events", { events: [] });
  }

  const news = await ok("GET", "/news", undefined, A);
  save("news", news);
  let recapId = detail0.storyId as string | undefined;
  if (!recapId) recapId = (news.stories.find((s: { kind: string }) => s.kind === "recap") ?? news.stories[0]).id;
  const recap = { id: recapId };
  save("story", await ok("GET", `/news/${recap.id}`, undefined, A));
  const scandal = news.stories.find((s: { kind: string }) => s.kind === "scandal");
  if (scandal) save("story-scandal", await ok("GET", `/news/${scandal.id}`, undefined, A));
  const life = news.stories.find((s: { kind: string }) => s.kind === "life");
  if (life) save("story-life", await ok("GET", `/news/${life.id}`, undefined, A));
  if (news.next) save("news-page2", await ok("GET", `/news?cursor=${news.next}`, undefined, A));
  save("thread", await ok("GET", `/threads/story:${story0.id}`, undefined, A));
  save("thread-bbs", await ok("GET", "/threads/bbs:general", undefined, A));

  const detail = await ok("GET", `/games/${g0.id}`, undefined, A);
  const star = detail.decisions?.w?.id ?? g0.probables.home.id;
  save("person", await ok("GET", `/people/${star}`, undefined, A));
  save("person-batter", await ok("GET", `/people/${detail.box.home.bat[2].p.id}`, undefined, A));
  save("person-umpire", await ok("GET", `/people/${g0.umpire.id}`, undefined, A));
  save("team", await ok("GET", `/teams/${g0.home.id}`, undefined, A));
  save("team-farm", await ok("GET", `/teams/${g0.home.id}-AA`, undefined, A).catch(() => ({})));
  save("standings", await ok("GET", "/standings?level=ML", undefined, A));
  save("standings-aa", await ok("GET", "/standings?level=AA", undefined, A));
  save("standings-EL", await ok("GET", "/standings?level=EL", undefined, A));
  save("schedule-EL", await ok("GET", "/schedule?level=EL", undefined, A));
  save("me", await ok("GET", "/me", undefined, A));
  await captureBonus(L, A, B, draft);
  save("crew-after", await ok("GET", "/crew", undefined, A));
  save("syndicate", await ok("GET", "/syndicate", undefined, A));
  save("syndicate-leaderboard", await ok("GET", "/syndicates/leaderboard", undefined, A));
  save("today-next", await ok("GET", "/today", undefined, A).catch(() => ({})));

  // --- hostile owners: A's crew is known at one park (bleacher jobs banned there, guards on that club)
  const nextG = ((await ok("GET", `/schedule?team=${g0.home.abbr}`, undefined, A)).games as { id: string; status: string; circuit: string; home: { id: string }; away: { id: string } }[])
    .find(g => g.status === "scheduled" && g.circuit === "continental");
  if (nextG) {
    await ok("POST", "/admin/grudge", { account: "Lefty Loot", team: nextG.home.id, level: 3 }, undefined, true);
    const banned = await call("GET", `/ops/catalog?game=${nextG.id}`, undefined, A);
    if (banned.status === 200) save("ops-catalog-banned", banned.body);
    else console.warn("banned catalog failed", banned.body);
    const anyCrew = ((await ok("GET", "/crew", undefined, A)).crew as { id: string }[])[0];
    save("error-banned", (await call("POST", "/ops", { kind: "laser", gameId: nextG.id, targetTeamId: nextG.away.id, crew: anyCrew ? [anyCrew.id] : [], gear: [] }, A)).body);
    await ok("POST", "/admin/grudge", { account: "Lefty Loot", team: nextG.home.id, level: 0 }, undefined, true);
  } else console.warn("no scheduled game for the bleacher-ban fixtures");
  save("error-unauthorized", (await call("GET", "/me")).body);
  save("error-not-found", (await call("GET", "/games/nope", undefined, A)).body);
  save("error-window-closed", (await call("POST", "/bets", { gameId: g0.id, side: "home", amount: 10 }, A)).body);
  save("thread-bbs-rumors", await ok("GET", "/threads/bbs:rumors", undefined, A));

  // --- drama props, later: play on until some of A's props settle (":when" questions settle within 31 days)
  let settledProps = await ok("GET", "/props/bets?status=settled", undefined, A);
  for (let i = 0; i < 12 && settledProps.bets.length < 2; i++) {
    await ok("POST", "/admin/advance", { days: 3 }, undefined, true);
    settledProps = await ok("GET", "/props/bets?status=settled", undefined, A);
  }
  if (!settledProps.bets.length) console.warn("no prop bets settled for the fixtures");
  save("props-bets-settled", settledProps);
  // the Gossip Board page doc: open markets, rumour chatter, A's open and settled props
  save("gossip", await ok("GET", "/gossip", undefined, A));
  // A's inbox now has the prop results (Bets By Bobby bank mail)
  save("mail-props", await ok("GET", "/mail", undefined, A));
}

/**
 * Loyalty card & odd jobs: A has punched three days running (the admin knob moves the punches
 * back a day at a time), does a few things the odd jobs count, claims one, and then the board
 * (bonus.json: today not punched yet, so the client shows the punch moment) and the punch.
 */
export async function captureBonus(L: Awaited<ReturnType<typeof startLocal>>, A: string, B: string, draft: (seed: number) => { template: string; words: string[] }, out = save) {
  const { ok, call } = L;
  const name = (await ok("GET", "/me", undefined, A)).account.name as string;
  for (let i = 0; i < 3; i++) {
    await ok("POST", "/bonus/punch", undefined, A);
    await ok("POST", "/admin/bonus", { account: name, shiftDays: 1 }, undefined, true);
  }
  const board0 = await ok("GET", "/bonus", undefined, A);
  // do what the board asks where it's quick: a bet, a post, a reaction, a pack
  const games = (await ok("GET", "/today", undefined, A)).games.filter((g: { status: string }) => g.status === "scheduled");
  for (const j of board0.jobs as { kind: string }[]) {
    if ((j.kind === "bet" || j.kind === "bet3" || j.kind === "underdog") && games.length) {
      for (const g of games.slice(0, j.kind === "bet3" ? 3 : 1)) {
        const side = j.kind === "underdog" && g.pool.pays.away > g.pool.pays.home ? "away" : "home";
        await call("POST", "/bets", { gameId: g.id, side, amount: 10 }, A);
      }
    } else if (j.kind === "bbs" || j.kind === "story") {
      const thread = j.kind === "bbs" ? "bbs:general" : `story:${(await ok("GET", "/news", undefined, A)).stories[0].id}`;
      await sleep(1100);
      await call("POST", "/comments", { thread, ...draft(11) }, A);
    } else if (j.kind === "react") {
      await sleep(1100);
      const c = await call("POST", "/comments", { thread: "bbs:general", ...draft(12) }, B);
      if (c.status === 200) await call("POST", `/comments/${c.body.comment.id}/react`, { kind: "agree" }, A);
    } else if (j.kind === "pack") {
      const paid = (await ok("GET", "/shop", undefined, A)).packs.find((p: { price: number }) => p.price > 0);
      if (paid) await call("POST", "/packs/buy", { kind: paid.kind }, A);
    }
  }
  const board1 = await ok("GET", "/bonus", undefined, A);
  const done = (board1.jobs as { id: string; status: string }[]).filter(j => j.status === "done");
  if (done[0]) out("bonus-claim", await ok("POST", `/bonus/jobs/${done[0].id}/claim`, undefined, A));
  else console.warn("no odd job finished for the fixtures");
  out("bonus", await ok("GET", "/bonus", undefined, A));
  out("bonus-punch", await ok("POST", "/bonus/punch", undefined, A));
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});
