--[[
The drawing model: an ordered list of ops over a fixed W x H canvas, the one
source of truth. The screen and the saved image are both made by replaying the
ops in order. A stroke op is:
    { kind = "ink" | "erase", width = <canvas px>, alpha = 0..255,
      color = { r, g, b } or nil (black), style = "solid"|"pencil"|"charcoal"|"marker",
      seed = <int for grain>, pts = { x1,y1, x2,y2, ... } }
Shapes, fills, text and images are ops too. Points are in canvas coordinates, so
a stroke keeps its thickness and position in the export at any zoom. An erase
clears pixels along its path (to transparent in the export, to whatever lies
under the ink on screen).

Undo history holds shallow snapshots (arrays of op references), which is cheap
because appending or deleting never changes an existing op; an edit clones the
op and replaces it (cloneOp, replaceOp), so older snapshots keep the original.
Plain Lua, so the headless tests drive it directly.
]]

local Geom = require("ink/geom")
local Shapes = require("ink/shapes")
local Text = require("ink/text")

local Canvas = {}
Canvas.__index = Canvas

-- Simplification tuning (canvas pixels).
local MIN_SPACING = 1.5   -- drop points closer than this while drawing
local RDP_TOL = 0.75      -- max deviation when collapsing a finished stroke
local HISTORY_MAX = 8     -- undo depth, kept small: each snapshot entry pins a
                          -- whole ops array

function Canvas.new(w, h)
    return setmetatable({
        w = w,
        h = h,
        ops = {},          -- committed strokes
        live = nil,        -- stroke currently being drawn
        undo_stack = {},   -- past ops-list snapshots (shallow)
        redo_stack = {},
        rev = 0,           -- counts every change to the ops, so a save can tell what changed
        layers = nil,      -- a drawing's layers, when it has them (see ink/layers.lua)
        hidden_layers = {},
        lrev = 0,          -- counts changes outside the active layer (the view's
                           -- layer caches are kept while it stays the same)
    }, Canvas)
end

-- (loaded on first use: ink/layers.lua uses this module too)
local Layers
local function layers()
    if not Layers then Layers = require("ink/layers") end
    return Layers
end

