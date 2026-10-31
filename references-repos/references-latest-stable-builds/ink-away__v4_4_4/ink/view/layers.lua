--[[
Layers in a drawing, in the view (the model is ink/layers.lua): what is drawn
(hidden layers left out), what can be edited (the active layer only), the
eraser that cuts the active layer's strokes, and keeping it all with the file.

Layers are never kept as bitmaps of their own. The master (canvas_bb) is the
whole page as before, drawn from the one list of ops. Only two caches exist,
each made the first time it is needed and freed as soon as it is not:
  * drawing on a layer with others shown above it: what those layers cover
    (their opaque pixels, only over the box they reach), laid back over each
    new piece of the stroke so they stay on top while it is drawn;
  * erasing: the page without the active layer, which the eraser uncovers as
    it goes.
Both stay valid while the active layer is the only one changing (the usual
case), and go when another layer is chosen, shown, hidden or changed, when
layers are turned off and when the drawing closes.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ffi = require("ffi")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local Canvas = require("ink/canvas")
local Cut = require("ink/cut")
local Layers = require("ink/layers")
local Symmetry = require("ink/symmetry")
local Theme = require("ink/ui/theme")

local Screen = Device.screen
-- A translated text with %1, %2... filled in (as KOReader's template).
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end
local FILL = Blitbuffer.ColorRGB32(0xF0, 0xF0, 0xF0, 0xFF)
local BORDER = Blitbuffer.ColorRGB32(0xB4, 0xB4, 0xB4, 0xFF)
local GLYPH = Blitbuffer.ColorRGB32(0x33, 0x34, 0x36, 0xFF)
local FAINT = Blitbuffer.ColorRGB32(0x9A, 0x9A, 0x9A, 0xFF)

local InkAwayView = {}

------------------------------------------------------------------------------
-- What is drawn and what can be edited
------------------------------------------------------------------------------

-- Can this document have layers? Only a drawing (not a notebook, not a book).
function InkAwayView:layersAllowed()
    return not (self.notebook or self.reader_mode or self.over_book)
end

-- Does the open drawing have layers?
function InkAwayView:layered()
    return self.canvas and self.canvas.layers ~= nil
end

-- The ops drawn now: every op, or without the hidden layers'.
function InkAwayView:drawnOps()
    return Layers.visible(self.canvas)
end

-- The canvas as exports and the paint bucket read it: its size and the ops
-- drawn now (the canvas itself when nothing is hidden).
function InkAwayView:drawnCanvas()
    local c = self.canvas
    local ops = Layers.visible(c)
    if ops == c.ops then return c end
    return { w = c.w, h = c.h, ops = ops }
end

-- Can this op be picked, moved or erased now? Only the active layer's.
function InkAwayView:editableOp(op)
    return Layers.editable(self.canvas, op)
end

-- The ops the whole-stroke eraser and the hit tests may take: all of them, or
-- the active layer's (shown).
function InkAwayView:editableOps()
    local c = self.canvas
    if not c.layers then return c.ops end
    local out = {}
    if not Layers.shown(c, c.active_layer) then return out end
    for _i, op in ipairs(c.ops) do
        if Layers.editable(c, op) then out[#out + 1] = op end
    end
    return out
end

------------------------------------------------------------------------------
-- The eraser of a layered drawing
------------------------------------------------------------------------------

-- An eraser stroke on a layered drawing cuts the active layer's strokes, shapes
-- and fills where it went (ink/cut.lua), so the layers under it stay. It is one
-- undo step, as the stroke was. Called for every committed stroke (see
-- finalizeStroke); false leaves the stroke as it is.
function InkAwayView:takeStroke(op)
    local c = self.canvas
    if not (c.layers and op.kind == "erase") then return false end
    c:undo()                 -- the eraser's own stroke, as if never drawn
    c.redo_stack = {}
    local W, H = self.view.canvas_w, self.view.canvas_h
    local ops, changed = c.ops, false
    local opts = { text = not self.text_erase_protect, pictures = self.erase_bg,
        only = function(o) return Layers.editable(c, o) end }
    local x0, y0, x1, y1
    local before = {}
    for _i, o in ipairs(ops) do before[o] = true end
    -- the eraser and its mirror copies
    for _i, f in ipairs(Symmetry.flips(op.sym)) do
        local pts = Symmetry.flipPoints(op.pts, f, W, H)
        local cut, did = Cut.ops(ops, pts, (op.width or 1) / 2, opts)
        if did then ops, changed = cut, true end
    end
    if changed then
        -- the box of everything that went (its pieces lie inside it)
        local now = {}
        for _i, o in ipairs(ops) do now[o] = true end
        for o in pairs(before) do
            if not now[o] then
                local a, b, cc, d = Canvas.opBox(o)
                if a then
                    x0, y0 = math.min(x0 or a, a), math.min(y0 or b, b)
                    x1, y1 = math.max(x1 or cc, cc), math.max(y1 or d, d)
                end
                if o.sym and o.sym ~= "off" then x0, y0, x1, y1 = 0, 0, W, H end
            end
        end
        c:pushHistory()
        c.ops = ops
        self:markDirty()
    end
    self:resetLasso()
    if x0 then self:composeRegion(x0, y0, x1, y1) else self:composeCanvas() end
    self:renderView()
    UIManager:setDirty(self, self:cleanMode(), self:areaScreenRect())
    self:afterCommit()
    return true
end


------------------------------------------------------------------------------
-- The two caches
------------------------------------------------------------------------------

-- What the caches were made for: the active layer, the state of the others
-- (canvas.lrev counts their changes), what is hidden, the page's size, paper
-- and picture. When it changes they are made again.
function InkAwayView:layerKey()
    local c, v = self.canvas, self.view
    local p = self:paperRGB()
    return table.concat({ c.active_layer or 0, c.lrev or 0, c._hid or 0, v.canvas_w, v.canvas_h,
        p and (p[1] .. "," .. p[2] .. "," .. p[3]) or "w", tostring(self.bg_bb) }, "|")
end

-- The box (canvas px, clipped to the page) the ops can draw in, or nil.
local function opsBox(ops, W, H)
    local x0, y0, x1, y1
    for _i, op in ipairs(ops) do
        if op.sym and op.sym ~= "off" then return 0, 0, W, H end
        local a, b, c, d = Canvas.opBox(op)
        if a then
            x0, y0 = math.min(x0 or a, a), math.min(y0 or b, b)
            x1, y1 = math.max(x1 or c, c), math.max(y1 or d, d)
        elseif op.kind == "text" then
            return 0, 0, W, H   -- not laid out yet: anywhere
        end
    end
    if not x0 then return nil end
    x0, y0 = math.max(0, math.floor(x0)), math.max(0, math.floor(y0))
    x1, y1 = math.min(W, math.ceil(x1)), math.min(H, math.ceil(y1))
    if x1 <= x0 or y1 <= y0 then return nil end
    return x0, y0, x1, y1
end

-- What the shown layers above the active one cover: their pixels drawn the same
-- over white and over black (fully opaque), with alpha, over just their box.
-- See-through ink up there is left out: it is put back when the stroke lifts.
function InkAwayView:buildLayerAbove(ops)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local x0, y0, x1, y1 = opsBox(ops, W, H)
    if not x0 then return nil end
    local typ = self.canvas_bb:getType()
    local grey = typ == Blitbuffer.TYPE_BB8
    if not grey and typ ~= Blitbuffer.TYPE_BBRGB32 then return nil end
    local w, h = x1 - x0, y1 - y0
    local scratch = Blitbuffer.new(W, H, typ)
    local over = Blitbuffer.new(w, h, grey and Blitbuffer.TYPE_BB8A or Blitbuffer.TYPE_BBRGB32)
    local sp, ss = ffi.cast("uint8_t*", scratch.data), tonumber(scratch.stride)
    local op_, os = ffi.cast("uint8_t*", over.data), tonumber(over.stride)
    -- over white: its colours, not yet opaque
    scratch:fill(Blitbuffer.COLOR_WHITE)
    self:composeInto(scratch, ops, nil, nil, nil, nil, true, nil, nil, true)
    for y = 0, h - 1 do
        local s, o = sp + (y0 + y) * ss, op_ + y * os
        if grey then
            for x = 0, w - 1 do o[2 * x] = s[x0 + x]; o[2 * x + 1] = 0 end
        else
            for x = 0, w - 1 do
                local si, oi = 4 * (x0 + x), 4 * x
                o[oi], o[oi + 1], o[oi + 2], o[oi + 3] = s[si], s[si + 1], s[si + 2], 0
            end
        end
    end
    -- over black: where it matches, nothing of the page shows through
    scratch:fill(Blitbuffer.COLOR_BLACK)
    self:composeInto(scratch, ops, nil, nil, nil, nil, true, nil, nil, true)
    local any = false
    for y = 0, h - 1 do
        local s, o = sp + (y0 + y) * ss, op_ + y * os
        if grey then
            for x = 0, w - 1 do
                if s[x0 + x] == o[2 * x] then o[2 * x + 1] = 255; any = true end
            end
        else
            for x = 0, w - 1 do
                local si, oi = 4 * (x0 + x), 4 * x
                if s[si] == o[oi] and s[si + 1] == o[oi + 1] and s[si + 2] == o[oi + 2] then
                    o[oi + 3] = 255; any = true
                end
            end
        end
    end
    scratch:free()
    if not any then over:free(); return nil end
    return { bb = over, x = x0, y = y0, w = w, h = h }
end

-- The cache of what lies above the active layer (nil when nothing does).
function InkAwayView:layerAbove()
    if not (self:layered() and self.canvas_bb) then return nil end
    local key = self:layerKey()
    if self._lay_above_key ~= key then
        self:layerAboveFree()
        self._lay_above = self:buildLayerAbove(Layers.above(self.canvas)) or false
        self._lay_above_key = key
    end
    return self._lay_above or nil
end

function InkAwayView:layerAboveFree()
    if self._lay_above then self._lay_above.bb:free() end
    self._lay_above, self._lay_above_key, self._lay_over = nil, nil, nil
end

-- Lay what the layers above cover back over the canvas rect (x0, y0)-(x1, y1),
-- and its mirror copies with `sym`, during a stroke on a lower layer.
function InkAwayView:layerCover(x0, y0, x1, y1, sym)
    local a = self._lay_over
    if not a then return end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local base = { x0 = math.floor(x0), y0 = math.floor(y0), x1 = math.ceil(x1), y1 = math.ceil(y1) }
    local rects, nr
    if sym and sym ~= "off" then rects, nr = Symmetry.mirrorRects(base, sym, W, H) else rects, nr = { base }, 1 end
    for i = 1, nr do
        local r = rects[i]
        local bx0, by0 = math.max(r.x0, a.x), math.max(r.y0, a.y)
        local bx1, by1 = math.min(r.x1, a.x + a.w), math.min(r.y1, a.y + a.h)
        if bx1 > bx0 and by1 > by0 then
            self.canvas_bb:alphablitFrom(a.bb, bx0, by0, bx0 - a.x, by0 - a.y, bx1 - bx0, by1 - by0)
        end
    end
end

-- The page without the active layer, which the eraser uncovers as it goes:
-- the paper or picture with the other shown layers on it.
function InkAwayView:layerRest()
    if not (self:layered() and self.canvas_bb) then return nil end
    local key = self:layerKey()
    if self._lay_rest_key ~= key then
        self:layerRestFree()
        local W, H = self.view.canvas_w, self.view.canvas_h
        local rest = Blitbuffer.new(W, H, self.canvas_bb:getType())
        local others = Layers.others(self.canvas)
        local base = self.bg_bb or self:plainPaperBB()
        local bare = Canvas.scanOps(others).hard_erase and self:barePaperBB() or nil
        self:composeInto(rest, others, base, nil, nil, nil, false, bare)
        self._lay_rest, self._lay_rest_key = rest, key
    end
    return self._lay_rest
end

function InkAwayView:layerRestFree()
    if self._lay_rest then self._lay_rest:free() end
    self._lay_rest, self._lay_rest_key = nil, nil
end

-- Free both caches (layers turned off, another document, closing).
function InkAwayView:layerCachesDrop()
    if self._lay_prepare then UIManager:unschedule(self._lay_prepare) end
    self:layerAboveFree()
    self:layerRestFree()
end

------------------------------------------------------------------------------
-- A stroke on a layer
------------------------------------------------------------------------------

-- Before anything is drawn on the active layer: show it if it was hidden.
function InkAwayView:layerReady()
    local c = self.canvas
    if c.layers and not Layers.shown(c, c.active_layer) then
        Layers.setHidden(c, c.active_layer, false)
        self:markDirty()
        self:composeCanvas()
        self:renderView()
        self._paint_all = true
        UIManager:setDirty(self, "ui")
    end
end

-- A stroke begins: on a layer under others, keep what they cover ready to lay
-- back over it.
function InkAwayView:layerStrokeBegin(is_erase)
    self._lay_over = nil
    if not self:layered() then return end
    self:layerReady()
    if not is_erase then self._lay_over = self:layerAbove() end
end

-- The stroke is in: where others lie above it, the page is drawn again from
-- the ops there, so see-through ink above shows over it as it will in the file.
function InkAwayView:layerStrokeEnd(op)
    local had = self._lay_over
    self._lay_over = nil
    if not (had and op) then return end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local x0, y0, x1, y1 = Canvas.opBox(op)
    if not x0 then return end
    if op.sym and op.sym ~= "off" then x0, y0, x1, y1 = 0, 0, W, H end
    self:composeRegion(x0, y0, x1, y1)
    local ax0, ay0 = self:toAreaLocal(x0, y0)
    local ax1, ay1 = self:toAreaLocal(x1, y1)
    self:renderViewRect(ax0 - 1, ay0 - 1, ax1 + 1, ay1 + 1)
    self:dirtyAreaRect("ui", { x0 = ax0, y0 = ay0, x1 = ax1, y1 = ay1 }, 2)
end


------------------------------------------------------------------------------
-- Turning layers on and off, and what can be done to one
------------------------------------------------------------------------------

-- After a change to the layers: the page drawn again (when what shows changed),
-- the caches made again when next needed, the strip repainted, a save to come.
function InkAwayView:layersChanged(recompose)
    self:resetLasso()
    self:layerCachesDrop()
    self:markDirty()
    if recompose then self:composeCanvas(); self:renderView() end
    self._paint_all = true
    UIManager:setDirty(self, "ui")
end

-- Turn layers on: what is drawn so far becomes the first layer.
function InkAwayView:layersOn()
    if not self:layersAllowed() or self:layered() then return end
    self:flushPending()
    Layers.enable(self.canvas)
    self:layersChanged(false)
end

-- Turn them off, after asking: every layer merged into one drawing.
function InkAwayView:confirmLayersOff()
    if not self:layered() then return end
    if #self.canvas.layers == 1 then return self:layersOff() end
    self:ask{ field = "_layer_confirm", title = _("Turn layers off?"),
        text = _("All the layers are merged into one drawing, hidden ones too. Undo brings the layers back."),
        ok_text = _("Merge"), on_ok = function() self:layersOff() end }
end

function InkAwayView:layersOff()
    self:flushPending()
    if Layers.flatten(self.canvas) then self:layersChanged(true) end
end

-- Draw on layer `id` from now on.
function InkAwayView:layerSelect(id)
    local c = self.canvas
    if not Layers.pos(c, id) or c.active_layer == id then return end
    self:flushPending()
    self:resetLasso()            -- a selection belongs to the layer it was made on
    if self.editing_text then self:finishTextEdit(true) end
    c.active_layer = id
    self:layerCachesDrop()       -- made for the layer before
    self:markDirty()
    self:refreshFabRegion(self:fabRect("layers"))
    -- the cache the next stroke needs, made just after the strip shows the
    -- choice (a big drawing takes a moment), not at that stroke's first touch
    if not self._lay_prepare then
        self._lay_prepare = function()
            if not self:layered() then return end
            if self.tool == "erase" then
                if not self.erase_whole then self:layerRest() end
            else
                self:layerAbove()
            end
        end
    end
    UIManager:unschedule(self._lay_prepare)
    UIManager:scheduleIn(0.05, self._lay_prepare)
end

-- A new empty layer over the active one, to draw on.
function InkAwayView:layerAdd()
    self:flushPending()
    if not Layers.add(self.canvas) then
        self:showNotice(T(_("A drawing can have up to %1 layers."), Layers.MAX))
        return
    end
    self:layersChanged(false)
end

function InkAwayView:layerToggleShown(id)
    local c = self.canvas
    self:flushPending()
    if Layers.setHidden(c, id, Layers.shown(c, id)) then self:layersChanged(true) end
end

function InkAwayView:layerMove(id, dir)
    local can, why = Layers.canMove(self.canvas, id, dir)
    if not can then
        if why == "erase" then
            self:showNotice(_("The first layer has erasing from before layers were on, so it stays at the bottom."))
        else
            self:showNotice(dir > 0 and _("This layer is already at the top.") or _("This layer is already at the bottom."))
        end
        return
    end
    self:flushPending()
    Layers.move(self.canvas, id, dir)
    self:layersChanged(true)
end

function InkAwayView:layerMergeDown(id)
    self:flushPending()
    if Layers.pos(self.canvas, id) == 1 then
        self:showNotice(_("There is no layer under this one."))
        return
    end
    if Layers.mergeDown(self.canvas, id) then self:layersChanged(true) end
end

function InkAwayView:layerDelete(id)
    local c = self.canvas
    if #c.layers < 2 then
        self:showNotice(_("A drawing with layers keeps at least one. To stop using layers, turn them off in File."))
        return
    end
    local function go()
        self:flushPending()
        if Layers.remove(c, id) then self:layersChanged(true) end
    end
    if (Layers.counts(c)[id] or 0) == 0 then return go() end
    local l = Layers.get(c, id)
    self:ask{ field = "_layer_confirm", title = _("Delete this layer?"),
        text = T(_("%1 and everything on it are deleted. Undo brings them back."), l and Layers.label(c, id) or ""),
        ok_text = _("Delete"), ok_icon = "trash", on_ok = go }
end

function InkAwayView:layerRename(id)
    local l = Layers.get(self.canvas, id)
    if not l then return end
    self:promptText{ title = _("Rename layer"), input = Layers.label(self.canvas, id), ok_text = _("Rename"),
        on_ok = function(text)
            if Layers.rename(self.canvas, id, text) then self:layersChanged(false) end
        end }
end

-- The menu of a layer (a tap on the active layer in the strip).
function InkAwayView:openLayerMenu(id)
    local c = self.canvas
    local l = Layers.get(c, id)
    if not l then return end
    local content_w, gap = self:sheetWidth()
    local half = math.floor((content_w - gap) / 2)
    local function closeSelf() self:closeSheet("_layer_menu") end
    local function act(label, cb, icon)
        return self:actionButton(label, half, function() closeSelf(); cb() end, nil, nil, icon)
    end
    local function row(a, b)
        return HorizontalGroup:new{ align = "center", a, HorizontalSpan:new{ width = gap }, b }
    end
    local build = function()
        local shown = Layers.shown(c, id)
        local pos = Layers.pos(c, id) or 1
        return VerticalGroup:new{ align = "left",
            self:sheetTitle(Layers.label(c, id), content_w, _("Done"), closeSelf),
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            self:sheetHint(T(_("Layer %1 of %2. New drawing goes on this layer."), pos, #c.layers), content_w, 14),
            VerticalSpan:new{ width = Screen:scaleBySize(14) },
            row(act(shown and _("Hide") or _("Show"), function() self:layerToggleShown(id) end, "eye"),
                act(_("Rename\u{2026}"), function() self:layerRename(id) end, "rename")),
            VerticalSpan:new{ width = gap },
            row(act(_("Move up"), function() self:layerMove(id, 1) end, "arrow_up"),
                act(_("Move down"), function() self:layerMove(id, -1) end, "arrow_down")),
            VerticalSpan:new{ width = gap },
            row(act(_("Merge down"), function() self:layerMergeDown(id) end, "mergedown"),
                act(_("Delete\u{2026}"), function() self:layerDelete(id) end, "trash")),
        }
    end
    self:showSheet("_layer_menu", build)
end

------------------------------------------------------------------------------
-- The strip: a small floating column at the right, only while layers are on
------------------------------------------------------------------------------

-- The strip's rect and rows: a "+" on top (while another layer can be added),
-- then a chip per layer, the top layer first. nil without layers.
function InkAwayView:layerStripRect()
    local c = self.canvas
    if not (c and c.layers and self.view) then return nil end
    local v = self.view
    local m = Screen:scaleBySize(16)
    local w, rh, pad = Screen:scaleBySize(46), Screen:scaleBySize(40), Screen:scaleBySize(4)
    local plus = #c.layers < Layers.MAX
    local rows = #c.layers + (plus and 1 or 0)
    local h = rows * rh + 2 * pad
    local x = v.area_x + v.area_w - m - w
    local y = v.area_y + math.floor((v.area_h - h) / 2)
    -- clear of the Pan button and the zoom under it at the bottom right
    local pan = self.fab_side == "right" and self:fabRect("pan")
    if pan and y + h > pan.y - Screen:scaleBySize(10) then y = pan.y - Screen:scaleBySize(10) - h end
    y = math.max(v.area_y + m, y)
    return { x = x, y = y, w = w, h = h, rh = rh, pad = pad, plus = plus, n = #c.layers }
end

-- What a point on the strip is: "layer+" (the plus) or "layer<k>" (the layer
-- at position k from the bottom).
function InkAwayView:layerStripHit(py, r)
    local row = math.floor((py - r.y - r.pad) / r.rh) + 1
    if r.plus then
        if row <= 1 then return "layer+" end
        row = row - 1
    end
    row = math.max(1, math.min(r.n, row))
    return "layer" .. (r.n - row + 1)
end

-- A tap on the strip.
function InkAwayView:layerStripAction(kind)
    local c = self.canvas
    if not c.layers then return end
    if kind == "layer+" then return self:layerAdd() end
    local pos = tonumber(kind:match("^layer(%d+)$"))
    local l = pos and c.layers[pos]
    if not l then return end
    if l.id == c.active_layer then self:openLayerMenu(l.id) else self:layerSelect(l.id) end
end

-- A layer's short label: the number of "Layer n", else the start of its name.
local function shortName(name)
    local n = tostring(name or ""):match("^Layer (%d+)$")
    if n then return n end
    local out, k = {}, 0
    for ch in tostring(name or "?"):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        k = k + 1
        if k > 2 then break end
        out[#out + 1] = ch
    end
    return table.concat(out)
end

-- Paint the strip into bb at offset (ox, oy).
function InkAwayView:drawLayerStrip(bb, ox, oy, r)
    local c = self.canvas
    local x, y = ox + r.x, oy + r.y
    local rad = Screen:scaleBySize(14)
    bb:paintRoundedRect(x, y, r.w, r.h, BORDER, rad)
    local b = Screen:scaleBySize(1)
    bb:paintRoundedRect(x + b, y + b, r.w - 2 * b, r.h - 2 * b, FILL, rad - b)
    local inset = Screen:scaleBySize(4)
    local face = Font:getFace("cfont", 17)
    local function label(text, rx, ry, color, bold)
        local t = TextWidget:new{ text = text, face = face, bold = bold, fgcolor = color, max_width = r.w - 2 * inset }
        local sz = t:getSize()
        t:paintTo(bb, rx + math.floor((r.w - sz.w) / 2), ry + math.floor((r.rh - sz.h) / 2))
        t:free()
    end
    local ry = y + r.pad
    if r.plus then
        local s, t = Screen:scaleBySize(14), math.max(2, Screen:scaleBySize(2))
        local cx, cy = x + math.floor(r.w / 2), ry + math.floor(r.rh / 2)
        bb:paintRect(cx - math.floor(s / 2), cy - math.floor(t / 2), s, t, GLYPH)
        bb:paintRect(cx - math.floor(t / 2), cy - math.floor(s / 2), t, s, GLYPH)
        ry = ry + r.rh
    end
    local dark = Theme.invert()
    local active_at
    for pos = #c.layers, 1, -1 do
        local l = c.layers[pos]
        if l.id == c.active_layer then
            active_at = ry
        else
            local shown = Layers.shown(c, l.id)
            label(shortName(Layers.label(c, l.id)), x, ry, shown and GLYPH or FAINT, false)
            if not shown then   -- a hidden layer: struck through
                local t = math.max(2, Screen:scaleBySize(2))
                local lx0, ly0 = x + inset * 2, ry + r.rh - inset * 2
                local lx1, ly1 = x + r.w - inset * 2, ry + inset * 2
                local n = math.max(1, lx1 - lx0)
                for i = 0, n do
                    bb:paintRect(lx0 + i, math.floor(ly0 + (ly1 - ly0) * i / n), t, t, FAINT)
                end
            end
        end
        ry = ry + r.rh
    end
    if dark then Theme.invertRounded(bb, x, y, r.w, r.h, rad) end
    -- the active layer: in the accent, as the active tool is (after the dark
    -- inversion, so it keeps its colour)
    if active_at then
        local a = Accent.get()
        Accent.paintRounded(bb, x + inset, active_at + inset / 2, r.w - 2 * inset, r.rh - inset, Screen:scaleBySize(10))
        if dark and not a.custom then bb:invertRect(x + inset, active_at + inset / 2, r.w - 2 * inset, r.rh - inset) end
        local l = Layers.get(c, c.active_layer)
        local shown = Layers.shown(c, c.active_layer)
        label(shortName(l and Layers.label(c, l.id)), x, active_at, (dark and not a.custom) and Blitbuffer.COLOR_BLACK or a.text, true)
        if not shown then
            -- (the active layer hidden: shown again as soon as something is drawn)
            local t = math.max(2, Screen:scaleBySize(2))
            bb:paintRect(x + inset * 3, active_at + math.floor(r.rh / 2), r.w - inset * 6, t,
                (dark and not a.custom) and Blitbuffer.COLOR_BLACK or a.text)
        end
    end
end

------------------------------------------------------------------------------
-- Keeping them with the drawing
------------------------------------------------------------------------------

-- The fields a drawing file keeps for its layers (nil without them).
function InkAwayView:layersForFile()
    if not self:layersAllowed() then return nil end
    return Layers.save(self.canvas)
end

-- A drawing just opened: its layers, as the file keeps them.
function InkAwayView:loadLayers(saved)
    if self:layersAllowed() then Layers.load(self.canvas, saved) end
    self:layerCachesDrop()
end

return InkAwayView
