-- DiamondMail: inbox list and letter view.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Mail = Page.define({ canvasH = 600, refreshOnResume = false })
Sites.Mail = Mail

local KIND_LABEL <const> = { tip = "TIP", op = "JOB", league = "LEAGUE", bank = "BANK", fan = "FAN", threat = "THREAT" }

function Mail:url() return "http://mail.diamondnet.com/inbox?user=" .. Fmt.slug(Game.account and Game.account.name or "") end
function Mail:sources()
  return { m = "/mail" .. (self.args.cursor and ("?cursor=" .. self.args.cursor) or "") }
end

function Mail:resume(r)
  Page.resume(self, r)
  self:render(true)
end

function Mail:statusText()
  local a = Game.account
  return (a and a.unreadMail or 0) .. " unread message(s)"
end

--- Shorter forms of a sender for the FROM column ("The Haldane Organization Front Office" ->
--- "Haldane Organization" -> "Haldane Org."), longest first; Text.fit takes the first that fits.
local function shortFrom(from)
  local a = from:gsub("^The ", "")
  local b = a:gsub(" Front Office$", "")
  local c = b:gsub("Organization", "Org."):gsub("Commissioner's Office", "Commissioner"):gsub("Brotherhood", "Bros.")
  return { a, b, c }
end

local function envelopeIcon(x, y, unread)
  if unread then
    gfx.fillRect(x, y, 14, 10)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawLine(x, y, x + 7, y + 5)
    gfx.drawLine(x + 13, y, x + 7, y + 5)
    gfx.setColor(gfx.kColorBlack)
  else
    gfx.drawRect(x, y, 14, 10)
    gfx.drawLine(x, y, x + 7, y + 5)
    gfx.drawLine(x + 13, y, x + 7, y + 5)
  end
end

