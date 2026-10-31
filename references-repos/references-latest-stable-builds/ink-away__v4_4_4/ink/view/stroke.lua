--[[
Freehand pen and eraser strokes, from touch-down to commit: live stamping into the
master and the on-screen buffer, rejoining a dropped contact, and hold to
straighten.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")
local Pens = require("ink/pens")
local Raster = require("ink/raster")
local Recognize = require("ink/recognize")
local Symmetry = require("ink/symmetry")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local displayColor = Paint.displayColor
local spanWriter = Paint.spanWriter
local bgSpanWriter = Paint.bgSpanWriter


-- After a lift, wait this long before committing the stroke; a touch that lands
-- nearby in the meantime continues it. Panels often drop and reacquire a finger
-- mid-line, and this keeps one lift as one stroke and one undo step, with no gap.
local COALESCE_SEC = 0.15

local GC_HEAL_KB = 48 * 1024        -- ~48 MB: far above any legitimate drawing
local GC_HEAL_EVERY = 96            -- check at most once per this many commits

local InkAwayView = {}

------------------------------------------------------------------------------
-- Drawing a stroke
------------------------------------------------------------------------------

-- Current live ink colour and width, from the active tool.
function InkAwayView:liveColor()
    if self.tool == "erase" then return WHITE end
    return displayColor(self:shownInk(self.pen_color, self:paperRGB()), self.pen_alpha)
end
function InkAwayView:liveWidth()
    return (self.tool == "erase") and self.eraser_width or self.pen_width
end

-- Build the stroke's writers once, in beginStroke. Colour, width, brush and
-- symmetry are fixed for the whole stroke, so the per-point path (stampLive)
-- allocates almost nothing; building them per point made fast symmetric drawing
-- stutter under garbage collection.
function InkAwayView:setupLiveWriters()
    local color = self:liveColor()
    local style = (self.tool ~= "erase") and self.pen_style or nil
    local st = style and Raster.STYLES[style]
    local textured = st and not st.solid
    local seed = self.live_seed or 0
    if st and (st.engine or (st.pressure and self._live_pressured)) then
        -- a pen whose width changes: each segment with its two pressures
        local nib = st.engine == "nib" and Pens.nibAngle(self.pen_nib) or nil
        self._lw_stroke = function(seg, r, put, p0, p1, t0, t1)
            Pens.segment(st, seg, r, p0, p1, put, seed, t0, t1, nib)
        end
    else
        self._lw_stroke = function(seg, r, put)
            if textured then Raster.pathTex(seg, r, put, st, seed) else Raster.path(seg, r, put) end
        end
    end
    -- the buffers these writers target, so stampLive can rebuild them if a relayout
    -- reallocated one mid-stroke (rather than draw into a freed buffer)
    self._lw_area_bb, self._lw_canvas_bb = self.area_bb, self.canvas_bb
    self._lw_acc = self._lw_acc or { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
    -- canvas bbox of everything the stroke writes into the master, so the mirror
    -- (see display.lua) is resynced over just that rect when it ends
    self._lw_cacc = self._lw_cacc or { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    -- reused segment tables (master and screen); Raster reads them synchronously
    self._lw_seg_c = self._lw_seg_c or { 0, 0, 0, 0 }
    self._lw_seg_a = self._lw_seg_a or { 0, 0, 0, 0 }
    local sym = self.symmetry
    -- On a colour panel live ink uses the fast waveform (the colour one blocks on
    -- each sample there). Ink is drawn in its own colour at once ("Colour while
    -- drawing"); the fast waveform shows it roughly on colour e-ink, and one
    -- refresh settles the true colour once the pen rests. With that setting off
    -- the screen copy of a non-black pen is drawn in the page's ink (black, white
    -- on a dark paper), which that waveform shows sharply, and its colour comes
    -- back on lift. The master always keeps it. A grey pen (or black at a lowered
    -- opacity) draws that copy on e-ink even with the setting on, as a grey has
    -- no colour to show and the fast waveform would show a light one as white;
    -- so does a grey Boox or Elipsa that Ink Away drives (see fastLive).
    local area_color = color
    self._live_preview = false
    local grey = not Paint.isChromatic(color) and not self:instantColour()
    local preview = self:colourPanel() and (not self.live_colour or grey)
        or (not self:colourPanel() and (self:einkDriven() or self:elipsaDriven()))
    if preview and self.tool ~= "erase" and self._live_mode == "fast" and not self:pureBlackPen() then
        area_color, self._live_preview = Paint.inkOn(self:paperRGB()), true
    end
    -- master (1:1) writer
    local v = self.view
    local cput = spanWriter(self.canvas_bb, v.canvas_w, v.canvas_h, color, self._lw_cacc)
    if sym and sym ~= "off" then
        local crefx, crefy = Symmetry.canvasRefs(v.canvas_w, v.canvas_h)
        cput = Symmetry.wrap(cput, sym, crefx, crefy)
    end
    self._lw_cput = cput
    -- On-screen writer: the base image grows _lw_acc, the mirror images go through
    -- a writer that does not, so the refresh stays a few small rects.
    local aput = spanWriter(self.area_bb, v.area_w, v.area_h, area_color, self._lw_acc)
    if sym and sym ~= "off" then
        local arefx, arefy = Symmetry.areaRefs(v)
        aput = Symmetry.wrap(aput, sym, arefx, arefy,
            spanWriter(self.area_bb, v.area_w, v.area_h, area_color, nil))
    end
    self._lw_aput = aput
end

-- The eraser over something to reveal (a background, images, notebook paper):
-- restore those pixels along the path in the master, then re-render the touched
-- rects on screen, so ink goes and the picture underneath shows through.
function InkAwayView:stampEraseRestore(cx, cy, fresh, reveal)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local r = self.eraser_width / 2
    local px, py = self.last_cx, self.last_cy
    local cacc = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    local put = bgSpanWriter(self.canvas_bb, reveal or self:eraseRevealBB(), W, H, cacc)
    if self.symmetry ~= "off" then
        local rx, ry = Symmetry.canvasRefs(W, H)
        put = Symmetry.wrap(put, self.symmetry, rx, ry)
    end
    if px and not fresh then
        Raster.path({ px, py, cx, cy }, r, put)
    else
        Raster.path({ cx, cy }, r, put)
    end
    -- sync the mirror over the restored region before renderViewRect reads it
    self:markCanvasDirtyAcc(cacc)
    self.last_cx, self.last_cy = cx, cy
    local zr = r * self.view.zoom + 2
    local ax0, ay0 = self:toAreaLocal(px or cx, py or cy)
    local ax1, ay1 = self:toAreaLocal(cx, cy)
    local acc = {
        x0 = math.min(ax0, ax1) - zr, y0 = math.min(ay0, ay1) - zr,
        x1 = math.max(ax0, ax1) + zr, y1 = math.max(ay0, ay1) + zr,
    }
    self._stroke_rect = InkGeom.growRect(self._stroke_rect, acc.x0, acc.y0, acc.x1, acc.y1)
    -- re-render only the touched rects (base and mirrors) from the master
    local rects, nr = self:symAreaRects(acc)
    for i = 1, nr do
        local rr = rects[i]
        self:renderViewRect(rr.x0, rr.y0, rr.x1, rr.y1)
        self:liveDirty(self._live_mode or "fast", rr, 1)
    end
end

-- Stamp the live segment ending at canvas point (cx, cy) into the master (1:1,
-- so a later re-render is right) and into the on-screen buffer at the current
-- zoom (so drawing is immediate), refreshing only what changed. `fresh` starts a
-- new segment with no line back.
function InkAwayView:stampLive(cx, cy, fresh, p)
    if self.tool == "erase" then
        -- a soft erase reveals the page; a hard erase the bare paper (in a notebook
        -- with its ruling, so the ruling can never be rubbed out), or white
        local reveal
        if self.erase_bg and not self.canvas.layers then reveal = self:barePaperBB()
        else reveal = self:eraseRevealBB() end
        if reveal then return self:stampEraseRestore(cx, cy, fresh, reveal) end
    end
    -- a see-through pen blends its whole stroke so far (see view/wash.lua), and
    -- the smudge moves the ink under it (view/smudge.lua)
    if self._wl then return self:washPoint(cx, cy, fresh, p) end
    if self._sm then return self:smudgePoint(cx, cy, fresh) end
    -- rebuild the writers if they are missing or a buffer was reallocated
    if not self._lw_stroke or self._lw_area_bb ~= self.area_bb
            or self._lw_canvas_bb ~= self.canvas_bb then
        self:setupLiveWriters()
    end
    local width = self:liveWidth()
    local strokeFn = self._lw_stroke
    local p0 = (not fresh) and self._live_p or nil
    -- how far along the stroke this piece is, in widths (a tapered pen thins at
    -- its start)
    local t0 = (not fresh) and self._live_t or 0
    local t1 = t0
    if self.last_cx and not fresh then
        local dx, dy = cx - self.last_cx, cy - self.last_cy
        t1 = t0 + math.sqrt(dx * dx + dy * dy) / math.max(1, width)
    end
    self._live_t = t1

    -- master, at 1:1
    if self.canvas_bb then
        local lx, ly = cx, cy
        if self.last_cx and not fresh then
            lx, ly = self.last_cx, self.last_cy
            local seg = self._lw_seg_c
            seg[1], seg[2], seg[3], seg[4] = self.last_cx, self.last_cy, cx, cy
            strokeFn(seg, width / 2, self._lw_cput, p0, p, t0, t1)
        else
            strokeFn({ cx, cy }, width / 2, self._lw_cput, p, p, t0, t0)
        end
        self.last_cx, self.last_cy = cx, cy
        -- on a layer under others: they stay over it (see view/layers.lua)
        if self._lay_over then
            local pad = width / 2 + 2
            self:layerCover(math.min(lx, cx) - pad, math.min(ly, cy) - pad,
                math.max(lx, cx) + pad, math.max(ly, cy) + pad, self.symmetry)
        end
    end

    -- on screen, at the current zoom; acc tracks the base image only (see
    -- setupLiveWriters) and is reset for each point
    local ax, ay = self:toAreaLocal(cx, cy)
    local acc = self._lw_acc
    acc.x0, acc.y0, acc.x1, acc.y1 = math.huge, math.huge, -math.huge, -math.huge
    if self.last_ax and not fresh then
        local seg = self._lw_seg_a
        seg[1], seg[2], seg[3], seg[4] = self.last_ax, self.last_ay, ax, ay
        strokeFn(seg, (width * self.view.zoom) / 2, self._lw_aput, p0, p, t0, t1)
    else
        strokeFn({ ax, ay }, (width * self.view.zoom) / 2, self._lw_aput, p, p, t0, t0)
    end
    self.last_ax, self.last_ay = ax, ay
    self._live_p = p
    if acc.x1 >= acc.x0 then
        -- grow the whole stroke's base rect for the refresh at the end
        self._stroke_rect = InkGeom.growRect(self._stroke_rect, acc.x0, acc.y0, acc.x1, acc.y1)
        local rects, nr = self:symAreaRects(acc)
        for i = 1, nr do
            -- (under other layers: the screen's rect from the master, which has them on top)
            if self._lay_over then
                local rr = rects[i]
                self:renderViewRect(rr.x0 - 1, rr.y0 - 1, rr.x1 + 1, rr.y1 + 1)
            end
            self:liveDirty(self._live_mode or "fast", rects[i], 1)
        end
    end
end

-- Add a screen point to the live stroke (kept in canvas coords) and draw it.
-- The stabilizer pulls the point towards the previous one, turning wobble into a
-- clean line; strength 0 draws the raw point. The `lift` point is taken as it
-- is: the smoothed line trails the pen, and would otherwise stop short of where
-- the pen left (a quick highlighter stroke missed the last word).
-- The eraser's outline (view/erasecursor.lua) comes off before each point is
-- erased and back on after it, where the eraser now is.
function InkAwayView:addScreenPoint(sx, sy, fresh, lift)
    local erasing = self.tool == "erase"
    local was = erasing and self:eraserCursorHide() or nil
    local cx, cy
    if self._wipe then   -- the whole-stroke eraser
        self:wipeTo(sx, sy)
        cx, cy = self._wipe.x, self._wipe.y
    else
        cx, cy = self:toCanvasClamped(sx, sy)
        if fresh or lift then
            self.sm_x, self.sm_y = cx, cy
        else
            local a = InkGeom.stabilizerAlpha(self.stabilizer)
            self.sm_x, self.sm_y = InkGeom.ema(self.sm_x, self.sm_y, cx, cy, a)
            cx, cy = self.sm_x, self.sm_y
        end
        local p = self._live_pressured and self:livePressure(sx, sy, fresh) or nil
        self.canvas:addPoint(cx, cy, p)
        self:stampLive(cx, cy, fresh, p)
    end
    if not erasing then return end
    -- (the outline is off unless turned on in the Eraser sheet: on e-ink each
    -- refresh of it costs time while erasing)
    if not self.eraser_outline then return end
    -- (at the lift the outline stays off: the eraser has left the page)
    if lift then
        self:eraserCursorGone(was)
    else
        self:eraserCursorShow(cx, cy, was)
    end
end

-- The pressure (0-255) for a new point of a pressured stroke: the pen's own when
-- it reports one (see ink/pressure.lua), else for pens that want it simulated
-- from the speed, else full. Eased along the distance so it never jumps.
function InkAwayView:livePressure(sx, sy, fresh)
    local now = self:nowMs()
    local dpi = Screen.getDPI and Screen:getDPI() or 300
    local last = self._lp_at
    local dist_mm = (last and not fresh) and Pens.mm(sx - last.x, sy - last.y, dpi) or 0
    local p
    local raw = self._pen_raw_pressure
    if raw ~= nil then
        p = Pens.fromRaw(raw, self:pressureMax(), self.pressure_curve)
    elseif self._live_sim and last and not fresh then
        local dt = math.max(1, now - last.t)
        p = Pens.fromSpeed(dist_mm / dt)
    else
        p = fresh and (self._live_sim and 200 or 255) or self._live_p or 255
    end
    if not fresh then p = Pens.smooth(self._live_p, p, dist_mm) end
    if last then last.x, last.y, last.t = sx, sy, now else self._lp_at = { x = sx, y = sy, t = now } end
    return p
end

-- Is the pen solid, fully opaque, pure black (what the fast waveform shows as is)?
function InkAwayView:pureBlackPen()
    local style = self.pen_style
    local solid = (style == nil) or (Raster.STYLES[style] and Raster.STYLES[style].solid)
    local c = self.pen_color
    return (self.pen_alpha or 255) >= 255 and solid and (c == nil
        or (c[1] == 0 and c[2] == 0 and c[3] == 0)) and true or false
end

function InkAwayView:beginStroke(sx, sy)
    self:elipsaStroke(true)
    -- in a layered drawing: the active layer shown, what lies above it at hand
    self:layerStrokeBegin(self.tool == "erase")
    if self.tool == "erase" and self.erase_whole then return self:wipeBegin(sx, sy) end
    local is_erase = self.tool == "erase"
    self.live_seed = math.random(1, 1000000)
    local style = nil
    if not is_erase then style = self.pen_style end
    -- The live refresh waveform, chosen once per stroke. The fast (A2/DU) waveform
    -- is black and white only: it shows solid opaque black ink at once but cannot
    -- render grey, colour or partial opacity, which would only appear at the lift.
    if is_erase then
        -- fast can only show white, so it suits erasing to a blank page; over a
        -- notebook ruling or a picture the erased path needs the grey-capable "ui",
        -- except where that holds the eraser up (see fastEraser): there the lift
        -- shows the ruling or picture again
        local reveal = (self.erase_bg and self:barePaperBB()) or self:eraseRevealBB()
        self._live_mode = (reveal and not self:einkDriven() and not self:fastEraser()) and "ui" or "fast"
    else
        -- on a colour panel every pen draws with "fast", and on a grey Boox Ink
        -- Away drives, or the original Elipsa, every opaque one (see fastLive and
        -- setupLiveWriters), settled once the pen rests; a see-through pen there
        -- would show as a black bar over the text until then
        local opaque = (self.pen_alpha or 255) >= 255
        self._live_mode = (self:pureBlackPen() or self:colourPanel()
            or (opaque and (self:einkDriven() or self:elipsaDriven()))) and "fast" or "ui"
    end
    -- a new stroke pushes back the pending colour settle (see queueReconcile);
    -- on a Kobo Sage or Elipsa it waits on its own while the pen is down (see
    -- runReconcile), as not every lift there sets it again
    if self._reconcile and self:fastLive() then UIManager:unschedule(self._reconcile_cb) end
    -- pens whose width changes keep a pressure per point: the pen's own with Pen
    -- pressure (Beta) on, else for Ballpoint and Fountain one simulated from the
    -- drawing speed; Calligraphy and Pencil then keep none (Pencil as before 4.0)
    local st = style and Raster.STYLES[style]
    self._live_pressured = (not is_erase) and Pens.usesPressure(style)
        and (self:realPressure() or (st and st.sim)) and true or false
    self._live_sim = self._live_pressured and st and st.sim and self._pen_raw_pressure == nil or false
    self._live_p, self._lp_at = nil, nil
    local smudge = (not is_erase) and style == "smudge"
    if smudge and not self:colourPanel() then self._live_mode = "ui" end   -- smudged ink is grey
    -- On a colour panel, ink that the fast waveform shows in its own colours
    -- (not the black preview) needs a settle that drives every pixel (see
    -- runReconcile); solid black shows exactly, and an eraser has nothing to settle.
    self._live_drive = (not is_erase) and self:colourPanel() and self._live_mode == "fast"
        and not self:pureBlackPen()
    self.canvas:startStroke(is_erase and "erase" or (smudge and "smudge" or "ink"),
        self:liveWidth(), self.pen_alpha, self.pen_color, style, self.live_seed, self._live_pressured)
    if self.symmetry ~= "off" and self.canvas.live then self.canvas.live.sym = self.symmetry end
    -- a calligraphy nib keeps the angle it was drawn with
    if st and st.engine == "nib" and self.pen_nib and self.canvas.live then self.canvas.live.nib = self.pen_nib end
    -- a "hard" erase also removes pictures; the soft default leaves them
    if is_erase and self.erase_bg and self.canvas.live then self.canvas.live.ebg = true end
    self.capturing = true
    self.pending_lift = nil
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
    self._stroke_rect = nil
    if self._lw_cacc then
        self._lw_cacc.x0, self._lw_cacc.y0 = math.huge, math.huge
        self._lw_cacc.x1, self._lw_cacc.y1 = -math.huge, -math.huge
    end
    self:setupLiveWriters()
    self._wl, self._sm = nil, nil
    local wst = (not is_erase) and self:washStyle(style)
    if wst then self:washBegin(wst) end
    if smudge then self:smudgeBegin() end
    self:addScreenPoint(sx, sy, true)
end

-- A lift: hold the stroke open for COALESCE_SEC in case the panel dropped the
-- contact and it comes back nearby.
function InkAwayView:scheduleFinalize(sx, sy)
    self:eraserCursorOff()   -- (the eraser lifted: its outline goes at once)
    self.pending_lift = { x = sx, y = sy }
    UIManager:unschedule(self._finalize)
    UIManager:scheduleIn(COALESCE_SEC, self._finalize)
end

------------------------------------------------------------------------------
-- Committing a stroke
------------------------------------------------------------------------------

-- Straighten: replace the just-committed ink op `committed` with a clean shape
-- recognised from its raw path, in place. Returns true if it did. It reuses the
-- history entry finishStroke pushed, so the swap is part of the same undo step.
function InkAwayView:beautifyStroke(raw, committed)
    -- the minimum size is ~20 screen px at any zoom
    local zoom = (self.view and self.view.zoom) or 1
    local min_size = Screen:scaleBySize(20) / (zoom > 0 and zoom or 1)
    local pts, shape = Recognize.detect(raw, { min_size = min_size })
    if not pts then return false end
    if shape then
        -- A line, rectangle, ellipse or triangle becomes a real shape op, so it gets
        -- the same edit menu as a shape drawn with the tool. It keeps the pen's
        -- width, colour, opacity and symmetry.
        committed.kind = "shape"
        committed.shape = shape.shape
        committed.pts = shape.pts
        committed.closed = shape.closed
        committed.fill = false
        committed.angle = 0
        committed.style, committed.seed, committed.pr = nil, nil, nil   -- ink-only fields; a shape ignores them
    else
        -- any other straightened path (an L, a polygon) stays ink with the same
        -- brush; only its points change (a pressure per old point no longer fits)
        committed.pts, committed.pr = pts, nil
    end
    self:markDirty()
    if not self:beautifyRecompose(raw, committed) then
        self:composeCanvas()
    end
    self:redraw()
    return true
end

-- What a lift must draw again from the saved stroke of a pen whose width
-- changes or that has its own engine: nil for the whole stroke, a canvas rect
-- {x0, y0, x1, y1} for just that, or false for nothing.
--   * a tapered pen (Ballpoint, Fountain): only where its end thins, which
--     the live drawing could not know of, or all of a stroke too short for
--     both its tapers (both are then shortened)
--   * Calligraphy and a pressed Pencil: nothing; the live drawing is the
--     saved stroke's, but for a pixel or two of the simplification here and
--     there, as with any pen
--   * anything else (the see-through pens blend over the page): all of it
-- Redrawing the whole stroke at every lift cost ten to twenty times what the
-- rest of the lift does.
function InkAwayView:liftTail(op, st)
    if st.engine == "nib" then return false end
    if not st.engine and op.pr then return false end
    if st.engine ~= "var" then return nil end
    local tp = st.taper
    if not tp then return false end
    local pts, w = op.pts, op.width or 1
    local n = math.floor(#pts / 2)
    if n < 2 then return nil end
    local total = 0
    for i = 2, n do
        total = total + math.sqrt((pts[2 * i - 1] - pts[2 * i - 3]) ^ 2 + (pts[2 * i] - pts[2 * i - 2]) ^ 2) / w
    end
    if total < 1.2 or total < tp.a + tp.b then return nil end
    -- the saved stroke from where its end's taper starts, b widths from the end
    local x0, y0, x1, y1 = pts[2 * n - 1], pts[2 * n], pts[2 * n - 1], pts[2 * n]
    local e = 0
    for i = n, 2, -1 do
        local ax, ay, bx, by = pts[2 * i - 3], pts[2 * i - 2], pts[2 * i - 1], pts[2 * i]
        local seg = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) / w
        local px, py = ax, ay
        if e + seg > tp.b then
            local f = (tp.b - e) / seg
            px, py = bx + (ax - bx) * f, by + (ay - by) * f
        end
        if px < x0 then x0 = px end
        if px > x1 then x1 = px end
        if py < y0 then y0 = py end
        if py > y1 then y1 = py end
        e = e + seg
        if e >= tp.b then break end
    end
    local pad = w / 2 + 2
    return { x0 = x0 - pad, y0 = y0 - pad, x1 = x1 + pad, y1 = y1 + pad }
end

-- Show an area-local rect of area_bb drawn again once the stroke has ended.
-- After a paint during the stroke the next paint copies to the screen only
-- what the samples since changed (_blit_rect, see paintTo), so the rect joins
-- that; without it the end drawn again stayed off the screen until a full
-- repaint.
function InkAwayView:blitAfterStroke(r)
    if self._blit_rect then
        self._blit_rect = InkGeom.growRect(self._blit_rect, r.x0, r.y0, r.x1, r.y1)
    end
end

-- On a Kobo Sage or Elipsa (see sunxiPanel) solid black ink is drawn live with
-- the fast waveform, which shows black and white exactly, and its lift is shown
-- with it too: the grey one keeps the panel busy longer, and could still be
-- running as the next letter began.
function InkAwayView:fastLift()
    return self:sunxiPanel() and self._live_mode == "fast"
end

-- Show an area-local rect drawn again at a lift. Where fastLift, the fast
-- waveform shows it at once and the grey one follows once the pen rests (see
-- queueReconcile), for anything grey under it that the fast one shows only as
-- black or white (a ruling or a book's text where a tapered end thinned, other
-- ink, the scaled ink of a zoom); elsewhere the grey one shows it at once.
function InkAwayView:showRedrawn(rr)
    if self:fastLift() then
        self:dirtyAreaRect("fast", rr, 2)
        self:queueReconcile(rr, 2)
    else
        self:dirtyAreaRect("ui", rr, 2)
    end
end

-- Draw the canvas rect `tail` again from the saved ops (and its mirrors under
-- symmetry), and show it. Zoomed in or out, the screen shows the page scaled,
-- while the live ink was drawn at the screen's own size, so all of the stroke
-- (`sr`, its area rect) is shown from the page: its end then joins it without
-- a step.
function InkAwayView:redrawTail(tail, op, sr)
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    local rects, nr = Symmetry.mirrorRects(tail, op.sym, W, H)
    for i = 1, nr do
        local r = rects[i]
        if r.x1 > r.x0 and r.y1 > r.y0 then self:composeRegion(r.x0, r.y0, r.x1, r.y1) end
    end
    local ax0, ay0 = self:toAreaLocal(tail.x0, tail.y0)
    local ax1, ay1 = self:toAreaLocal(tail.x1, tail.y1)
    if v.zoom ~= 1 and sr then
        ax0, ay0 = math.min(ax0, sr.x0), math.min(ay0, sr.y0)
        ax1, ay1 = math.max(ax1, sr.x1), math.max(ay1, sr.y1)
    end
    local srects, sn = self:symAreaRects({ x0 = ax0, y0 = ay0, x1 = ax1, y1 = ay1 })
    for i = 1, sn do
        local rr = srects[i]
        self:renderViewRect(rr.x0, rr.y0, rr.x1, rr.y1)
        self:blitAfterStroke(rr)
        if not self:fastLive() then self:showRedrawn(rr) end
    end
end

-- Update the master after a hold swapped a stroke for a clean op, over just the
-- footprint of the raw ink and the clean op, and of each symmetry mirror of it,
-- composed again (pixel-identical to composeCanvas). Returns false without a
-- master.
function InkAwayView:beautifyRecompose(raw, committed)
    if not self.canvas_bb then return false end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local hw = (committed.width or self.pen_width or 1) / 2 + 2
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    local function grow(pts)
        if not pts then return end
        for i = 1, #pts - 1, 2 do
            local px, py = pts[i], pts[i + 1]
            if px < x0 then x0 = px end
            if px > x1 then x1 = px end
            if py < y0 then y0 = py end
            if py > y1 then y1 = py end
        end
    end
    grow(raw)
    grow(committed.pts)
    if x1 < x0 or y1 < y0 then return false end
    local base = {
        x0 = math.max(0, math.floor(x0 - hw)),
        y0 = math.max(0, math.floor(y0 - hw)),
        x1 = math.min(W, math.ceil(x1 + hw)),
        y1 = math.min(H, math.ceil(y1 + hw)),
    }
    -- under symmetry the raw ink was mirrored too, so redo every mirror
    local rects, nr = Symmetry.mirrorRects(base, committed.sym, W, H)
    for i = 1, nr do
        local r = rects[i]
        if r.x1 > r.x0 and r.y1 > r.y0 then self:composeRegion(r.x0, r.y0, r.x1, r.y1) end
    end
    return true
end

------------------------------------------------------------------------------
-- Hold to straighten: a pen stroke held still at its end for HOLD_SEC becomes a
-- clean line or shape at once. Only
-- a stroke of some size that the recogniser takes for a line, box, ellipse or
-- triangle snaps, so a pause in writing leaves the writing alone; the rest of
-- that touch draws nothing.
------------------------------------------------------------------------------

local HOLD_SEC = 0.6

-- A point of the stroke being drawn: moving more than a little restarts the
-- wait (a still pen sends no points, so the timer then fires).
function InkAwayView:straightenWatch(sx, sy, fresh)
    if not (self.hold_straighten and self.capturing and self.tool == "pen") or self._wipe then return end
    local a = self._straight_at
    local slop = Screen:scaleBySize(7)
    if fresh or not a or math.abs(sx - a.x) > slop or math.abs(sy - a.y) > slop then
        if a then a.x, a.y = sx, sy else self._straight_at = { x = sx, y = sy } end   -- (no garbage per point)
        UIManager:unschedule(self._straighten_cb)
        UIManager:scheduleIn(HOLD_SEC, self._straighten_cb)
    end
end

-- The wait is over: straighten the stroke if it is a shape.
function InkAwayView:straightenNow()
    self._straight_at = nil
    local live = self.canvas.live
    if not (self.capturing and self.tool == "pen" and live and not self.pending_lift) or self._wipe then return end
    local lp = live.pts
    if #lp < 4 then return end
    local x0, y0, x1, y1 = InkGeom.bounds(lp)
    local zoom = (self.view and self.view.zoom) or 1
    -- about 5 mm on screen: a letter is smaller, a drawn shape is not
    if math.max(x1 - x0, y1 - y0) * zoom < Screen:scaleBySize(32) then return end
    -- only a true shape (a line, a box, an ellipse, a triangle): a zigzag of
    -- big writing straightened into corners is not what a pause asks for
    local pts, shape = Recognize.detect(lp, { min_size = Screen:scaleBySize(20) / zoom })
    if not (pts and shape) then return end
    self._straighten = true
    self:finalizeStroke()
    self._straighten = nil
    self._swallow = true   -- the rest of this touch draws nothing
end

-- Commit the live stroke as one op. Called by the coalesce timer, or straight
-- away by flushPending before anything that needs the ops up to date.
function InkAwayView:finalizeStroke()
    if not self.capturing then return end
    UIManager:unschedule(self._finalize)
    UIManager:unschedule(self._straighten_cb)
    self._straight_at = nil
    self.pending_lift = nil
    self.capturing = false
    self:elipsaStroke(false)
    self:eraserCursorOff()
    if self._wipe then return self:wipeEnd() end
    -- the live stroke wrote canvas_bb directly; resync the mirror over it
    self:markCanvasDirtyAcc(self._lw_cacc)
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
    local was_erase = self.tool == "erase"
    -- keep the raw points before finishStroke simplifies them: a held stroke is
    -- recognised from the full path
    local raw
    if self._straighten and self.tool == "pen" and self.canvas.live then
        local lp = self.canvas.live.pts
        raw = {}
        for i = 1, #lp do raw[i] = lp[i] end
    end
    local committed = self.canvas:finishStroke()
    if self._wl then self:washEnd() end   -- the page under it is drawn again from the op below
    if self._sm then self:smudgeEnd() end
    self:layerStrokeEnd(committed)   -- under other layers: the page there drawn again
    -- a mode may take the stroke over (the annotation mode makes a highlighter
    -- stroke along a line of text the reader's own highlight)
    if committed and self.takeStroke and self:takeStroke(committed) then
        self._stroke_rect = nil
        return
    end
    -- An erase records whether text was protected when it was made, so changing
    -- the setting later never erases or restores text retroactively.
    if committed and committed.kind == "erase" then
        committed.spare_text = self.text_erase_protect or nil
    end
    if raw and committed and committed.kind == "ink" and self:beautifyStroke(raw, committed) then
        self._stroke_rect = nil
        self:afterCommit()
        return
    end
    self:markDirty()
    local sr = self._stroke_rect
    -- A pen whose width changes is drawn live sample by sample, and saved
    -- simplified; draw its footprint again from the saved op, so what shows is
    -- exactly what thumbnails and exports will show.
    local st = committed and committed.kind == "ink" and committed.style and Raster.STYLES[committed.style]
    if st and (st.engine or committed.pr) and self.canvas_bb then
        local tail = self:liftTail(committed, st)
        local c = self._lw_cacc
        if tail == nil then
            if c and c.x1 > c.x0 and self:beautifyRecompose({ c.x0, c.y0, c.x1, c.y1 }, committed) and sr then
                local rects, nr = self:symAreaRects(sr)
                for i = 1, nr do
                    local rr = rects[i]
                    self:renderViewRect(rr.x0, rr.y0, rr.x1, rr.y1)
                    self:blitAfterStroke(rr)
                    if not self:fastLive() then self:showRedrawn(rr) end
                end
            end
        elseif tail then
            self:redrawTail(tail, committed, sr)
        end
    end
    if self:fastLive() then
        -- show the last samples now, put the real colours back where the black
        -- preview was, and let one refresh settle them once the pen rests (not
        -- needed where every refresh already shows the colour as drawn). A
        -- driven Boox is asked for the whole stroke again, in case a live
        -- request reached the panel before its frame.
        self:liveFlush()
        local settle = self._live_preview or not self:instantColour()
        local drive = self._live_drive and not self._live_preview
        if sr then
            local rects, nr = self:symAreaRects(sr)
            for i = 1, nr do
                local rr = rects[i]
                if self._live_mode == "fast" then self:einkAsk("fast", rr, 2) end
                if self._live_preview then self:renderViewRect(rr.x0, rr.y0, rr.x1, rr.y1) end
                if settle then self:queueReconcile(rr, 2, drive) end
            end
        else
            local v = self.view
            if self._live_preview then self:renderView() end
            if settle then self:queueReconcile({ x0 = 0, y0 = 0, x1 = v.area_w, y1 = v.area_h }, 0, drive) end
        end
        self._live_preview = false
    elseif was_erase then
        -- Taking ink back to white with the fast waveform leaves a faint grey
        -- ghost, which one cleaning refresh over the erased rects removes. A pen
        -- stroke needs nothing more: its live refreshes already showed it as it is
        -- ("fast" for solid black, which that waveform shows exactly, "ui" for any
        -- other ink), and refreshing it again only redrew the page under it.
        local mode = self:cleanMode()
        if sr then
            local rects, nr = self:symAreaRects(sr)
            for i = 1, nr do
                self:dirtyAreaRect(mode, rects[i], 2)
            end
        else
            UIManager:setDirty(self, mode, self:areaScreenRect())
        end
    elseif sr and self:sunxiPanel() then
        -- a Kobo Sage or Elipsa may have dropped some of the live updates (see
        -- sunxiPanel): the whole stroke shows once more as the pen lifts, in one
        -- update with its last samples, in the waveform it was drawn with (see
        -- fastLift)
        self:liveFlush()
        local mode = self:fastLift() and "fast" or "ui"
        local rects, nr = self:symAreaRects(sr)
        for i = 1, nr do
            self:blitAfterStroke(rects[i])
            self:dirtyAreaRect(mode, rects[i], 2)
        end
        -- a grey refresh still to come waits for the pen to rest again
        if self._reconcile then self:queueReconcile(self._reconcile) end
    end
    self._stroke_rect = nil
    self:afterCommit()
end

-- Called once per committed drawing action. With ghosting clean-up on, every
-- `ghost_clean` actions get one full-screen refresh to clear what the fast
-- refreshes left behind.
function InkAwayView:afterCommit()
    self:healMemory()
    local n = self.ghost_clean or 0
    if n <= 0 then return end
    self._strokes_since_full = (self._strokes_since_full or 0) + 1
    if self._strokes_since_full >= n then
        self._strokes_since_full = 0
        UIManager:setDirty(self, "full")
    end
end

-- A safety net: if the Lua heap ever grows large over a long session, collect
-- between strokes, where the pause goes unnoticed. Normal drawing allocates
-- almost nothing per stroke, so this should never fire.
function InkAwayView:healMemory()
    self._commits_since_gc = (self._commits_since_gc or 0) + 1
    if self._commits_since_gc < GC_HEAL_EVERY then return end
    self._commits_since_gc = 0
    if collectgarbage("count") > GC_HEAL_KB then collectgarbage("collect") end
end

-- Give the previous drawing's or notebook's memory back after starting a new one
-- (not on a page turn): collect now.
function InkAwayView:resetTransientMemory()
    self._commits_since_gc = 0
    collectgarbage("collect")
end

-- Commit the stroke now if one is open or pending. Safe to call any time.
function InkAwayView:flushPending()
    if self.capturing then self:finalizeStroke() end
end

return InkAwayView
