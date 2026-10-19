--[[ Mad-libs comment composer + shared comment-list rendering.

  Composer.open{ thread = "story:s1", title = "Sign the Guestbook", style = "browser"|"bbs",
                 onPosted = function(comment) end }
    1. pick a template (word wheel), 2. fill each slot from its word list (word wheel
    with letter-jump), 3. Post. Pops with the new comment as the resume result.

  Comments.layout(L, page, comments, x, y, w, opts) -> new y
    Renders a comment list with agree/lol/rat reaction links. opts.thread enables a
    "Post a comment" button; opts.style "bbs" renders white-on-black. ]]

local gfx <const> = playdate.graphics

Composer = Page.define({ style = "bare", opaque = false, canvasH = 200 })

local WX, WY, WW, WH = 22, 22, 356, 200

function Composer:viewport()
  return WX + 2, WY + 17, WW - 4, WH - 19
end

function Composer:init(args)
  self.thread = args.thread
  self.words = {}
  self.tpl = nil
  self.bbs = args.style == "bbs"
end

function Composer:sources() return { words = "/words" } end

function Composer:loaded()
  local w = self.data.words
  if w then Game.words = w end
  -- jump straight into template choice the first time
  if not self.tpl and w and w.templates and #w.templates > 0 then
    self.tpl = w.templates[1]
    playdate.timer.performAfterDelay(150, function()
      if App.top() == self then self:chooseTemplate() end
    end)
  end
end

local function templateLabel(t)
  return (t.text:gsub("{(%w+)}", "___"))
end

