--[[
The shape tool (drag to place, a second drag to bend a curve), picking a placed
shape, and the paint bucket. A picked shape is a selection like any other (see
view/selection.lua).
Part of InkAwayView (see ink/view.lua).
]]

local bit = require("bit")
local Device = require("device")
local Export = require("ink/export")
local Fill = require("ink/fill")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")
local Shapes = require("ink/shapes")
local Symmetry = require("ink/symmetry")
local UIManager = require("ui/uimanager")

local Screen = Device.screen
local displayColor = Paint.displayColor

local InkAwayView = {}

------------------------------------------------------------------------------
-- Placing a shape: drag to stretch it. The master is untouched while stretching;
-- the shape is drawn on top in paintTo and only its changed rectangle refreshes.
-- On release it is stamped into the master.
------------------------------------------------------------------------------

-- Screen-coordinate op for the current drag, drawn as the live preview.
local function screenShapeOp(self, shape, fill, x0, y0, x1, y1, cx, cy)
    local arrow, head
    if (shape == "line" or shape == "curve") and self.shape_arrow then
        arrow = self.shape_arrow
        head = self.arrow_head * self.view.zoom
    end
    return {
        kind = "shape", shape = shape, fill = fill, arrow = arrow, head = head,
        width = math.max(1, self.pen_width * self.view.zoom),
        color = self.pen_color, alpha = self.pen_alpha,
        pts = cx and { x0, y0, x1, y1, cx, cy } or { x0, y0, x1, y1 },
    }
end

-- Show the curve bending towards its control point.
local function previewCurve(self)
    local p0, p1, c = self.curve_p0, self.curve_p1, self.curve_ctrl
    self.shape_preview = screenShapeOp(self, "curve", false, p0.x, p0.y, p1.x, p1.y, c.x, c.y)
    self:refreshPreview()
end

-- Padded screen rect touched by a preview op.
function InkAwayView:previewRect(op)
    local x0, y0, x1, y1 = Shapes.bounds(op)
    local pad = op.width + 4
    return { x = math.floor(x0 - pad), y = math.floor(y0 - pad),
             x2 = math.ceil(x1 + pad), y2 = math.ceil(y1 + pad) }
end

-- Does a shape preview wait for the panel to finish showing the last one before
-- sending the next? Each preview refresh covers the shape's whole box. Colour
-- e-ink queues such overlapping updates one after another instead of dropping
-- the stale ones, so with one per pen move the outline fell further behind the
-- pen the bigger the shape. Waiting there lets the moves made meanwhile go out
-- together, as one refresh of the newest outline. Grey e-ink keeps up as it is,
-- and Android paces its refreshes its own way (see liveBox).
function InkAwayView:previewWaits()
    return self:colourPanel() and not self:instantColour() and not self:onAndroid()
end

-- Before the next refresh of a drag that redraws a whole box each move (a
-- shape's outline, a text box moved, resized or turned, the export box): on
-- colour e-ink, wait for the panel to show the last one (see previewWaits).
function InkAwayView:waitForPanel()
    if UIManager.waitForVSync and self:previewWaits() then UIManager:waitForVSync() end
end

-- Refresh the union of the previous and current preview rectangles, so the old
-- outline is wiped (from the untouched base) and the new one drawn.
function InkAwayView:refreshPreview()
    local r = self.shape_preview and self:previewRect(self.shape_preview) or nil
    local u = r
    local prev = self._preview_rect
    if prev then
        if u then
            u = { x = math.min(u.x, prev.x), y = math.min(u.y, prev.y),
                  x2 = math.max(u.x2, prev.x2), y2 = math.max(u.y2, prev.y2) }
        else
            u = prev
        end
    end
    self._preview_rect = r
    if not u then return end
    -- the first outline of a drag shows at once; each later one waits for the
    -- panel (see previewWaits)
    if prev then self:waitForPanel() end
    local x0, y0, x1, y1 = self:liveBox("fast", u.x, u.y, u.x2, u.y2)
    -- Region fast path (see paintTo): while creating a shape (a live drag or the
    -- curve's bend stage), paint only this region instead of the whole view and
    -- toolbar on every touch sample, which matters most on a rotated landscape
    -- screen. The rect accumulates, so a skipped paint never strands an outline.
    -- Not while moving or rotating a placed shape (its selection chrome can lie
    -- outside), nor with symmetry on (previewRect covers only the base shape).
    if x0 and (self.shape_drag or self.curve_stage) and self.symmetry == "off" then
        local v = self.view
        self._blit_rect = InkGeom.growRect(self._blit_rect,
            x0 - v.area_x, y0 - v.area_y, x1 - v.area_x, y1 - v.area_y)
    end
end

function InkAwayView:shapeTouch(pos)
    if self.curve_stage == "bend" then
        self.curve_ctrl = { x = pos.x, y = pos.y }
        previewCurve(self)
        return true
    end
    -- If a previous shape never got its release (a dropped lift event), place it
    -- now instead of silently losing it when this new drag begins.
    if self.shape_drag then
        if self.shape == "curve" then self:cancelShape() else self:commitShape() end
    end
    local x0, y0 = self:snapScreen(pos.x, pos.y)
    -- Snapshot the settings this shape is being drawn with, so a deferred commit
    -- (a missed lift, or a tool change) still places the shape it started as.
    self.shape_drag = { x0 = x0, y0 = y0, x1 = x0, y1 = y0,
        shape = self.shape, fill = self.shape_fill, arrow = self.shape_arrow,
        head = self.arrow_head, sym = self.symmetry,
        width = self.pen_width, alpha = self.pen_alpha, color = self.pen_color }
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill, x0, y0, x0, y0)
    self:refreshPreview()
    return true
end

function InkAwayView:shapeMove(pos)
    if not pos then return true end
    if self.curve_stage == "bend" then
        local c = self.curve_ctrl
        if c and c.x == pos.x and c.y == pos.y then return true end   -- no change, skip
        self.curve_ctrl = { x = pos.x, y = pos.y }
        previewCurve(self)
        return true
    end
    if not self.shape_drag then return false end
    local d = self.shape_drag
    local nx, ny = self:shapeEndPoint(pos)
    if nx == d.x1 and ny == d.y1 then return true end   -- endpoint unchanged, skip the flash
    d.x1, d.y1 = nx, ny
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill, d.x0, d.y0, d.x1, d.y1)
    self:refreshPreview()
    return true
