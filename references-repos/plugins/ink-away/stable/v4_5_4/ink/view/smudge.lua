--[[
Smudging live (see ink/smudge.lua). The brush works straight on the master as
the pen moves, through the same function the replay uses, so what shows is what
thumbnails and exports will show; only the touched rects are drawn again on
screen. The page without ink (paper, ruling, background, pictures, text) is
built once at the start of each smudge stroke.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Smudge = require("ink/smudge")
local Symmetry = require("ink/symmetry")

local InkAwayView = {}

function InkAwayView:smudgeBegin()
    if not self.canvas_bb then return end
    local surf = Smudge.surfaceOf(self.canvas_bb)
    if not surf then return end   -- an unusual screen type: the smudge only shows on the replay
    local W, H = self.view.canvas_w, self.view.canvas_h
    -- the page without ink: what composeCanvas starts from, with pictures and text
    local base = Blitbuffer.new(W, H, self.canvas_bb:getType())
    local page = (self.notebook and self._paper_bb) or self.bg_bb or self:plainPaperBB()
    if page then
        base:blitFrom(page, 0, 0, 0, 0, W, H)
    else
        base:fill(Blitbuffer.COLOR_WHITE)
    end
    self:stampOps(base, self:drawnOps(), "image")
    self:stampOps(base, self:drawnOps(), "text")
    local live = self.canvas.live
    local r = math.max(1, (live.width or 1) / 2)
    local states = {}
    for i, f in ipairs(Symmetry.flips(live.sym)) do states[i] = { flip = f, st = Smudge.newState(r) } end
    self._sm = { base = base, surf = surf, bsurf = Smudge.surfaceOf(base), states = states, r = r,
                 k = live.alpha or 255, W = W, H = H }
end

-- One point of a smudge stroke at canvas (cx, cy).
function InkAwayView:smudgePoint(cx, cy, fresh)
    local sm = self._sm
    if not sm then return end
    local px, py = self.last_cx, self.last_cy
    if fresh then px, py = nil, nil end
    self.last_cx, self.last_cy = cx, cy
    local W, H = sm.W, sm.H
    for _i, s in ipairs(sm.states) do
        local f = s.flip
        local function fx(x) return (x and f % 2 == 1) and (W - 1 - x) or x end
        local function fy(y) return (y and f >= 2) and (H - 1 - y) or y end
        Smudge.segment(s.st, sm.surf, sm.bsurf, fx(px), fy(py), fx(cx), fy(cy), sm.k)
        local r = Smudge.rect(fx(px), fy(py), fx(cx), fy(cy), sm.r)
        r.x0, r.y0 = math.max(0, r.x0), math.max(0, r.y0)
        r.x1, r.y1 = math.min(W, r.x1), math.min(H, r.y1)
        if r.x1 > r.x0 and r.y1 > r.y0 then
            self:layerCover(r.x0, r.y0, r.x1, r.y1)   -- other layers above stay on top
            self:markCanvasDirty(r.x0, r.y0, r.x1, r.y1)
            local ax0, ay0 = self:toAreaLocal(r.x0, r.y0)
            local ax1, ay1 = self:toAreaLocal(r.x1, r.y1)
            local ar = { x0 = math.min(ax0, ax1) - 1, y0 = math.min(ay0, ay1) - 1,
                         x1 = math.max(ax0, ax1) + 1, y1 = math.max(ay0, ay1) + 1 }
            self:renderViewRect(ar.x0, ar.y0, ar.x1, ar.y1)
            local sr = self._stroke_rect
            self._stroke_rect = sr and { x0 = math.min(sr.x0, ar.x0), y0 = math.min(sr.y0, ar.y0),
                x1 = math.max(sr.x1, ar.x1), y1 = math.max(sr.y1, ar.y1) } or ar
            self:liveDirty(self._live_mode or "ui", ar, 1)
        end
    end
end

function InkAwayView:smudgeEnd()
    local sm = self._sm
    self._sm = nil
    if sm and sm.base then sm.base:free() end
end

return InkAwayView
