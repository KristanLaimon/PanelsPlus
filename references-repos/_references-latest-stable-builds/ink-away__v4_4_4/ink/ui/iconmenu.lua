--[[
IconMenu: the sheet every tool menu opens in. It is built from stock KOReader
widgets (as ButtonDialog is), pinned under the toolbar or above the notebook bar,
and scrolls when it is taller than the screen.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Theme = require("ink/ui/theme")

local Screen = Device.screen

-- The sheet's white rounded panel around the content build() returns.
local function panel(content)
    return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
        radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
end
-- A modal sheet with ButtonDialog's structure (a MovableContainer around a
-- FrameContainer). `build(menu)` returns the content, built with the menu at hand
-- so its controls can use it as their repaint parent. A tap outside the panel, or
-- Back, closes it.
--
-- It is deliberately not covers_fullscreen: the canvas must keep painting under
-- the sheet, or closing or reopening a smaller sheet would leave stale panel
-- pixels around it.
local IconMenu = InputContainer:extend{
    modal = true,              -- stay on top; don't let un-consumed gestures fall
                               -- through and draw on the canvas underneath
    build = nil,               -- function(menu) -> the sheet's content
    flash = true,              -- flash on show (grey panels; see onShow)
    on_close = nil,
    on_closed = nil,           -- function() once the sheet is gone, however it closed
    keep_open = nil,           -- taps beside it leave it open (a job's progress)
    top_y = nil,               -- if set, pin the sheet's top here (below the toolbar)
                               -- instead of centring it vertically
    bottom_y = nil,            -- if set, pin the sheet's bottom here (on the notebook
                               -- bottom bar); takes precedence over top_y
    anchor = nil,              -- function() -> { x, y, w, h, gap }: sit beside this
                               -- screen rect (above it when there is room, else
                               -- below, else at the foot of the screen), `gap` away
    left_x = nil,              -- if set, centre the sheet in the screen right of
                               -- this x (beside a toolbar down the left side)
    right_x = nil,             -- and left of this x (beside one down the right)
    tap_pos = nil,             -- where the tap that closed it landed, if one did
    on_uncover = nil,          -- function(): the sheet left part of the screen to be
                               -- painted again under it (it closed, or a rebuild
                               -- shrank or moved it)
    on_page = nil,             -- function(delta): turn the sheet's pages (set by IconMenu.pager)
}

-- The menu's content in its panel. A pager row built inside it (IconMenu.pager)
-- gives the menu its page turn, for the reader's page turn buttons.
local function framed(menu)
    menu.on_page = nil
    IconMenu.building = menu
    local content = menu:build()
    IconMenu.building = nil
    return panel(content)
end

-- Called while a menu's content is built: `on_turn(delta)` turns its pages.
function IconMenu.pager(on_turn)
    if IconMenu.building then IconMenu.building.on_page = on_turn end
end

-- If the sheet is taller than the space it has (a long sheet, or any sheet in a
-- short landscape screen), wrap its content in a ScrollableContainer capped to that
-- height, as ButtonDialog does. Gestures reach children first, so a pan inside the
-- scroll area scrolls while MovableContainer only sees drags outside it.
function IconMenu:fitFrame()
    if not self.frame then return end
    local content = self.frame[1]
    if not content or not content.getSize then return end
    local pad = Screen:scaleBySize(4)
    -- a sheet hung from the toolbar slides up over it when it is too tall (see
    -- paintTo), so it only scrolls when it is taller than the screen
    local avail
    if self.bottom_y then avail = self.bottom_y - pad
    else avail = Screen:getHeight() - 2 * pad end
    local chrome = 2 * ((self.frame.padding or 0) + (self.frame.bordersize or 0))
    -- measuring can fail with the headless test mocks; then no scroll wrapper
    local ok, csz = pcall(function() return content:getSize() end)
    if not ok or not csz or csz.h + chrome <= avail then return end   -- fails or fits
    -- (with arrows beside the scrollbar, as a drag on e-ink often moves a
    -- toggle or slider instead of the sheet)
    self.frame[1], self.scroller = require("ink/ui/arrowscroll").new(content, csz.w,
        math.max(1, avail - chrome), self)
    self.frame._size = nil   -- drop any cached size so the frame remeasures
end

function IconMenu:init()
    if self.build then self.frame = framed(self); self:fitFrame() end
    if Device:isTouchDevice() then
        self.ges_events = { TapClose = { GestureRange:new{ ges = "tap",
            range = GeomUI:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } } } }
    end
    if Device:hasKeys() then
        local g = Device.input.group
        self.key_events = { CloseMenu = { { g.Back } } }
        -- the page turn buttons turn a sheet's pages, when it has them (#53)
        if g.PgFwd then self.key_events.MenuPageFwd = { { g.PgFwd } } end
        if g.PgBack then self.key_events.MenuPageBack = { { g.PgBack } } end
    end
    -- MovableContainer gives the content a reliable .dimen (set at paint time) and
    -- swallows drags that start on the frame; paintTo positions it
    self.movable = MovableContainer:new{ self.frame }
    self[1] = self.movable
    -- opened in place of a sheet that was dragged elsewhere: open there too
    self._carry, IconMenu.carried = IconMenu.carried, nil