end

-- Snap the drag's end point to the grid (if on) and, for a line or curve, to
-- 45-degree steps (if angle snapping is on). Rectangles and ellipses keep any
-- proportion.
function InkAwayView:shapeEndPoint(pos)
    local d = self.shape_drag
    local x1, y1 = self:snapScreen(pos.x, pos.y)
    if self.snap_angle and (self.shape == "line" or self.shape == "curve") then
        x1, y1 = InkGeom.snapAngle(d.x0, d.y0, x1, y1)
    end
    return x1, y1
end

function InkAwayView:shapeRelease(pos)
    if self.curve_stage == "bend" then
        if pos then self.curve_ctrl = { x = pos.x, y = pos.y } end
        self:commitCurve()
        return true
    end
    if not self.shape_drag then return false end
    if pos then self.shape_drag.x1, self.shape_drag.y1 = self:shapeEndPoint(pos) end
    local d = self.shape_drag
    local dx, dy = d.x1 - d.x0, d.y1 - d.y0
    if dx * dx + dy * dy < 9 then      -- basically a tap: nothing to place
        self:cancelShape()
        return true
    end
    if (d.shape or self.shape) == "curve" then
        -- keep the straight segment on screen and wait for a bend drag; carry
        -- the draw-time settings over to the eventual commit
        self.curve_p0 = { x = d.x0, y = d.y0 }
        self.curve_p1 = { x = d.x1, y = d.y1 }
        self.curve_ctrl = { x = (d.x0 + d.x1) / 2, y = (d.y0 + d.y1) / 2 }
        self.curve_snap = { arrow = d.arrow, head = d.head, sym = d.sym,
            width = d.width, alpha = d.alpha, color = d.color }
        self.curve_stage = "bend"
        self.shape_drag = nil
        return true
    end
    self:commitShape()
    return true
end

-- Give a freshly placed shape op its symmetry mode and, for a line or curve, any
-- arrowheads, before it is stamped in. `snap` holds the settings captured when
-- the shape was started (see shapeTouch).
function InkAwayView:decorateShapeOp(op, snap)
    local sym = (snap and snap.sym) or self.symmetry
    if sym ~= "off" then op.sym = sym end
    local arrow = snap and snap.arrow
    if arrow == nil and not snap then arrow = self.shape_arrow end
    if (op.shape == "line" or op.shape == "curve") and arrow then
        op.arrow = arrow
        op.head = (snap and snap.head) or self.arrow_head
    end
end