function Mail:layout(L)
  local W = 392
  -- webmail header
  gfx.setPattern(UI.pat.gray)
  gfx.fillRect(0, 0, W, 24)
  gfx.setColor(gfx.kColorBlack)
  Draw.wordart("DiamondMail", 8, 0, UI.fonts.slab, { align = "left" })
  Text.draw("Inbox", W - 8, 6, UI.fonts.bold, nil, "right")
  local y = 28
  local mail = self.data.m and self.data.m.mail or {}
  -- column heads
  Text.draw("FROM", 26, y, UI.fonts.bold)
  Text.draw("SUBJECT", 130, y, UI.fonts.bold)
  Text.draw("WHEN", W - 6, y, UI.fonts.bold, nil, "right")
  y += 14
  gfx.drawLine(2, y, W - 2, y)
  y += 3
  if #mail == 0 then
    L:text("No mail. Nobody loves you. (Yet.)", 8, y + 4)
    y += 24
  end
  -- runs of 3+ receipts from Bobby fold into one row (the While You Were Out sums them up)
  self.expanded = self.expanded or {}
  local rows, i = {}, 1
  while i <= #mail do
    local m = mail[i]
    local j = i
    if m.kind == "bank" and m.from == "Bets By Bobby" then
      while mail[j + 1] and mail[j + 1].kind == "bank" and mail[j + 1].from == "Bets By Bobby" do j += 1 end
    end
    if j - i >= 2 and not self.expanded[m.id] then
      local won, unread = 0, false
      for k = i, j do
        local subj = mail[k].subject or ""
        local amt = tonumber(subj:match("%$([%d,]+)") and subj:match("%$([%d,]+)"):gsub(",", "") or nil)
        if amt and (subj:lower():find("won") or subj:lower():find("paid")) then won += amt end
        if not mail[k].read then unread = true end
      end
      rows[#rows + 1] = { group = true, first = m, n = j - i + 1, won = won, unread = unread }
      i = j + 1
    else
      rows[#rows + 1] = m
      i += 1
    end
  end
  for _, m in ipairs(rows) do
    if m.group then
      local f = m.unread and UI.fonts.bold or UI.fonts.body
      envelopeIcon(6, y + 2, m.unread)
      Text.draw("Bets By Bobby", 26, y, f)
      local kx = 130 + Draw.chip(130, y, "BANK", UI.fonts.body, true) + 4
      Text.draw(m.n .. " receipts" .. (m.won > 0 and (": " .. Fmt.money(m.won) .. " won") or ""), kx, y, f)
      Text.draw("\u{25bc}", W - 6, y, UI.fonts.body, nil, "right")
      local first = m.first
      L:link(2, y - 2, W - 4, 17, function() self.expanded[first.id] = true self:render(true) end,
        { id = "grp:" .. first.id, hint = "Show all " .. m.n .. " receipts", style = "invert" })
      y += 18
      goto continue
    end
    local unread = not m.read
    envelopeIcon(6, y + 2, unread)
    local f = unread and UI.fonts.bold or UI.fonts.body
    Text.draw(Text.fit(m.from or "?", 98, f, { short = shortFrom(m.from or "?"), fonts = {} }), 26, y, f)
    local kind = KIND_LABEL[m.kind] or ""
    local kx = 130
    if kind ~= "" then
      kx += Draw.chip(130, y, kind, UI.fonts.body, m.kind ~= "threat") + 4
    end
    Text.draw(Text.ellipsize(m.subject or "", f, W - kx - 58), kx, y, f)
    Text.draw(Fmt.ago(m.at), W - 6, y, UI.fonts.body, nil, "right")
    L:link(2, y - 2, W - 4, 17, function() Sites.Letter.open({ mail = m }) end, { id = "m:" .. m.id, hint = (m.from or "") .. ": " .. (m.subject or ""), style = "invert" })
    y += 18
    ::continue::
  end
  local nxt = self.data.m and self.data.m.next
  if nxt then
    y += 4
    L:textLink("Older mail >>", 8, y, function() Mail.open({ cursor = nxt }) end, { id = "older", font = UI.fonts.bold })
    y += 18
  end
  L:mark(y + 4)
end

-- Letter -----------------------------------------------------------------------------------

local Letter = Page.define({ canvasH = 500 })
Sites.Letter = Letter

function Letter:url() return "http://mail.diamondnet.com/read?id=" .. (self.args.mail and self.args.mail.id or "") end

function Letter:init(args)
  local m = args.mail
  if m and m.kind == "bank" then
    local subj = (m.subject or ""):lower()
    if subj:find("win") or subj:find("won") or subj:find("paid") then Sfx.stinger("bet_won")
    elseif subj:find("tough") or subj:find("lost") or subj:find("luck") then Sfx.stinger("bet_lost") end
  elseif m and m.kind == "threat" then
    Sfx.stinger("arrest")
  end
  if m and not m.read then
    m.read = true
    Api.post("/mail/" .. m.id .. "/read", {}, function(err)
      if not err and Game.account and (Game.account.unreadMail or 0) > 0 then
        Game.account.unreadMail -= 1
      end
    end)
  end
end

function Letter:layout(L)
  local W = 392
  local m = self.args.mail or {}
  Draw.tile(0, 0, W, 2000, "lighter")
  -- paper
  local px, pw = 14, W - 28
  local y = 8
  local lines = {}
  local f = m.kind == "threat" and UI.fonts.bold or UI.fonts.body
  local textX = px + 12
  local textW = pw - 24
  local headerH = 52
  if m.fromFace then headerH = 70 end
  local photo = m.photo and Archive.get(m.photo, 96)
  if photo then headerH = math.max(headerH, 84 + (m.photoCaption and 14 or 0)) end
  -- measure body
  local bodyH = 0
  for _, p in ipairs(m.body or {}) do bodyH += #Text.wrap(p, f, textW) * (f:getHeight() + 1) + 6 end
  local ph = headerH + bodyH + 40
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(px + 3, y + 3, pw, ph)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(px, y, pw, ph)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(px, y, pw, ph)
  -- ruled lines like notepaper
  gfx.setColor(gfx.kColorBlack)
  local hx = textX
  if m.fromFace then
    Faces.draw(m.fromFace, textX, y + 8, 48)
    hx = textX + 58
  end
  Text.draw("From: " .. (m.from or "?"), hx, y + 8, UI.fonts.bold)
  Text.draw(Text.ellipsize("Re: " .. (m.subject or ""), UI.fonts.bold, px + pw - hx - (photo and 112 or 10)), hx, y + 22, UI.fonts.bold)
  Text.draw(Fmt.ago(m.at) .. "  \u{2022}  " .. ((KIND_LABEL[m.kind] or "MAIL")), hx, y + 36, UI.fonts.body)
  if photo then
    Archive.draw(m.photo, px + pw - 106, y + 8, 96)
    -- archive captions end in a year ("On the telephone, 1910"): drop it before cutting words
    if m.photoCaption then Text.draw(Text.fit(m.photoCaption, 96, UI.fonts.body, { short = (m.photoCaption:gsub(",%s*%d%d%d%d$", "")), fonts = {} }), px + pw - 106, y + 82, UI.fonts.body) end
  end
  local by = y + headerH
  gfx.drawLine(px + 6, by, px + pw - 6, by)
  by += 6
  for _, p in ipairs(m.body or {}) do
    by += Text.block(p, textX, by, textW, f) + 6
  end
  y += ph + 10
  L:button("Back to Inbox", px, y, 110, 18, function() self:goBack() end, { id = "back", hint = "Inbox" })
  if m.storylineId then
    -- a tip about a storyline: its Gossip Board entry (secret ones show as "you heard...")
    L:button("Bet on this rumour", px + 120, y, 140, 18, function() Nav.storyline(m.storylineId) end, { id = "gossip", hint = "The Gossip Board, at the story this tip is about" })
    L:button("Send a crew", px + 268, y, 96, 18, function() Nav.job({ storylineId = m.storylineId }) end, { id = "rig", hint = "Clubhouse BBS: a job on this story" })
  elseif m.kind == "bank" and (m.subject or ""):find("^Prop") then
    L:button("My props", px + 120, y, 80, 18, function() Sites.Gossip.open({ mine = true }) end, { id = "gossip", hint = "Your prop bets on the Gossip Board" })
  elseif m.kind == "bank" then
    L:button("Bets", px + 120, y, 60, 18, function() Sites.Bets.open() end, { id = "bets", hint = "Bets By Bobby" })
  elseif m.kind == "op" then
    L:button("Clubhouse", px + 120, y, 90, 18, function() Sites.BBS.open() end, { id = "bbs", hint = "The Clubhouse BBS" })
  end
  L:mark(y + 24)
end