--- A filled example ("Mullane is clutch!") so templates read before you pick them.
local function templateExample(t, slots, n)
  local i = 0
  return (t.text:gsub("{(%w+)}", function(kind)
    i += 1
    local list = slots and slots[kind]
    if not list or #list == 0 then return "___" end
    local w = list[((n * 7 + i * 3) % #list) + 1]
    if kind == "player" or kind == "person" then w = w:match("(%S+)$") or w end
    return w
  end))
end

function Composer:chooseTemplate()
  local w = self.data.words
  if not w then return end
  local items = {}
  local sel = 1
  for i, t in ipairs(w.templates) do
    items[i] = { label = templateExample(t, w.slots, i), value = t }
    if self.tpl == t then sel = i end
  end
  Picker.open({
    title = "Pick a template", items = items, selected = sel, letterJump = false, width = 330,
    style = self.bbs and "bbs" or nil,
    onPick = function(it)
      if it.value ~= self.tpl then self.words = {} end
      self.tpl = it.value
      self:render()
      self:focusFirstEmpty()
    end,
  })
end

function Composer:focusFirstEmpty()
  for i, l in ipairs(self.links) do
    if l.data and l.data.slot and not self.words[l.data.slot] then self.focus = i self.ring = nil return end
  end
  for i, l in ipairs(self.links) do if l.id == "post" then self.focus = i self.ring = nil return end end
end

function Composer:chooseWord(slotIndex, kind)
  local w = self.data.words
  local list = (w.slots and w.slots[kind]) or {}
  -- sorted once per word list (lowercasing inside the comparator made opening the
  -- ~1,000-player list hitch for half a second on the device)
  w.sortedSlots = w.sortedSlots or {}
  local sorted = w.sortedSlots[kind]
  if not sorted then
    -- the server sends lists sorted; only sort if this one isn't (old servers, fixtures)
    local prev, inOrder = "", true
    for _, s in ipairs(list) do
      local l = s:lower()
      if l < prev then inOrder = false break end
      prev = l
    end
    if inOrder then
      sorted = list
    else
      local keyed = {}
      for i, s in ipairs(list) do keyed[i] = { s:lower(), s } end
      table.sort(keyed, function(a, b) return a[1] < b[1] end)
      sorted = {}
      for i, k in ipairs(keyed) do sorted[i] = k[2] end
    end
    w.sortedSlots[kind] = sorted
  end
  local items = {}
  local sel = 1
  for i, s in ipairs(sorted) do
    items[i] = { label = s, value = s }
    if s == self.words[slotIndex] then sel = i end
  end
  Picker.open({
    title = "Pick a " .. kind, items = items, selected = sel, letterJump = true,
    style = self.bbs and "bbs" or nil,
    onPick = function(it)
      self.words[slotIndex] = it.value
      self:render(true)
      -- advance to the next empty slot or Post
      self:focusFirstEmpty()
    end,
  })
end

function Composer:complete()
  if not self.tpl then return false end
  for i = 1, #self.tpl.slots do
    if not self.words[i] then return false end
  end
  return true
end

function Composer:preview()
  local i = 0
  return (self.tpl.text:gsub("{(%w+)}", function()
    i += 1
    return self.words[i] or "___"
  end))
end

function Composer:post()
  if not self:complete() then
    Sfx.error()
    Toast.show("Fill in every blank first.", "bad")
    self:focusFirstEmpty()
    return
  end
  local words = {}
  for i = 1, #self.tpl.slots do words[i] = self.words[i] end
  Busy.post("/comments", { thread = self.thread, template = self.tpl.id, words = words }, "Posting", function(d)
    Sfx.coin()
    Toast.show("Posted!", "good")
    App.pop(d.comment or true)
    if self.args.onPosted then self.args.onPosted(d.comment) end
  end)
end

function Composer:underlay()
  Draw.dim(0.5)
  if self.bbs then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(WX, WY, WW, WH)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(WX, WY, WW, WH)
    gfx.fillRect(WX, WY, WW, 16)
    Text.draw(" POST A MESSAGE", WX + 4, WY, UI.fonts.mono)
    gfx.setColor(gfx.kColorBlack)
  else
    Draw.window(WX, WY, WW, WH, self.args.title or "Post a Comment")
  end
end

function Composer:layout(L)
  local _, _, w, h = self:viewport()
  local fg = self.bbs and "white" or nil
  if self.bbs then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 0, w, h + 40)
  end
  local x = 8
  local y = 6
  if not self.tpl then
    L:text("Loading the word list...", x, y, UI.fonts.body, fg)
    return
  end
  -- template row
  Text.draw("Template:", x, y + 2, UI.fonts.bold, fg)
  local tl = Text.ellipsize(templateLabel(self.tpl), UI.fonts.body, w - 110)
  local tw = Text.width(tl, UI.fonts.body) + 10
  gfx.setColor(self.bbs and gfx.kColorWhite or gfx.kColorBlack)
  gfx.drawRect(x + 68, y, tw, 16)
  Text.draw(tl, x + 73, y + 2, UI.fonts.body, fg)
  Text.draw("\u{25bc}", x + 68 + tw + 3, y + 2, UI.fonts.body, fg)
  L:link(x + 66, y - 2, tw + 16, 20, function() self:chooseTemplate() end, { id = "tpl", hint = "Change template" })
  y += 24
  Draw.hr(x, y, w - 16)
  y += 8
  -- sentence with slot chips (flow layout)
  local font = UI.fonts.head
  local lh = 22
  local cx, cy = x, y
  local maxX = w - 10
  local slotI = 0
  local text = self.tpl.text
  local pos = 1
  local function place(width)
    if cx + width > maxX and cx > x then
      cx = x
      cy += lh
    end
    local px = cx
    cx += width
    return px, cy
  end
  while pos <= #text do
    local s, e, kind = text:find("{(%w+)}", pos)
    local literal = s and text:sub(pos, s - 1) or text:sub(pos)
    for word, space in literal:gmatch("(%S+)(%s*)") do
      local ww = font:getTextWidth(word)
      local px, py = place(ww)
      Text.draw(word, px, py + 3, font, fg)
      if space ~= "" then cx += 6 end
    end
    if literal:match("^%s") then end
    if not s then break end
    slotI += 1
    local idx = slotI
    local filled = self.words[idx]
    local label = filled or ("<" .. kind .. ">")
    local f = filled and font or UI.fonts.body
    local cw = f:getTextWidth(label) + 10
    if cw > maxX - x then
      label = Text.ellipsize(label, f, maxX - x - 12)
      cw = f:getTextWidth(label) + 10
    end
    local px, py = place(cw)
    if filled then
      gfx.setColor(self.bbs and gfx.kColorWhite or gfx.kColorBlack)
      gfx.drawLine(px, py + 18, px + cw - 1, py + 18)
      gfx.drawLine(px, py + 19, px + cw - 1, py + 19)
      Text.draw(label, px + 5, py + 3, f, fg)
    else
      Draw.fade(px, py + 1, cw, 18, 0.5, self.bbs)
      gfx.setColor(self.bbs and gfx.kColorBlack or gfx.kColorWhite)
      gfx.fillRect(px + 3, py + 4, cw - 6, 12)
      gfx.setColor(gfx.kColorBlack)
      Text.draw(label, px + 5, py + 3, f, fg)
    end
    gfx.setColor(gfx.kColorBlack)
    L:link(px - 1, py, cw + 2, 21, function() self:chooseWord(idx, kind) end,
      { id = "slot" .. idx, hint = "Pick a " .. kind, data = { slot = idx }, style = "ring" })
    pos = e + 1
    -- keep punctuation glued to the chip
    local punct = text:match("^[%p]+", pos)
    if punct and not punct:find("{") then
      local pw = font:getTextWidth(punct)
      Text.draw(punct, cx + 2, cy + 3, font, fg)
      cx += pw + 2
      pos += #punct
    end
    if text:sub(pos, pos) == " " then cx += 6 end
  end
  y = cy + lh + 10
  -- preview
  Draw.hr(x, y, w - 16)
  y += 6
  Text.draw("Preview:", x, y, UI.fonts.bold, fg)
  y += 14
  y += L:para("\"" .. self:preview() .. "\"", x, y, w - 16, UI.fonts.body, 2, fg)
  y += 8
  local ready = self:complete()
  local by = math.max(y, h - 26)
  L:button(ready and "Post it!" or "Post", w - 170, by, 78, 20, function() self:post() end,
    { id = "post", hint = ready and "Send it to the world" or "Fill every blank first", state = (not ready) and "disabled" or nil })
  L:button("Cancel", w - 86, by, 72, 20, function() self:goBack() end, { id = "cancel", hint = "Throw it away" })
  L:mark(by + 24)
end

function Composer:goBack()
  Sfx.back()
  App.pop()
end

-- Comments ---------------------------------------------------------------------------------

Comments = Comments or {}

local REACTS <const> = { { "agree", "Agreed" }, { "lol", "LOL" }, { "rat", "Rat" } }

function Comments.react(page, c, kind)
  Api.post("/comments/" .. c.id .. "/react", { kind = kind }, function(err, d)
    if err then
      Toast.show(Api.errorText(err), "bad")
      return
    end
    local nc = d and d.comment
    if nc and nc.reactions then
      c.reactions = nc.reactions
    else
      c.reactions[kind] = (c.reactions[kind] or 0) + 1
    end
    page.popText = { text = "+1", t = 0 }
    Sfx.coin()
    page:render(true)
  end)
end

--- opts: { thread=, title=, style="bbs", max=n, compact=bool, emptyText= }
function Comments.layout(L, page, comments, x, y, w, opts)
  opts = opts or {}
  local bbs = opts.style == "bbs"
  local fg = bbs and "white" or nil
  local fb = UI.fonts.bold
  local f = UI.fonts.body
  if opts.thread then
    L:button(opts.postLabel or "Post a comment", x, y, 120, 18, function()
      Composer.open({ thread = opts.thread, title = opts.title, style = bbs and "bbs" or nil })
    end, { id = "post:" .. opts.thread, hint = "Build a comment from the word lists" })
    y += 26
  end
  if not comments or #comments == 0 then
    L:text(opts.emptyText or "No comments yet. Be the first!", x, y, f, fg)
    return y + 16
  end
  for i, c in ipairs(comments) do
    if opts.max and i > opts.max then break end
    local aw = Text.draw(c.author or "anonymous", x, y, fb, fg)
    local meta = "(" .. (c.authorRank or "?") .. ") " .. Fmt.ago(c.at)
    Text.draw(meta, x + aw + 5, y, f, fg)
    y += 13
    local h = Text.block(c.text or "", x + 8, y, w - 8, f, fg)
    L:mark(y + h)
    y += h + 1
    -- reactions
    local rx = x + 8
    local r = c.reactions or {}
    for _, rk in ipairs(REACTS) do
      local label = rk[2] .. " " .. (r[rk[1]] or 0)
      local lw = f:getTextWidth(label) + 8
      gfx.setColor(bbs and gfx.kColorWhite or gfx.kColorBlack)
      gfx.drawRoundRect(rx, y, lw, 13, 3)
      Text.draw(label, rx + 4, y, f, fg)
      gfx.setColor(gfx.kColorBlack)
      L:link(rx, y, lw, 13, function() Comments.react(page, c, rk[1]) end,
        { id = "react:" .. c.id .. ":" .. rk[1], hint = rk[2] .. ": " .. (c.author or "") .. "'s comment", style = "invert" })
      rx += lw + 4
    end
    y += 17
    if not opts.compact then
      Draw.dotted(x, x + w, y, bbs)
      gfx.setColor(gfx.kColorBlack)
      y += 4
    end
  end
  L:mark(y)
  return y
end