function InkAwayView:commitShape()
    local d = self.shape_drag
    local c0x, c0y = self:toCanvasClamped(d.x0, d.y0)
    local c1x, c1y = self:toCanvasClamped(d.x1, d.y1)
    -- use the settings from when the drag began: a shape whose lift was missed
    -- may commit after the tool or shape type changed, and must stay what it was
    local shape = d.shape or self.shape
    local fill = d.fill; if fill == nil then fill = self.shape_fill end
    local op = self.canvas:addShape(shape, fill,
        { c0x, c0y, c1x, c1y }, d.width or self.pen_width,
        d.alpha or self.pen_alpha, d.color or self.pen_color)
    self:decorateShapeOp(op, d)
    self:stampOpIntoCanvas(op)
    self:markDirty()
    local sx0, sy0, sx1, sy1 = d.x0, d.y0, d.x1, d.y1
    self.shape_drag = nil
    self.shape_preview = nil
    self._preview_rect = nil
    self:renderCommittedOp(op, sx0, sy0, sx1, sy1)   -- re-render only the shape's rect
    self:afterCommit()
end

function InkAwayView:commitCurve()
    local c0x, c0y = self:toCanvasClamped(self.curve_p0.x, self.curve_p0.y)
    local c1x, c1y = self:toCanvasClamped(self.curve_p1.x, self.curve_p1.y)
    local ccx, ccy = self:toCanvasClamped(self.curve_ctrl.x, self.curve_ctrl.y)
    local snap = self.curve_snap
    local op = self.canvas:addShape("curve", false,
        { c0x, c0y, c1x, c1y, ccx, ccy }, (snap and snap.width) or self.pen_width,
        (snap and snap.alpha) or self.pen_alpha, (snap and snap.color) or self.pen_color)
    self:decorateShapeOp(op, snap)
    self:stampOpIntoCanvas(op)
    self:markDirty()
    -- the curve's screen extent = its two ends + control point (before they're cleared)
    local sx0 = math.min(self.curve_p0.x, self.curve_p1.x, self.curve_ctrl.x)
    local sy0 = math.min(self.curve_p0.y, self.curve_p1.y, self.curve_ctrl.y)
    local sx1 = math.max(self.curve_p0.x, self.curve_p1.x, self.curve_ctrl.x)
    local sy1 = math.max(self.curve_p0.y, self.curve_p1.y, self.curve_ctrl.y)
    self.curve_stage = nil
    self.curve_snap = nil
    self.curve_p0, self.curve_p1, self.curve_ctrl = nil, nil, nil
    self.shape_preview = nil
    self._preview_rect = nil
    self:renderCommittedOp(op, sx0, sy0, sx1, sy1)   -- re-render only the curve's rect
    self:afterCommit()
end

-- Drop any in-progress shape and wipe its preview.
function InkAwayView:cancelShape()
    if not (self.shape_drag or self.curve_stage or self.shape_preview) then return end
    self.shape_drag = nil
    self.curve_stage = nil
    self.curve_snap = nil
    self.curve_p0, self.curve_p1, self.curve_ctrl = nil, nil, nil
    self.shape_preview = nil
    self:refreshPreview()   -- clears the old preview region from the base
end

-- Place a shape that is finished but still pending (usually because the panel
-- missed its lift) before the tool or shape type changes under it. A curve
-- waiting for its bend is placed straight; a drag too small to be a shape is
-- dropped. Called at every such transition, so a drawn shape is never lost or
-- turned into a different shape.
function InkAwayView:flushShape()
    if self.curve_stage == "bend" then
        self:commitCurve()
    elseif self.shape_drag then
        local d = self.shape_drag
        local dx, dy = d.x1 - d.x0, d.y1 - d.y0
        if dx * dx + dy * dy < 9 then self:cancelShape() else self:commitShape() end
    end
end

------------------------------------------------------------------------------
-- Paint bucket: flood fill an enclosed area on tap
------------------------------------------------------------------------------

