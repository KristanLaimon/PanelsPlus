--[[
The two row controls used in the sheets: ToggleRow (a label and a sliding switch)
and SliderRow (a label, a draggable track and the value). A switch that is on
and a slider's filled part take the accent (see ink/accent.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Accent = require("ink/accent")
local Theme = require("ink/ui/theme")
local Paint = require("ink/paint")

local Screen = Device.screen
local TRACK_BG = Paint.TRACK_BG
local KNOB_EDGE = Paint.KNOB_EDGE

-- A rounded bar of w x h filled with `color` (a track, or a slider's filled part).
local function pill(w, h, color)
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, radius = math.floor(h / 2),
        background = color, WidgetContainer:new{ dimen = GeomUI:new{ w = w, h = h } } }
end

-- A bar of w x h in a chosen accent, painted by Accent: round at both ends, or
-- (`bar`) only on the left, for a slider's fill, which then repaints at any width
-- while it is dragged without drawing a new image each step.
local AccentPill = WidgetContainer:extend{ bar = false }
function AccentPill:getSize() return self.dimen end
function AccentPill:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y     -- where it is, for dark (see Theme.restore)
    local w, h = self.dimen.w, self.dimen.h
    if self.bar then Accent.paintBar(bb, x, y, w, h)
    else Accent.paintRounded(bb, x, y, w, h, math.floor(h / 2)) end
end

-- A bar in the accent: black by default, as before.
local function accentPill(w, h, bar)
    if not Accent.get().custom then return pill(w, h, Blitbuffer.COLOR_BLACK) end
    -- a theme colour stays itself in dark
    return Theme.keep(AccentPill:new{ dimen = GeomUI:new{ w = w, h = h }, bar = bar }, bar and 0 or math.floor(h / 2))
end

-- The round white knob of diameter d, with a thin grey rim.
local function knob(d)
    return FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = KNOB_EDGE,
        padding = 0, margin = 0, radius = math.floor(d / 2), background = Blitbuffer.COLOR_WHITE,
        WidgetContainer:new{ dimen = GeomUI:new{ w = d - Screen:scaleBySize(2), h = d - Screen:scaleBySize(2) } } }
end

-- A sliding on/off toggle row: a label and a pill switch (grey track with the
-- knob on the left when off, black with the knob on the right when on). The
-- whole row is one tap target and flips in place; `parent` is the shown widget
-- used as the repaint target.
local ToggleRow = InputContainer:extend{
    label = "", is_on = false, width = nil, callback = nil, parent = nil,
}
function ToggleRow:init()
    self.sw_h = Screen:scaleBySize(30)
    self.sw_w = Screen:scaleBySize(54)
    self:_build()
    if Device:isTouchDevice() then
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap",
            range = function() return self.dimen end } } }
    end
end
function ToggleRow:_switch()
    local w, h = self.sw_w, self.sw_h
    local track = self.is_on and accentPill(w, h) or pill(w, h, TRACK_BG)
    local d = h - Screen:scaleBySize(6)
    local inset = Screen:scaleBySize(3)
    local thumb = knob(d)
    thumb.overlap_offset = { self.is_on and (w - d - inset) or inset, math.floor((h - d) / 2) }
    return OverlapGroup:new{ dimen = { w = w, h = h }, allow_mirroring = false, track, thumb }
end
function ToggleRow:_build()
    local label = TextWidget:new{ text = self.label, face = Font:getFace("cfont", 18) }
    local sw = self:_switch()
    local span
    if self.compact then
        -- the switch sits right after the label; the row is as wide as its content
        span = Screen:scaleBySize(12)
        self.width = label:getSize().w + span + self.sw_w
    else
        span = math.max(Screen:scaleBySize(8), self.width - label:getSize().w - self.sw_w)
    end
    self[1] = HorizontalGroup:new{ align = "center",
        label, HorizontalSpan:new{ width = span }, sw }
    local sz = self[1]:getSize()
    self.dimen = GeomUI:new{ x = 0, y = 0, w = self.width, h = sz.h }
end
function ToggleRow:onTap()
    self.is_on = not self.is_on
    self:_build()
    if self.callback then self.callback(self.is_on) end
    UIManager:setDirty(self.parent or self, "ui", self.dimen)
    return true
end
function ToggleRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

-- A horizontal slider row (0..100): a label on the left, a draggable track in
-- the middle, and the value on the right. Tap or drag the track to set it; the
-- value flips in place. `parent` is the shown widget used as the repaint target.
local SliderRow = InputContainer:extend{
    label = "", value = 0, width = nil, on_set = nil, parent = nil, on_release = nil,
    min = 0, max = 100, step = 1, format = nil,   -- format(v) -> value text (default "N%")
}
function SliderRow:_fmt(v) return self.format and self.format(v) or string.format("%d%%", v) end
function SliderRow:init()
    self.knob = Screen:scaleBySize(26)
    self.track_h = Screen:scaleBySize(8)
    self:_build()
    if Device:isTouchDevice() then
        local range = function() return self.dimen end
        self.ges_events = {
            SlTap = { GestureRange:new{ ges = "tap", range = range } },
            SlPan = { GestureRange:new{ ges = "pan", range = range } },
            SlPanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
            SlHold = { GestureRange:new{ ges = "hold", range = range } },
            SlHoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
            -- KOReader ends any drag lifted within ~0.9 s as a swipe (or a
            -- multiswipe if it changed direction) instead of a pan release.
            -- Unclaimed, the sheet's MovableContainer moves the whole sheet on it.
            SlSwipe = { GestureRange:new{ ges = "swipe", range = range } },
            SlMultiSwipe = { GestureRange:new{ ges = "multiswipe", range = range } },
        }
    end
