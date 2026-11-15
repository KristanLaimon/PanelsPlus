--[[
The sticker sheet: ready-made notes, speech bubbles, marks, tape and little
pictures to put on a page (see ink/stickers.lua), and the reader's own pictures
as stickers. Every sticker shows its preview, a few to a page; a tap puts it on
the page (selected, to move and resize), a hold offers to hide a built-in one or
delete one of your own. A colour row sets the colour of notes, tape and marks and
is remembered, and so is the last sticker used.

The button is in the toolbar, or under Image (Settings): on a small screen the
toolbar is already full.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Export = require("ink/export")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Paint = require("ink/paint")
local Storage = require("ink/storage")
local Stickers = require("ink/stickers")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local TILE_BG = Paint.TILE_BG

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

-- How many stickers a page of the sheet holds: (columns, rows).
local PER_PAGE = { [4] = { 2, 2 }, [6] = { 3, 2 }, [9] = { 3, 3 }, [12] = { 4, 3 } }
local DEFAULT_PER_PAGE = 6
local PALETTE = { notes = "pastel", tape = "pastel", marks = "strong" }
local USER_EXT = { png = true, jpg = true, jpeg = true }

------------------------------------------------------------------------------
-- What is remembered
------------------------------------------------------------------------------

-- Is the Stickers button in the toolbar (else under Image)?
function InkAwayView:stickersInToolbar()
    return self:getSetting("inkaway_stickers_in_bar", true) ~= false
end

function InkAwayView:stickersPerPage()
    local n = tonumber(self:getSetting("inkaway_stickers_per_page", DEFAULT_PER_PAGE))
    return PER_PAGE[n] and n or DEFAULT_PER_PAGE
end

-- The colour chosen for a palette ("pastel" or "strong"), or its first.
function InkAwayView:stickerColour(palette)
    local c = self:getSetting("inkaway_sticker_colour_" .. (palette or "pastel"))
    if type(c) == "table" and tonumber(c[1]) and tonumber(c[2]) and tonumber(c[3]) then return { c[1], c[2], c[3] } end
    return Stickers.defaultColour(palette)
end

function InkAwayView:stickerHidden()
    local h = self:getSetting("inkaway_stickers_hidden", {})
    local set = {}
    if type(h) == "table" then for _i, id in ipairs(h) do set[id] = true end end
    return set
end

function InkAwayView:hideSticker(id)
    local h = self:getSetting("inkaway_stickers_hidden", {})
    local list = {}
    if type(h) == "table" then for _i, v in ipairs(h) do list[#list + 1] = v end end
    list[#list + 1] = id
    self:setSetting("inkaway_stickers_hidden", list)
end

function InkAwayView:restoreStickers()
    self:setSetting("inkaway_stickers_hidden", nil)
end

-- A change to where the button is: the toolbar is laid out again.
function InkAwayView:stickersBarChanged()
    self:flushPending()
    self:relayout()
    UIManager:setDirty(self, "full")
end

function InkAwayView:setStickersInToolbar(on)
    on = on and true or false
    if on == self:stickersInToolbar() then return end
    self:setSetting("inkaway_stickers_in_bar", on)
    self:stickersBarChanged()
end

------------------------------------------------------------------------------
-- Pictures of the stickers
------------------------------------------------------------------------------

function InkAwayView:freeStickerThumbs()
    local t = self._stk_thumbs
    if not t then return end
    for _k, bb in pairs(t) do if bb and bb.free then pcall(function() bb:free() end) end end
    self._stk_thumbs = nil
end

-- A built-in sticker's preview, size x size, drawn by the same code as the page.
local function renderThumb(s, body, size)
    local bb = Blitbuffer.new(size, size, Screen.bb:getType())
    Paint.fillRect(bb, 0, 0, size, size, TILE_BG, false)
    local pad = math.floor(size * 0.13)
    local avail = size - 2 * pad
    local k = math.min(avail / s.w, avail / s.h)
    local w, h = s.w * k, s.h * k
    local ops = Stickers.build(s.id, body, pad + (avail - w) / 2, pad + (avail - h) / 2, w)
    for _i, op in ipairs(ops or {}) do
        local put = Paint.spanWriter(bb, size, size, Paint.displayColor(op.color, op.alpha))
        local fill_put = op.fill_color and Paint.spanWriter(bb, size, size,
            Paint.displayColor(op.fill_color, op.fill_alpha)) or nil
        Export.paintGeom(op, put, fill_put, nil)
    end
    return bb
end

-- The preview of a picture of the reader's own.
local function renderUserThumb(path, size)
    local RenderImage = require("ui/renderimage")
    local img = RenderImage:renderImageFile(path, false)
    if not img then return nil end
    local iw, ih = img:getWidth(), img:getHeight()
    local pad = math.floor(size * 0.1)
    local avail = size - 2 * pad
    local k = math.min(avail / iw, avail / ih)
    local sw, sh = math.max(1, math.floor(iw * k)), math.max(1, math.floor(ih * k))
    local scaled = img
    if sw ~= iw or sh ~= ih then
        local ok, s = pcall(function() return RenderImage:scaleBlitBuffer(img, sw, sh, false) end)
        if ok and s then scaled = s end
    end
    local bb = Blitbuffer.new(size, size, Screen.bb:getType())
    Paint.fillRect(bb, 0, 0, size, size, TILE_BG, false)
    local dx, dy = math.floor((size - sw) / 2), math.floor((size - sh) / 2)
    if not pcall(function() bb:alphablitFrom(scaled, dx, dy, 0, 0, sw, sh) end) then
        pcall(function() bb:blitFrom(scaled, dx, dy, 0, 0, sw, sh) end)
    end
    if scaled ~= img and scaled.free then scaled:free() end
    if img.free then img:free() end
    return bb
end

local function thumbFor(self, item, body, size)
    self._stk_thumbs = self._stk_thumbs or {}
    local key
    if item.kind == "built" then
        key = table.concat({ item.s.id, body and (body[1] .. "," .. body[2] .. "," .. body[3]) or "", size }, "|")
    else
        key = item.path .. "|" .. size
    end
    local bb = self._stk_thumbs[key]
    if bb == nil then
        local ok, made = pcall(function()
            if item.kind == "built" then return renderThumb(item.s, body, size) end
            return renderUserThumb(item.path, size)
        end)
        bb = ok and made or false
        self._stk_thumbs[key] = bb
    end
    return bb or nil
end

------------------------------------------------------------------------------
-- The reader's own stickers
------------------------------------------------------------------------------

function InkAwayView:userStickersDir()
    return Storage.appDir("stickers")
end

-- The reader's own stickers, oldest first: { { kind = "user", path } }.
function InkAwayView:userStickers()
    local dir = self:userStickersDir()
    local out = {}
    if not dir then return out end
    for _i, e in ipairs(Storage.list(dir)) do
        local ext = e.name:match("%.(%w+)$")
        if e.mode == "file" and ext and USER_EXT[ext:lower()] then out[#out + 1] = { kind = "user", path = e.path, name = e.name } end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Keep a picture as a sticker: shrunk to at most 480 px, as a PNG in the stickers
-- folder, so a photo does not take megabytes. Returns true, or false and a reason.
function InkAwayView:importSticker(path)
    local dir = self:userStickersDir()
    if not dir then return false end
    local ImageProc = require("ink/imageproc")
    local src = self:decodeCapped(path)
    if not src then return false end
    local w, h = src:getWidth(), src:getHeight()
    local cap = math.min(1, 480 / w, 480 / h)
    local nw, nh = math.max(1, math.floor(w * cap + 0.5)), math.max(1, math.floor(h * cap + 0.5))
    local img = src
    if nw ~= w or nh ~= h then
        local ok, s = pcall(function() return require("ui/renderimage"):scaleBlitBuffer(src, nw, nh, false) end)
        if ok and s then img = s else nw, nh = w, h end
    end
    local rgba = ImageProc.bbToRGBA(img, nw, nh)
    local out
    if rgba then
        self._stk_seq = (self._stk_seq or 0) + 1
        out = string.format("%s/%d-%d.png", dir, os.time(), self._stk_seq)
        local ok = pcall(function() require("ffi/png").encodeToFile(out, rgba, nw, nh, 4) end)
        if not ok then out = nil end
    end
    if img ~= src and img.free then img:free() end
    if src.free then src:free() end
    return out ~= nil
end

-- Delete one of the reader's own stickers (a page that already uses it keeps its copy).
function InkAwayView:deleteUserSticker(path)
    os.remove(path)
    if self._stk_thumbs then
        for k, bb in pairs(self._stk_thumbs) do
            if k:sub(1, #path) == path then
                if bb and bb.free then pcall(function() bb:free() end) end
                self._stk_thumbs[k] = nil
            end
        end
    end
end

------------------------------------------------------------------------------
-- Putting one on the page
------------------------------------------------------------------------------

-- The width a new sticker takes on the page: about a third of what is in view,
-- and not so tall that it fills the view.
local function stickerWidth(self, s)
    local v = self.view
    local w = math.max(90, 0.32 * v.area_w / v.zoom)
    local h = w * s.h / s.w
    local cap = 0.5 * v.area_h / v.zoom
    if h > cap then w = w * cap / h end
    return w
end

-- Put a built-in sticker (`s`, in `body` colour) in the middle of the view, selected
-- with its menu open, as for a picture, so it can be moved, resized or turned at once.
function InkAwayView:placeSticker(s, body)
    local v = self.view
    local w = stickerWidth(self, s)
    local ops, h = Stickers.build(s.id, body, 0, 0, w)
    if not ops then return end
    local ccx = v.pan_x + (v.area_w / 2) / v.zoom
    local ccy = v.pan_y + (v.area_h / 2) / v.zoom
    local x = math.max(0, math.min(v.canvas_w - w, ccx - w / 2))
    local y = math.max(0, math.min(v.canvas_h - h, ccy - h / 2))
    ops = Stickers.build(s.id, body, x, y, w)
    self:flushPending()
    self:layerReady()
    self.canvas:pushHistory()
    local idxs = {}
    for _i, op in ipairs(ops) do
        local _op, at = self.canvas:placeOp(op)
        idxs[#idxs + 1] = at
    end
    self:setSetting("inkaway_sticker_last", s.id)
    self:markDirty()
    self:setTool("pan")
    self:recompose()
    self:selectOps(idxs, "pan")
    self:openSelectionMenu()
end

-- A picture of the reader's own goes on the page as a picture (a copy of its own,
-- so deleting the sticker later does not touch pages that use it), a good deal
-- smaller than a photo would be.
function InkAwayView:placeUserSticker(path)
    local dir = Storage.appDir("sticker pictures")
    local name = path:match("([^/]+)$")
    local dest = dir and (dir .. "/" .. name)
    local function exists(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end
    if dest and not exists(dest) then
        local f = io.open(path, "rb")
        local data = f and f:read("*a")
        if f then f:close() end
        local out = data and io.open(dest, "wb")
        if out then out:write(data); out:close() else dest = nil end
    end
    self:insertImage(dest or path, 0.32)
end

------------------------------------------------------------------------------
-- The sheet
------------------------------------------------------------------------------

-- The stickers of a category, as items: built-in ones not hidden, or the reader's own.
function InkAwayView:stickerItems(cat)
    local out = {}
    if cat == "mine" then
        out[1] = { kind = "add" }
        for _i, u in ipairs(self:userStickers()) do out[#out + 1] = u end
        return out
    end
    local hidden = self:stickerHidden()
    for _i, s in ipairs(Stickers.inCategory(cat)) do
        if not hidden[s.id] then out[#out + 1] = { kind = "built", s = s } end
    end
    return out
end

local CATEGORY_NAMES = function()
    return { notes = _("Notes"), bubbles = _("Bubbles"), marks = _("Marks"), tape = _("Tape"), fun = _("Fun"),
        mine = _("Mine") }
end

-- One tile of the grid: the sticker's preview on a rounded tile, framed more
-- boldly when it is the last one used. A tap puts it on the page, a hold offers to
-- hide it (a built-in one) or delete it (the reader's own).
function InkAwayView:stickerTile(item, body, w, h, chosen)
    local cb, hold
    if item.kind == "add" then
        cb = function()
            self:closeSheet("_stickers")
            self:pickImageFile(function(path)
                if not self:importSticker(path) then self:tell(_("Couldn't add that sticker.")) end
                self:openStickers("mine")
            end)
        end
    else
        cb = function()
            self:closeSheet("_stickers")
            if item.kind == "built" then self:placeSticker(item.s, body)
            else self:placeUserSticker(item.path) end
        end
        hold = function() self:askRemoveSticker(item) end
    end
    local btn = Button:new{ text = "", width = w, height = h, bordersize = 0, radius = Screen:scaleBySize(14),
        background = TILE_BG, margin = 0, padding = 0, callback = cb, hold_callback = hold, show_parent = self }
    if item.kind == "add" then
        local TextWidget = require("ui/widget/textwidget")
        local Font = require("ui/font")
        self:setButtonLabel(btn, TextWidget:new{ text = "+", face = Font:getFace("cfont", 54), bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK })
    else
        local size = math.min(w, h) - Screen:scaleBySize(8)
        local bb = thumbFor(self, item, body, size)
        if bb then
            self:setButtonLabel(btn, ImageWidget:new{ image = bb, width = size, height = size,
                image_disposable = false, fgcolor = Blitbuffer.COLOR_BLACK })
        end
    end
    local edge = Screen:scaleBySize(chosen and 3 or 1)
    return FrameContainer:new{ bordersize = edge, color = chosen and Blitbuffer.COLOR_BLACK or Paint.HAIRLINE,
        radius = Screen:scaleBySize(16), padding = Screen:scaleBySize(chosen and 1 or 3), margin = 0, btn }
end

-- Hold on a sticker: ask before hiding a built-in one or deleting one of the reader's own.
function InkAwayView:askRemoveSticker(item)
    if item.kind == "built" then
        self:ask{ field = "_stk_ask", title = _("Hide this sticker?"),
            text = _("You can bring hidden stickers back in the sticker options."),
            ok_text = _("Hide"), on_ok = function()
                self:hideSticker(item.s.id)
                self:rebuildSheet("_stickers")
            end }
    elseif item.kind == "user" then
        self:ask{ field = "_stk_ask", title = _("Delete this sticker?"),
            text = _("Pages that already use it keep their copy."),
            ok_text = _("Delete"), on_ok = function()
                self:deleteUserSticker(item.path)
                self:rebuildSheet("_stickers")
            end }
    end
end

-- The colour row for a palette: its colours, a colour of your own (kept as the
-- choice) and, on a colour screen, the wheel to pick one.
function InkAwayView:stickerColourRow(palette, content_w, gap, again)
    local cur = self:stickerColour(palette)
    local list = {}
    local function same(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end
    local found = false
    for _i, rgb in ipairs(Stickers.COLOURS[palette]) do if same(rgb, cur) then found = true end end
    local entries = {}
    for _i, rgb in ipairs(Stickers.COLOURS[palette]) do entries[#entries + 1] = rgb end
    if not found then entries[#entries + 1] = cur end
    local colour = self:colorScreen()
    local n = #entries + (colour and 1 or 0)
    local sw = math.floor((content_w - (n - 1) * gap) / n)
    local swh = math.floor(sw * 0.62)
    for _i, rgb in ipairs(entries) do
        list[#list + 1] = self:swatchTile(rgb, same(rgb, cur), sw, function()
            self:setSetting("inkaway_sticker_colour_" .. palette, { rgb[1], rgb[2], rgb[3] })
            again()
        end, nil, swh)
    end
    if colour then
        list[#list + 1] = self:wheelTile(sw, swh, function()
            self:openTextColourWheel("mark", cur, function(rgb)
                self:setSetting("inkaway_sticker_colour_" .. palette, { rgb[1], rgb[2], rgb[3] })
                again()
            end)
        end)
    end
    local row = HorizontalGroup:new{ align = "center" }
    for i, w in ipairs(list) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = w
    end
    return row
end

-- Open the sticker sheet on `cat` (the last one by default).
function InkAwayView:openStickers(cat)
    self:dropSelection()
    self:closeSheet("_stickers")
    local st = self._stk or { cat = "notes", page = 1 }
    self._stk = st
    if cat and cat ~= st.cat then st.cat, st.page = cat, 1 end
    local content_w, gap = self:sheetWidth()
    local function close() self:closeSheet("_stickers") end
    local function again() self:rebuildSheet("_stickers") end
    self:ensureUserIcons()
    local build = function()
        local names = CATEGORY_NAMES()
        local palette = PALETTE[st.cat]
        local body = palette and self:stickerColour(palette) or nil
        -- the fixed parts first, so the grid gets exactly the height that is left
        local title = self:sheetTitle(_("Stickers"), content_w, _("Done"), close, nil,
            { { icon = "menu", cb = function() close(); self:openStickerOptions() end } })
        local order = { "notes", "bubbles", "marks", "tape", "fun", "mine" }
        local tw = math.floor((content_w - (#order - 1) * gap) / #order)
        local tabs = HorizontalGroup:new{ align = "center" }
        for i, c in ipairs(order) do
            if i > 1 then tabs[#tabs + 1] = HorizontalSpan:new{ width = gap } end
            tabs[#tabs + 1] = self:actionButton(names[c], tw, function() st.cat, st.page = c, 1; again() end, st.cat == c, "small")
        end
        local colours = palette and self:stickerColourRow(palette, content_w, gap, again) or nil
        local hint = (st.cat == "notes") and self:sheetHint(
            _("Write on a note with the pen or the Text tool, and it moves with the note."), content_w, 13) or nil
        local items = self:stickerItems(st.cat)
        local cols, rows = unpack(PER_PAGE[self:stickersPerPage()])
        local cell_w = math.floor((content_w - (cols - 1) * gap) / cols)
        local cell_h = math.floor(cell_w * 0.84)
        local footer_h = Screen:scaleBySize(48)
        local chrome = title:getSize().h + tabs:getSize().h + (colours and colours:getSize().h or 0)
            + (hint and hint:getSize().h or 0) + footer_h + Screen:scaleBySize(16 + 12 + (colours and 12 or 0) + (hint and 8 or 0) + 12)
        local usable = Screen:getHeight() - self:sheetTopY() - Screen:scaleBySize(10) - 2 * Screen:scaleBySize(18)
        local fit = math.max(1, math.floor((usable - chrome + gap) / (cell_h + gap)))
        rows = math.min(rows, fit)
        local per = cols * rows
        local pages = math.max(1, math.ceil(#items / per))
        st.page = math.max(1, math.min(st.page or 1, pages))
        local first = (st.page - 1) * per

        local g = VerticalGroup:new{ align = "left" }
        local function add(w) g[#g + 1] = w end
        add(title); add(vspan(10)); add(tabs)
        if colours then add(vspan(12)); add(colours) end
        add(vspan(12))
        local last = self:getSetting("inkaway_sticker_last")
        local shown = 0
        for r = 1, rows do
            local row = HorizontalGroup:new{ align = "center" }
            for c = 1, cols do
                local item = items[first + (r - 1) * cols + c]
                if c > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
                if item then
                    row[#row + 1] = self:stickerTile(item, body, cell_w, cell_h, item.kind == "built" and item.s.id == last)
                    shown = shown + 1
                else
                    row[#row + 1] = HorizontalSpan:new{ width = cell_w }
                end
            end
            if shown > 0 or r == 1 then add(row) end
            if r < rows and first + r * cols < #items then add(vspan(10)) end
        end
        if #items == 0 then
            add(self:sheetHint(_("Nothing here. Hidden stickers come back in the sticker options."), content_w, 14))
        end
        if hint then add(vspan(8)); add(hint) end
        if pages <= 1 then return g end   -- (one page: nothing to turn)
        -- (the reader's page turn buttons turn its pages too, as on every paged sheet: #79)
        require("ink/ui/iconmenu").pager(function(d)
            local p = st.page + d
            if p >= 1 and p <= pages then st.page = p; again() end
        end)
        add(vspan(12))
        local TextWidget = require("ui/widget/textwidget")
        local Font = require("ui/font")
        local mid = math.floor(content_w * 0.2)
        local side = math.floor((content_w - mid - 2 * gap) / 2)
        add(HorizontalGroup:new{ align = "center",
            self:actionButton("\u{2039} " .. _("Prev"), side, function()
                if st.page > 1 then st.page = st.page - 1; again() end
            end),
            HorizontalSpan:new{ width = gap },
            require("ui/widget/container/centercontainer"):new{
                dimen = require("ui/geometry"):new{ w = mid, h = footer_h },
                TextWidget:new{ text = string.format("%d / %d", st.page, pages), face = Font:getFace("cfont", 16) } },
            HorizontalSpan:new{ width = gap },
            self:actionButton(_("Next") .. " \u{203A}", side, function()
                if st.page < pages then st.page = st.page + 1; again() end
            end) })
        return g
    end
    self:showSheet("_stickers", build, { on_closed = function() self:freeStickerThumbs() end })
end

------------------------------------------------------------------------------
-- The options
------------------------------------------------------------------------------

-- How many stickers a page of the sheet shows, where the button is, and bringing
-- back the stickers that were hidden.
function InkAwayView:openStickerOptions()
    self:closeSheet("_stk_options")
    local content_w = self:sheetWidth()
    local function close() self:closeSheet("_stk_options") end
    local function again() self:rebuildSheet("_stk_options") end
    local build = function(menu)
        local g = VerticalGroup:new{ align = "left" }
        local function add(w) g[#g + 1] = w end
        add(self:sheetTitle(_("Sticker options"), content_w, _("Done"), function() close(); self:openStickers() end))
        add(vspan(14))
        add(self:sheetLabel(_("Stickers per page")))
        add(vspan(6))
        add(self:segmentedRow({ { 4, "4" }, { 6, "6" }, { 9, "9" }, { 12, "12" } }, self:stickersPerPage(), content_w,
            function(n) self:setSetting("inkaway_stickers_per_page", n); again() end))
        add(vspan(14))
        add(ToggleRow:new{ label = _("Stickers button in the toolbar"), is_on = self:stickersInToolbar(),
            width = content_w, parent = menu,
            callback = function(on) self:setStickersInToolbar(on); again() end })
        add(vspan(4))
        add(self:sheetHint(_("Off keeps the toolbar shorter: stickers are then under Image."), content_w))
        local hidden = 0
        for _id in pairs(self:stickerHidden()) do hidden = hidden + 1 end
        if hidden > 0 then
            add(vspan(14))
            add(self:actionButton(string.format(_("Show all stickers (%d hidden)"), hidden), content_w, function()
                self:restoreStickers(); again()
            end))
        end
        return g
    end
    self:showSheet("_stk_options", build)
end

return InkAwayView
