--[[
Viewport: orientation, where the drawing area sits on screen, zoom and pan, and
collapsing the toolbar or notebook bar to give the page more room.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InkGeom = require("ink/geom")

local Screen = Device.screen

local ZOOM_RATIO = 1.5    -- one zoom press multiplies by this, for even steps
local ZOOM_MAX = 8.0

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
    if v.canvas_w == W and v.canvas_h == H then return false end   -- already that shape
    -- a PDF-backed notebook's pages are the imported PDF at its own size
    if self.notebook and self.notebook.template and self.notebook.template.pdf_path then
        return false
    end
    v.canvas_w, v.canvas_h = W, H
    self.canvas.w, self.canvas.h = W, H
    if self.notebook then self.notebook.w, self.notebook.h = W, H end
    if self.canvas_bb then self.canvas_bb:free() end
    self.canvas_bb = Blitbuffer.new(W, H, Screen.bb:getType())
    self:composeCanvas()   -- marks past the new bounds are just not drawn (kept in ops)
    return true
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
    self.zoom_min = InkGeom.coverZoom(v)   -- zooming out stops where the page fills the area
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
    self:redraw()
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
    self.zoom_min = InkGeom.coverZoom(v)
    v.zoom = self.zoom_min
    InkGeom.clampPan(v)
end

return InkAwayView