end

-- UIManager:show without a refresh type only marks the widget dirty, so the sheet
-- schedules its own refresh, reading the region in a closure because
-- movable.dimen is nil until the first paint. On a grey panel it is a flashing
-- "flashui": the sheet opens over dark ink and grid lines, a plain "ui" fades
-- them out slowly, and the fast waveform does not clear them at all, so the ink
-- would show through the sheet. A colour panel (`flash` false) gets "ui": a
-- flash there takes a second or two, and on Kobo's controller the reader waits
-- for it to finish.
function IconMenu:onShow()
    local mode = self.flash and "flashui" or "ui"
    UIManager:setDirty(self, function() return mode, self.movable.dimen end)
end

-- On close UIManager repaints the canvas underneath, and a plain "ui" brings it
-- back without the black blink a flash would leave. The content is freed, as some
-- sheets build buffers (brush previews).
function IconMenu:onCloseWidget()
    local region = self.movable and self.movable.dimen
    -- A sheet dragged elsewhere hands its place to a sheet opened in the same
    -- moment (an option that opens another sheet, or the way back from it);
    -- one opened any later starts in its usual place.
    local o = self.movable and self.movable.getMovedOffset and self.movable:getMovedOffset()
    if region and o and (o.x ~= 0 or o.y ~= 0) then
        local carried = { x = region.x, y = region.y }
        IconMenu.carried = carried
        UIManager:nextTick(function()
            if IconMenu.carried == carried then IconMenu.carried = nil end
        end)
    end
    UIManager:setDirty(nil, function() return "ui", region end)
    if self.on_uncover then self.on_uncover() end
    if self.movable and self.movable.free then self.movable:free() end
    if self.on_closed then self.on_closed() end
end

-- Rebuild the sheet's content in place when a control inside it changes state
-- (picking a brush or a colour), where it was dragged to if it was. When the
-- footprint is unchanged, the usual case, only that region is refreshed with
-- "ui" (the sheet is already opaque white on screen); when it changes, the
-- uncovered canvas is repainted and the union flashes (on a grey panel; see
-- onShow).
function IconMenu:rebuild()
    if not (self.movable and self.build) then return end
    local old = self.movable.dimen and self.movable.dimen:copy()
    local moved = self.movable.getMovedOffset and self.movable:getMovedOffset()
    if self.movable.free then self.movable:free() end
    self.frame = framed(self)
    self:fitFrame()
    self.movable = MovableContainer:new{ self.frame }
    if moved and self.movable.setMovedOffset then self.movable:setMovedOffset(moved) end
    self[1] = self.movable
    UIManager:widgetRepaint(self, 0, 0)      -- paint the new contents; sets movable.dimen
    local new = self.movable.dimen
    if old and new and old.x == new.x and old.y == new.y
            and old.w == new.w and old.h == new.h then
        -- mark this menu dirty (not nil): when the same tap also repaints the view
        -- underneath (a shape pick moves the toolbar pill), the menu must be
        -- repainted on top of it
        UIManager:setDirty(self, function() return "ui", new end)
    else
        local region = (old and new) and old:combine(new) or new
        local mode = self.flash and "flashui" or "ui"
        UIManager:setDirty("all", function() return mode, region end)
        if self.on_uncover then self.on_uncover() end
    end
