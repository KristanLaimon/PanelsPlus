--[[
Drawing a see-through pen live (Highlighter, Marker, Watercolor; see
ink/wash.lua). Blending each new piece of the stroke onto the page would darken
it wherever the stroke overlaps itself, so a wash stroke keeps:
  * a mask of the whole stroke so far, the larger value winning, and
  * a copy of the page as it was under the stroke, taken tile by tile the first
    time the stroke reaches a tile.
Each new point stamps its segment into the mask, puts back the page under that
segment's box from the copy, and blends the mask over the box again. At the lift
the stroke is drawn again from the saved op (see finalizeStroke), so the screen
always matches thumbnails and exports.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Raster = require("ink/raster")
local Symmetry = require("ink/symmetry")
local Wash = require("ink/wash")

local InkAwayView = {}

local TILE = 64

-- Start a wash stroke for style `st`; the pen's colour, opacity and width are
-- those of the live op.
function InkAwayView:washBegin(st)
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    if not self.canvas_bb then return end
    local m = self._wash_live_mask
    if not (m and m.w == W and m.h == H) then
        m = Wash.newMask(W, H, 0, 0)
        self._wash_live_mask = m
    end
    local under = self._wash_under
    if not (under and under:getWidth() == W and under:getHeight() == H
            and under:getType() == self.canvas_bb:getType()) then
        if under then under:free() end
        under = Blitbuffer.new(W, H, self.canvas_bb:getType())
        self._wash_under = under
    end
    local live = self.canvas.live
    self._wl = {
        st = st, mask = m, under = under, tiles = {},
        op = live,                  -- colour, opacity, width, seed and symmetry
        box = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge },
    }
end

-- Copy the tiles of the page under canvas rect r into the "under" copy, the
-- first time the stroke reaches each.
local function ensureUnder(wl, src, r)
    local tiles, under = wl.tiles, wl.under
    local W, H = src:getWidth(), src:getHeight()
    for ty = math.floor(r.y0 / TILE), math.floor((r.y1 - 1) / TILE) do
        for tx = math.floor(r.x0 / TILE), math.floor((r.x1 - 1) / TILE) do
            local k = ty * 100000 + tx
            if not tiles[k] then
                tiles[k] = true
                local x, y = tx * TILE, ty * TILE
                under:blitFrom(src, x, y, x, y, math.min(TILE, W - x), math.min(TILE, H - y))
            end
        end
    end
end

-- One point of a wash stroke, at canvas (cx, cy) with pressure p.
function InkAwayView:washPoint(cx, cy, fresh, p)
    local wl = self._wl
    if not (wl and self.canvas_bb) then return end
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    local op, st = wl.op, wl.st
    local r = (op.width or 1) / 2
    local seg, pr
    if self.last_cx and not fresh then
        seg = { self.last_cx, self.last_cy, cx, cy }
        pr = p and { self._live_p or p, p } or nil
    else
        seg = { cx, cy }
        pr = p and { p } or nil
    end
    self.last_cx, self.last_cy = cx, cy
    self._live_p = p
    Wash.unmark(wl.mask)
    Wash.stamp(wl.mask, st, seg, pr, r, Wash.strength(op, st), op.sym, W, H)
    -- what changed: only the pixels this piece raised are drawn again and
    -- refreshed, a sliver at the front of a wide stroke rather than a box round
    -- the whole tip, so the panel has less to redraw per piece and the stroke
    -- keeps closer to the pen. A symmetric stroke takes the segment's box and its
    -- mirror images.
    local base
    if not op.sym or op.sym == "off" then
        local mx0, my0, mx1, my1 = Wash.marked(wl.mask)
        if not mx0 then return end   -- nothing new under the pen
        base = { x0 = math.max(0, mx0), y0 = math.max(0, my0), x1 = math.min(W, mx1 + 1), y1 = math.min(H, my1 + 1) }
    else
        local pad = math.ceil(r) + 2
        local x0, y0 = math.min(seg[1], seg[#seg - 1]) - pad, math.min(seg[2], seg[#seg]) - pad
        local x1, y1 = math.max(seg[1], seg[#seg - 1]) + pad, math.max(seg[2], seg[#seg]) + pad
        base = { x0 = math.max(0, math.floor(x0)), y0 = math.max(0, math.floor(y0)),
                 x1 = math.min(W, math.ceil(x1)), y1 = math.min(H, math.ceil(y1)) }
    end
    if base.x1 <= base.x0 or base.y1 <= base.y0 then return end
    local rects, nr = Symmetry.mirrorRects(base, op.sym, W, H)
    local cacc = self._lw_cacc
    for i = 1, nr do
        local rr = rects[i]
        rr.x0, rr.y0 = math.max(0, rr.x0), math.max(0, rr.y0)
        rr.x1, rr.y1 = math.min(W, rr.x1), math.min(H, rr.y1)
        if rr.x1 > rr.x0 and rr.y1 > rr.y0 then
            ensureUnder(wl, self.canvas_bb, rr)
            local w, h = rr.x1 - rr.x0, rr.y1 - rr.y0
            self.canvas_bb:blitFrom(wl.under, rr.x0, rr.y0, rr.x0, rr.y0, w, h)
            Wash.blendBB(self.canvas_bb, wl.mask, self:shownWash(op), st, rr.x0, rr.y0, rr.x1, rr.y1)
            self:layerCover(rr.x0, rr.y0, rr.x1, rr.y1)   -- other layers above stay on top
            self:markCanvasDirty(rr.x0, rr.y0, rr.x1, rr.y1)
            local b = wl.box
            b.x0, b.y0 = math.min(b.x0, rr.x0), math.min(b.y0, rr.y0)
            b.x1, b.y1 = math.max(b.x1, rr.x1), math.max(b.y1, rr.y1)
            if cacc then
                cacc.x0, cacc.y0 = math.min(cacc.x0, rr.x0), math.min(cacc.y0, rr.y0)
                cacc.x1, cacc.y1 = math.max(cacc.x1, rr.x1), math.max(cacc.y1, rr.y1)
            end
            -- show it: the screen's rect from the master
            local ax0, ay0 = self:toAreaLocal(rr.x0, rr.y0)
            local ax1, ay1 = self:toAreaLocal(rr.x1, rr.y1)
            local ar = { x0 = math.min(ax0, ax1) - 1, y0 = math.min(ay0, ay1) - 1,
                         x1 = math.max(ax0, ax1) + 1, y1 = math.max(ay0, ay1) + 1 }
            self:renderViewRect(ar.x0, ar.y0, ar.x1, ar.y1)
            self._stroke_rect = self._stroke_rect and {
                x0 = math.min(self._stroke_rect.x0, ar.x0), y0 = math.min(self._stroke_rect.y0, ar.y0),
                x1 = math.max(self._stroke_rect.x1, ar.x1), y1 = math.max(self._stroke_rect.y1, ar.y1) } or ar
            self:liveDirty(self._live_mode or "ui", ar, 1)
        end
    end
end

-- End (or drop) the wash stroke: clear what the mask holds, forget the tiles.
function InkAwayView:washEnd()
    local wl = self._wl
    self._wl = nil
    if not wl then return end
    local b = wl.box
    if b.x1 > b.x0 then Wash.clearMask(wl.mask, b.x0, b.y0, b.x1, b.y1) end
end

-- Let go of the wash buffers (closing, or memory pressure).
function InkAwayView:washFree()
    self._wl = nil
    self._wash_live_mask = nil
    if self._wash_under then self._wash_under:free(); self._wash_under = nil end
    Wash.clearCache()
end

-- Is the pen being set up a see-through one? Its style, or nil.
function InkAwayView:washStyle(style)
    local st = style and Raster.STYLES[style]
    return st and st.engine == "wash" and st or nil
end

return InkAwayView
