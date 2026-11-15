--[[
The brush maker: a panel with a live sample stroke above sliders for the ink
amount, grain, edge, spread and paper tooth. The sample redraws as a slider moves,
through the same rasterizer the pen uses; a named brush joins the pen menu. It
paints itself and reads its own touches.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Device = require("device")
local Brushes = require("ink/brushes")
local Accent = require("ink/accent")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")
local Theme = require("ink/ui/theme")
local _ = require("ink/l10n")

local Screen = Device.screen

local BrushMaker = InputContainer:extend{
    params = nil,       -- brush params being edited
    on_save = nil,      -- function(name, params) called when saved
    init_name = nil,    -- prefilled name (when editing an existing brush)
    modal = true,
    stop_events_propagation = true,
}

local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
local GREY  = Blitbuffer.COLOR_GRAY
local TILE  = Paint.TILE_BG     -- secondary button fill
local TRACK = Paint.TRACK_BG
local KNOB  = Paint.KNOB_EDGE
local KNOB_DARK = Blitbuffer.Color8(0xFF - KNOB.a)   -- the rim as dark shows it

function BrushMaker:init()
    self.params = self.params or Brushes.defaults()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.box_w = math.floor(math.min(sw * 0.9, Screen:scaleBySize(440)))
    self.pad = Screen:scaleBySize(16)
    self.preview_h = Screen:scaleBySize(120)
    self.row_h = Screen:scaleBySize(52)
    self.btn_h = Screen:scaleBySize(48)
    self.title_h = Screen:scaleBySize(40)
    local rows = #Brushes.FIELDS
    local function measure()
        self.box_h = self.title_h + self.preview_h + self.pad
                     + rows * self.row_h + self.btn_h + self.pad * 2
    end
    measure()
    -- shrink the parts of a panel taller than the screen (high-DPI devices), so
    -- the title and the Save and Cancel buttons are never clipped
    local avail = sh - Screen:scaleBySize(24)
    if self.box_h > avail then
        local k = avail / self.box_h
        self.title_h = math.floor(self.title_h * k)
        self.preview_h = math.floor(self.preview_h * k)
        self.row_h = math.floor(self.row_h * k)
        self.btn_h = math.floor(self.btn_h * k)
        self.pad = math.max(4, math.floor(self.pad * k))
        measure()
    end
    self.box_x = math.floor((sw - self.box_w) / 2)
    self.box_y = math.max(Screen:scaleBySize(12), math.floor((sh - self.box_h) / 2))
    -- span the whole screen, so the panel is always inside the painted and
    -- refreshed region; the box rect is kept for the small slider refreshes
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.panel = Geom:new{ x = self.box_x, y = self.box_y, w = self.box_w, h = self.box_h }

    self.preview_bb = Blitbuffer.new(self.box_w - self.pad * 2, self.preview_h, Screen.bb:getType())
    self:renderPreview()

    if Device:isTouchDevice() then
        -- capture the whole screen, so a touch outside the panel cannot draw on
        -- the canvas behind it; pans are rate-limited by GestureRange's `rate`
        -- (tuned per device through Screen.low_pan_rate)
        local full = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        local pan_rate = Screen.low_pan_rate and 2.0 or 30.0
        self.ges_events = {
            BmTap = { GestureRange:new{ ges = "tap", range = full } },
            BmPan = { GestureRange:new{ ges = "pan", range = full, rate = pan_rate } },
            BmHoldPan = { GestureRange:new{ ges = "hold_pan", range = full, rate = pan_rate } },
        }
    end
end

-- Refresh the whole panel when first shown, rather than only the region the
-- closing pen sheet leaves.
function BrushMaker:onShow()
    UIManager:setDirty(self, "ui", self.panel)
    return true
end

-- Screen rect of slider `i`'s draggable track.
function BrushMaker:trackRect(i)
    local x = self.box_x + self.pad
    local w = self.box_w - self.pad * 2
    local y = self.box_y + self.title_h + self.preview_h + self.pad + (i - 1) * self.row_h
    local label_w = math.floor(w * 0.34)
    local tx = x + label_w
    local tw = w - label_w - Screen:scaleBySize(44)
    return tx, y + math.floor(self.row_h / 2), tw, y, w, x
end

-- The two bottom buttons as screen rects: save, cancel.
function BrushMaker:buttonRects()
    local y = self.box_y + self.box_h - self.btn_h - self.pad
    local w = self.box_w - self.pad * 2
    local half = math.floor((w - self.pad) / 2)
    return { x = self.box_x + self.pad, y = y, w = half, h = self.btn_h },
           { x = self.box_x + self.pad + half + self.pad, y = y, w = half, h = self.btn_h }
end

-- Render the sample stroke with the current params into preview_bb.
function BrushMaker:renderPreview()
    local bb = self.preview_bb
    bb:paintRect(0, 0, bb:getWidth(), bb:getHeight(), WHITE)
    local st = {}
    for k, v in pairs(self.params) do st[k] = v end
    -- a gentle S so the stroke shows body, edge and taper
    Paint.brushSample(bb, st, BLACK, self.pad, math.max(6, Screen:scaleBySize(9)), 0.24, 40)
end

function BrushMaker:paintTo(bb, x, y)
    local bx, by, bw, bh = self.box_x + x, self.box_y + y, self.box_w, self.box_h
    local radius = Screen:scaleBySize(28)
    -- panel (rounded, to match the tool sheets)
    bb:paintRoundedRect(bx, by, bw, bh, WHITE, radius)
    bb:paintBorder(bx, by, bw, bh, Size.border.window or 2, BLACK, radius)

    -- title
    local title = TextWidget:new{ text = _("Create brush"), face = Font:getFace("cfont", 22), bold = true, fgcolor = BLACK }
    title:paintTo(bb, bx + self.pad, by + math.floor((self.title_h - title:getSize().h) / 2))
    title:free()

    -- preview (rounded frame)
    local pv_r = Screen:scaleBySize(12)
    bb:blitFrom(self.preview_bb, bx + self.pad, by + self.title_h, 0, 0,
        self.preview_bb:getWidth(), self.preview_bb:getHeight())
    bb:paintBorder(bx + self.pad, by + self.title_h, self.preview_bb:getWidth(),
        self.preview_bb:getHeight(), 1, GREY, pv_r)

    -- what keeps its colours in dark (the preview, a theme colour), and the
    -- knobs, drawn last over the fills
    local custom = Accent.get().custom
    local keeps = { { bx + self.pad, by + self.title_h, self.preview_bb:getWidth(), self.preview_bb:getHeight(), pv_r } }
    local knobs = {}

    -- sliders: a pill track, black fill and round white knob, like the sheets
    for i, f in ipairs(Brushes.FIELDS) do
        local tx, cy, tw, _ry, _w, rx = self:trackRect(i)
        tx = tx + x; cy = cy + y; rx = rx + x
        local lbl = TextWidget:new{ text = _(f.label), face = Font:getFace("cfont", 17), fgcolor = BLACK }
        lbl:paintTo(bb, rx, cy - math.floor(lbl:getSize().h / 2))
        lbl:free()
        local th = Screen:scaleBySize(8)
        local tr = math.floor(th / 2)
        bb:paintRoundedRect(tx, cy - tr, tw, th, TRACK, tr)
        local val = self.params[f.id] or f.min
        local frac = (val - f.min) / (f.max - f.min)
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        local fillw = math.floor(tw * frac)
        if fillw > 0 then
            Accent.paintBar(bb, tx, cy - tr, math.max(th, fillw), th)
            if custom then keeps[#keeps + 1] = { tx, cy - tr, math.max(th, fillw), th, tr } end
        end
        local kd = Screen:scaleBySize(24)
        local kx = math.max(tx, math.min(tx + tw - kd, tx + fillw - math.floor(kd / 2)))
        knobs[#knobs + 1] = { kx, cy - math.floor(kd / 2), kd }
        local shown = f.step and tostring(math.floor(val + 0.5))
                              or tostring(math.floor(frac * 100 + 0.5))
        local vw = TextWidget:new{ text = shown, face = Font:getFace("cfont", 15), bold = true, fgcolor = BLACK }
        vw:paintTo(bb, tx + tw + Screen:scaleBySize(8), cy - math.floor(vw:getSize().h / 2))
        vw:free()
    end

    -- buttons: Save in the accent (black by default), Cancel grey
    local save, cancel = self:buttonRects()
    local br = Screen:scaleBySize(14)
    for _, b in ipairs({ { save, _("Save brush"), true }, { cancel, _("Cancel"), false } }) do
        local r, label = b[1], b[2]
        if b[3] then
            Accent.paintRounded(bb, r.x + x, r.y + y, r.w, r.h, br)
            if custom then keeps[#keeps + 1] = { r.x + x, r.y + y, r.w, r.h, br } end
        else bb:paintRoundedRect(r.x + x, r.y + y, r.w, r.h, TILE, br) end
        local t = TextWidget:new{ text = label, face = Font:getFace("cfont", 18), bold = true,
            fgcolor = b[3] and Accent.get().text or BLACK }
        t:paintTo(bb, r.x + x + math.floor((r.w - t:getSize().w) / 2),
                      r.y + y + math.floor((r.h - t:getSize().h) / 2))
        t:free()
    end

    -- dark (see ink/ui/theme.lua): the panel inverted, the kept parts back
    local dark = Theme.invert()
    if dark then
        Theme.invertRounded(bb, bx, by, bw, bh, radius)
        for _i, k in ipairs(keeps) do Theme.invertRounded(bb, k[1], k[2], k[3], k[4], k[5]) end
    end
    for _i, k in ipairs(knobs) do
        local kx, ky, kd = k[1], k[2], k[3]
        bb:paintRoundedRect(kx, ky, kd, kd, dark and BLACK or WHITE, math.floor(kd / 2))
        bb:paintBorder(kx, ky, kd, kd, Screen:scaleBySize(1), dark and KNOB_DARK or KNOB, math.floor(kd / 2))
    end
end

-- The slider a screen point falls on, with a generous vertical band, or nil.
function BrushMaker:sliderAt(px, py)
    for i, f in ipairs(Brushes.FIELDS) do
        local tx, cy, tw = self:trackRect(i)
        if py >= cy - self.row_h / 2 and py <= cy + self.row_h / 2
           and px >= tx - Screen:scaleBySize(12) and px <= tx + tw + Screen:scaleBySize(12) then
            local frac = (px - tx) / tw
            if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
            local val = f.min + frac * (f.max - f.min)
            if f.step then val = math.floor(val / f.step + 0.5) * f.step end
            return f, val
        end
    end
end

function BrushMaker:setSlider(px, py)
    local f, val = self:sliderAt(px, py)
    if not f then return false end
    if self.params[f.id] ~= val then
        -- pans are rate-limited by the GestureRange, so redraw directly
        self.params[f.id] = val
        self:renderPreview()
        UIManager:setDirty(self, "fast", self.panel)
    end
    return true
end

function BrushMaker:onBmTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    if self:setSlider(p.x, p.y) then return true end
    local save, cancel = self:buttonRects()
    if InkGeom.inRect(p.x, p.y, save) then self:promptName(); return true end
    if InkGeom.inRect(p.x, p.y, cancel) then UIManager:close(self); return true end
    -- a tap outside the panel dismisses it
    if p.x < self.box_x or p.x > self.box_x + self.box_w
       or p.y < self.box_y or p.y > self.box_y + self.box_h then
        UIManager:close(self)
    end
    return true
end

function BrushMaker:onBmPan(_, ges)
    local p = ges and ges.pos
    if p then self:setSlider(p.x, p.y) end
    return true
end
BrushMaker.onBmHoldPan = BrushMaker.onBmPan

function BrushMaker:promptName()
    -- close the full-screen maker before showing the name entry, which would
    -- otherwise open behind it (keyboard included)
    local on_save, params, init_name = self.on_save, self.params, self.init_name
    UIManager:close(self)
    if not self.prompt then return end
    self.prompt{
        title = _("Name this brush"),
        input = init_name or os.date("brush-%H%M%S"),
        ok_text = _("Save"),
        on_ok = function(name)
            if not name or name == "" then return end
            name = name:gsub("[/\\%[%]\"]", " ")   -- keep it a plain, storable name
            if on_save then on_save(name, params) end
        end,
    }
end

function BrushMaker:onCloseWidget()
    if self.preview_bb then self.preview_bb:free(); self.preview_bb = nil end
    -- repaint the whole screen as the panel leaves: "all" runs every remaining
    -- widget's paintTo, where nil would only refresh the panel from the stale
    -- buffer and leave the panel's edges behind
    UIManager:setDirty("all", "full")
end

return BrushMaker
