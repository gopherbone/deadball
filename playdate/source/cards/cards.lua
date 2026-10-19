-- Cards: shop → pack opening, binder (+ zoom/flip, list on market, fan page), market.
-- Exports Cards = { shopScene, packOpenScene, binderScene, marketScene }.
--
--   App.push(Cards.shopScene)
--   App.push(Cards.binderScene)
--   App.push(Cards.marketScene)
--   App.push(Cards.packOpenScene, { kind = "wax", cards = {CardView...} })

import "CoreLibs/graphics"
import "ballcast/kit"
import "ballcast/puppets"
import "cards/render"
import "cards/ui"
import "cards/shop"
import "cards/packopen"
import "cards/binder"
import "cards/market"

--- Screenshot script for ballcast/devharness.lua (dev only).
function Cards.debugScript(step, waitFor, shot)
  local K = BCKit
  local function top() return App.top() end
  -- a showcase pack: one of each rarity (from the fixture pack, with rarities swapped in)
  local function showcase()
    local src = K.fixture("/cards") or {}
    local fx = K.readJson("fixtures/pack-open.json") or src
    local cards = {}
    local rar = { "common", "uncommon", "rare", "gilded", "misprint", "original" }
    local var = { nil, nil, nil, nil, "raccoon-photobomb", "signed" }
    for i, c in ipairs(fx.cards or {}) do
      if i > 6 then break end
      local cc = {}
      for k, v in pairs(c) do cc[k] = v end
      cc.id = (c.id or "x") .. "-sc" .. i
      cc.rarity, cc.variant = rar[i], var[i]
      if i >= 4 then cc.serial = string.format("%02d/%d", i, i == 6 and 1 or 50) end
      cards[#cards + 1] = cc
    end
    return cards
  end
  step(function() App.push(Cards.shopScene) end, 25)
  step(function() shot("cards_shop") end)
  step(function() local s = top(); s:rightButtonDown() end, 10)
  step(function() shot("cards_shop_cigar") end)
  step(function() App.pop(); App.push(Cards.packOpenScene, { kind = "wax", name = "Wax Pack", cards = showcase() }) end, 5)
  step(function() local s = top(); s:cranked(140) end, 3)
  step(function() shot("cards_pack_tear") end)
  step(function() local s = top(); s:cranked(200) end, 40)
  step(function() local s = top(); s.idx = 4; s:advance() end, 12)
  step(function() shot("cards_reveal_flip") end)
  step(function() end, 12)
  step(function() shot("cards_reveal_gilded") end)
  step(function() local s = top(); s.idx = 5; s.flipT, s.revealT = nil, nil; s:advance() end, 14)
  step(function() shot("cards_reveal_misprint") end)
  step(function() local s = top(); s.idx = 6; s.flipT, s.revealT = nil, nil; s:advance() end, 30)
  step(function() shot("cards_reveal_original") end)
  step(function() local s = top(); s.stage = "summary" end, 4)
  step(function() shot("cards_pack_summary") end)
  step(function() App.pop(); App.push(Cards.binderScene) end, 30)
  step(function() local s = top(); s:rightButtonDown(); s:downButtonDown() end, 6)
  step(function() shot("cards_binder") end)
  step(function()
    local b = top()
    local c = {}
    for k, v in pairs(b.cards[1]) do c[k] = v end
    c.id, c.rarity, c.serial, c.value = c.id .. "-gz", "gilded", "07/50", 140
    App.push(Cards.zoomScene, { card = c })
  end, 6)
  step(function() shot("cards_zoom_front") end)
  step(function() local z = top(); z.flipTarget = 1 end, 20)
  step(function() shot("cards_zoom_back") end)
  step(function()
    print("[harness] number precision", 1792289718078 - 1792289718000)
    local fx = BCKit.readJson("fixtures/market.json")
    local a = fx and fx.listings[1].auction
    print("[harness] endsAt decoded", a and a.endsAt, math.type and math.type(a and a.endsAt), "secs", playdate.getSecondsSinceEpoch())
    local z = top()
    z.card.redeem = { kind = "boost", boost = 12, days = 7, label = "REDEEMABLE: BOOST +12 FOR 7 DAYS" }
    z.flipTarget = 0; z:buildActions(); z.sel = #z.actions; Cards.Render.trim(nil); z:AButtonDown()
  end, 6)
  step(function() shot("cards_redeem_confirm") end)
  step(function() local d = top(); d:AButtonDown() end, 20)
  step(function() shot("cards_redeemed") end)
  step(function() App.pop(); App.pop() end, 3)
  step(function() App.push(Cards.marketScene) end, 30)
  step(function() local m = top(); for i = 1, 4 do m:downButtonDown() end end, 4)
  step(function() shot("cards_market") end)
  step(function() local m = top(); for i = 1, 3 do m:downButtonDown() end end, 4)
  step(function() shot("cards_market_scrolled") end)
  step(function()
    local m = top()
    -- open the first auction
    for i = 1, m:count() do local it = m:itemAt(i); if type(it) == "table" and it.kind == "auction" and (it.auction and it.auction.bids or 0) > 0 then m.sel = i break end end
    m:AButtonDown()
  end, 10)
  step(function() shot("cards_market_item") end)
  step(function() local it = top(); it.sel = 1; it:AButtonDown() end, 4)
  step(function() local p = top(); p:cranked(60) end, 4)
  step(function() shot("cards_market_bid") end)
  step(function() local p = top(); p:AButtonDown() end, 4)
  step(function() local c = top(); c:AButtonDown() end, 10)
  step(function() shot("cards_market_bid_result") end)
  step(function() local it = top(); it.showBids = true end, 3)
  step(function() shot("cards_market_bidhistory") end)
  step(function() App.pop(); local m = top(); m:rightButtonDown(); m:rightButtonDown() end, 4)
  step(function() shot("cards_market_selling") end)
  step(function() App.pop() end, 3)
  step(function() App.push(Cards.binderScene) end, 30)
  step(function() local b = top(); App.push(Cards.sellScene, { card = b.cards[1] }) end, 4)
  step(function() local s = top(); s.sel = 3; s:cranked(40) end, 4)
  step(function() shot("cards_sell") end)
  step(function() App.pop(); App.pop() end, 3)
end
