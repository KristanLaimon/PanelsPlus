--[[
The narrow toolbar Ink Away uses over a book: in the annotation mode
(ink/reader/inkview.lua), along a side of the screen the reader chooses (down
the left by default, the right, or across the top or bottom), and in the book
notes window (ink/reader/notesview.lua), down the window's left. Mixed into a
view class with VBar.into(Class); the view gives the buttons (buildVBar) and
says which tool is active (vbarActive), and paintTo places the bar at
self._bar_x, self._bar_y.

Its measures: _vb_side (left, right, top or bottom), _vb_cell (a button's size
along the bar), _vb_thick (the bar's thickness) and _vbar_h (its length); a
bar down a side also keeps them as _btn_h and _bar_w.
]]

local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Accent = require("ink/accent")
local Paint = require("ink/paint")

local Screen = Device.screen

local VBar = {}

-- The thinnest and thickest a bar sized to a book's margin may be (see
-- VBar.fitThickness): thin enough for a modest margin, thick enough that its
-- icons stay big enough to tap.
function VBar.fitRange()
    return Screen:scaleBySize(26), Screen:scaleBySize(64)
end

-- The space left between a bar fitted in the margin and the book's text, so it
-- does not end right where the text begins (about a millimetre).
function VBar.fitGap()
    return Screen:scaleBySize(6)
end

-- The bar's thickness for a margin `m` px wide, kept within fitRange.
function VBar.fitThickness(m)
    local lo, hi = VBar.fitRange()
    return math.max(lo, math.min(hi, math.floor(m)))
end

