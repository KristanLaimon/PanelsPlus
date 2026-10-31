--[[
The selection: what the lasso loops (pen strokes, shapes, fills, pictures and
text boxes alike), or the shape or picture a touch or hold with Pan picks. It is
one group of ops with one frame and one menu, however it was made.

The frame has a square handle at each corner (drag to resize, proportions
kept; line thickness scales with it) and a round handle above it (drag to turn
it to any angle, snapping to quarter turns). A drag inside moves it. While it
moves or resizes it is lifted off the page and drawn on a small white card
that follows the finger (cheap blits); a turn shows the turning frame. Each
change is one undo step, made on copies of the ops (ink/transform.lua), and
only the boxes it touched are composed again.

The menu is a compact sheet beside the frame: Convert to text (for writing),
Cut, Copy, Duplicate, a quarter turn, the two mirrors (not for text alone),
To front, Colour, Opacity and Size (for pen strokes, shapes and fills, in the
same sheet), Remove background (one picture), Delete and Done. The page stays
live under it, so the selection can be dragged with the menu open.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Device = require("device")
local Font = require("ui/font")
local _ = require("ink/l10n")
local Canvas = require("ink/canvas")
local Clipboard = require("ink/clipboard")
local InkGeom = require("ink/geom")
local Layers = require("ink/layers")
local Palette = require("ink/palette")
local Shapes = require("ink/shapes")
local Text = require("ink/text")
local Transform = require("ink/transform")
local IconMenu = require("ink/ui/iconmenu")
local SliderRow = require("ink/ui/controls").SliderRow

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local sameColor = Palette.sameColor
local translateOp = Canvas.translateOp

local InkAwayView = {}

local function S(px) return Screen:scaleBySize(px) end

------------------------------------------------------------------------------
-- What is selected
------------------------------------------------------------------------------

-- The box an op covers as drawn (canvas coords, line width included).
local function opExtent(op)
    local k = op.kind
    if k == "image" then
        local a = math.rad(op.angle or 0)
        local ca, sa = math.abs(math.cos(a)), math.abs(math.sin(a))
        local bw, bh = op.w * ca + op.h * sa, op.w * sa + op.h * ca
        local cx, cy = op.x + op.w / 2, op.y + op.h / 2
        return cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2
    elseif k == "text" then
        local a, b, c, d = Text.bounds(op)
        if a then return a, b, c, d end
        local h = (op.size or 20) * 1.5   -- not laid out yet
        return op.x, op.y, op.x + (op.w or 0), op.y + h
    elseif k == "shape" and op.pts and #op.pts >= 4 then
        local x0, y0, x1, y1 = Shapes.bounds(op)
        local p = (op.width or 1) / 2 + 1
        return x0 - p, y0 - p, x1 + p, y1 + p
    end
    return Canvas.opBox(op)
end
InkAwayView.opExtent = opExtent

-- Select the ops at `idxs` (from the lasso, or "pan" for a touch or hold with
-- Pan). Returns whether anything is selected.
function InkAwayView:selectOps(idxs, from)
    if #idxs == 0 then self.selection = nil; return false end
    self.selection = { idxs = idxs, from = from or "lasso" }
    self:recomputeSelectionBBox()
    return self.selection ~= nil
end

-- The selected ops, in drawing order.
function InkAwayView:selectionOps()
    local out = {}
    if not self.selection then return out end
    local idxs = {}
    for i, idx in ipairs(self.selection.idxs) do idxs[i] = idx end
    table.sort(idxs)
    for _, idx in ipairs(idxs) do
        local op = self.canvas.ops[idx]
        if op then out[#out + 1] = op end
    end
    return out
end

-- How many of each kind the selection holds: { ink, shape, fill, image, text,
-- link, n }, counted when its box is (see recomputeSelectionBBox).
function InkAwayView:selectionKinds()
    local sel = self.selection
    if not sel then return { ink = 0, shape = 0, fill = 0, image = 0, text = 0, link = 0, n = 0 } end
    if not sel.kinds then self:recomputeSelectionBBox() end
    return sel.kinds or { ink = 0, shape = 0, fill = 0, image = 0, text = 0, link = 0, n = 0 }
end

-- The selection's box (canvas coords), from its ops as drawn, and how many of
-- each kind it holds (asked on every touch and paint, so counted here, once).
function InkAwayView:recomputeSelectionBBox()
    local sel = self.selection
    if not sel then return end
    local x0, y0, x1, y1
    local k = { ink = 0, shape = 0, fill = 0, image = 0, text = 0, link = 0, n = 0 }
    for _, op in ipairs(self:selectionOps()) do
        local kind = op.kind == "erase" and "ink" or op.kind
        k[kind] = (k[kind] or 0) + 1
        k.n = k.n + 1
        local a, b, c, d = opExtent(op)
        if a then
            x0, y0 = math.min(x0 or a, a), math.min(y0 or b, b)
            x1, y1 = math.max(x1 or c, c), math.max(y1 or d, d)
        end
    end
    sel.kinds = k
    sel.bbox = x0 and { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } or nil
    if not x0 then self.selection = nil end
end

-- Forget the selection and any lasso loop, without repainting.
function InkAwayView:resetLasso()
    self:endSelectionDrag(true)
    self.selection, self.lassoing, self.lasso_scr = nil, false, nil
    self:closeSelectionMenu()
    self:setSelectionActive(false)
end

-- Drop the selection and repaint where its frame was.
function InkAwayView:dropSelection()
    local had = self.selection ~= nil or self.lassoing
    local frame = self.selection and self:selFrame()
    self:resetLasso()
    if had then
        if frame then
            self:refreshAreaBox("ui", frame.x0 - S(48), frame.y0 - S(64), frame.x1 + S(48), frame.y1 + S(64))
        end
        UIManager:setDirty(self, "ui", self:areaScreenRect())
    end
end
InkAwayView.clearSelection = InkAwayView.dropSelection

-- Keep the canvas receiving gestures while a popup is on top (KOReader only
-- delivers events to a lower widget that is is_always_active), so the selection
-- can be dragged with its menu open. The previous value is restored on close.
function InkAwayView:setSelectionActive(on)
    if on then
        if self._sel_prev_active == nil then self._sel_prev_active = self.is_always_active or false end
        self.is_always_active = true
    elseif self._sel_prev_active ~= nil then
        self.is_always_active = self._sel_prev_active
        self._sel_prev_active = nil
    end
end

------------------------------------------------------------------------------
-- The frame and its handles (screen coords)
------------------------------------------------------------------------------

-- The frame around the selection: { x0, y0, x1, y1 } on screen. A small
-- selection gets a frame of at least a finger's reach each way, so its middle
-- (to move it) stays clear of the corner handles.
function InkAwayView:selFrame()
    local b = self.selection and self.selection.bbox
    if not b then return nil end
    local v, pad, least = self.view, S(6), S(72)
    local x0, y0 = InkGeom.toScreen(v, b.x0, b.y0)
    local x1, y1 = InkGeom.toScreen(v, b.x1, b.y1)
    x0, y0, x1, y1 = math.floor(x0) - pad, math.floor(y0) - pad, math.ceil(x1) + pad, math.ceil(y1) + pad
    if x1 - x0 < least then
        local c = (x0 + x1) / 2
        x0, x1 = math.floor(c - least / 2), math.ceil(c + least / 2)
    end
    if y1 - y0 < least then
        local c = (y0 + y1) / 2
        y0, y1 = math.floor(c - least / 2), math.ceil(c + least / 2)
    end
    return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

-- Can the selection turn? Not when it is only links (they stay upright).
function InkAwayView:selCanTurn()
    local k = self:selectionKinds()
    return k.n > k.link
end

-- Where the turning handle sits: above the frame's middle, or below it when the
-- frame reaches the top of the drawing area.
function InkAwayView:selKnob(f)
    f = f or self:selFrame()
    if not f then return nil end
    local d = S(34)
    local x = math.floor((f.x0 + f.x1) / 2)
    if f.y0 - d < self.view.area_y + S(14) then return x, f.y1 + d, f.y1 end
    return x, f.y0 - d, f.y0
end

-- What a screen point is on: "turn", a corner ("nw", "ne", "sw", "se"), "move"
-- (inside the frame), or nil.
function InkAwayView:selHit(sx, sy)
    local f = self:selFrame()
    if not f then return nil end
    local r = S(22)
    local function near(x, y) return math.abs(sx - x) <= r and math.abs(sy - y) <= r end
    if self:selCanTurn() then
        local kx, ky = self:selKnob(f)
        if near(kx, ky) then return "turn" end
    end
    if near(f.x0, f.y0) then return "nw" end
    if near(f.x1, f.y0) then return "ne" end
    if near(f.x0, f.y1) then return "sw" end
    if near(f.x1, f.y1) then return "se" end
    local m = S(10)
    if sx >= f.x0 - m and sx <= f.x1 + m and sy >= f.y0 - m and sy <= f.y1 + m then return "move" end
    return nil
end
-- (the lasso's older name)
function InkAwayView:inSelBBoxScreen(sx, sy) return self:selHit(sx, sy) ~= nil end

------------------------------------------------------------------------------
-- Dragging: move, resize, turn
------------------------------------------------------------------------------

-- A touch with the lasso or Pan: on the frame or a handle starts a drag.
-- Returns whether it did.
function InkAwayView:selTouch(pos)
    local hit = pos and self:selHit(pos.x, pos.y)
    if not hit then return false end
    local b = self.selection.bbox
    local d = { kind = hit == "turn" and "turn" or (hit == "move" and "move" or "resize"),
        corner = hit, sx = pos.x, sy = pos.y, x = pos.x, y = pos.y, began = false }
    if d.kind == "resize" then
        -- the opposite corner stays put
        d.ax = (hit == "nw" or hit == "sw") and b.x1 or b.x0
        d.ay = (hit == "nw" or hit == "ne") and b.y1 or b.y0
        d.w0, d.h0 = math.max(1, b.x1 - b.x0), math.max(1, b.y1 - b.y0)
        d.s = 1
    elseif d.kind == "turn" then
        local cx, cy = InkGeom.toScreen(self.view, (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2)
        d.cx, d.cy = cx, cy
        d.grab = math.atan2(pos.y - cy, pos.x - cx)
        d.a = 0
    end
    self.sel_drag = d
    return true
end

-- The angle a turn snaps to: a quarter turn when within 4 degrees of one.
local function snapAngle(a)
    local q = math.floor(a / (math.pi / 2) + 0.5) * (math.pi / 2)
    if math.abs(a - q) < math.rad(4) then return q end
    return a
end

function InkAwayView:selPan(pos)
    local d = self.sel_drag
    if not (d and pos) then return false end
    d.x, d.y = pos.x, pos.y
    if not d.began then
        if math.abs(pos.x - d.sx) + math.abs(pos.y - d.sy) < S(3) then return true end
        -- where the frame stood: the first move repaints it too, as the lift
        -- takes the selection off the page there
        self._sel_last_rect = self:selDragRect()
        d.began = true
        -- the menu goes while it moves (it comes back beside the new place), or
        -- every frame would repaint it too; the paint after it is a whole one
        -- (see uncovered)
        self:closeSelectionMenu()
        if d.kind ~= "turn" then self:liftSelection() end
    end
    if d.kind == "resize" then
        local px, py = InkGeom.toCanvas(self.view, pos.x, pos.y)
        local s = math.max(math.abs(px - d.ax) / d.w0, math.abs(py - d.ay) / d.h0)
        local least = S(12) / self.view.zoom / math.min(d.w0, d.h0)   -- never smaller than a fingertip
        d.s = math.max(least, math.min(20, s))
    elseif d.kind == "turn" then
        d.a = snapAngle(math.atan2(pos.y - d.cy, pos.x - d.cx) - d.grab)
    end
    self:selShowDrag()
    return true
end

-- The lift: the selection is drawn once onto a white card (canvas scale, then
-- screen scale), and the page under it is composed again without it, so the
-- card can follow the finger with plain blits.
function InkAwayView:liftSelection()
    local sel, d = self.selection, self.sel_drag
    if not (sel and sel.bbox and d) or not self.canvas_bb then return end
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    local b = sel.bbox
    local box = { x0 = math.max(0, math.floor(b.x0)), y0 = math.max(0, math.floor(b.y0)),
                  x1 = math.min(W, math.ceil(b.x1)), y1 = math.min(H, math.ceil(b.y1)) }
    if box.x1 <= box.x0 or box.y1 <= box.y0 then return end
    local ops = self:selectionOps()
    local ok = pcall(function()
        -- the selection alone, drawn into its box of the master and copied out;
        -- the box is composed again without it just below
        local cb = self.canvas_bb
        self:composeInto(cb, ops, nil, nil, nil, nil, true, nil, box)
        local w, h = box.x1 - box.x0, box.y1 - box.y0
        local card = Blitbuffer.new(w, h, cb:getType())
        card:blitFrom(cb, 0, 0, box.x0, box.y0, w, h)
        d.card, d.card_box = card, box
    end)
    if not ok then d.card = nil end
    local lifted = {}
    for _, op in ipairs(ops) do lifted[op] = true end
    self._lifted = lifted
    self:repaintCanvasBoxes({ box }, self:selNeedsFullCompose(ops))
end

-- The card at the size it is shown now (screen px), cached per size.
function InkAwayView:selCardAt(w, h)
    local d = self.sel_drag
    if not (d and d.card) then return nil end
    w, h = math.max(1, math.floor(w + 0.5)), math.max(1, math.floor(h + 0.5))
    if d.card_view and d.card_view_w == w and d.card_view_h == h then return d.card_view end
    if d.card_view and d.card_view ~= d.card then d.card_view:free() end
    d.card_view, d.card_view_w, d.card_view_h = nil, nil, nil
    local view
    if w == d.card:getWidth() and h == d.card:getHeight() then
        view = d.card
    else
        local ok, scaled = pcall(function() return RenderImage:scaleBlitBuffer(d.card, w, h, false) end)
        view = ok and scaled or nil
    end
    -- on a screen turned in software, keep the card in the screen's pixel order:
    -- turned once here, then every frame is a row copy (see blitPanel)
    d.card_rot = 0
    if view and self:screenBBRot() ~= 0 then
        local ok, panel = pcall(function()
            local p = self:newPanelBuffer(w, h)
            p:blitFrom(view, 0, 0, 0, 0, w, h)
            return p
        end)
        if ok and panel then
            if view ~= d.card then view:free() end
            view, d.card_rot = panel, self:screenBBRot()
        end
    end
    d.card_view, d.card_view_w, d.card_view_h = view, w, h
    return view
end

-- The frame's corners on screen as the drag stands now: { x, y, ... } for the
-- four corners, in order.
function InkAwayView:selDragCorners()
    local f, d = self:selFrame(), self.sel_drag
    if not f then return nil end
    local c = { f.x0, f.y0, f.x1, f.y0, f.x1, f.y1, f.x0, f.y1 }
    if not (d and d.began) then return c end
    if d.kind == "move" then
        local dx, dy = d.x - d.sx, d.y - d.sy
        for i = 1, 8, 2 do c[i], c[i + 1] = c[i] + dx, c[i + 1] + dy end
    elseif d.kind == "resize" then
        local ax, ay = InkGeom.toScreen(self.view, d.ax, d.ay)
        for i = 1, 8, 2 do c[i], c[i + 1] = ax + (c[i] - ax) * d.s, ay + (c[i + 1] - ay) * d.s end
    elseif d.kind == "turn" then
        local ca, sa = math.cos(d.a), math.sin(d.a)
        for i = 1, 8, 2 do
            local dx, dy = c[i] - d.cx, c[i + 1] - d.cy
            c[i], c[i + 1] = d.cx + dx * ca - dy * sa, d.cy + dx * sa + dy * ca
        end
    end
    return c
end

-- The screen box the frame covers now, with room for the handles.
function InkAwayView:selDragRect()
    local c = self:selDragCorners()
    if not c then return nil end
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, 8, 2 do
        x0, x1 = math.min(x0, c[i]), math.max(x1, c[i])
        y0, y1 = math.min(y0, c[i + 1]), math.max(y1, c[i + 1])
    end
    local pad = S(52)   -- handles, the turning knob and its label
    return { x = math.floor(x0) - pad, y = math.floor(y0) - pad,
             w = math.ceil(x1 - x0) + 2 * pad, h = math.ceil(y1 - y0) + 2 * pad }
end

-- Show the drag as it stands, at every move: the frame's old and new places are
-- painted from the page buffer (no toolbar, no full blit) and refreshed with the
-- fast waveform, so the card keeps up with the finger. The places it passed are
-- kept, so the drop can clean the fast waveform's trail with one even refresh.
function InkAwayView:selShowDrag()
    local d = self.sel_drag
    local cur = d and self:selDragRect()
    if not cur then return end
    local v = self.view
    local last = self._sel_last_rect or cur
    self._sel_last_rect = cur
    local x0, y0 = math.min(cur.x, last.x) - v.area_x, math.min(cur.y, last.y) - v.area_y
    local x1 = math.max(cur.x + cur.w, last.x + last.w) - v.area_x
    local y1 = math.max(cur.y + cur.h, last.y + last.h) - v.area_y
    d.swept = InkGeom.growRect(d.swept, x0, y0, x1, y1)
    self._blit_rect = InkGeom.growRect(self._blit_rect, x0, y0, x1, y1)
    self:liveDirty("fast", { x0 = x0, y0 = y0, x1 = x1, y1 = y1 })
end

-- End a drag: commit it (a move, a resize or a turn), or with `drop` just undo
-- the lift. Returns whether anything changed.
function InkAwayView:endSelectionDrag(drop)
    local d = self.sel_drag
    if not d then return false end
    self.sel_drag = nil
    self._sel_last_rect = nil
    self:liveDrop()   -- the drop's own refresh covers anything still pending
    local lifted = self._lifted
    self._lifted = nil
    local changed = false
    local rx0, ry0, rx1, ry1   -- the screen box the repaint below refreshes
    if d.began and not drop and self.selection then
        local v = self.view
        if d.kind == "move" then
            local dx, dy = (d.x - d.sx) / v.zoom, (d.y - d.sy) / v.zoom
            if math.abs(dx) >= 0.5 or math.abs(dy) >= 0.5 then
                rx0, ry0, rx1, ry1 = self:transformSelection(function(op) translateOp(op, dx, dy) end)
                changed = true
            end
        elseif d.kind == "resize" and math.abs(d.s - 1) > 1e-3 then
            rx0, ry0, rx1, ry1 = self:transformSelection(function(op) Transform.scale(op, d.ax, d.ay, d.s) end)
            changed = true
        elseif d.kind == "turn" and math.abs(d.a) > 1e-3 then
            local b = self.selection.bbox
            local cx, cy = (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2
            rx0, ry0, rx1, ry1 = self:transformSelection(function(op) Transform.rotate(op, cx, cy, d.a) end)
            changed = true
        end
    end
    if lifted and not changed and self.selection and self.selection.bbox then
        local b = self.selection.bbox   -- nothing moved after all: put it back
        rx0, ry0, rx1, ry1 = self:repaintCanvasBoxes({ b }, self:selNeedsFullCompose(self:selectionOps()))
    end
    -- the drag's path, once, with an even refresh. With the menu gone since the
    -- drag began, nothing else needs painting, so the paint stays a region one
    -- (a full compose above has already asked for a full one).
    local sw = d.swept
    if sw then
        local v = self.view
        self:refreshAreaBox("ui", v.area_x + sw.x0, v.area_y + sw.y0, v.area_x + sw.x1, v.area_y + sw.y1)
        if drop then
            self._blit_rect = nil   -- called off: a full paint puts everything back
        else
            self._blit_rect = InkGeom.growRect(self._blit_rect, sw.x0, sw.y0, sw.x1, sw.y1)
            if rx0 then
                self._blit_rect = InkGeom.growRect(self._blit_rect, rx0 - v.area_x, ry0 - v.area_y,
                    rx1 - v.area_x, ry1 - v.area_y)
            end
        end
    end
    if d.card_view and d.card_view ~= d.card then d.card_view:free() end
    if d.card then d.card:free() end
    return changed
end

function InkAwayView:selRelease()
    local d = self.sel_drag
    if not d then return false end
    local began = d.began
    self:endSelectionDrag(false)
    if began and self.selection then
        self:openSelectionMenu()   -- (again) beside the frame's new place
    elseif self.selection and not self._sel_dialog then
        self:openSelectionMenu()   -- a tap on the frame
    end
    return true
end

------------------------------------------------------------------------------
-- Changing the selected ops
------------------------------------------------------------------------------

-- Does recomposing the selection's ops need the whole page? Mirrored ops draw
-- elsewhere too, and pictures and text feed the buffers an eraser reveals.
function InkAwayView:selNeedsFullCompose(ops)
    for _, op in ipairs(ops) do
        if (op.sym and op.sym ~= "off") or op.kind == "image" or op.kind == "text" then return true end
    end
    return false
end

-- Compose the canvas boxes `boxes` again (or the whole page with `full`), show
-- them and refresh them. Boxes that touch are composed as one; boxes apart (a
-- selection moved away) each on their own, far less than the box around both.
-- Returns the screen box refreshed (nil for the whole page).
function InkAwayView:repaintCanvasBoxes(boxes, full)
    if full then
        self:composeCanvas(); self:renderView()
        UIManager:setDirty(self, "ui", self:areaScreenRect())
        return
    end
    local groups = {}
    for _, b in ipairs(boxes) do
        local g = { x0 = b.x0 - 2, y0 = b.y0 - 2, x1 = b.x1 + 2, y1 = b.y1 + 2 }
        for i = #groups, 1, -1 do
            local o = groups[i]
            if g.x0 < o.x1 and o.x0 < g.x1 and g.y0 < o.y1 and o.y0 < g.y1 then
                g = { x0 = math.min(g.x0, o.x0), y0 = math.min(g.y0, o.y0),
                      x1 = math.max(g.x1, o.x1), y1 = math.max(g.y1, o.y1) }
                table.remove(groups, i)
            end
        end
        groups[#groups + 1] = g
    end
    local v = self.view
    local x0, y0, x1, y1
    for _, g in ipairs(groups) do
        self:composeRegion(g.x0, g.y0, g.x1, g.y1)
        local sx0, sy0 = InkGeom.toScreen(v, g.x0, g.y0)
        local sx1, sy1 = InkGeom.toScreen(v, g.x1, g.y1)
        self:renderViewRect(sx0 - v.area_x, sy0 - v.area_y, sx1 - v.area_x, sy1 - v.area_y)
        x0, y0 = math.min(x0 or sx0, sx0), math.min(y0 or sy0, sy0)
        x1, y1 = math.max(x1 or sx1, sx1), math.max(y1 or sy1, sy1)
    end
    if not x0 then return end
    return self:refreshAreaBox("ui", x0 - S(56), y0 - S(56), x1 + S(56), y1 + S(56))
end

-- Change every selected op through fn(copy), as one undo step, and repaint the
-- old and new boxes. Returns the screen box refreshed, as repaintCanvasBoxes.
function InkAwayView:transformSelection(fn)
    local sel = self.selection
    if not sel then return end
    local before = sel.bbox
    self.canvas:pushHistory()
    for _, idx in ipairs(sel.idxs) do
        local op = self.canvas.ops[idx]
        if op then
            local c = self.canvas:cloneOp(op)
            fn(c)
            self.canvas:replaceOp(idx, c)
        end
    end
    self:markDirty()
    self:recomputeSelectionBBox()
    local boxes = { before }
    if self.selection and self.selection.bbox then boxes[2] = self.selection.bbox end
    return self:repaintCanvasBoxes(boxes, self:selNeedsFullCompose(self:selectionOps()))
end

-- Edit the op at `idx` as one undo step: it is copied, mutate(copy) changes the
-- copy, and the copy takes its place, so history snapshots keep the original.
-- Returns the copy.
function InkAwayView:editOp(idx, op, mutate)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(op)
    if mutate then mutate(clone) end
    self.canvas:replaceOp(idx, clone)
    self:markDirty()
    return clone
end

-- The ops that take colour, opacity and size.
local function styled(op) return op.kind == "ink" or op.kind == "shape" or op.kind == "fill" end

function InkAwayView:selSetColour(rgb)
    self:transformSelection(function(op)
        if styled(op) then op.color = { rgb[1], rgb[2], rgb[3] } end
    end)
end

function InkAwayView:selSetOpacity(pct)
    local a = math.max(1, math.min(255, math.floor(pct / 100 * 255 + 0.5)))
    self:transformSelection(function(op) if styled(op) then op.alpha = a end end)
end

function InkAwayView:selSetSize(w)
    self:transformSelection(function(op)
        if (op.kind == "ink" or op.kind == "shape") then op.width = math.max(1, w) end
    end)
end

-- A quarter turn clockwise about the middle of the selection.
function InkAwayView:selTurn90()
    local b = self.selection and self.selection.bbox
    if not b then return end
    local cx, cy = (b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2
    self:transformSelection(function(op) Transform.rotate(op, cx, cy, math.pi / 2) end)
end

-- Mirror the selection across its middle, side to side ("h") or up and down.
function InkAwayView:selFlip(axis)
    local b = self.selection and self.selection.bbox
    if not b then return end
    local mid = axis == "h" and (b.x0 + b.x1) / 2 or (b.y0 + b.y1) / 2
    self:transformSelection(function(op) Transform.flip(op, axis, mid) end)
end

-- Move the selection above everything else, keeping its own order.
function InkAwayView:selToFront()
    local sel = self.selection
    if not sel then return end
    local idxs = {}
    for i, idx in ipairs(sel.idxs) do idxs[i] = idx end
    table.sort(idxs)
    local ops = self.canvas.ops
    -- the top of the list, or of the active layer in a layered drawing
    local top = self.canvas.layers and (Layers.insertIndex(self.canvas, self.canvas.active_layer) - 1) or #ops
    if idxs[#idxs] == top and idxs[1] == top - #idxs + 1 then return end   -- already on top
    self.canvas:pushHistory()
    local moved = {}
    for k = #idxs, 1, -1 do table.insert(moved, 1, table.remove(ops, idxs[k])) end
    local new = {}
    for _, op in ipairs(moved) do
        local _op, at = self.canvas:placeOp(op)
        new[#new + 1] = at
    end
    sel.idxs = new
    self:markDirty()
    self:repaintCanvasBoxes({ sel.bbox }, self:selNeedsFullCompose(moved))
end

-- Duplicate the selection a little down and right (a grid step with the grid
-- on); the copies become the selection.
function InkAwayView:selDuplicate()
    local sel = self.selection
    if not sel then return end
    self.canvas:pushHistory()
    local off = self.grid_on and self.grid_size or math.floor(24 / self.view.zoom + 0.5)
    local new = {}
    for _, op in ipairs(self:selectionOps()) do
        local c = self.canvas:cloneOp(op)
        translateOp(c, off, off)
        local _op, at = self.canvas:placeOp(c)
        new[#new + 1] = at
    end
    sel.idxs = new
    self:recomputeSelectionBBox()
    self:markDirty()
    self:repaintCanvasBoxes({ self.selection.bbox }, self:selNeedsFullCompose(self:selectionOps()))
end

function InkAwayView:selDelete()
    local sel = self.selection
    if not sel then return end
    local ops = self:selectionOps()
    local box = sel.bbox
    self.canvas:pushHistory()
    local idxs = {}
    for i, idx in ipairs(sel.idxs) do idxs[i] = idx end
    table.sort(idxs, function(a, b) return a > b end)   -- remove high to low
    for _, idx in ipairs(idxs) do self.canvas:removeOp(idx) end
    self:resetLasso()
    self:markDirty()
    self:repaintCanvasBoxes({ box }, self:selNeedsFullCompose(ops))
end

-- Put the selection on the clipboard; `cut` also deletes it.
function InkAwayView:selCopy(cut)
    local sel = self.selection
    if not (sel and sel.bbox) then return end
    local ops = self:selectionOps()
    Clipboard.put(ops, sel.bbox)
    if cut then self:selDelete() end
    self:showNotice(string.format(cut and _("Cut %d item(s). Tap with the lasso to paste.")
        or _("Copied %d item(s). Tap with the lasso to paste."), #ops))
end

------------------------------------------------------------------------------
-- The menu
------------------------------------------------------------------------------

function InkAwayView:closeSelectionMenu()
    local m = self._sel_dialog
    self._sel_dialog = nil
    if m then
        m.on_close = nil
        pcall(function() UIManager:close(m) end)
    end
end

-- Open the selection's menu beside it. `panel` shows the colour, opacity or
-- size controls in its place.
function InkAwayView:openSelectionMenu(panel)
    if not (self.selection and self.selection.bbox) then return end
    self:closeSelectionMenu()
    self:setSelectionActive(true)   -- keep the selection draggable under the menu
    local k = self:selectionKinds()
    local cols = 3
    local gap = S(8)
    local content_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.62)
    local bw = math.floor((content_w - (cols - 1) * gap) / cols)
    local menu
    local function again(p) self:openSelectionMenu(p) end
    local function act(label, fn, dark)
        return self:actionButton(label, bw, function() fn() end, dark, "small")
    end
    local function row(list)
        local hg = HorizontalGroup:new{ align = "center" }
        for i, w in ipairs(list) do
            if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
            table.insert(hg, w)
        end
        return hg
    end
    local build = function(m)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w)
            if #content > 0 then table.insert(content, VerticalSpan:new{ width = gap }) end
            table.insert(content, w)
        end
        local stylable = k.ink + k.shape + k.fill > 0
        if panel == "colour" then
            add(self:sheetLabel(_("Colour"), true))
            local per = 6
            local tw = math.floor((content_w - (per - 1) * gap) / per)
            local current = self:selectionOps()[1]
            local tiles = {}
            local entries = {}
            for _, e in ipairs(Palette.SHADES) do entries[#entries + 1] = e end
            if self:colorScreen() then
                for _, e in ipairs(Palette.COLORS) do entries[#entries + 1] = e end
            end
            for _, e in ipairs(entries) do
                tiles[#tiles + 1] = self:swatchTile(e.rgb, current and current.color and sameColor(current.color, e.rgb),
                    tw, function() self:selSetColour(e.rgb); again("colour") end)
                if #tiles == per then add(row(tiles)); tiles = {} end
            end
            if #tiles > 0 then add(row(tiles)) end
        elseif panel == "opacity" or panel == "size" then
            local first
            for _, op in ipairs(self:selectionOps()) do
                if (panel == "size" and (op.kind == "ink" or op.kind == "shape")) or (panel == "opacity" and styled(op)) then
                    first = op; break
                end
            end
            if panel == "size" then
                add(SliderRow:new{ label = _("Size"), value = math.floor((first and first.width or 4) + 0.5),
                    min = 1, max = 60, width = content_w, parent = m,
                    format = function(v) return string.format("%d px", v) end,
                    on_set = function(v) self:selSetSize(v) end })
            else
                add(SliderRow:new{ label = _("Opacity"),
                    value = math.floor(((first and first.alpha) or 255) / 255 * 100 + 0.5),
                    width = content_w, parent = m,
                    on_set = function(v) self:selSetOpacity(v) end })
            end
        else
            if self:selectionHasWriting() then
                add(self:actionButton(_("Convert to text"), content_w, function()
                    self:closeSelectionMenu(); self:convertSelectionToText() end, true, "small"))
            end
            add(row({ act(_("Cut"), function() self:closeSelectionMenu(); self:selCopy(true) end),
                      act(_("Copy"), function() self:selCopy(false) end),
                      act(_("Duplicate"), function() self:selDuplicate(); again() end) }))
            if self:selCanTurn() then
                local turn = { act("\u{21BB} " .. _("90\u{00B0}"), function() self:selTurn90(); again() end) }
                if k.n > k.text + k.link then   -- (a text box alone stays readable: no mirror)
                    turn[2] = act("\u{2194} " .. _("Flip"), function() self:selFlip("h"); again() end)
                    turn[3] = act("\u{2195} " .. _("Flip"), function() self:selFlip("v"); again() end)
                end
                add(row(turn))
            end
            if stylable then
                local style = { act(_("Colour"), function() again("colour") end),
                                act(_("Opacity"), function() again("opacity") end) }
                if k.ink + k.shape > 0 then style[#style + 1] = act(_("Size"), function() again("size") end) end
                add(row(style))
            end
            if (k.link or 0) > 0 then
                add(row({ act(_("Change link\u{2026}"), function() self:selLink() end),
                          act(_("Go to link"), function()
                              local idx = self:selectionLinks()[1]
                              if idx then self:followLink(self.canvas.ops[idx]) end
                          end),
                          act(_("Remove link"), function() self:selUnlink() end) }))
            elseif not self.reader_mode then   -- over a book there are no pages to link to
                add(self:actionButton(_("Link to page\u{2026}"), content_w, function() self:selLink() end,
                    false, "small", "link"))
            end
            if k.n == 1 and k.image == 1 then
                add(self:actionButton(_("Remove background"), content_w, function()
                    self:closeSelectionMenu(); self:removeImageBackground(); again() end, false, "small", "wand"))
            end
            add(row({ act(_("To front"), function() self:selToFront(); again() end),
                      act("\u{2715} " .. _("Delete"), function() self:closeSelectionMenu(); self:selDelete() end),
                      act(_("Done"), function() self:dropSelection() end, true) }))
        end
        if panel then add(act(_("Back"), function() again() end, true)) end
        return content
    end
    menu = IconMenu:new{
        build = build,
        flash = false,   -- small, and opened often: no flash
        on_uncover = function() self:uncovered() end,
        anchor = function()
            local f = self:selFrame()
            if not f then return nil end
            return { x = f.x0, y = f.y0, w = f.x1 - f.x0, h = f.y1 - f.y0, gap = S(56),
                     top = self.view.area_y }
        end,
        on_close = function()
            if self._sel_dialog ~= menu then return end
            self._sel_dialog = nil
            -- a tap away from the selection drops it; a tap on it keeps it
            local p = menu.tap_pos
            if not (p and self:selHit(p.x, p.y)) then self:dropSelection() end
        end,
    }
    self._sel_dialog = menu
    UIManager:show(menu)
end

------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------

-- A one-pixel line of dots from (x0, y0) to (x1, y1), clipped to the box.
local function line(bb, x0, y0, x1, y1, t, cx0, cy0, cx1, cy1, c)
    local n = math.max(1, math.floor(math.max(math.abs(x1 - x0), math.abs(y1 - y0))))
    for i = 0, n do
        local px = math.floor(x0 + (x1 - x0) * i / n)
        local py = math.floor(y0 + (y1 - y0) * i / n)
        if px >= cx0 and py >= cy0 and px + t <= cx1 and py + t <= cy1 then bb:paintRect(px, py, t, t, c or BLACK) end
    end
end

-- A filled disc of radius r at (x, y), as rows, clipped to the box.
local function disc(bb, x, y, r, c, cx0, cy0, cx1, cy1)
    for dy = -r, r do
        local half = math.floor(math.sqrt(r * r - dy * dy))
        local x0, x1 = math.max(cx0, x - half), math.min(cx1, x + half + 1)
        local py = y + dy
        if py >= cy0 and py < cy1 and x1 > x0 then bb:paintRect(x0, py, x1 - x0, 1, c) end
    end
end

-- The selection over the page: the lifted card while it moves or resizes, the
-- frame (turning with a turn), and the handles when it is still.
function InkAwayView:paintSelection(bb, x, y)
    if not (self.selection and self.selection.bbox) then return end
    local v, d = self.view, self.sel_drag
    local ax0, ay0 = x + v.area_x, y + v.area_y
    local ax1, ay1 = ax0 + v.area_w, ay0 + v.area_h
    local c = self:selDragCorners()
    if not c then return end
    -- black marks, white on a dark paper
    local ink = self:textInk()
    local back = ink == BLACK and WHITE or BLACK
    for i = 1, 8, 2 do c[i], c[i + 1] = c[i] + x, c[i + 1] + y end
    -- the lifted card
    if d and d.began and d.card and d.kind ~= "turn" then
        local b = d.card_box
        local bx0, by0 = InkGeom.toScreen(v, b.x0, b.y0)
        local bx1, by1 = InkGeom.toScreen(v, b.x1, b.y1)
        local w, h, ox, oy = bx1 - bx0, by1 - by0, bx0 + x, by0 + y
        if d.kind == "move" then
            ox, oy = ox + d.x - d.sx, oy + d.y - d.sy
        else
            local sax, say = InkGeom.toScreen(v, d.ax, d.ay)
            ox, oy = sax + x + (ox - x - sax) * d.s, say + y + (oy - y - say) * d.s
            w, h = w * d.s, h * d.s
        end
        local card = self:selCardAt(w, h)
        if card then
            ox, oy = math.floor(ox), math.floor(oy)
            local sx0, sy0 = math.max(ox, ax0), math.max(oy, ay0)
            local sx1 = math.min(ox + card:getWidth(), ax1)
            local sy1 = math.min(oy + card:getHeight(), ay1)
            if sx1 > sx0 and sy1 > sy0 then
                self:blitPanel(bb, card, d.card_rot or 0, sx0, sy0, sx0 - ox, sy0 - oy, sx1 - sx0, sy1 - sy0)
            end
        end
    end
    -- the frame: four bars, or four lines while it turns
    local t = S(2)
    if d and d.began and d.kind == "turn" then
        for i = 1, 8, 2 do
            local j = (i + 2 > 8) and 1 or i + 2
            line(bb, c[i], c[i + 1], c[j], c[j + 1], t, ax0, ay0, ax1, ay1, ink)
        end
    else
        local fx0, fy0 = math.floor(math.min(c[1], c[5])), math.floor(math.min(c[2], c[6]))
        local fx1, fy1 = math.floor(math.max(c[1], c[5])), math.floor(math.max(c[2], c[6]))
        local function bar(bx, by, bw, bh)
            local cx0, cy0 = math.max(bx, ax0), math.max(by, ay0)
            local cx1, cy1 = math.min(bx + bw, ax1), math.min(by + bh, ay1)
            if cx1 > cx0 and cy1 > cy0 then bb:paintRect(cx0, cy0, cx1 - cx0, cy1 - cy0, ink) end
        end
        bar(fx0, fy0, fx1 - fx0 + t, t); bar(fx0, fy1, fx1 - fx0 + t, t)
        bar(fx0, fy0, t, fy1 - fy0 + t); bar(fx1, fy0, t, fy1 - fy0 + t)
    end
    if d and d.began and d.kind == "turn" then
        -- how far it has turned, by the knob
        local deg = math.floor(math.deg(d.a) + 0.5)
        local label = TextWidget:new{ text = string.format("%d\u{00B0}", deg), face = Font:getFace("cfont", 15),
            bold = true, fgcolor = ink }
        local sz = label:getSize()
        local lx = math.floor(d.x + x + S(18))
        local ly = math.floor(d.y + y - sz.h / 2)
        if lx + sz.w <= ax1 and ly >= ay0 and ly + sz.h <= ay1 then
            bb:paintRect(lx - S(4), ly, sz.w + S(8), sz.h, back)
            label:paintTo(bb, lx, ly)
        end
        label:free()
        return
    end
    if d and d.began then return end
    -- handles: squares at the corners, a disc on a stalk for turning
    local hs = S(14)
    for i = 1, 8, 2 do
        local px = math.max(ax0, math.min(ax1 - hs, math.floor(c[i] - hs / 2)))
        local py = math.max(ay0, math.min(ay1 - hs, math.floor(c[i + 1] - hs / 2)))
        bb:paintRect(px, py, hs, hs, ink)
    end
    if self:selCanTurn() then
        local kx, ky, ey = self:selKnob()
        kx, ky, ey = kx + x, ky + y, ey + y
        line(bb, kx, ey, kx, ky, t, ax0, ay0, ax1, ay1, ink)
        disc(bb, kx, ky, S(11), ink, ax0, ay0, ax1, ay1)
        disc(bb, kx, ky, S(6), back, ax0, ay0, ax1, ay1)
    end
end

return InkAwayView
