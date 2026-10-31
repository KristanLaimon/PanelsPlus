--[[
A sheet's scroll area with arrow buttons: KOReader's ScrollableContainer for the
content, and beside it a column of an up arrow, the scrollbar and a down arrow.
On e-ink a drag through a sheet full of toggles and sliders often moves one of
them instead of the sheet, so a tap on an arrow scrolls most of a screenful.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Paint = require("ink/paint")

local Screen = Device.screen
local DIR = (debug.getinfo(1, "S").source:match("^@(.*/)ink/")) or "./"

local ArrowScroll = {}

-- How much an arrow scrolls: most of what shows, so a line stays in view.
ArrowScroll.STEP = 0.8

-- The two widget classes, made the first time a sheet scrolls (so asking only
-- for extraWidth needs none of KOReader's scroll widgets):
--   Scroller: ScrollableContainer without a scrollbar of its own (the column
--     has it), so the content keeps its whole width.
--   Bar: the scrollbar, set from the scroller each time it is painted. A tap or
--     drag on it scrolls there, as on KOReader's own.
local Scroller, Bar
local function classes()
    if Scroller then return Scroller, Bar end
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    Scroller = ScrollableContainer:extend{ scroll_bar_width = 0 }
    function Scroller:initState()
        ScrollableContainer.initState(self)
        self._v_scroll_bar, self._h_scroll_bar = nil, nil
    end
    Bar = WidgetContainer:extend{}
    function Bar:getSize() return { w = self.w, h = self.h } end
    function Bar:paintTo(bb, x, y)
        local s = self.scroller
        if not s._is_scrollable then return end
        local total = s._max_scroll_offset_y + s._crop_h
        self[1]:set(s._scroll_offset_y / total, (s._scroll_offset_y + s._crop_h) / total)
        self[1]:paintTo(bb, x + math.floor((self.w - self[1].width) / 2), y)
    end
    return Scroller, Bar
end

-- A square grey rounded button with an arrow, as the sheets' other buttons.
local function arrow(name, size, cb, parent)
    local radius = Screen:scaleBySize(12)
    local b = Button:new{ text = "", width = size, height = size, bordersize = 0,
        radius = radius, background = Paint.TILE_BG,
        margin = 0, padding = 0, callback = cb, show_parent = parent }
    -- KOReader's tap highlight ends by leaving the corners square; the sheet's
    -- other buttons are built again after a tap, these stay, so they get them back
    local undo = b._undoFeedbackHighlight
    function b:_undoFeedbackHighlight(...)
        undo(self, ...)
        if self[1].radius ~= radius then
            self[1].radius = radius
            UIManager:widgetRepaint(self[1], self[1].dimen.x, self[1].dimen.y)
        end
    end
    local isz = Screen:scaleBySize(22)
    -- (fgcolor: the tap highlight inverts the label's colour, and a nil one crashes)
    local ok, icon = pcall(IconWidget.new, IconWidget, { file = DIR .. "ink/icons/" .. name .. ".svg",
        width = isz, height = isz, alpha = true, fgcolor = Blitbuffer.COLOR_BLACK })
    if ok and icon and b.label_container then b.label_widget = icon; b.label_container[1] = icon end
    return b
end

-- `content` (w wide) in a scroll area h high with the arrow column beside it,
-- repainting `parent` (the sheet) as it scrolls. Returns the widget and the
-- scroller.
function ArrowScroll.new(content, w, h, parent)
    local S = function(px) return Screen:scaleBySize(px) end
    local bw, gap = S(40), S(8)
    classes()
    local VerticalScrollBar = require("ui/widget/verticalscrollbar")
    local scroller = Scroller:new{ dimen = GeomUI:new{ w = w, h = h }, show_parent = parent, content }
    local function by(dir)
        if not scroller._is_scrollable then return end
        scroller:_scrollBy(0, dir * math.floor(scroller._crop_h * ArrowScroll.STEP))
    end
    local bar_h = math.max(S(24), h - 2 * (bw + gap))
    local bar = Bar:new{ w = bw, h = bar_h, scroller = scroller,
        VerticalScrollBar:new{ width = S(6), height = bar_h,
            scroll_callback = function(ratio) scroller:scrollToRatio(nil, ratio) end } }
    local column = VerticalGroup:new{ align = "center",
        arrow("arrow_up", bw, function() by(-1) end, parent),
        VerticalSpan:new{ width = gap }, bar, VerticalSpan:new{ width = gap },
        arrow("arrow_down", bw, function() by(1) end, parent) }
    local row = HorizontalGroup:new{ align = "top", scroller, HorizontalSpan:new{ width = S(12) }, column }
    return row, scroller
end

-- How much wider than its content the scroll area is.
function ArrowScroll.extraWidth()
    return Screen:scaleBySize(40 + 12)
end

return ArrowScroll
