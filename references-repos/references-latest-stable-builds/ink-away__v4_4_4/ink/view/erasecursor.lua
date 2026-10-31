--[[
The eraser's outline under the pen while erasing: a ring at the exact size and
place of what it clears (see ink/ui/eraserring.lua), moved along with every
point and gone at the lift. The pixels under it are kept aside and put back
before the next point is erased, so the ring never touches the drawing itself.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local EraserRing = require("ink/ui/eraserring")

local InkAwayView = {}

-- Put back what the outline covers, if it is shown. Returns its area-local
-- rect { x0, y0, x1, y1 } (for the refresh), or nil.
function InkAwayView:eraserCursorHide()
    local c = self._ecur
    if not c then return nil end
    self._ecur = nil
    -- (a screen rebuilt since then shows no outline: nothing to put back)
    if c.area_bb ~= self.area_bb or not self.area_bb then return nil end
    self.area_bb:blitFrom(self._ecur_under, c.x, c.y, 0, 0, c.w, c.h)
    return { x0 = c.x, y0 = c.y, x1 = c.x + c.w, y1 = c.y + c.h }
end

-- Show the outline around canvas point (cx, cy), in place of the one before
-- (`was`, the rect eraserCursorHide gave back), and refresh both places.
function InkAwayView:eraserCursorShow(cx, cy, was)
    local v, bb = self.view, self.area_bb
    if not (v and bb) then return end
    local ax, ay = self:toAreaLocal(cx, cy)
    local r = self.eraser_width / 2 * v.zoom
    local x, y, w, h = EraserRing.box(ax, ay, r)
    -- (kept to the drawing area, which the buffer is)
    local x1, y1 = math.min(x + w, v.area_w), math.min(y + h, v.area_h)
    x, y = math.max(0, x), math.max(0, y)
    w, h = x1 - x, y1 - y
    local rect = was
    if w > 0 and h > 0 then
        local under = self._ecur_under
        if not under or under:getWidth() < w or under:getHeight() < h or under:getType() ~= bb:getType() then
            -- (grown to the largest size asked for, so a stroke allocates once)
            local nw, nh = w, h
            if under then
                nw, nh = math.max(w, under:getWidth()), math.max(h, under:getHeight())
                under:free()
            end
            under = Blitbuffer.new(nw, nh, bb:getType())
            self._ecur_under = under
        end
        under:blitFrom(bb, 0, 0, x, y, w, h)
        EraserRing.paint(bb, ax, ay, r)
        -- (its box, and its centre and radius in the area)
        self._ecur = { x = x, y = y, w = w, h = h, area_bb = bb, cx = ax, cy = ay, r = r }
        rect = rect and { x0 = math.min(rect.x0, x), y0 = math.min(rect.y0, y),
            x1 = math.max(rect.x1, x + w), y1 = math.max(rect.y1, y + h) }
            or { x0 = x, y0 = y, x1 = x + w, y1 = y + h }
    end
    if rect then self:liveDirty(self._live_mode or "fast", rect, 1) end
end

-- Refresh where the outline was, at once, with whatever live refresh is still
-- waiting (Android paces them): the stroke's clean-up drops the waiting ones,
-- which would leave the ring on the screen.
function InkAwayView:eraserCursorGone(was)
    if not was then return end
    self:liveDirty(self._live_mode or "fast", was, 1)
    self:liveFlush()
end

-- Take the outline away (the eraser lifted, or the stroke ended).
function InkAwayView:eraserCursorOff()
    self:eraserCursorGone(self:eraserCursorHide())
end

-- Free what the outline keeps (Ink Away closing, or memory reclaimed).
function InkAwayView:eraserCursorFree()
    self._ecur = nil
    if self._ecur_under then self._ecur_under:free(); self._ecur_under = nil end
end

return InkAwayView
