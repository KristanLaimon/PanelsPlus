--[[
A full-screen grid of cards, paged: the page overview and the library. Each card
is a folder or a thumbnail with a name under it; a tap picks it, a hold asks for
its menu. Thumbnails come from a callback, and only the grid page on screen is
rendered and kept, so a long notebook or a full folder stays light. An optional
column of tabs on the left (the folders and notebooks of a folder, in the
overview) chooses what the grid shows; a name too long for a tab takes two lines.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local Theme = require("ink/ui/theme")
local Paint = require("ink/paint")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
local GREY  = Blitbuffer.COLOR_GRAY
-- Luminance greys (Color8): paintRoundedRect misbehaves with a ColorRGB32 on
-- older device builds.
local CARD  = Blitbuffer.Color8(0xE6)   -- light-grey rounded card behind a thumbnail
local LABEL = Blitbuffer.Color8(0x66)   -- muted grey for names and notes

local ThumbGrid = InputContainer:extend{
    title = "",
    items = nil,        -- list of { label, sub, folder = bool, selected = bool, star = bool,
                        -- icon = SVG path drawn on the card in place of a thumbnail }
    render = nil,       -- function(item, maxw, maxh) -> BlitBuffer or nil (the grid frees it)
    on_pick = nil,      -- function(item) after a tap; the grid stays open unless it closes itself
    on_hold = nil,      -- function(item) after a hold
    on_back = nil,      -- function(): shows a back arrow before the title
    on_back_top = nil,  -- function(): a hold on that arrow, straight to the top
    on_close = nil,     -- function() once the grid has closed
    actions = nil,      -- header buttons left of the close pill: { { label, cb, dark, icon = svg path }, ... }
    close_label = nil,  -- the close pill's text (Close by default)
    empty_text = nil,   -- shown when there are no items
    folder_icon = nil,  -- path of the SVG drawn on folder cards
    folder_tile = nil,  -- function(item, w, bg) -> a folder's own look w wide on grey bg (a
                        -- BlitBuffer the caller keeps), or nil for the plain icon
    tabs = nil,         -- list of { label, color = Blitbuffer colour or nil, selected = bool, folder = bool }
    on_tab = nil,       -- function(tab) after a tap on a tab
    on_tab_hold = nil,  -- function(tab) after a hold on a tab
    tab_footer = nil,   -- { { label, cb }, ... }: buttons under the tabs, the last one lowest
    start = 1,          -- the item whose grid page shows first
    flash_open = true,  -- flash when shown (over ink); not when it replaces another grid
    cols = nil,         -- 3 x 3 cards, or 4 x 2 on a wide screen, unless given
    rows = nil,
    -- not modal: its menus and prompts must open on top of it
    stop_events_propagation = true,
}

function ThumbGrid:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.sw, self.sh = sw, sh
    self.top_h = Screen:scaleBySize(54)
    self.bot_h = Screen:scaleBySize(58)
    self.pad = Screen:scaleBySize(12)
    self.label_h = Screen:scaleBySize(22)
    local wide = sw > sh
    -- with tabs, the cards share the width with the tab column
    self.tab_w = self.tabs and math.floor(sw * (wide and 0.24 or 0.32)) or 0
    self.tpage = 0
    if self.tabs then
        self.cols = self.cols or (wide and 3 or 2)
        self.rows = self.rows or (wide and 2 or 3)
    end
    self.cols = self.cols or (wide and 4 or 3)
    self.rows = self.rows or (wide and 2 or 3)
    self.per = self.cols * self.rows
    self.items = self.items or {}
    self.gpage = math.floor(((self.start or 1) - 1) / self.per)
    self.cache = {}     -- item -> thumbnail BlitBuffer, for the visible grid page
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        self.ges_events = {
            TgTap   = { GestureRange:new{ ges = "tap", range = full } },
            TgHold  = { GestureRange:new{ ges = "hold", range = full } },
            TgSwipe = { GestureRange:new{ ges = "swipe", range = full } },
        }
    end
    if Device:hasKeys() then
        local g = Device.input.group
        self.key_events = { TgClose = { { g.Back } } }
        -- the page turn buttons turn the grid's pages, as a swipe does (#53)
        if g.PgFwd then self.key_events.TgKeyFwd = { { g.PgFwd } } end
        if g.PgBack then self.key_events.TgKeyBack = { { g.PgBack } } end
    end
end

function ThumbGrid:gridCount()
    return math.max(1, math.ceil(#self.items / self.per))
end

-- Replace the cards (after a rename, a move, a new folder...), keeping the grid
-- page when it still exists, and optionally the tabs.
function ThumbGrid:setItems(items, title, tabs)
    self:freeCache()
    self.items = items or {}
    if title then self.title = title end
    if tabs then self.tabs = tabs end
    self.gpage = math.min(self.gpage, self:gridCount() - 1)
    UIManager:setDirty(self, "ui")
end

-- The tab column's layout: tab height and gap, how many tabs fit, and the rects
-- of the paging arrows and the buttons under the tabs.
function ThumbGrid:tabLayout()
    local th, gap = Screen:scaleBySize(52), Screen:scaleBySize(8)
    local top = self.top_h + self.pad
    local bottom = self.sh - self.bot_h
    local x, w = self.pad, self.tab_w - self.pad
    local foot = {}
    local n = self.tab_footer and #self.tab_footer or 0
    for i = 1, n do
        foot[i] = { x = x, y = bottom - (n - i + 1) * th - (n - i) * gap, w = w - self.pad, h = th }
    end
    local avail = (n > 0 and foot[1].y - gap or bottom) - top
    local fit = math.max(1, math.floor((avail + gap) / (th + gap)))
    local arrows
    if #self.tabs > fit then
        fit = math.max(1, fit - 1)   -- a row for the arrows
        local ay = top + fit * (th + gap)
        local aw = math.floor((w - self.pad - gap) / 2)
        arrows = { up = { x = x, y = ay, w = aw, h = th }, down = { x = x + aw + gap, y = ay, w = aw, h = th } }
    end
    return { th = th, gap = gap, top = top, x = x, w = w, fit = fit, foot = foot, arrows = arrows }
end

-- Screen rect of the tab in slot `i` (0-based) of the shown tab page, and the tab.
function ThumbGrid:tabRect(L, i)
    local tab = self.tabs[self.tpage * L.fit + i + 1]
    return { x = L.x, y = L.top + i * (L.th + L.gap), w = L.w, h = L.th, tab = tab }
end

-- Show the tab page holding the selected tab.
function ThumbGrid:showSelectedTab()
    if not self.tabs then return end
    local L = self:tabLayout()
    for i, t in ipairs(self.tabs) do
        if t.selected then self.tpage = math.floor((i - 1) / L.fit) end
    end
end

-- Screen rect of cell `slot` (0-based) on the current grid page, plus the item
-- it shows (or nil for an empty slot past the last one).
function ThumbGrid:cellRect(slot)
    local col = slot % self.cols
    local row = math.floor(slot / self.cols)
    local area_h = self.sh - self.top_h - self.bot_h
    local area_w = self.sw - self.tab_w
    local cw = math.floor((area_w - self.pad * (self.cols + 1)) / self.cols)
    local ch = math.floor((area_h - self.pad * (self.rows + 1)) / self.rows)
    local x = self.tab_w + self.pad + col * (cw + self.pad)
    local y = self.top_h + self.pad + row * (ch + self.pad)
    return { x = x, y = y, w = cw, h = ch, item = self.items[self.gpage * self.per + slot + 1] }
end

-- Render (and cache) every thumbnail on the current grid page.
function ThumbGrid:prepare()
    if not self.render then return end
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        if c.item and not c.item.folder and not c.item.icon and self.cache[c.item] == nil then
            local ok, bb = pcall(self.render, c.item, c.w - 2 * self.pad, c.h - self.label_h - 2 * self.pad)
            self.cache[c.item] = ok and bb or false
        end
    end
end

function ThumbGrid:freeCache()
    for k, bb in pairs(self.cache) do
        if bb and bb.free then bb:free() end
        self.cache[k] = nil
    end
end

-- The folder icon on a card-coloured tile, drawn once per size; `slot` keeps
-- the card's and the tabs' sizes apart.
function ThumbGrid:folderTile(sz, slot)
    return self:iconTile(self.folder_icon, sz, slot or "_folder")
end

-- The SVG at `path` drawn `sz` square on the card grey, kept in self[slot]
-- until the size changes or the grid closes.
function ThumbGrid:iconTile(path, sz, slot)
    local held = self[slot]
    if held and held.sz == sz and held.path == path then return held.bb end
    if held and held.bb then held.bb:free() end
    self[slot] = { sz = sz, path = path }
    if not path then return nil end
    local ok, raw, straight = pcall(function()
        return RenderImage:renderSVGImageFile(path, sz, sz)
    end)
    if ok and raw then
        local w, h = raw:getWidth(), raw:getHeight()
        local tile = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        tile:fill(CARD)
        if straight then tile:alphablitFrom(raw, 0, 0, 0, 0, w, h)
        else tile:pmulalphablitFrom(raw, 0, 0, 0, 0, w, h) end
        raw:free()
        self[slot].bb = tile
    end
    return self[slot].bb
end

-- E-ink refreshes follow the sheets: opening over the drawing flashes on a grey
-- panel, as ink would otherwise show through faintly; everything after that
-- (page turns, tabs, closing) is a plain "ui" refresh, like KOReader's own file
-- browser. A colour panel never flashes here: it takes a second or two, and on
-- Kobo's controller the reader waits for it to finish.
function ThumbGrid:onShow()
    self:showSelectedTab()
    self:prepare()
    UIManager:setDirty(self, self.flash_open and "full" or "ui")
    return true
end

function ThumbGrid:paintTo(bb, x, y)
    self:prepare()
    local sw, sh = self.sw, self.sh
    local S = function(px) return Screen:scaleBySize(px) end
    bb:paintRect(x, y, sw, sh, WHITE)
    -- what keeps its colours in dark (see ink/ui/theme.lua): thumbnails, tab
    -- colours, and anything in a theme colour
    local keeps = {}
    local function keep(kx, ky, kw, kh, kr) keeps[#keeps + 1] = { kx, ky, kw, kh, kr or 0 } end
    local function label(s, cx, cy, face, fgcolor, max_w, bold)
        local t = TextWidget:new{ text = s, face = face, fgcolor = fgcolor or BLACK, bold = bold,
            max_width = max_w }
        local sz = t:getSize()
        t:paintTo(bb, math.floor(cx - sz.w / 2), math.floor(cy - sz.h / 2))
        t:free()
    end
    -- top bar: an optional back arrow and the title on the left, then the action
    -- pills and a black close pill on the right; font sizes are plain points, as
    -- Font:getFace applies the DPI scaling
    local pill_h = S(36)
    local pill_y = y + math.floor(self.top_h / 2 - pill_h / 2)
    local pface = Font:getFace("cfont", 15)
    local right = x + sw - self.pad
    local accent = Accent.get()
    local function pill(text, dark, icon)
        local t = TextWidget:new{ text = text, face = pface, bold = true }
        -- a word gets a pill at least as wide as "Close"; a lone symbol or an
        -- icon a small one
        local glyph = icon or (#text <= 4 and not text:find("%w"))
        local w = icon and S(52) or math.max(glyph and S(52) or S(84), t:getSize().w + S(22))
        t:free()
        right = right - w
        if dark then
            Accent.paintRounded(bb, right, pill_y, w, pill_h, S(11))
            if accent.custom then keep(right, pill_y, w, pill_h, S(11)) end
        else bb:paintRoundedRect(right, pill_y, w, pill_h, CARD, S(11)) end
        local ib = icon and not dark and self:iconTile(icon, S(22), "_icon " .. icon)
        if ib then
            bb:blitFrom(ib, math.floor(right + (w - ib:getWidth()) / 2),
                math.floor(pill_y + (pill_h - ib:getHeight()) / 2), 0, 0, ib:getWidth(), ib:getHeight())
        else
            label(text, right + w / 2, pill_y + pill_h / 2, pface, dark and accent.text or BLACK, nil, true)
        end
        local r = { x = right, y = pill_y, w = w, h = pill_h }
        right = right - S(6)
        return r
    end
    self._close = pill(self.close_label or _("Close"), true)
    self._actions = {}
    for i = #(self.actions or {}), 1, -1 do
        local a = self.actions[i]
        self._actions[i] = pill(a[1], a[3], a.icon)
    end
    local tx = x + self.pad
    self._back = nil
    if self.on_back then
        local bw = S(40)
        label("\u{2039}", tx + bw / 2, y + self.top_h / 2, Font:getFace("cfont", 30), BLACK)
        self._back = { x = tx - self.pad, y = y, w = bw + self.pad, h = self.top_h }
        tx = tx + bw
    end
    -- the title steps down a size before it is cut short, as a folder's name
    -- shares the bar with its back arrow and the buttons
    local room = math.max(S(40), right - tx)
    local size
    for _, pt in ipairs({ 22, 19, 17 }) do
        size = pt
        local t = TextWidget:new{ text = self.title, face = Font:getFace("cfont", pt), bold = true }
        local fits = t:getSize().w <= room
        t:free()
        if fits then break end
    end
    local title = TextWidget:new{ text = self.title, face = Font:getFace("cfont", size), bold = true, max_width = room }
    local tsz = title:getSize()
    title:paintTo(bb, tx, y + math.floor(self.top_h / 2 - tsz.h / 2))
    title:free()
    bb:paintRect(x, y + self.top_h - 1, sw, 1, GREY)

    -- the tab column: each tab a card with its colour as a strip on the left; the
    -- selected one white, framed in the accent
    if self.tabs then
        local L = self:tabLayout()
        local tface = Font:getFace("cfont", 16)
        local strip = S(8)
        for i = 0, L.fit - 1 do
            local r = self:tabRect(L, i)
            local t = r.tab
            if t then
                local rx, ry = x + r.x, y + r.y
                if t.selected then
                    local fw = S(3)
                    if accent.custom then keep(rx, ry, r.w - self.pad, r.h, S(12)) end
                    Accent.paintRounded(bb, rx, ry, r.w - self.pad, r.h, S(12))
                    bb:paintRoundedRect(rx + fw, ry + fw, r.w - self.pad - 2 * fw, r.h - 2 * fw, WHITE, S(12) - fw)
                else
                    bb:paintRoundedRect(rx, ry, r.w - self.pad, r.h, CARD, S(12))
                end
                if t.color then   -- (a plain paintRect would draw a colour grey)
                    Paint.fillRect(bb, rx + S(4), ry + S(8), strip, r.h - S(16), t.color, Paint.isChromatic(t.color))
                    if not (t.selected and accent.custom) then keep(rx + S(4), ry + S(8), strip, r.h - S(16)) end
                end
                local lx = rx + strip + S(10)
                if t.folder then
                    local tbg = t.selected and 0xFF or 0xE6
                    local own = self.folder_tile and self.folder_tile(t, S(28), Theme.invert() and 0xFF - tbg or tbg)
                    local icon = own or self:folderTile(S(22), "_tab_folder")
                    if icon then
                        local iw, ih = icon:getWidth(), icon:getHeight()
                        local iy = ry + math.floor((r.h - ih) / 2)
                        bb:blitFrom(icon, lx, iy, 0, 0, iw, ih)
                        if own then keep(lx, iy, iw, ih) end
                    end
                    lx = lx + (own and S(36) or S(30))
                end
                local tw = TextBoxWidget:new{ text = t.label, face = tface, bold = t.selected,
                    bgcolor = t.selected and WHITE or CARD,   -- it fills its box
                    width = math.max(S(20), rx + r.w - self.pad - S(10) - lx), height = r.h - S(6),
                    height_adjust = true, height_overflow_show_ellipsis = true }
                local twsz = tw:getSize()
                tw:paintTo(bb, lx, ry + math.floor((r.h - twsz.h) / 2))
                tw:free()
            end
        end
        if L.arrows then
            local a = L.arrows
            local pages = math.ceil(#self.tabs / L.fit)
            if self.tpage > 0 then
                bb:paintRoundedRect(x + a.up.x, y + a.up.y, a.up.w, a.up.h, CARD, S(12))
                label("\u{25B2}", x + a.up.x + a.up.w / 2, y + a.up.y + a.up.h / 2, tface)
            end
            if self.tpage < pages - 1 then
                bb:paintRoundedRect(x + a.down.x, y + a.down.y, a.down.w, a.down.h, CARD, S(12))
                label("\u{25BC}", x + a.down.x + a.down.w / 2, y + a.down.y + a.down.h / 2, tface)
            end
        end
        for i, f in ipairs(L.foot) do
            Accent.paintRounded(bb, x + f.x, y + f.y, f.w, f.h, S(12))
            if accent.custom then keep(x + f.x, y + f.y, f.w, f.h, S(12)) end
            label(self.tab_footer[i][1], x + f.x + f.w / 2, y + f.y + f.h / 2, tface, accent.text, f.w - S(8), true)
        end
        -- the line between the tabs and the grid
        bb:paintRect(x + self.tab_w, y + self.top_h, 1, sh - self.top_h - self.bot_h, GREY)
    end

    if #self.items == 0 and self.empty_text then
        local aw = sw - self.tab_w
        label(self.empty_text, x + self.tab_w + aw / 2, y + self.top_h + (sh - self.top_h - self.bot_h) / 2,
            Font:getFace("cfont", 17), LABEL, aw - 4 * self.pad)
    end

    local card_r = S(16)
    local nface = Font:getFace("cfont", 16)
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        local it = c.item
        if it then
            local cx, cy = x + c.x, y + c.y
            -- a rounded light grey card; the selected one gets a border in the
            -- accent (an accent card with an inset grey card)
            local kept = it.selected and accent.custom
            if kept then keep(cx, cy, c.w, c.h, card_r) end
            if it.selected then
                Accent.paintRounded(bb, cx, cy, c.w, c.h, card_r)
                local ins = S(3)
                bb:paintRoundedRect(cx + ins, cy + ins, c.w - 2 * ins, c.h - 2 * ins, CARD, card_r)
            else
                bb:paintRoundedRect(cx, cy, c.w, c.h, CARD, card_r)
            end
            -- a folder in its own colour and icon is drawn bigger than the
            -- plain icon, and keeps its colours in dark (on the card's dark grey)
            local box = math.min(c.w, c.h - self.label_h)
            local own = it.folder and self.folder_tile
                and self.folder_tile(it, math.floor(box * 0.62), Theme.invert() and 0x19 or 0xE6)
            local img = own or (it.folder and self:folderTile(math.floor(box * 0.45)))
                or (it.icon and self:iconTile(it.icon, math.floor(box * 0.45), "_icon " .. it.icon)) or self.cache[it]
            if img then
                local iw, ih = img:getWidth(), img:getHeight()
                local ix, iy = cx + math.floor((c.w - iw) / 2), cy + math.floor((c.h - self.label_h - ih) / 2)
                bb:blitFrom(img, ix, iy, 0, 0, iw, ih)
                if not kept and (own or not (it.folder or it.icon)) then keep(ix, iy, iw, ih) end   -- a page as it is
            end
            local name = it.star and ("\u{2605} " .. it.label) or it.label
            label(name, cx + c.w / 2, cy + c.h - self.label_h / 2 - S(4), nface,
                it.selected and BLACK or LABEL, c.w - 2 * self.pad, it.selected)
        end
    end

    -- bottom bar: paging pills and a "grid page / total" indicator
    local by = y + sh - self.bot_h
    local pw, ph = S(120), S(40)
    local pcy = by + math.floor(self.bot_h / 2)
    local bface = Font:getFace("cfont", 16)
    self._prev, self._next = nil, nil
    if self.gpage > 0 then
        local px0 = x + self.pad
        bb:paintRoundedRect(px0, pcy - math.floor(ph / 2), pw, ph, CARD, S(14))
        self._prev = { x = px0, y = pcy - math.floor(ph / 2), w = pw, h = ph }
        label("\u{2039} " .. _("Prev"), px0 + pw / 2, pcy, bface)
    end
    if self.gpage < self:gridCount() - 1 then
        local px0 = x + sw - self.pad - pw
        bb:paintRoundedRect(px0, pcy - math.floor(ph / 2), pw, ph, CARD, S(14))
        self._next = { x = px0, y = pcy - math.floor(ph / 2), w = pw, h = ph }
        label(_("More") .. " \u{203A}", px0 + pw / 2, pcy, bface)
    end
    if self:gridCount() > 1 then
        label(string.format("%d / %d", self.gpage + 1, self:gridCount()),
            x + sw / 2, pcy, Font:getFace("cfont", 15), LABEL)
    end
    if Theme.invert() then
        bb:invertRect(x, y, sw, sh)
        for _i, k in ipairs(keeps) do Theme.invertRounded(bb, k[1], k[2], k[3], k[4], k[5]) end
    end
end

function ThumbGrid:gridGo(delta)
    local g = self.gpage + delta
    if g < 0 or g >= self:gridCount() then return end
    self:freeCache()          -- only the visible grid page is kept resident
    self.gpage = g
    self:prepare()
    UIManager:setDirty(self, "ui")
end

-- The card under screen point p, if any.
function ThumbGrid:itemAt(p)
    for slot = 0, self.per - 1 do
        local c = self:cellRect(slot)
        if c.item and p.x >= c.x and p.x <= c.x + c.w and p.y >= c.y and p.y <= c.y + c.h then
            return c.item
        end
    end
end

local function hit(r, p) return r and p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h end

-- What of the tab column is at screen point p: a tab, "up" or "down" (paging),
-- the index of a button under the tabs, or nil.
function ThumbGrid:tabAt(p)
    if not self.tabs or p.x > self.tab_w then return nil end
    local L = self:tabLayout()
    for i, f in ipairs(L.foot) do if hit(f, p) then return i end end
    if L.arrows then
        if hit(L.arrows.up, p) and self.tpage > 0 then return "up" end
        if hit(L.arrows.down, p) and self.tpage < math.ceil(#self.tabs / L.fit) - 1 then return "down" end
    end
    for i = 0, L.fit - 1 do
        local r = self:tabRect(L, i)
        if r.tab and hit(r, p) then return r.tab end
    end
end

function ThumbGrid:onTgTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    if hit(self._close, p) then self:close(); return true end
    for i, r in pairs(self._actions or {}) do
        if hit(r, p) then self.actions[i][2](); return true end
    end
    if hit(self._back, p) then self.on_back(); return true end
    local tab = self:tabAt(p)
    if tab == "up" then self.tpage = math.max(0, self.tpage - 1); UIManager:setDirty(self, "ui"); return true end
    if tab == "down" then self.tpage = self.tpage + 1; UIManager:setDirty(self, "ui"); return true end
    if type(tab) == "number" then self.tab_footer[tab][2](); return true end
    if tab then
        if self.on_tab then self.on_tab(tab) end
        return true
    end
    if hit(self._prev, p) then self:gridGo(-1); return true end
    if hit(self._next, p) then self:gridGo(1); return true end
    local it = self:itemAt(p)
    if it and self.on_pick then self.on_pick(it) end
    return true
end

function ThumbGrid:onTgHold(_, ges)
    local p = ges and ges.pos
    if p and hit(self._back, p) and self.on_back_top then self.on_back_top(); return true end
    local tab = p and self:tabAt(p)
    if type(tab) == "table" then
        if self.on_tab_hold then self.on_tab_hold(tab) end
        return true
    end
    local it = p and self:itemAt(p)
    if it and self.on_hold then self.on_hold(it) end
    return true
end

function ThumbGrid:onTgSwipe(_, ges)
    local dir = ges and ges.direction
    if dir == "west" then self:gridGo(1) elseif dir == "east" then self:gridGo(-1) end
    return true
end

function ThumbGrid:onTgKeyFwd() self:gridGo(1); return true end
function ThumbGrid:onTgKeyBack() self:gridGo(-1); return true end

function ThumbGrid:onTgClose()
    self:close()
    return true
end

function ThumbGrid:close()
    UIManager:close(self)
end

function ThumbGrid:onCloseWidget()
    self:freeCache()
    local slots = { "_folder", "_tab_folder" }
    for k in pairs(self) do
        if type(k) == "string" and k:sub(1, 6) == "_icon " then slots[#slots + 1] = k end
    end
    for _, slot in ipairs(slots) do
        if self[slot] and self[slot].bb then self[slot].bb:free() end
        self[slot] = nil
    end
    UIManager:setDirty("all", "ui")   -- repaint what is underneath, without a flash
    if self.on_close then self.on_close() end
end

return ThumbGrid
