--[[
Viewport: orientation, where the drawing area sits on screen, zoom and pan, and
collapsing the toolbar or notebook bar to give the page more room.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InkGeom = require("ink/geom")
local Accent = require("ink/accent")
local Theme = require("ink/ui/theme")

local Screen = Device.screen

local ZOOM_RATIO = 1.5    -- one zoom press multiplies by this, for even steps
local ZOOM_MAX = 8.0
local PAN_SETTLE_SEC = 0.2   -- a panned page is drawn once it has rested this long (see panMapStep)
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
-- the map is dressed like the floating controls (see FAB_FILL and FAB_BORDER in
-- ink/view/toolbar.lua): a light rounded card with a thin grey edge
local CARD_FILL   = Blitbuffer.ColorRGB32(0xF0, 0xF0, 0xF0, 0xFF)
local CARD_BORDER = Blitbuffer.ColorRGB32(0xB4, 0xB4, 0xB4, 0xFF)
local PAGE_EDGE   = Blitbuffer.ColorRGB32(0x78, 0x78, 0x78, 0xFF)
local VIEW_FILL   = Blitbuffer.ColorRGB32(0xD2, 0xD2, 0xD2, 0xFF)

local InkAwayView = {}

------------------------------------------------------------------------------
-- Small geometry helpers
------------------------------------------------------------------------------

function InkAwayView:inArea(x, y)
    local v = self.view
    return x >= v.area_x and x < v.area_x + v.area_w
       and y >= v.area_y and y < v.area_y + v.area_h
end

-- Convert a screen point to canvas coordinates, clamped to the canvas.
function InkAwayView:toCanvasClamped(sx, sy)
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    if cx < 0 then cx = 0 elseif cx > self.view.canvas_w then cx = self.view.canvas_w end
    if cy < 0 then cy = 0 elseif cy > self.view.canvas_h then cy = self.view.canvas_h end
    return cx, cy
end

-- Convert canvas coordinates to area_bb coordinates (origin at the area's top left).
function InkAwayView:toAreaLocal(cx, cy)
    local v = self.view
    return (cx - v.pan_x) * v.zoom, (cy - v.pan_y) * v.zoom
end

-- Snap a screen point to the grid (in canvas space) when grid snapping is on.
function InkAwayView:snapScreen(sx, sy)
    if not self.snap_grid then return sx, sy end
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    cx, cy = InkGeom.snapToGrid(cx, cy, self.grid_size)
    return InkGeom.toScreen(self.view, cx, cy)
end

------------------------------------------------------------------------------
-- Orientation (portrait / landscape)
--
-- KOReader rotates the whole screen: rotation mode 0 is upright portrait, 1
-- clockwise landscape, 2 upside-down portrait and 3 counter-clockwise landscape.
-- Ink Away puts the reader's own rotation back on close and remembers the
-- orientation last drawn in, so the next launch comes up the same way; the very
-- first launch adopts whatever the screen is.
--
-- The canvas is created at the screen size, so a landscape session gets a wide
-- page and a landscape export. Rotating reshapes the page (see reshapeToScreen).
------------------------------------------------------------------------------

local function modeIsLandscape(mode) return mode ~= nil and (mode % 2 == 1) end

-- Is screen rotation available? It is on devices and the emulator; the headless
-- tests stub Screen without it.
function InkAwayView:orientationSupported()
    return (Screen.setRotationMode and Screen.getRotationMode) and true or false
end

function InkAwayView:currentRotation()
    return (Screen.getRotationMode and Screen:getRotationMode()) or 0
end

-- The class ("portrait" or "landscape") of a rotation mode, the current one by
-- default.
function InkAwayView:orientationClass(mode)
    if mode == nil then mode = self:currentRotation() end
    return modeIsLandscape(mode) and "landscape" or "portrait"
end

-- Which rotation mode to use for an orientation: the reader's own rotation when
-- it already matches (keeping the way up the device is held), else upright for
-- portrait and counter-clockwise for landscape (bottom bezel on the right, the
-- usual way to turn a reader).
function InkAwayView:rotationForClass(class)
    local orig = self.orig_rotation
    if class == "landscape" then
        if modeIsLandscape(orig) then return orig end
        return Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE or 3
    else
        if orig ~= nil and not modeIsLandscape(orig) then return orig end
        return Screen.DEVICE_ROTATED_UPRIGHT or 0
    end
end

-- Apply the orientation to open in, once at init before the canvas and buffers
-- are sized: the remembered choice, else (remembered from now on) however the
-- device is held.
function InkAwayView:applyStartupOrientation()
    if not self:orientationSupported() then
        self.orientation = self:orientationClass()
        return
    end
    local pref = self:getSetting("inkaway_orientation", nil)
    if pref ~= "portrait" and pref ~= "landscape" then
        self.orientation = self:orientationClass()
        self:setSetting("inkaway_orientation", self.orientation)
        return
    end
    self.orientation = pref
    local target = self:rotationForClass(pref)
    if target ~= self:currentRotation() then
        pcall(function() Screen:setRotationMode(target) end)
    end
end

-- Switch orientation from the Settings sheet: rotate the screen, remember the
-- choice, then reshape the page and lay out again.
function InkAwayView:setOrientation(class)
    if not self:orientationSupported() then return end
    if self:orientationClass() == class then return end   -- already that way up
    pcall(function() Screen:setRotationMode(self:rotationForClass(class)) end)
    self.orientation = class
    self:setSetting("inkaway_orientation", class)
    self:handleScreenResize()
    -- a full refresh draws the new orientation and clears the panel
    UIManager:setDirty(self, "full")
end

-- Reshape the page to the screen size, so it matches the orientation (and so does
-- the export). Marks keep their canvas coordinates, so text stays on its ruling;
-- a mark past the new, shorter edge is not drawn or exported until the screen
-- turns back, and nothing is deleted. A PDF-backed notebook keeps the PDF's page
-- size. Returns true if it reshaped; the master is recomposed for the caller's
-- renderView.
function InkAwayView:reshapeToScreen()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local v = self.view
    if not v then return false end
    -- a notebook from a reader with another screen keeps its own page size: it is
    -- fitted to the screen instead (see pageNeedsFit)
    if self.nb_fit and self.notebook then return false end
    if v.canvas_w == W and v.canvas_h == H then return false end   -- already that shape
    -- a PDF-backed notebook's pages are the imported PDF at its own size
    if self.notebook and self.notebook.template and self.notebook.template.pdf_path then
        return false
    end
    if self.notebook then self.notebook.w, self.notebook.h = W, H end
    self:resizePage(W, H)
    self:composeCanvas()   -- marks past the new bounds are just not drawn (kept in ops)
    return true
end

-- Give the page (the canvas and its master) the size W x H; the caller composes.
function InkAwayView:resizePage(W, H)
    local v = self.view
    v.canvas_w, v.canvas_h = W, H
    self.canvas.w, self.canvas.h = W, H
    if self.canvas_bb then self.canvas_bb:free() end
    self.canvas_bb = Blitbuffer.new(W, H, Screen.bb:getType())
end

-- Does a page of w x h belong to another screen than this one (neither this
-- screen's size nor this screen turned)? Such a notebook was made on another
-- reader: it keeps its own page size, so what is written stays where it was, and
-- the screen shows the whole page, smaller or larger.
function InkAwayView:pageNeedsFit(w, h)
    if type(w) ~= "number" or type(h) ~= "number" or w < 200 or h < 200 then return false end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local function near(a, b) return math.abs(a - b) <= 2 end
    return not ((near(w, sw) and near(h, sh)) or (near(w, sh) and near(h, sw)))
end

-- A notebook just read takes this screen's size unless it is to be fitted.
-- Returns whether it is to be fitted.
function InkAwayView:adoptScreenSize(nb)
    if self:pageNeedsFit(nb.w, nb.h) then return true end
    nb.w, nb.h = self.screen_w, self.screen_h
    return false
end

-- The smallest zoom: the whole page in the area for a fitted notebook (with
-- margins where the shapes differ), else the page covering the area.
function InkAwayView:minZoom()
    if self.nb_fit and self.notebook then return InkGeom.fitZoom(self.view) end
    return InkGeom.coverZoom(self.view)
end

-- Lay out again after the screen size changed, from the orientation setting or
-- the device being turned (onSetDimensions): reshape the page first, then rebuild
-- the toolbar and area and refit the view.
function InkAwayView:handleScreenResize()
    self:reshapeToScreen()
    self:relayout()
    self.orientation = self:orientationClass()
end

-- Rebuild the toolbar and drawing area for the current screen size and refit the
-- view. The page itself is left alone (see reshapeToScreen).
function InkAwayView:relayout()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.screen_w, self.screen_h = W, H
    self.dimen.w, self.dimen.h = W, H     -- mutate in place; GestureRanges hold it
    self:buildToolbar()
    self[1] = self.toolbar
    if self.notebook then self.nb_bar_h = self:nbBarHeight() end
    self:fitBars(W, H)
    self:refitArea()   -- the canvas keeps its size; only the on-screen buffer follows the screen
    self._area_only = false   -- layout/chrome changed: the next paint must be full
end

-- Refit the view after the drawing area changed size, then reallocate the
-- on-screen buffer and render it. The page covers the whole area (see
-- InkGeom.coverZoom) even when its shape differs from the screen, so there is no
-- undrawable margin; a zoomed-in view is kept.
function InkAwayView:refitArea()
    local v = self.view
    self.zoom_min = self:minZoom()   -- zooming out stops where the page fills the area
    v.zoom = math.max(self.zoom_min, math.min(ZOOM_MAX, v.zoom))
    InkGeom.clampPan(v)
    if self.area_bb then self.area_bb:free() end
    self.area_bb = self:newAreaBuffer()
    self:renderView()
end

------------------------------------------------------------------------------
-- Zoom, in even multiplicative steps up to ZOOM_MAX
------------------------------------------------------------------------------

function InkAwayView:setZoom(new_zoom, anchor_sx, anchor_sy)
    local v = self.view
    new_zoom = math.max(self.zoom_min, math.min(ZOOM_MAX, new_zoom))
    if math.abs(new_zoom - v.zoom) < 1e-6 then return false end
    -- keep the canvas point under (anchor_sx, anchor_sy) fixed; default to the
    -- centre of the drawing area
    anchor_sx = anchor_sx or (v.area_x + v.area_w / 2)
    anchor_sy = anchor_sy or (v.area_y + v.area_h / 2)
    local acx, acy = InkGeom.toCanvas(v, anchor_sx, anchor_sy)
    v.zoom = new_zoom
    v.pan_x = acx - (anchor_sx - v.area_x) / v.zoom
    v.pan_y = acy - (anchor_sy - v.area_y) / v.zoom
    InkGeom.clampPan(v)
    self:redraw()
    return true
end

function InkAwayView:zoomStep(dir)
    self:flushPending()
    local factor = (dir > 0) and ZOOM_RATIO or (1 / ZOOM_RATIO)
    self:setZoom(self.view.zoom * factor)
end

-- Pinch (dir < 0) zooms out and spread (dir > 0) zooms in, anchored at the
-- gesture's midpoint, by an amount that follows how far the fingers moved. One
-- jump per gesture, rather than a live zoom, avoids ghosting on e-ink.
function InkAwayView:pinchZoom(ges, dir)
    self:flushPending()
    self:cancelShape()
    local v = self.view
    local dist = (ges and ges.distance) or 0
    local ref = math.min(self.screen_w, self.screen_h) * 0.6
    local factor = 1 + math.min(dist, ref) / ref            -- up to ~2x per gesture
    local nz = (dir > 0) and (v.zoom * factor) or (v.zoom / factor)
    local pos = ges and ges.pos
    self:setZoom(nz, pos and pos.x, pos and pos.y)
end

-- Hide or show the top toolbar, growing the paper into the freed space.
function InkAwayView:setToolbarHidden(hidden)
    if (self._toolbar_hidden or false) == hidden then return end
    self:flushPending()
    self._toolbar_hidden = hidden
    self._area_only = false   -- toolbar shown/hidden: the next paint must be full
    self:fitBars()
    -- when hidden, the toolbar buttons must not swallow taps in the freed strip
    -- (plain if/else: `hidden and nil or self.toolbar` would never yield nil)
    if hidden then self[1] = nil else self[1] = self.toolbar end
    self:refitArea()
    self:refresh(self, "full")
end

-- Hide or show the notebook bottom bar, growing the paper into the freed space.
-- The toolbar can be collapsed independently.
function InkAwayView:setNbBarHidden(hidden)
    if not self.notebook then return end
    if (self._nb_collapsed or false) == hidden then return end
    self:flushPending()
    self._nb_collapsed = hidden
    self.nb_bar_h = self:nbBarHeight()      -- 0 when collapsed (see nbBarHeight)
    self:fitBars()
    self:refitArea()
    self:refresh(self, "full")
end

------------------------------------------------------------------------------
-- Pan, shared by the Pan tool and two-finger pan. It works from one step to the
-- next, so it stays reliable when the panel sends events unevenly.
------------------------------------------------------------------------------

function InkAwayView:panByScreen(dx, dy)
    local v = self.view
    local px, py = v.pan_x, v.pan_y
    -- content follows the finger: dragging right reveals more of the left
    v.pan_x = v.pan_x - dx / v.zoom
    v.pan_y = v.pan_y - dy / v.zoom
    InkGeom.clampPan(v)
    if v.pan_x == px and v.pan_y == py then return end   -- at the edge: nothing to redraw
    if self:onAndroid() then
        -- each refresh there copies the whole screen, so the page is redrawn when
        -- the paced refresh goes out, where the finger is by then (see liveFlush)
        self._view_stale = true
        self:liveDirty("ui", { x0 = 0, y0 = 0, x1 = v.area_w, y1 = v.area_h })
        return
    end
    if self:panMapOn() then return self:panMapStep() end
    self:redraw()
end

------------------------------------------------------------------------------
-- The pan map (Settings, Screen: on for a colour panel unless turned off)
--
-- A colour panel takes several tenths of a second over a refresh of the whole
-- drawing area, so a page that is scaled and refreshed as the finger moves
-- trails far behind it, however the steps are paced. The page is left as it is
-- instead while it is panned, and a small map in the middle of the area shows
-- where the view is: the page's outline with the visible part as a box inside
-- it. Only the map is refreshed, with the fast waveform. Once nothing has moved
-- for PAN_SETTLE_SEC the page is drawn where it ended, once.
--
-- A grey panel refreshes quickly enough for the page to follow the finger, so
-- the map is off there unless it is asked for (a large or slow one may want it).
------------------------------------------------------------------------------

-- Is a pan shown as the map? As set in Settings, else on a colour panel only.
-- (Android paces its pans its own way, see panByScreen.)
function InkAwayView:panMapOn()
    if self:onAndroid() then return false end
    local set = self:getSetting("inkaway_pan_map")
    if set == nil then return self:colourPanel() end
    return set == true
end

-- The map in area-local pixels: the page's outline {x, y, w, h}, the visible
-- part's box inside it, the outline's line width, and the card the outline sits
-- on, {x, y, w, h, r} with its corner radius.
function InkAwayView:panMapRects()
    local v = self.view
    local scale = math.min(v.area_w, v.area_h) / 4 / math.max(v.canvas_w, v.canvas_h)
    local line = math.max(2, math.floor(Screen:scaleBySize(2)))
    local w = math.max(8 * line, math.floor(v.canvas_w * scale))
    local h = math.max(8 * line, math.floor(v.canvas_h * scale))
    local x = math.floor((v.area_w - w) / 2)
    local y = math.floor((v.area_h - h) / 2)
    local function span(pan, seen, page, len)
        local n = math.max(3 * line, math.min(len, math.floor(math.min(seen, page) / page * len + 0.5)))
        local at = math.floor(pan / page * len + 0.5)
        return math.max(0, math.min(len - n, at)), n
    end
    local ix, iw = span(v.pan_x, v.area_w / v.zoom, v.canvas_w, w)
    local iy, ih = span(v.pan_y, v.area_h / v.zoom, v.canvas_h, h)
    local pad = Screen:scaleBySize(8)
    local card = { x = x - pad, y = y - pad, w = w + 2 * pad, h = h + 2 * pad, r = Screen:scaleBySize(10) }
    return { x = x, y = y, w = w, h = h }, { x = x + ix, y = y + iy, w = iw, h = ih }, line, card
end

-- One step of a pan: show the map where the view is now, and put off the page.
function InkAwayView:panMapStep()
    self._pan_map = true
    local _, _, _, card = self:panMapRects()
    local r = { x0 = card.x, y0 = card.y, x1 = card.x + card.w, y1 = card.y + card.h }
    -- only the map changed, so the paint blits just that part of the area
    self._blit_rect = InkGeom.growRect(self._blit_rect, r.x0, r.y0, r.x1, r.y1)
    self:liveDirty("fast", r)
    UIManager:unschedule(self._pan_settle_cb)
    UIManager:scheduleIn(PAN_SETTLE_SEC, self._pan_settle_cb)
end

-- The pan has rested (or something needs the page where it is, see beginStroke):
-- take the map away and draw the page there.
function InkAwayView:settlePan()
    UIManager:unschedule(self._pan_settle_cb)
    if not self._pan_map then return end
    self._pan_map = nil
    if self.closing then return end
    self:liveDrop()   -- a map refresh still waiting is covered by this one
    self:redraw()
end

-- Paint the map over the drawing area (see paintTo): the card, the page on it,
-- and the part in view as a rounded box, in the accent on a coloured accent.
function InkAwayView:paintPanMap(bb, x, y)
    local v = self.view
    local m, i, line, card = self:panMapRects()
    local ox, oy = x + v.area_x, y + v.area_y
    local S1 = math.max(1, Screen:scaleBySize(1))
    bb:paintRoundedRect(ox + card.x, oy + card.y, card.w, card.h, CARD_FILL, card.r)
    bb:paintBorder(ox + card.x, oy + card.y, card.w, card.h, S1, CARD_BORDER, card.r)
    -- the page: white with a darker edge, its corners a little rounded
    local pr = Screen:scaleBySize(3)
    bb:paintRoundedRect(ox + m.x, oy + m.y, m.w, m.h, WHITE, pr)
    bb:paintBorder(ox + m.x, oy + m.y, m.w, m.h, S1, PAGE_EDGE, pr)
    -- the part in view
    local vr = math.max(2, math.floor(pr / 2))
    if Accent.get().custom then
        Accent.paintRounded(bb, ox + i.x, oy + i.y, i.w, i.h, vr)
    else
        bb:paintRoundedRect(ox + i.x, oy + i.y, i.w, i.h, VIEW_FILL, vr)
        bb:paintBorder(ox + i.x, oy + i.y, i.w, i.h, line, BLACK, vr)
    end
    -- dark (see ink/ui/theme.lua): inverted within the card's shape, as the floating controls are
    if Theme.invert() then Theme.invertRounded(bb, ox + card.x, oy + card.y, card.w, card.h, card.r) end
end

-- Recompute the drawing area (it shrinks by nb_bar_h in notebook mode) and the
-- fit zoom, then reallocate the on-screen buffer to the new height.
function InkAwayView:recomputeArea()
    local v = self.view
    self:fitBars()
    if self.area_bb then self.area_bb:free() end
    self.area_bb = self:newAreaBuffer()
    -- cover the whole area, as for a drawing, even when the page shape differs
    -- from the screen after a rotation; zooming out stops there too
    self.zoom_min = self:minZoom()
    v.zoom = self.zoom_min
    InkGeom.clampPan(v)
end

return InkAwayView
