--[[
The colour wheel, for an exact colour beyond the swatches: hue around the rim,
saturation toward the centre, a brightness slider and a live preview. A colour
can be used once or saved to the pen menu's swatches. It paints itself and reads
its own touches; fills go through Paint.fillRect, as paintRect flattens a colour
to grey.
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
local _ = require("ink/l10n")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")
local Theme = require("ink/ui/theme")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK

local floor, sqrt, atan2, cos, sin, pi = math.floor, math.sqrt, math.atan2, math.cos, math.sin, math.pi

-- Convert HSV (0..1) to R, G, B (0..255).
local function hsv2rgb(h, s, v)
    local i = floor(h * 6)
    local f = h * 6 - i
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    local r, g, b
    i = i % 6
    if     i == 0 then r, g, b = v, t, p
    elseif i == 1 then r, g, b = q, v, p
    elseif i == 2 then r, g, b = p, v, t
    elseif i == 3 then r, g, b = p, q, v
    elseif i == 4 then r, g, b = t, p, v
    else               r, g, b = v, p, q end
    return floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5)
end

-- Convert R, G, B (0..255) to H, S, V (0..1).
local function rgb2hsv(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d = mx - mn
    local h = 0
    if d > 0 then
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h / 6
    end
    return h, (mx == 0 and 0 or d / mx), mx
end

local ColorPicker = InputContainer:extend{
    title = nil,     -- the heading ("Custom colour" by default)
    color = nil,     -- initial {r,g,b}
    on_pick = nil,   -- function(rgb) apply the colour
    on_save = nil,   -- function(rgb) save the colour, then apply; no Save button without it
    modal = true,
    stop_events_propagation = true,
}

function ColorPicker:init()
    local c = self.color or { 0xD0, 0x00, 0x00 }
    self.h, self.s, self.v = rgb2hsv(c[1], c[2], c[3])

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.pad = Screen:scaleBySize(16)
    self.title_h = Screen:scaleBySize(38)
    self.slider_h = Screen:scaleBySize(48)
    self.preview_h = Screen:scaleBySize(56)
    self.btn_h = Screen:scaleBySize(48)
    self.box_w = floor(math.min(sw * 0.9, Screen:scaleBySize(340)))
    self.wheel_d = self.box_w - self.pad * 2
    local function measure()
        self.box_h = self.title_h + self.wheel_d + self.pad + self.slider_h
                     + self.pad + self.preview_h + self.pad + self.btn_h + self.pad * 2
    end
    measure()
    local avail = sh - Screen:scaleBySize(20)
    if self.box_h > avail then
        -- shrink the wheel (the tall part) to fit small screens
        self.wheel_d = self.wheel_d - (self.box_h - avail)
        if self.wheel_d < Screen:scaleBySize(120) then self.wheel_d = Screen:scaleBySize(120) end
        measure()
    end
    self.box_x = floor((sw - self.box_w) / 2)
    self.box_y = math.max(Screen:scaleBySize(10), floor((sh - self.box_h) / 2))
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.panel = Geom:new{ x = self.box_x, y = self.box_y, w = self.box_w, h = self.box_h }

    self.wheel_bb = ColorPicker.cachedWheel(self.wheel_d)

    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        local pan_rate = Screen.low_pan_rate and 2.0 or 30.0   -- KOReader's per-device gesture rate
        self.ges_events = {
            CpTap = { GestureRange:new{ ges = "tap", range = full } },
            CpPan = { GestureRange:new{ ges = "pan", range = full, rate = pan_rate } },
            CpHoldPan = { GestureRange:new{ ges = "hold_pan", range = full, rate = pan_rate } },
        }
    end
end

function ColorPicker:onShow()
    UIManager:setDirty(self, "ui", self.panel)
    return true
end

-- Fill the wheel bitmap once: hue around the rim, saturation to the centre, at
-- full brightness (the slider dims the chosen colour, not the wheel).
-- Paint a hue/saturation wheel of diameter D into bb (D x D), on `bg` (white by
-- default) outside the circle. The theme colour row shows a small one.
function ColorPicker.paintWheel(bb, D, bg)
    bg = bg or WHITE
    local R = D / 2
    local r2 = R * R
    for py = 0, D - 1 do
        local dy = py - R
        for px = 0, D - 1 do
            local dx = px - R
            local dist2 = dx * dx + dy * dy
            if dist2 <= r2 then
                local h = atan2(dy, dx) / (2 * pi)
                if h < 0 then h = h + 1 end
                local s = sqrt(dist2) / R
                local r, g, b = hsv2rgb(h, s, 1)
                bb:setPixel(px, py, Blitbuffer.ColorRGB32(r, g, b, 0xFF))
            else
                bb:setPixel(px, py, bg)
            end
        end
    end
end

-- The wheel never changes, so one of each size is drawn once and kept until
-- Ink Away closes (ColorPicker.freeCache); a picker only borrows it.
local wheels = {}
function ColorPicker.cachedWheel(d)
    local key = d .. "|" .. Screen.bb:getType()
    if not wheels[key] then
        local bb = Blitbuffer.new(d, d, Screen.bb:getType())
        ColorPicker.paintWheel(bb, d)
        wheels[key] = bb
    end
    return wheels[key]
end

function ColorPicker.freeCache()
    for k, bb in pairs(wheels) do bb:free(); wheels[k] = nil end
end

function ColorPicker:selectedRGB()
    return hsv2rgb(self.h, self.s, self.v)
end

-- Geometry helpers, all in screen coordinates.
function ColorPicker:wheelRect()
    return self.box_x + self.pad, self.box_y + self.title_h, self.wheel_d, self.wheel_d
end
function ColorPicker:sliderRect()
    local x = self.box_x + self.pad
    local y = self.box_y + self.title_h + self.wheel_d + self.pad
    return x, y + floor(self.slider_h / 2), self.box_w - self.pad * 2, y
end
function ColorPicker:previewRect()
    local y = self.box_y + self.title_h + self.wheel_d + self.pad + self.slider_h + self.pad
    return { x = self.box_x + self.pad, y = y, w = self.box_w - self.pad * 2, h = self.preview_h }
end
-- The bottom buttons as { rect, label, bold, action }: Use, Save (when there is
-- an on_save) and Cancel, sharing the width.
function ColorPicker:buttons()
    local list = { { _("Use"), true, "use" } }
    if self.on_save then list[#list + 1] = { _("Save"), true, "save" } end
    list[#list + 1] = { _("Cancel"), false, "cancel" }
    local y = self.box_y + self.box_h - self.btn_h - self.pad
    local w = self.box_w - self.pad * 2
    local n = #list
    local bw = floor((w - self.pad * (n - 1)) / n)
    local x = self.box_x + self.pad
    local out = {}
    for i, e in ipairs(list) do
        local rw = (i == n) and (self.box_x + self.pad + w - x) or bw
        out[i] = { rect = { x = x, y = y, w = rw, h = self.btn_h }, label = e[1], bold = e[2], action = e[3] }
        x = x + bw + self.pad
    end
    return out
end

-- Fill a rectangle with a colour (Paint.fillRect keeps it a colour).
local function fillColor(bb, x, y, w, h, r, g, b)
    Paint.fillRect(bb, x, y, w, h, Blitbuffer.ColorRGB32(r, g, b, 0xFF), true)
end

function ColorPicker:paintTo(bb, x, y)
    local bx, by = self.box_x + x, self.box_y + y
    bb:paintRect(bx, by, self.box_w, self.box_h, WHITE)
    bb:paintBorder(bx, by, self.box_w, self.box_h, Size.border.window or 2, BLACK)

    local title = TextWidget:new{ text = self.title or _("Custom colour"), face = Font:getFace("tfont", 20),
        fgcolor = BLACK }
    title:paintTo(bb, bx + self.pad, by + floor((self.title_h - title:getSize().h) / 2))
    title:free()

    -- the wheel and its selection marker
    local wx, wy, D = self:wheelRect()
    wx, wy = wx + x, wy + y
    bb:blitFrom(self.wheel_bb, wx, wy, 0, 0, D, D)

    -- brightness slider: a gradient from black to the full colour
    local sx, cy, sw = self:sliderRect()
    sx, cy = sx + x, cy + y
    local th = Screen:scaleBySize(10)
    for i = 0, sw - 1 do
        local r, g, b = hsv2rgb(self.h, self.s, i / (sw - 1))
        fillColor(bb, sx + i, cy - floor(th / 2), 1, th, r, g, b)
    end

    -- preview swatch and RGB readout
    local pr = self:previewRect()
    local px, py = pr.x + x, pr.y + y
    local r, g, b = self:selectedRGB()
    local sww = pr.w - Screen:scaleBySize(120)
    fillColor(bb, px, py, sww, pr.h, r, g, b)
    bb:paintBorder(px, py, sww, pr.h, 1, BLACK)
    local txt = TextWidget:new{ text = string.format("R %d  G %d  B %d", r, g, b),
        face = Font:getFace("cfont", 16), fgcolor = BLACK }
    txt:paintTo(bb, px + sww + Screen:scaleBySize(8), py + floor((pr.h - txt:getSize().h) / 2))
    txt:free()

    -- buttons
    for _, e in ipairs(self:buttons()) do
        local rr, label = e.rect, e.label
        local rx, ry = rr.x + x, rr.y + y
        bb:paintBorder(rx, ry, rr.w, rr.h, e.bold and 2 or 1, BLACK)
        local t = TextWidget:new{ text = label, face = Font:getFace("cfont", 17), fgcolor = BLACK }
        t:paintTo(bb, rx + floor((rr.w - t:getSize().w) / 2), ry + floor((rr.h - t:getSize().h) / 2))
        t:free()
    end

    -- dark (see ink/ui/theme.lua): the panel inverted, the colours kept
    local dark = Theme.invert()
    if dark then
        bb:invertRect(bx, by, self.box_w, self.box_h)
        Theme.invertRounded(bb, wx, wy, D, D, floor(D / 2))
        bb:invertRect(sx, cy - floor(th / 2), sw, th)
        bb:invertRect(px + 1, py + 1, sww - 2, pr.h - 2)
    end

    -- the wheel's selection marker and the slider's knob, over the colours
    local R = D / 2
    local mx = wx + R + cos(self.h * 2 * pi) * self.s * R
    local my = wy + R + sin(self.h * 2 * pi) * self.s * R
    local mr = Screen:scaleBySize(7)
    bb:paintBorder(floor(mx - mr), floor(my - mr), mr * 2, mr * 2, 2, BLACK)
    bb:paintBorder(floor(mx - mr) + 2, floor(my - mr) + 2, mr * 2 - 4, mr * 2 - 4, 1, WHITE)
    local kx = sx + floor(self.v * (sw - 1))
    bb:paintBorder(kx - Screen:scaleBySize(4), cy - floor(th / 2) - 3, Screen:scaleBySize(8), th + 6, 2,
        dark and WHITE or BLACK)
end

function ColorPicker:refresh()
    UIManager:setDirty(self, "ui", self.panel)
end

-- Set the hue and saturation from a point on the wheel; true if it was inside.
function ColorPicker:setFromWheel(px, py)
    local wx, wy, D = self:wheelRect()
    local R = D / 2
    local dx, dy = px - (wx + R), py - (wy + R)
    local dist = sqrt(dx * dx + dy * dy)
    if dist > R + Screen:scaleBySize(6) then return false end
    local h = atan2(dy, dx) / (2 * pi)
    if h < 0 then h = h + 1 end
    self.h = h
    self.s = math.min(1, dist / R)
    self:refresh()
    return true
end

function ColorPicker:setFromSlider(px, py)
    local sx, cy, sw = self:sliderRect()
    if py < cy - self.slider_h or py > cy + self.slider_h then return false end
    if px < sx - Screen:scaleBySize(12) or px > sx + sw + Screen:scaleBySize(12) then return false end
    local v = (px - sx) / (sw - 1)
    self.v = math.max(0, math.min(1, v))
    self:refresh()
    return true
end

function ColorPicker:onCpTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    if self:setFromWheel(p.x, p.y) then return true end
    if self:setFromSlider(p.x, p.y) then return true end
    for _, e in ipairs(self:buttons()) do
        if InkGeom.inRect(p.x, p.y, e.rect) then
            UIManager:close(self)
            local fn = (e.action == "use" and self.on_pick) or (e.action == "save" and self.on_save)
            if fn then fn({ self:selectedRGB() }) end
            return true
        end
    end
    -- tap outside the panel dismisses
    if p.x < self.box_x or p.x > self.box_x + self.box_w or p.y < self.box_y or p.y > self.box_y + self.box_h then
        UIManager:close(self)
    end
    return true
end

function ColorPicker:onCpPan(_, ges)
    local p = ges and ges.pos
    if p then
        if not self:setFromWheel(p.x, p.y) then self:setFromSlider(p.x, p.y) end
    end
    return true
end
ColorPicker.onCpHoldPan = ColorPicker.onCpPan

function ColorPicker:onCloseWidget()
    self.wheel_bb = nil   -- the cache keeps it for the next picker
end

return ColorPicker