-- A shallow snapshot of the current ops list: the ops are shared, only the array
-- is copied (table.move copies in C).
local function snapshot(self)
    return table.move(self.ops, 1, #self.ops, 1, {})
end

-- History entries are one of:
--   { snap = <ops array>, lay = <layer list or false> }
--                           restore this whole list (an edit of existing ops:
--                           colour, size, move, delete, order, clear, load, and
--                           any change to the layers)
--   { add = true, at = n }  an op was added (at position n: the end of its layer
--                           in a layered drawing, else the end); undo drops it
--   { mark = <any> }        a change made outside the ops (the annotation mode's
--                           reader highlights): undo and redo hand it back to
--                           the view to undo or redo
-- Appending is by far the most common action, so a committed stroke costs O(1)
-- history instead of a copy of the whole list, which would make a long drawing
-- slower as it fills.
local function pushEntry(self, entry)
    self.rev = self.rev + 1
    local u = self.undo_stack
    u[#u + 1] = entry
    if #u > HISTORY_MAX then table.remove(u, 1) end
    self.redo_stack = {}
end

-- Snapshot checkpoint: call before an edit that changes existing ops or the
-- layers.
function Canvas:pushHistory()
    pushEntry(self, { snap = snapshot(self), lay = self.layers and layers().copy(self.layers) or false, act = self.active_layer })
end

-- O(1) checkpoint for appending one op to the end of the list. Undo just drops
-- whatever is last, so it does not matter that the op is recorded by position.
function Canvas:recordAppend()
    pushEntry(self, { add = true })
end

-- Put a new op in its place without an undo step of its own, for a change that
-- made one already (pushHistory): at the end, or in a layered drawing at the end
-- of the active layer (on the page, over that layer and under the ones above).
-- Returns the op and its index.
function Canvas:placeOp(op)
    local at = #self.ops + 1
    if self.layers then
        local id = self.active_layer or 1
        local label = (id ~= 1) and id or nil
        if op.layer ~= label then op.layer = label end
        at = layers().insertIndex(self, id)
    elseif op.layer ~= nil then
        op.layer = nil   -- (pasted from a layered drawing into one without)
    end
    table.insert(self.ops, at, op)
    self.rev = self.rev + 1
    self.last_placed = op
    return op, at
end

-- Add a new op where placeOp puts it, as one undo step. Returns the op and its
-- index.
function Canvas:addOp(op)
    local at
    op, at = self:placeOp(op)
    if at < #self.ops then
        pushEntry(self, { add = true, at = at })
    else
        self:recordAppend()
    end
    return op, at
end

-- A change made outside the ops, for the view to undo and redo itself.
function Canvas:pushMark(m)
    pushEntry(self, { mark = m })
end

function Canvas:canUndo() return #self.undo_stack > 0 end
function Canvas:canRedo() return #self.redo_stack > 0 end

-- A copy of an op safe to edit without touching older snapshots.
function Canvas:cloneOp(op)
    local c = {}
    for k, v in pairs(op) do c[k] = v end
    if op.pts then
        local p = {}; for i = 1, #op.pts do p[i] = op.pts[i] end; c.pts = p
    end
    if op.color then c.color = { op.color[1], op.color[2], op.color[3] } end
    if op.fill_color then c.fill_color = { op.fill_color[1], op.fill_color[2], op.fill_color[3] } end
    if op.runs then
        local r = {}; for i = 1, #op.runs do r[i] = op.runs[i] end; c.runs = r
    end
    if op.pr then
        local r = {}; for i = 1, #op.pr do r[i] = op.pr[i] end; c.pr = r
    end
    return c
end

function Canvas:replaceOp(idx, op) self.ops[idx] = op end
function Canvas:removeOp(idx) return table.remove(self.ops, idx) end

function Canvas:isEmpty()
    return #self.ops == 0 and not self.live
end

function Canvas:opCount()
    return #self.ops
end

-- Begin a new stroke. `kind` is "ink" or "erase"; `alpha` (0-255, opaque by
-- default) is the ink opacity, ignored by an erase, which always clears fully;
-- `color` is an optional {r,g,b} (black by default). With `pressured` the stroke
-- keeps a pen pressure (0-255) per point in op.pr.
function Canvas:startStroke(kind, width, alpha, color, style, seed, pressured)
    self.live = { kind = kind, width = width, alpha = alpha or 255, color = color,
                  style = style, seed = seed, pts = {}, pr = pressured and {} or nil }
end

-- Add a raw point, in canvas coordinates, to the live stroke, with its pressure
-- `p` (0-255) on a pressured stroke. A repeated point is not added again; it only
-- takes the newer pressure, as a pen pressed harder in place.
function Canvas:addPoint(cx, cy, p)
    local live = self.live
    if not live then return end
    local pts, pr = live.pts, live.pr
    local n = #pts
    if n >= 2 and pts[n - 1] == cx and pts[n] == cy then
        if pr and p then pr[#pr] = p end
        return
    end
    pts[n + 1] = cx
    pts[n + 2] = cy
    if pr then pr[#pr + 1] = p or 255 end
end

-- Finish the live stroke, simplify it and commit it. Returns the committed op,
-- or nil if the stroke had no points.
function Canvas:finishStroke()
    local live = self.live
    self.live = nil
    if not live or #live.pts == 0 then return nil end
    -- a smudge keeps its points as drawn: replaying it must retrace the live
    -- stroke exactly (see ink/smudge.lua)
    if live.kind ~= "smudge" then
        local pts, pr = Geom.dropClose(live.pts, MIN_SPACING, live.pr)
        -- a pressure step of 255 can change the radius by up to half the width
        pts, pr = Geom.rdp(pts, RDP_TOL, pr, (live.width or 1) * 0.5 / 255)
        live.pts, live.pr = pts, pr
    end
    self:addOp(live)
    return live
end

function Canvas:cancelStroke()
    self.live = nil
end

-- Commit a shape as one op (shapes are placed whole, not point by point).
-- `pts` is { x0,y0, x1,y1 [, cx,cy] } in canvas coordinates. Returns the op.
function Canvas:addShape(shape, fill, pts, width, alpha, color)
    local op = {
        kind = "shape", shape = shape, fill = fill and true or false,
        width = width, alpha = alpha or 255, color = color, pts = pts,
    }
    return (self:addOp(op))
end

-- Commit a flood fill as one op. `runs` is a flat { x,y,len, ... } run list.
function Canvas:addFillOp(runs, color, alpha)
    local op = { kind = "fill", runs = runs, color = color, alpha = alpha or 255 }
    return (self:addOp(op))
end

-- Undo and redo step through the history. An `add` entry drops (undo) or
-- re-appends (redo) the single op; a `snap` entry swaps the whole ops list.
-- Returns true if it moved.
function Canvas:undo()
    local entry = table.remove(self.undo_stack)
    if not entry then return false end
    self.rev = self.rev + 1
    if entry.mark ~= nil then
        self.redo_stack[#self.redo_stack + 1] = entry
        return true, entry.mark
    elseif entry.snap ~= nil then
        self.redo_stack[#self.redo_stack + 1] = { snap = snapshot(self), lay = self.layers and layers().copy(self.layers) or false, act = self.active_layer }
        self.ops = entry.snap
        self:restoreLayers(entry.lay, entry.act)
        self.lrev = (self.lrev or 0) + 1
    else   -- an added op: drop it, remember it so redo can add it again
        local op = table.remove(self.ops, entry.at or #self.ops)
        self.redo_stack[#self.redo_stack + 1] = { readd = op, at = entry.at }
        if self.layers and op and (op.layer or 1) ~= self.active_layer then self.lrev = (self.lrev or 0) + 1 end
    end
    self.live = nil
    return true
end

-- The layer list and active layer of a history entry put back (false: no
-- layers).
function Canvas:restoreLayers(lay, act)
    if lay == nil then return end
    self.layers = lay or nil
    if act ~= nil then self.active_layer = act end
    layers().fix(self)
end

function Canvas:redo()
    local entry = table.remove(self.redo_stack)
    if not entry then return false end
    self.rev = self.rev + 1
    if entry.mark ~= nil then
        self.undo_stack[#self.undo_stack + 1] = entry
        return true, entry.mark
    elseif entry.snap ~= nil then
        self.undo_stack[#self.undo_stack + 1] = { snap = snapshot(self), lay = self.layers and layers().copy(self.layers) or false, act = self.active_layer }
        self.ops = entry.snap
        self:restoreLayers(entry.lay, entry.act)
        self.lrev = (self.lrev or 0) + 1
    else   -- add again the op an undo removed, where it was
        table.insert(self.ops, entry.at or (#self.ops + 1), entry.readd)
        self.undo_stack[#self.undo_stack + 1] = { add = true, at = entry.at }
        local op = entry.readd
        if self.layers and op and (op.layer or 1) ~= self.active_layer then self.lrev = (self.lrev or 0) + 1 end
    end
    self.live = nil
    return true
end

function Canvas:clear()
    self:pushHistory()
    self.ops = {}
    self.live = nil
end

-- Replace all ops (used when loading a project). Clears history, and the
-- layers (a layered drawing sets them again: see Layers.load).
function Canvas:setOps(ops)
    self.rev = self.rev + 1
    self.ops = ops or {}
    self.live = nil
    self.undo_stack = {}
    self.redo_stack = {}
    self.layers, self.active_layer, self.hidden_layers = nil, nil, {}
    self.lrev = (self.lrev or 0) + 1
end

-- Which kinds of visible op a list holds: erases (soft_erase and hard_erase,
-- split by op.ebg, and spare_text for text-protecting ones), text and image.
function Canvas.scanOps(ops)
    local f = {}
    for _, op in ipairs(ops) do
        if not op.hidden then
            local kind = op.kind
            if kind == "erase" then
                f.erase = true
                if op.ebg then f.hard_erase = true else f.soft_erase = true end
                if op.spare_text then f.spare_text = true end
            elseif kind == "text" then
                f.text = true
            elseif kind == "image" then
                f.image = true
            elseif kind == "smudge" then
                f.smudge = true
            end
        end
    end
    return f
end

-- Bounding rect {x,y,w,h} of an op in canvas coordinates, padded by half its
-- width and a pixel, so the whole stamped disc is covered. nil for an empty op.
function Canvas:opRect(op, extra)
    local x0, y0, x1, y1 = Geom.bounds(op.pts)
    if not x0 then return nil end
    local pad = op.width / 2 + 1 + (extra or 0)
    return {
        x = x0 - pad,
        y = y0 - pad,
        w = (x1 - x0) + 2 * pad,
        h = (y1 - y0) + 2 * pad,
    }
end

-- The box x0, y0, x1, y1 (canvas px) around everything an op draws, before any
-- symmetry copies, or nil when it draws nothing (or is text not laid out yet).
function Canvas.opBox(op)
    local k = op.kind
    if k == "link" then
        return op.x, op.y, op.x + (op.w or 0), op.y + (op.h or 0)
    elseif k == "text" then
        return Text.bounds(op)   -- nil before it is laid out; turned with it
    elseif k == "image" then
        -- a turned picture stays inside the circle around its box
        local h = math.sqrt(op.w * op.w + op.h * op.h) / 2 + 1
        local cx, cy = op.x + op.w / 2, op.y + op.h / 2
        return cx - h, cy - h, cx + h, cy + h
    elseif k == "fill" then
        local r = op.runs
        if not r or #r < 3 then return nil end
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for i = 1, #r - 2, 3 do
            x0, x1 = math.min(x0, r[i]), math.max(x1, r[i] + r[i + 2])
            y0, y1 = math.min(y0, r[i + 1]), math.max(y1, r[i + 1] + 1)
        end
        return x0, y0, x1, y1
    end
    if not op.pts or #op.pts < 2 or (k == "shape" and #op.pts < 4) then return nil end
    local x0, y0, x1, y1
    if k == "shape" then x0, y0, x1, y1 = Shapes.bounds(op) else x0, y0, x1, y1 = Geom.bounds(op.pts) end
    local pad = (op.width or 1) * 0.75 + 2   -- half the width, and room for a brush's grain
    return x0 - pad, y0 - pad, x1 + pad, y1 + pad
end

-- Average point of an op's geometry (canvas coords), or nil if it has none.
local function opCentroid(op)
    local sx, sy, n = 0, 0, 0
    if op.pts then
        for i = 1, #op.pts, 2 do sx = sx + op.pts[i]; sy = sy + op.pts[i + 1]; n = n + 1 end
    elseif op.runs then
        for i = 1, #op.runs, 3 do sx = sx + op.runs[i]; sy = sy + op.runs[i + 1]; n = n + 1 end
    end
    if n == 0 then return nil end
    return sx / n, sy / n
end

-- Is an op picked by a lasso loop (canvas coords)? A point counts as inside when
-- the loop goes round it (by winding, so a loop that overlaps its own start
-- still holds what it wraps twice) or lies within `slop` of the loop's line, so
-- writing the lasso grazes is still taken. The op is picked when a good share
-- of its points are inside (sampled, so a dense stroke stays cheap), or its
-- centre is (a big shape looped around its middle); a shape by its outline. A
-- text box or a picture, which have no points, are picked by a grid over their
-- box.
local function opInPoly(op, poly, slop)
    -- a shape is judged by its outline as drawn (its defining points can lie
    -- off it: an ellipse's box corners, a turned rectangle's unturned ones)
    if op.kind == "shape" and op.pts and #op.pts >= 4 then
        op = { pts = (Shapes.outline(op)) }
    end
    local d2 = (slop or 0) * (slop or 0)
    local function inside(x, y)
        return Geom.windingInPoly(x, y, poly) or (d2 > 0 and Geom.nearPath(x, y, poly, d2))
    end
    if not (op.pts or op.runs) then
        local x0, y0, x1, y1 = Canvas.opBox(op)
        if not x0 then return false end
        local hit = 0
        for gy = 0, 2 do
            for gx = 0, 2 do
                if inside(x0 + (x1 - x0) * (gx + 0.5) / 3, y0 + (y1 - y0) * (gy + 0.5) / 3) then hit = hit + 1 end
            end
        end
        return hit >= 5
    end
    local n_in, total = 0, 0
    local function sample(x, y)
        total = total + 1
        if inside(x, y) then n_in = n_in + 1 end
    end
    if op.pts then
        local pairs_n = #op.pts / 2
        local step = math.max(1, math.floor(pairs_n / 48))   -- <= ~48 samples
        for p = 0, pairs_n - 1, step do
            local i = p * 2 + 1
            sample(op.pts[i], op.pts[i + 1])
        end
    elseif op.runs then
        local triples = #op.runs / 3
        local step = math.max(1, math.floor(triples / 48))
        for t = 0, triples - 1, step do
            local i = t * 3 + 1
            sample(op.runs[i], op.runs[i + 1])
        end
    end
    if total == 0 then return false end
    if n_in / total >= 0.3 then return true end             -- a good chunk is inside
    local cx, cy = opCentroid(op)
    if cx and Geom.windingInPoly(cx, cy, poly) then return true end   -- centre of mass is inside
    -- bounding-box centre is inside (stable for long strokes)
    local x0, y0, x1, y1
    local function ext(x, y)
        if not x0 or x < x0 then x0 = x end
        if not y0 or y < y0 then y0 = y end
        if not x1 or x > x1 then x1 = x end
        if not y1 or y > y1 then y1 = y end
    end
    if op.pts then for i = 1, #op.pts, 2 do ext(op.pts[i], op.pts[i + 1]) end
    elseif op.runs then for i = 1, #op.runs, 3 do ext(op.runs[i], op.runs[i + 1]) end end
    if x0 then return Geom.windingInPoly((x0 + x1) / 2, (y0 + y1) / 2, poly) end
    return false
end

local function accumBounds(op, x0, y0, x1, y1)
    local function acc(x, y)
        if not x0 or x < x0 then x0 = x end
        if not y0 or y < y0 then y0 = y end
        if not x1 or x > x1 then x1 = x end
        if not y1 or y > y1 then y1 = y end
    end
    if op.pts then for i = 1, #op.pts, 2 do acc(op.pts[i], op.pts[i + 1]) end end
    if op.runs then for i = 1, #op.runs, 3 do acc(op.runs[i], op.runs[i + 1]); acc(op.runs[i] + op.runs[i + 2], op.runs[i + 1]) end end
    if not (op.pts or op.runs) and (op.kind == "text" or op.kind == "image") then   -- by their box
        local bx0, by0, bx1, by1 = Canvas.opBox(op)
        if bx0 then acc(bx0, by0); acc(bx1, by1) end
    end
    return x0, y0, x1, y1
end

-- Shift every coordinate of an op by (dx, dy) canvas pixels, in place.
local function translateOp(op, dx, dy)
    if op.pts then for i = 1, #op.pts, 2 do op.pts[i] = op.pts[i] + dx; op.pts[i + 1] = op.pts[i + 1] + dy end end
    if op.runs then for i = 1, #op.runs, 3 do op.runs[i] = op.runs[i] + dx; op.runs[i + 1] = op.runs[i + 1] + dy end end
    if op.x then op.x, op.y = op.x + dx, op.y + dy end   -- an image or a text box
end

Canvas.opInPoly = opInPoly
Canvas.accumBounds = accumBounds
Canvas.translateOp = translateOp

return Canvas