-- The bar of buttons, `len` long, along `side` (left by default): specs are
-- { id, icon, tool, cb }. `fit`, when given, is the thickness to take (the
-- book's margin there, see VBar.fitThickness) instead of the usual one; the
-- icons are sized to it.
function VBar:buildVBar(specs, len, side, fit)
    self:ensureUserIcons()
    side = side or "left"
    local across = side == "top" or side == "bottom"
    local n = #specs
    local cell = math.floor(len / n)
    local thick, isz
    if across then
        thick = fit or math.max(Screen:scaleBySize(32), math.min(Screen:scaleBySize(46), math.floor(cell * 0.9)))
        isz = math.max(14, math.min(math.floor(thick * 0.62), math.floor(cell * 0.6)))
    else
        thick = fit or math.max(Screen:scaleBySize(36), math.min(Screen:scaleBySize(50), math.floor(cell * 1.15)))
        isz = math.max(14, math.min(math.floor(thick * 0.6), math.floor(cell * 0.62)))
    end
    self._vb_side, self._vb_cell, self._vb_thick, self._vbar_h = side, cell, thick, len
    self._btn_h, self._bar_w, self._icon_sz = cell, thick, isz
    self.tool_buttons, self._toolbar_icons = {}, {}
    local group = across and HorizontalGroup:new{ align = "center" } or VerticalGroup:new{ align = "center" }
    for i, s in ipairs(specs) do
        local size = (i == n) and (len - cell * (n - 1)) or cell
        local raw = s.cb
        local b = Button:new{ icon = "inkaway." .. s.icon, icon_width = isz, icon_height = isz,
            callback = function()
                local ok, err = xpcall(raw, debug.traceback)
                if not ok then logger.warn("Ink Away book toolbar '" .. s.id .. "' failed: " .. tostring(err)) end
            end,
            width = across and size or thick, height = across and thick or size,
            bordersize = 0, radius = 0, background = nil, margin = 0, padding = 0, show_parent = self }
        local path = self:pluginDir() .. "ink/icons/" .. s.icon .. ".svg"
        local ok_icon, icon = pcall(function() return IconWidget:new{ file = path, width = isz, height = isz } end)
        if ok_icon and icon then self:setButtonLabel(b, icon) end
        if b.frame then b.frame.background = nil end
        if s.tool then self.tool_buttons[s.id] = { button = b } end
        self._toolbar_icons[i] = { button = b, id = s.id, tool = s.tool == true,
            icon = ok_icon and icon or nil, path = path, size = isz }
        table.insert(group, b)
    end
    self.toolbar = FrameContainer:new{ background = nil, bordersize = 0, padding = 0, margin = 0, group }
    self._bar_h = nil        -- the canvas's own toolbar measures do not apply
    self:updateToolbarActive()
end

-- Button i's cell on the screen, the bar's top-left at (ox, oy): x, y, w, h.
function VBar:vbarCell(i, ox, oy)
    local cell, thick = self._vb_cell or self._btn_h, self._vb_thick or self._bar_w
    if self._vb_side == "top" or self._vb_side == "bottom" then
        return ox + cell * (i - 1), oy, cell, thick
    end
    return ox, oy + cell * (i - 1), thick, cell
end

-- The active tool's button shows it (tinted on a colour screen, inverted on grey).
function VBar:updateToolbarActive()
    if not self._toolbar_icons then return end
    local active = self:vbarActive()
    self._active_btn_idx = nil
    for i, e in ipairs(self._toolbar_icons) do
        if e.tool and e.button then
            local on = (e.id == active)
            if on then self._active_btn_idx = i end
            local tinted = on and e.path and Accent.icon(e.path, e.size)
            if tinted then
                self:setButtonLabel(e.button, ImageWidget:new{ image = tinted, width = e.size, height = e.size,
                    image_disposable = false })
            elseif e.icon then
                if e.button.label_widget ~= e.icon then self:setButtonLabel(e.button, e.icon) end
                e.icon.invert = on
            end
        end
    end
end

-- Which tool's button is active (the shape button stands for the fill too).
function VBar:vbarActive()
    return (self.tool == "fill") and "shape" or self.tool
end

-- The rounded pill behind the active tool; (ox, oy) is the bar's top-left.
function VBar:drawActiveToolPill(bb, ox, oy)
    if not (self._active_btn_idx and self._btn_h and self._bar_w) then return end
    local m = Screen:scaleBySize(5)
    local x, y, w, h = self:vbarCell(self._active_btn_idx, ox, oy)
    local r = Screen:scaleBySize(9)
    Accent.paintRounded(bb, x + m, y + m, w - 2 * m, h - 2 * m, r)
    self._pill_rect = { x = x + m, y = y + m, w = w - 2 * m, h = h - 2 * m, r = r }   -- for dark
end

-- The hairline between the bar and the page, and the pen in hand's colour
-- under its button (the highlighter's, when it is the highlighter).
function VBar:drawToolbarIcons(bb, ox, oy)
    self._pen_mark_rect = nil
    if not self._bar_w then return end
    ox, oy = ox or 0, oy or 0
    local side, thick, len = self._vb_side or "left", self._vb_thick or self._bar_w, self._vbar_h or self.screen_h
    if side == "right" then bb:paintRect(ox, oy, 1, len, Paint.HAIRLINE)
    elseif side == "top" then bb:paintRect(ox, oy + thick - 1, len, 1, Paint.HAIRLINE)
    elseif side == "bottom" then bb:paintRect(ox, oy, len, 1, Paint.HAIRLINE)
    else bb:paintRect(ox + thick - 1, oy, 1, len, Paint.HAIRLINE) end
    local want = self.pen_style == "highlighter" and "highlight" or "pen"
    for i, e in ipairs(self._toolbar_icons or {}) do
        if e.id == want or (want == "highlight" and e.id == "pen" and not self:vbarHas("highlight")) then
            self:paintPenMark(bb, self:vbarCell(i, ox, oy))
            break
        end
    end
end

-- Is there a button `id` in the column?
function VBar:vbarHas(id)
    for _i, e in ipairs(self._toolbar_icons or {}) do if e.id == id then return true end end
    return false
end

-- Add these to a view class.
function VBar.into(Class)
    for k, f in pairs(VBar) do
        if k ~= "into" then Class[k] = f end
    end
end

return VBar