end
function SliderRow:_build()
    local gap = Screen:scaleBySize(14)
    local labelw = TextWidget:new{ text = self.label, face = Font:getFace("cfont", 18) }
    local valw = TextWidget:new{ text = self:_fmt(self.value),
        face = Font:getFace("cfont", 16), bold = true }
    -- a fixed width for the value (measured at the max), so the track stays put
    -- as the digits change
    local val_w = Screen:scaleBySize(40)
    for _i, v in ipairs({ self.max, self.min, self.value }) do
        local t = TextWidget:new{ text = self:_fmt(v), face = Font:getFace("cfont", 16), bold = true }
        val_w = math.max(val_w, t:getSize().w + Screen:scaleBySize(2)); t:free()
    end
    local track_w = self.width - labelw:getSize().w - val_w - 2 * gap
    self._track_w = track_w
    self._track_dx = labelw:getSize().w + gap
    local frac = math.max(0, math.min(1, (self.value - self.min) / (self.max - self.min)))
    local th, kn = self.track_h, self.knob
    local ty = math.floor((kn - th) / 2)
    local fillW = math.max(th, math.floor(track_w * frac))
    local track = pill(track_w, th, TRACK_BG)
    track.overlap_offset = { 0, ty }
    local fill = accentPill(fillW, th, true)
    fill.overlap_offset = { 0, ty }
    local thumb = knob(kn)
    thumb.overlap_offset = { math.max(0, math.min(track_w - kn, math.floor(track_w * frac) - math.floor(kn / 2))), 0 }
    local trackGroup = OverlapGroup:new{ dimen = { w = track_w, h = kn }, allow_mirroring = false,
        track, fill, thumb }
    self[1] = HorizontalGroup:new{ align = "center",
        labelw, HorizontalSpan:new{ width = gap }, trackGroup, HorizontalSpan:new{ width = gap }, valw }
    -- kept so _apply can update the moving parts without rebuilding the row
    self._fill_wc, self._knob, self._valw = fill[1] or fill, thumb, valw
    local sz = self[1]:getSize()
    self.dimen = GeomUI:new{ x = 0, y = 0, w = self.width, h = sz.h }
end
-- Update the fill width, knob position and value text in place for the current
-- value, with no rebuild per drag step.
function SliderRow:_apply()
    local track_w, th, kn = self._track_w, self.track_h, self.knob
    local frac = math.max(0, math.min(1, (self.value - self.min) / (self.max - self.min)))
    if self._fill_wc then self._fill_wc.dimen.w = math.max(th, math.floor(track_w * frac)) end
    if self._knob then
        self._knob.overlap_offset[1] =
            math.max(0, math.min(track_w - kn, math.floor(track_w * frac) - math.floor(kn / 2)))
    end
    if self._valw then self._valw:setText(self:_fmt(self.value)) end
end
function SliderRow:_setFromX(x, mode)
    if not (self.dimen and self._track_w and self._track_w > 0) then return end
    local rel = x - (self.dimen.x + self._track_dx)
    local frac = math.max(0, math.min(1, rel / self._track_w))
    local v = self.min + frac * (self.max - self.min)
    v = self.min + math.floor((v - self.min) / self.step + 0.5) * self.step
    v = math.max(self.min, math.min(self.max, v))
    if v ~= self.value then
        self.value = v
        self:_apply()   -- update the moving parts in place; no rebuild, dimen unchanged
        if self.on_set then self.on_set(v) end
        -- Refresh only the band from the track to the value: with the fast
        -- black-and-white waveform while dragging, then with "ui" on release so
        -- the grey track shows. The sheet stays the repaint target, so it is
        -- painted over anything on_set refreshed underneath (a grid preview).
        local band = GeomUI:new{ x = self.dimen.x + self._track_dx, y = self.dimen.y,
            w = self.width - self._track_dx, h = self.dimen.h }
        UIManager:setDirty(self.parent or self, mode or "ui", band)
    end
end
function SliderRow:_released()
    if self.on_release then self.on_release(self.value) end
end
function SliderRow:onSlTap(_, ges) self:_setFromX(ges.pos.x, "ui"); self:_released(); return true end
function SliderRow:onSlPan(_, ges) self:_setFromX(ges.pos.x, "fast"); return true end
function SliderRow:onSlHold(_, ges) self:_setFromX(ges.pos.x, "fast"); return true end
function SliderRow:onSlHoldPan(_, ges) self:_setFromX(ges.pos.x, "fast"); return true end
-- A swipe's pos is where it started (on the slider); the value comes from where
-- it lifted.
function SliderRow:onSlSwipe(_, ges)
    local p = ges and (ges.end_pos or ges.pos)
    if p then self:_setFromX(p.x, "ui") end
    UIManager:setDirty(self.parent or self, "ui", self.dimen)
    self:_released()
    return true
end
SliderRow.onSlMultiSwipe = SliderRow.onSlSwipe
function SliderRow:onSlPanRelease(_, ges) if ges and ges.pos then self:_setFromX(ges.pos.x, "ui")
    else UIManager:setDirty(self.parent or self, "ui", self.dimen) end; self:_released(); return true end
function SliderRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

return { ToggleRow = ToggleRow, SliderRow = SliderRow }