-- The topmost closed shape whose interior contains a canvas point, or nil.
function InkAwayView:shapeUnderPoint(cx, cy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "shape" and self:editableOp(op) and Shapes.contains(op, cx, cy) then
            return { op = op, idx = i }
        end
    end
    return nil
end

function InkAwayView:doFill(pos)
    self:flushPending()
    self:layerReady()
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    -- A tap inside a shape fills that shape: the colour is stored on the shape
    -- (under its outline), so it moves, rotates, duplicates and deletes with it.
    -- Copy-on-write, so one Undo takes just the fill away.
    local shp = self:shapeUnderPoint(cx, cy)
    if shp then
        self:editOp(shp.idx, shp.op, function(o)
            o.fill_color = { self.fill_color[1], self.fill_color[2], self.fill_color[3] }
            o.fill_alpha = self.fill_alpha
        end)
        self:recompose()
        self:afterCommit()
        return
    end
    local paper = self:paperRGB()
    local gray = Export.buildGray(self:drawnCanvas(), paper and Paint.lum(paper), Paint.darkPaper(paper))
    local runs = Fill.compute(gray, self.view.canvas_w, self.view.canvas_h,
        math.floor(cx), math.floor(cy), 40)
    if not runs or #runs == 0 then return end
    local op = self.canvas:addFillOp(runs, self.fill_color, self.fill_alpha)
    if self.symmetry ~= "off" then op.sym = self.symmetry end
    self:stampOpIntoCanvas(op)
    self:markDirty()
    self:redraw()
    self:afterCommit()
end

------------------------------------------------------------------------------
-- Picking a placed shape (with Pan, or a finger's hold); what it can then do is
-- the selection's (see view/selection.lua)
------------------------------------------------------------------------------

-- Find the topmost shape op under a screen point. Returns {op, idx} or nil. A
-- shape with any part erased is left alone: moving it would leave the erased
-- part behind.
function InkAwayView:hitTestShape(sx, sy)
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "shape" and self:editableOp(op) then
            -- about 1.5 mm either side of the line, so a fingertip finds it
            local tol = (op.width or 6) / 2 + Screen:scaleBySize(10) / self.view.zoom
            if Shapes.hit(op, cx, cy, tol) and not self:shapeErased(i) then
                return { op = op, idx = i }
            end
        end
    end
    return nil
end

-- Has an erase stroke made after shape ops[idx] touched any of it, on any
-- mirror copy of either?
function InkAwayView:shapeErased(idx)
    local ops, W, H = self.canvas.ops, self.view.canvas_w, self.view.canvas_h
    local op = ops[idx]
    for j = idx + 1, #ops do
        local e = ops[j]
        if e.kind == "erase" and e.pts and #e.pts >= 2 then
            for _, a in ipairs(Symmetry.flips(e.sym)) do
                for _, b in ipairs(Symmetry.flips(op.sym)) do
                    -- erase copy a against shape copy b: flip both by b
                    local pts = Symmetry.flipPoints(e.pts, bit.bxor(a, b), W, H)
                    if Shapes.reachedBy(op, pts, (e.width or 1) / 2) then return true end
                end
            end
        end
    end
    return false
end

-- Is the outline being dragged out drawn in the page's ink? It is refreshed
-- with the fast waveform (see refreshPreview), which shows black and white
-- only: a grey, a colour or a partial opacity breaks up or does not show at all
-- until some other refresh. So on e-ink a pen that is not solid black has its
-- outline drawn in the page's ink while it is dragged out, as a pen's live ink
-- is on a colour panel, and the shape takes its own colour and opacity when it
-- is placed.
function InkAwayView:shapePreviewInInk(sp)
    if self:instantColour() then return false end
    local function solidBlack(c, a)
        return (a or 255) >= 255 and (c == nil or (c[1] == 0 and c[2] == 0 and c[3] == 0))
    end
    if not solidBlack(sp.color, sp.alpha) then return true end
    return sp.fill_color ~= nil and not sp.fill and not solidBlack(sp.fill_color, sp.fill_alpha)
end

-- The shape being placed, over the drawing and clipped to the area.
function InkAwayView:paintShapePreview(bb, x, y)
    local v = self.view
    local sw = self.screen_w
    local cy0, cy1 = y + v.area_y, y + v.area_y + v.area_h
    local mirror = self.symmetry ~= "off"
    local axsx, axsy
    if mirror then
        axsx = v.area_x + (v.canvas_w / 2 - v.pan_x) * v.zoom
        axsy = v.area_y + (v.canvas_h / 2 - v.pan_y) * v.zoom
    end
    local function makePut(color)
        local put = function(px, py, len)
            py = py + y
            if py < cy0 or py >= cy1 then return end
            px = px + x
            if px < x then len = len + (px - x); px = x end
            if px + len > x + sw then len = x + sw - px end
            if len > 0 then bb:paintRect(px, py, len, 1, color) end
        end
        -- mirror the preview too, so a symmetric shape shows before it is placed
        if mirror then
            put = Symmetry.wrap(put, self.symmetry,
                function(px, len) return 2 * axsx - px - len end,
                function(py) return 2 * axsy - py end)
        end
        return put
    end
    local sp = self.shape_preview
    if self:shapePreviewInInk(sp) then   -- its outline alone, in the page's ink
        local outline = {}
        for k, val in pairs(sp) do outline[k] = val end
        outline.fill, outline.fill_color = false, nil
        Shapes.render(outline, makePut(Paint.inkOn(self:paperRGB())))
        return
    end
    if sp.fill_color and not sp.fill then
        Shapes.fill(sp, makePut(displayColor(self:shownInk(sp.fill_color, self:paperRGB()), sp.fill_alpha)))
    end
    Shapes.render(sp, makePut(displayColor(self:shownInk(sp.color, self:paperRGB()), sp.alpha)))
end

return InkAwayView
