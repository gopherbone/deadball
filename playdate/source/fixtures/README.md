# Fixtures

Real server responses for every client-facing endpoint in `docs/API.md`, captured by
`npm run fixtures -w @deadball/server`. That script boots the Worker locally (workerd with
local D1/R2/Durable Objects) on a fast 40-second game day, plays a few days, and has three
test accounts (Lefty Loot, Dotty Dial, Gus Gumshoe) bet, run crew jobs, comment,
trade cards and form a syndicate. Regenerate any time. Ids, times and names change on each
run, so don't hard-code them.

Responses are the exact JSON bodies. `game-log*.json` are compact (as served); the rest are
pretty-printed. Times are epoch ms from the run, so for the clock offset use `clock.json`'s `now`.

| File | Endpoint | Notes |
|---|---|---|
| register.json | POST /v1/register | `{ token, account }` |
| me.json | GET /v1/me | account after a few days (in a syndicate) |
| clock.json | GET /v1/clock | taken while games were live |
| today.json | GET /v1/today | scheduled slate, betting open, with `myBet` |
| today-live.json | GET /v1/today | same slate mid-broadcast (`score.inning` like "BOT 3") |
| today-final.json | GET /v1/today | same slate after the finals |
| today-next.json | GET /v1/today | the following day |
| game.json, game-&lt;id&gt;.json | GET /v1/games/:id | final GameDetail (box, line, decisions, incidents, storyId) |
| game-live.json | GET /v1/games/:id | live GameDetail (partial line + aired incidents, no box) |
| game-log.json | GET /v1/games/:id/log | one full replay (all pages joined, `from: 0`, no `next`) |
| game-log-page.json | GET /v1/games/:id/log | first page as served (`next` = index for `?from=`) |
| game-log-live.json | GET /v1/games/:id/log | while live: only events aired so far |
| game-wire.json, game-wire-live.json | GET /v1/games/:id/wire | telegraph lines keyed to log index |
| standings.json, standings-aa.json | GET /v1/standings?level= | rows also carry `team` (TeamRef) |
| schedule.json | GET /v1/schedule?team= | SlateGame list, default window today-3..today+7 |
| standings-EL.json | GET /v1/standings?level=EL | the Enhanced League (six desert clubs); `playoff` = Mirage Cup bracket when running |
| schedule-EL.json | GET /v1/schedule?level=EL | Enhanced games + exhibitions, yesterday..+3 |
| gossip.json | GET /v1/gossip | Gossip Board page doc: storylines with prop markets, BBS chatter, A's open + settled props |
| props.json, props-storyline.json | GET /v1/props[?storyline=] | open prop markets grouped by storyline |
| prop-bet-place.json | POST /v1/props/bets | `{ bet, prop, account }` |
| props-bets-open.json, props-bets-settled.json | GET /v1/props/bets?status= | A's prop bets (settled ones won, lost or refunded) |
| error-prop-closed.json | POST /v1/props/bets | `window_closed` on a closed question (only written when the run had one) |
| mail-props.json | GET /v1/mail | A's inbox at the end, with "Prop won/lost/refunded" bank mail |
| digest.json | GET /v1/digest?sinceDay= | A's "While You Were Out" after the bets and jobs of the betting day settled |
| thread-bbs-rumors.json | GET /v1/threads/bbs:rumors | NPC rumour-mill chatter |
| bet-place.json | POST /v1/bets | `{ bet, pool, account }` |
| bets-open.json, bets.json | GET /v1/bets?status=open / settled | each bet carries its `game` |
| news.json, news-page2.json | GET /v1/news, ?cursor= | StorySummary list |
| story.json, story-scandal.json, story-life.json | GET /v1/news/:id | `{ story, comments }` |
| person.json, person-batter.json, person-umpire.json | GET /v1/people/:id | PersonPage (pitcher, hitter, NPC) |
| team.json, team-farm.json | GET /v1/teams/:id | TeamPage (ML club, AA affiliate) |
| words.json | GET /v1/words | templates + slot word lists + version |
| comment-post.json | POST /v1/comments | `{ comment }` |
| comment-react.json | POST /v1/comments/:id/react | `{ comment }` |
| thread.json, thread-bbs.json | GET /v1/threads/:thread | story thread, `bbs:general` |
| thread-guestbook-post.json | POST /v1/comments | guestbook post on a person page |
| crew.json, crew-after.json | GET /v1/crew | before / after jobs |
| candidates.json | GET /v1/crew/candidates | `{ candidates, refreshesAt }` |
| recruit.json | POST /v1/crew/recruit | `{ crew, account }` |
| ops-catalog.json | GET /v1/ops/catalog?game= | kinds + targets |
| ops-catalog-banned.json | GET /v1/ops/catalog?game= | owners hostile to Lefty Loot: bleacher jobs carry `blocked`, guarded success in `notes` |
| error-banned.json | POST /v1/ops | 403 `forbidden`: a bleacher job at a park that banned you |
| op-order.json | POST /v1/ops | joint syndicate job (own + ally crew), `chipIn: true` (OpView.chipIn) |
| op-cancel.json | DELETE /v1/ops/:id | a planned job called off and refunded (`status: "cancelled"`) |
| syndicate-chipin.json | GET /v1/syndicate | Dotty Dial's view with an open chip-in ask (`chipIns`) |
| chipin-accept.json | POST /v1/ops/:id/chipin | Dotty pays her share |
| ops.json, ops-done.json | GET /v1/ops | planned / resolved (`result` text) |
| mail.json, mail-b.json, mail-c.json, mail-after-events.json | GET /v1/mail | op reports, bank (bet payouts, sales), league, threats, tips |
| mail-read.json | POST /v1/mail/:id/read | `{ ok }` |
| events.json | GET /v1/events | pending event cards (heat, arrests...) |
| events-invite.json | GET /v1/events | a syndicate invite card (`accept` / `decline`) |
| event-choose.json | POST /v1/events/:id/choose | `{ result, account }` |
| shop.json | GET /v1/shop | includes the free `starter` pack while unopened |
| pack-open.json, pack-open-paid.json | POST /v1/packs/buy | `{ cards, account }` |
| cards.json | GET /v1/cards | binder page |
| card.json | GET /v1/cards/:id | `{ card }` (a `finalSeason` copy: its player was retired by a redeemed card) |
| redeem-boost.json | POST /v1/cards/:id/redeem | a Gilded BOOST +12 / 7 days: `effect`, bulletin `story` |
| redeem-retire.json | POST /v1/cards/:id/redeem | an Original RETIRE: the player retires; bulletin `story` |
| bulletins.json | GET /v1/bulletins | league ticker of redemptions |
| market.json | GET /v1/market | fixed-price listings and auctions (`kind`, `auction`) |
| market-list.json | POST /v1/market | `{ listing }` (fixed price) |
| market-buy.json | POST /v1/market/:id/buy | `{ card, account }` |
| market-auction.json | GET /v1/market/:id | `{ listing, bids }`: an auction with a reserve, proxy bids, masked bidders |
| market-bid.json | POST /v1/market/:id/bid | `{ listing, leading, result, account }` (`account.escrow`) |
| watchlist.json | GET /v1/watchlist | watched listings |
| price-history.json | GET /v1/market/history?def= | recent sales of one card + stats |
| syndicate.json | GET /v1/syndicate | `{ syndicate, invites }` |
| syndicate-invite.json | POST /v1/syndicate/invite | `{ invite }` |
| syndicate-accept.json | POST /v1/syndicate/invites/:id/accept | `{ result, syndicate, account }` |
| syndicate-treasury.json | POST /v1/syndicate/treasury | `{ syndicate, account }` |
| syndicate-leaderboard.json | GET /v1/syndicates/leaderboard | `{ season, rows }` |
| error-*.json | (various) | error bodies: `{ error, message }` for name_taken, name_rejected, bad_request, rate_limited, invalid_comment, unauthorized, not_found, window_closed |
