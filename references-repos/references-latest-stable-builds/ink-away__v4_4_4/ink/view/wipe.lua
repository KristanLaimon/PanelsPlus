--[[
Erase whole strokes: with the setting on, the eraser removes each stroke or shape
it touches instead of rubbing out pixels. One eraser stroke is one undo step.
Part of InkAwayView (see ink/view.lua).
]]

local Canvas = require("ink/canvas")
local InkGeom = require("ink/geom")
local Symmetry = require("ink/symmetry")
local Wipe = require("ink/wipe")

local InkAwayView = {}

-- Start an eraser stroke at screen (sx, sy).
function InkAwayView:wipeBegin(sx, sy)
    local v = self.view
    -- (in a layered drawing only the active layer's strokes can go; text unless
    -- it is protected, pictures with Erase pictures on)
    self._wipe = { boxes = Wipe.boxes(self:editableOps(), v.canvas_w, v.canvas_h,
            { text = not self.text_erase_protect, pictures = self.erase_bg }),
        areas = {}, rows = {}, removed = 0, path = {} }
    self.capturing, self.pending_lift = true, nil
    self:addScreenPoint(sx, sy, true)   -- (the first point, with the eraser's outline)
end

-- Move the eraser to screen (sx, sy), with its mirror copies: remove the lines
-- it meets and note the areas it crosses (see wipeEnd).
function InkAwayView:wipeTo(sx, sy)
    local w, v = self._wipe, self.view
    local cx, cy = self:toCanvasClamped(sx, sy)
    local seg = { w.x or cx, w.y or cy, cx, cy }
    w.x, w.y = cx, cy
    w.path[#w.path + 1], w.path[#w.path + 2] = cx, cy   -- (over a book: the highlights it crossed)
    local r = self.eraser_width / 2
    local ops = self.canvas.ops
    for _, f in ipairs(Symmetry.flips(self.symmetry)) do
        local s = Symmetry.flipPoints(seg, f, v.canvas_w, v.canvas_h)
        local x0, x1 = math.min(s[1], s[3]) - r, math.max(s[1], s[3]) + r
        local y0, y1 = math.min(s[2], s[4]) - r, math.max(s[2], s[4]) + r
        for i = #ops, 1, -1 do
            local b = w.boxes[ops[i]]
            if b and x0 <= b[3] and x1 >= b[1] and y0 <= b[4] and y1 >= b[2] then
                local line, area = Wipe.hits(ops[i], s, r, v.canvas_w, v.canvas_h, w.rows)
                if line then self:wipeRemove(i)
                elseif area then w.areas[ops[i]] = true end
            end
        end
    end
end

-- Remove ops[i] and show the page without it, redrawing only where it was.
function InkAwayView:wipeRemove(i)
    local w = self._wipe
    if w.removed == 0 then self.canvas:pushHistory() end
    local op = table.remove(self.canvas.ops, i)
    w.removed = w.removed + 1
    w.boxes[op], w.areas[op] = nil, nil
    self:markDirty()
    -- its copies can be anywhere on the page; text and pictures also feed the
    -- buffers the eraser reveals, which only a full compose rebuilds
    if (op.sym and op.sym ~= "off") or op.kind == "text" or op.kind == "image" then
        self:recompose()
        return
    end
    local x0, y0, x1, y1 = Canvas.opBox(op)
    self:composeRegion(x0, y0, x1, y1)
    local ax0, ay0 = self:toAreaLocal(x0, y0)
    local ax1, ay1 = self:toAreaLocal(x1, y1)
    self:renderViewRect(ax0 - 1, ay0 - 1, ax1 + 1, ay1 + 1)
    local r = { x0 = ax0, y0 = ay0, x1 = ax1, y1 = ay1 }
    self:liveDirty("ui", r, 1)
    w.flash = InkGeom.growRect(w.flash, r.x0, r.y0, r.x1, r.y1)
end

-- The eraser lifted. Areas go only if no line did, so rubbing out writing on a
-- filled box keeps the box. Then the ghosts of what went are cleaned away (see
-- cleanMode).
function InkAwayView:wipeEnd()
    local w = self._wipe
    if w.removed == 0 then
        local ops = self.canvas.ops
        for i = #ops, 1, -1 do
            if w.areas[ops[i]] then self:wipeRemove(i) end
        end
    end
    self._wipe = nil
    if w.removed == 0 then return end
    self:resetLasso()   -- removing ops moves the indices a selection holds
    if self:colourPanel() then
        self:liveFlush()
    elseif w.flash then
        self:liveDrop()   -- (Android) this covers every rect still pending
        self:dirtyAreaRect(self:cleanMode(), w.flash, 2)
    end
    self:afterCommit()
end

-- A palm began this eraser stroke: put back what it removed (the caller
-- redraws).
function InkAwayView:wipeCancel()
    local w = self._wipe
    self._wipe = nil
    if w and w.removed > 0 then
        self.canvas:undo()
        self.canvas.redo_stack = {}
    end
end

return InkAwayView