end

-- Paint the sheet centred horizontally and, with top_y or bottom_y, pinned there
-- and clamped to the screen. MovableContainer sets its .dimen from where it is
-- painted, which is used for hit tests and refresh regions.
function IconMenu:paintTo(bb, _x, _y)
    local sz = self.movable:getSize()
    local pad = Screen:scaleBySize(4)
    local px = math.floor((Screen:getWidth() - sz.w) / 2)
    local lx, rx = self.left_x or 0, self.right_x or Screen:getWidth()
    if (self.left_x or self.right_x) and sz.w + 2 * pad <= rx - lx then
        px = lx + math.floor((rx - lx - sz.w) / 2)
    end
    local py
    local r = self.anchor and self.anchor()
    if r then
        -- beside the rect, centred on it and kept on the screen
        local gap = r.gap or pad
        px = math.floor(r.x + r.w / 2 - sz.w / 2)
        px = math.max(pad, math.min(px, Screen:getWidth() - sz.w - pad))
        if r.y - gap - sz.h >= (r.top or pad) then
            py = r.y - gap - sz.h
        elseif r.y + r.h + gap + sz.h <= Screen:getHeight() - pad then
            py = r.y + r.h + gap
        else
            py = Screen:getHeight() - sz.h - pad
        end
    elseif self.bottom_y then
        -- pin the sheet's bottom here (on the top of the notebook bottom bar)
        py = math.max(pad, math.min(self.bottom_y - sz.h, Screen:getHeight() - sz.h - pad))
    elseif self.top_y then
        py = math.max(pad, math.min(self.top_y, Screen:getHeight() - sz.h - pad))
    else
        py = math.floor((Screen:getHeight() - sz.h) / 2)
    end
    -- where the sheet it replaced was dragged to (see onCloseWidget)
    if self._carry and self.movable.setMovedOffset then
        self.movable:setMovedOffset({ x = self._carry.x - px, y = self._carry.y - py })
        self._carry = nil
    end
    -- a sheet dragged elsewhere stays whole on the screen, even once an option
    -- has made it bigger
    local o = self.movable.getMovedOffset and self.movable:getMovedOffset()
    if o and (o.x ~= 0 or o.y ~= 0) then
        local ox = math.max(-px, math.min(o.x, Screen:getWidth() - sz.w - px))
        local oy = math.max(-py, math.min(o.y, Screen:getHeight() - sz.h - py))
        if ox ~= o.x or oy ~= o.y then self.movable:setMovedOffset({ x = ox, y = oy }) end
    end
    self.movable:paintTo(bb, px, py)
    self.dimen = self.movable.dimen
    -- dark: the panel inverted, round its corners, its colours given back
    local d = self.dimen
    if d and self.frame then Theme.apply(bb, self.frame, d.x, d.y, d.w, d.h, self.frame.radius or 0) end
end

function IconMenu:onTapClose(_, ges)
    if self.keep_open then return true end
    if ges and ges.pos and self.movable.dimen
            and ges.pos:notIntersectWith(self.movable.dimen) then
        self.tap_pos = { x = ges.pos.x, y = ges.pos.y }
        self:onCloseMenu()
    end
    return true
end

function IconMenu:onCloseMenu()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end
-- (what a text field inside asks for on Back)
IconMenu.onCloseDialog = IconMenu.onCloseMenu

function IconMenu:onMenuPageFwd()
    if not self.on_page then return false end
    self.on_page(1)
    return true
end

function IconMenu:onMenuPageBack()
    if not self.on_page then return false end
    self.on_page(-1)
    return true
end

return IconMenu
