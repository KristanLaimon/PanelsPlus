--[[
The 1:1 master bitmap: rebuilding it from the ops (paper, background, ruling and
the buffers an eraser reveals), and stamping one committed op into it.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local Canvas = require("ink/canvas")
local Export = require("ink/export")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Smudge = require("ink/smudge")
local Wash = require("ink/wash")
local Symmetry = require("ink/symmetry")
local Theme = require("ink/ui/theme")

local WHITE = Blitbuffer.COLOR_WHITE
local displayColor = Paint.displayColor
local spanWriter = Paint.spanWriter
local bgSpanWriter = Paint.bgSpanWriter
local paintPaper = Paint.paintPaper

local InkAwayView = {}

-- The colour a committed op is drawn with on screen: its ink at its opacity,
-- black showing white on a dark paper (`paper`, the open document's when nil;
-- false is white). An eraser is white: on any other paper it reveals the
-- paper's buffer instead.
function InkAwayView:opColor(op, paper)
    if op.kind == "erase" then return WHITE end
    if paper == nil then paper = self:paperRGB() end
    return displayColor(self:shownInk(op.color, paper), op.alpha or 255)
end

-- Are ink colours turned for KOReader's night mode (see Paint.nightInk)? On a
-- colour screen in night mode, unless Keep colours in night mode is off.
function InkAwayView:nightInk()
    if not (Theme.nightMode() and self:colorScreen()) then return false end
    return self:getSetting("inkaway_night_colours", true) ~= false
end

-- An ink colour as the screen shows it: on its paper (Paint.inkOnPaper), and
-- turned for night mode when the colours are kept there. Not while drawing
-- what is saved to a file (thumbnails, covers: see trueColours).
function InkAwayView:shownInk(rgb, paper)
    local c = Paint.inkOnPaper(rgb, paper)
    if not self._true_colours and self:nightInk() then c = Paint.nightInk(c) end
    return c
end

-- KOReader's night mode turned on or off (it inverts the screen on its own), or
-- Keep colours in night mode (`setting`) turned on or off in night mode: on a
-- colour screen the page is drawn again in the colours that now show right,
-- once KOReader has made the change.
function InkAwayView:nightModeChanged(setting)
    if not self:colorScreen() then return end
    if not setting and self:getSetting("inkaway_night_colours", true) == false then return end
    if setting and not Theme.nightMode() then return end   -- (nothing shows differently by day)
    UIManager:nextTick(function()
        if self.closing or not self.canvas_bb then return end
        self:composeCanvas()
        self:renderView()
        self._paint_all = true
        UIManager:setDirty(self, "full")
    end)
end
function InkAwayView:onToggleNightMode() self:nightModeChanged() end
function InkAwayView:onSetNightMode() self:nightModeChanged() end

-- Run fn drawing ink in its own colours whatever the night mode: for a page
-- drawn to be kept (a thumbnail, a cover), which day mode shows too.
function InkAwayView:trueColours(fn)
    local was = self._true_colours
    self._true_colours = true
    local ok, err = pcall(fn)
    self._true_colours = was
    if not ok then error(err, 0) end
end

-- A see-through stroke as the screen shows it (its colour turned for night
-- mode, see shownInk): the op itself, or a stand-in with the turned colour.
function InkAwayView:shownWash(op)
    if self._true_colours or not self:nightInk() or not op.color then return op end
    return setmetatable({ color = Paint.nightInk(op.color) }, { __index = op })
end

-- A span writer clipped to `region` (a canvas rect {x0, y0, x1, y1}), or put
-- itself without one.
local function inRegion(put, region)
    if not region then return put end
    local x0, y0, x1, y1 = region.x0, region.y0, region.x1, region.y1
    return function(x, y, len)
        if y < y0 or y >= y1 then return end
        if x < x0 then len = len - (x0 - x); x = x0 end
        if x + len > x1 then len = x1 - x end
        if len > 0 then put(x, y, len) end
    end
end

-- Can op draw anything inside `region`? Symmetric ops and text not yet laid out
-- are always taken.
local function meets(op, region)
    if op.sym and op.sym ~= "off" then return true end
    local x0, y0, x1, y1 = Canvas.opBox(op)
    if not x0 then return op.kind == "text" end
    return x0 < region.x1 and region.x0 < x1 and y0 < region.y1 and region.y0 < y1
end

-- Compose a page into `dst` (a canvas-sized bitmap): the paper, optional
-- background picture, notebook ruling, then the ops. Without a template `bg_bb`
-- is the open document's page (a drawing's paper or picture, a notebook's
-- ruled paper); a template (a notebook page, or another drawing's paper)
-- paints its own. The master and the page
-- thumbnails both use it, so a thumbnail always matches its page.
-- `reveal_resolved` means the caller already built the reveal buffers (see
-- composeCanvas) and the reveal_pic and reveal_text it passed are final (nil when
-- not needed); otherwise composeInto builds its own, as the thumbnails do. With
-- `region` only that rect of dst is rebuilt (see composeRegion). With `keep` the
-- ops are drawn over what dst already holds (the layer caches, view/layers.lua).
function InkAwayView:composeInto(dst, ops, bg_bb, template, reveal_text, reveal_pic, reveal_resolved, bare, region, keep)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local found = Canvas.scanOps(ops)
    -- the paper, and the text on it: black, or white on a dark paper
    local paper
    if template then paper = Palette.paperRGB(template.paper) else paper = self:paperRGB() end
    local text_ink = Paint.inkOn(paper)
    -- a smudge reads the page around it, so a page with one is always built whole
    if found.smudge then region = nil end
    local page_copy, owns_bare = nil, false
    if region then
        local rw, rh = region.x1 - region.x0, region.y1 - region.y0
        -- (a lifted selection's card is drawn on the paper, with no bg_bb)
        local fill = Paint.uiFill(paper or { 255, 255, 255 })
        Paint.fillRect(dst, region.x0, region.y0, rw, rh, fill, Paint.isChromatic(fill))
        if bg_bb then dst:blitFrom(bg_bb, region.x0, region.y0, region.x0, region.y0, rw, rh) end
    elseif template then
        -- a notebook page composed on its own (a thumbnail): paper colour or the
        -- PDF page, then the ruling, as on the live page
        local pic = bg_bb
        paintPaper(dst, W, H, template, pic)
        local function pageCopy()
            if not page_copy then
                page_copy = Blitbuffer.new(W, H, dst:getType())
                page_copy:blitFrom(dst, 0, 0, 0, 0, W, H)
            end
            return page_copy
        end
        -- erasing reveals that paper (ruling included), never plain white; a hard
        -- erase reveals the bare paper, without the picture or PDF page
        if found.soft_erase and not reveal_pic then bg_bb = pageCopy() end
        if found.hard_erase and not bare then
            if pic then
                bare = Blitbuffer.new(W, H, dst:getType())
                paintPaper(bare, W, H, template, nil)
                owns_bare = true
            else
                bare = pageCopy()
            end
        end
    elseif not keep then
        dst:paintRect(0, 0, W, H, WHITE)
        if bg_bb then dst:blitFrom(bg_bb, 0, 0, 0, 0, W, H) end
    end
    -- reveal_pic: the plain page with the placed images on it, so a soft erase
    -- keeps them as it keeps the background. Built here from these ops when the
    -- caller passed none; dst holds the plain base at this point.
    local owns_rp = false
    if not reveal_resolved and not reveal_pic and found.image and found.soft_erase then
        reveal_pic = Blitbuffer.new(W, H, dst:getType())
        reveal_pic:blitFrom(dst, 0, 0, 0, 0, W, H)
        self:stampOps(reveal_pic, ops, "image")
        owns_rp = true
    end
    -- reveal_text: the page including its text, revealed by an erase that spares
    -- text (op.spare_text, fixed when the erase was drawn), so it removes ink but
    -- leaves text. A normal erase reveals the plain page and removes both.
    local owns_rt = false
    if not reveal_resolved and not reveal_text and found.text and found.spare_text then
        reveal_text = Blitbuffer.new(W, H, dst:getType())
        reveal_text:blitFrom(reveal_pic or dst, 0, 0, 0, 0, W, H)   -- keep images under it too
        self:stampOps(reveal_text, ops, "text", text_ink)
        owns_rt = true
    end
    -- the page without ink, for a smudge to tell ink from paper (see ink/smudge.lua)
    local smudge_base
    if found.smudge then smudge_base = self:smudgeBase(dst, ops, text_ink) end
    local refx, refy = Symmetry.canvasRefs(W, H)
    -- a selection being moved or resized is lifted off the page (it follows the
    -- finger on its own card, see view/selection.lua)
    local lifted = self._lifted
    for _, op in ipairs(ops) do
        if op.kind == "link" then   -- luacheck: ignore 542
            -- a link draws nothing into the page (see ink/links.lua)
        elseif not op.hidden and not (lifted and lifted[op]) and (not region or meets(op, region)) then
            local wash, wst = Wash.isWash(op)
            if op.kind == "text" then
                self:stampTextInto(dst, op, region, text_ink)   -- glyphs, drawn straight into dst (z-order)
            elseif op.kind == "image" then
                self:blitImageInto(dst, op, region)   -- placed picture, alpha-blended (z-order)
            elseif wash then
                self:washInto(dst, op, wst, region)   -- see-through pen, blended (z-order)
            elseif op.kind == "smudge" then
                if smudge_base then
                    Smudge.apply(Smudge.surfaceOf(dst), Smudge.surfaceOf(smudge_base), op, W, H)
                end
            else
                local put, fill_put
                if op.kind == "erase" and op.spare_text and reveal_text then
                    put = bgSpanWriter(dst, reveal_text, W, H, nil)  -- reveal page + text (+ images)
                elseif op.kind == "erase" and not op.ebg and (reveal_pic or bg_bb) then
                    put = bgSpanWriter(dst, reveal_pic or bg_bb, W, H, nil)  -- reveal page (+ images)
                elseif op.kind == "erase" and op.ebg and bare then
                    put = bgSpanWriter(dst, bare, W, H, nil)  -- notebook: bare paper, ruling kept
                else
                    put = spanWriter(dst, W, H, self:opColor(op, paper or false), nil)
                end
                if op.kind == "shape" and op.fill_color and not op.fill then
                    fill_put = Symmetry.wrap(inRegion(
                        spanWriter(dst, W, H, displayColor(self:shownInk(op.fill_color, paper),
                            op.fill_alpha or 255), nil), region),
                        op.sym, refx, refy)
                end
                -- (a mirrored stroke can reach the region from anywhere: drawn whole)
                local clip = (region and (op.sym == nil or op.sym == "off")) and region or nil
                Export.paintGeom(op, Symmetry.wrap(inRegion(put, region), op.sym, refx, refy), fill_put, clip)
            end
        end
    end
    if smudge_base then smudge_base:free() end
    if owns_rt then reveal_text:free() end
    if owns_rp then reveal_pic:free() end
    if page_copy then page_copy:free() end
    if owns_bare then bare:free() end
end

-- The page without ink (its paper, ruling and background as dst holds them now,
-- then the pictures and text of `ops`), which a smudge never picks up.
function InkAwayView:smudgeBase(dst, ops, text_ink)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local b = Blitbuffer.new(W, H, dst:getType())
    b:blitFrom(dst, 0, 0, 0, 0, W, H)
    self:stampOps(b, ops, "image")
    self:stampOps(b, ops, "text", text_ink)
    return b
end

-- Blend a see-through pen's stroke into dst (a canvas-sized bitmap), within
-- `region` when given. Its mask comes from the cache (see Wash.cachedMask).
function InkAwayView:washInto(dst, op, st, region)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local m = Wash.cachedMask(op, st, W, H)
    if not m then return end
    local shown = self:shownWash(op)
    if region then Wash.blendBB(dst, m, shown, st, region.x0, region.y0, region.x1, region.y1)
    else Wash.blendBB(dst, m, shown, st) end
end

-- The buffer the eraser reveals under the ink. In a notebook that is the paper
-- (colour, ruling and any PDF page), so erasing never removes the ruling; in a
-- drawing it is the background image, else its paper, or nil for white.
function InkAwayView:eraseRevealBB()
    -- in a layered drawing: the page without the active layer (view/layers.lua)
    if self.canvas.layers then return self:layerRest() end
    -- while protection is on, a live erase stroke spares text, so it reveals the
    -- page-with-text buffer; otherwise it reveals the plain page
    if self.text_erase_protect and self._reveal_text_bb then return self._reveal_text_bb end
    if self._reveal_pic_bb then return self._reveal_pic_bb end   -- keep placed images under a soft erase
    if self.notebook then return self._paper_bb end
    return self.bg_bb or self:plainPaperBB()
end

-- Draw the visible ops of one kind ("image" or "text") into `bb`, text in
-- `text_ink` (the open document's, see textInk, by default).
function InkAwayView:stampOps(bb, ops, kind, text_ink)
    for _, op in ipairs(ops) do
        if not op.hidden and op.kind == kind then
            if kind == "text" then self:stampTextInto(bb, op, nil, text_ink) else self:blitImageInto(bb, op) end
        end
    end
end

-- Keep self[field] as a canvas-sized copy of `base` (white when nil) with the
-- visible ops of `kind` drawn on it, or free it when it is not `needed`.
function InkAwayView:buildRevealBuffer(field, needed, base, kind)
    local bb = self[field]
    if not needed then
        if bb then bb:free(); self[field] = nil end
        return
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if bb and (bb:getWidth() ~= W or bb:getHeight() ~= H) then bb:free(); bb = nil end
    if not bb then
        bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
        self[field] = bb
    end
    if base then bb:blitFrom(base, 0, 0, 0, 0, W, H) else bb:paintRect(0, 0, W, H, WHITE) end
    self:stampOps(bb, self:drawnOps(), kind)
end

-- What a hard erase (Erase pictures on) reveals in a notebook: the bare paper,
-- colour and ruling, without the picture or PDF page. Without a picture that is
-- the paper buffer itself; with one, a second buffer is built on first use. In
-- a drawing it is its paper (nil on white).
function InkAwayView:barePaperBB()
    if not self.notebook then return self:plainPaperBB() end
    if not self.canvas_bb then return nil end
    if not self.bg_bb then
        if self._bare_paper_bb then self._bare_paper_bb:free(); self._bare_paper_bb = nil end
        return self._paper_bb
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local bp = self._bare_paper_bb
    local template = self.notebook:pageTemplate()
    if bp and (bp:getWidth() ~= W or bp:getHeight() ~= H or self._bare_paper_for ~= template) then
        bp:free(); bp = nil
    end
    if not bp then
        bp = Blitbuffer.new(W, H, self.canvas_bb:getType())
        paintPaper(bp, W, H, template, nil)
        self._bare_paper_bb, self._bare_paper_for = bp, template
    end
    return bp
end

-- Build the notebook paper (once per compose): paper colour or PDF page, then the
-- ruling on top. It is its own buffer so the eraser can restore it.
function InkAwayView:buildNotebookPaper()
    if not (self.notebook and self.canvas_bb) then
        if self._paper_bb then self._paper_bb:free(); self._paper_bb = nil end
        return
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._paper_bb and (self._paper_bb:getWidth() ~= W or self._paper_bb:getHeight() ~= H) then
        self._paper_bb:free(); self._paper_bb = nil
    end
    if not self._paper_bb then
        self._paper_bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
    end
    paintPaper(self._paper_bb, W, H, self.notebook:pageTemplate(), self.bg_bb)
    -- a template or paper change rebuilds the bare paper on next use
    if self._bare_paper_bb then self._bare_paper_bb:free(); self._bare_paper_bb = nil end
end

-- Rebuild the 1:1 master bitmap from the committed ops. The cost follows the ink
-- drawn, not the zoom; it runs on open, undo, clear and resize.
function InkAwayView:composeCanvas()
    if not self.canvas_bb then return end
    local ops = self:drawnOps()   -- (without a hidden layer's)
    local found = Canvas.scanOps(ops)
    -- a drawing's picture, else its paper (nil on white)
    local base, bare = self.bg_bb or self:plainPaperBB(), nil
    if found.hard_erase and not self.notebook then bare = self:barePaperBB() end
    if self.notebook then
        -- the paper (with ruling) is both the base and what the eraser reveals
        self:buildNotebookPaper()
        base = self._paper_bb
        if found.hard_erase then bare = self:barePaperBB() end
    end
    -- what the eraser reveals: _reveal_pic_bb is the page with the placed images
    -- (a soft erase keeps them); _reveal_text_bb adds the text, for an erase that
    -- spares it (protection is on now, or was when an erase was made)
    self:buildRevealBuffer("_reveal_pic_bb", found.image, base, "image")
    self:buildRevealBuffer("_reveal_text_bb", found.text and (self.text_erase_protect or found.spare_text),
        self._reveal_pic_bb or base, "text")   -- text reveal keeps images too
    self:composeInto(self.canvas_bb, ops, base, nil,
        self._reveal_text_bb, self._reveal_pic_bb, true, bare)   -- reveal buffers already resolved
    -- the whole master was rebuilt: resync the panel-order mirror on the next render
    self:markCanvasDirty(0, 0, self.view.canvas_w, self.view.canvas_h)
end

-- Rebuild only the canvas rect (x0, y0)-(x1, y1) of the master, from the ops
-- that reach it. It reuses composeCanvas's paper and reveal buffers, so it is
-- not for changes to pictures or text.
function InkAwayView:composeRegion(x0, y0, x1, y1)
    if not self.canvas_bb then return end
    local W, H = self.view.canvas_w, self.view.canvas_h
    x0, y0 = math.max(0, math.floor(x0)), math.max(0, math.floor(y0))
    x1, y1 = math.min(W, math.ceil(x1)), math.min(H, math.ceil(y1))
    if x1 <= x0 or y1 <= y0 then return end
    local base, bare = self.bg_bb or self:plainPaperBB(), nil
    local ops = self:drawnOps()
    local found = Canvas.scanOps(ops)
    if found.smudge then return self:composeCanvas() end
    if not self.notebook and found.hard_erase then bare = self:barePaperBB() end
    if self.notebook then
        if not self._paper_bb then return self:composeCanvas() end
        base = self._paper_bb
        if found.hard_erase then bare = self:barePaperBB() end
    end
    self:composeInto(self.canvas_bb, ops, base, nil, self._reveal_text_bb,
        self._reveal_pic_bb, true, bare, { x0 = x0, y0 = y0, x1 = x1, y1 = y1 })
    self:markCanvasDirty(x0, y0, x1, y1)
end

-- Stamp a committed op into the 1:1 master.
function InkAwayView:stampOpIntoCanvas(op)
    if not self.canvas_bb then return end
    if op.kind == "text" then
        self:stampTextInto(self.canvas_bb, op)
        -- glyph blits do not report a span bbox; resync the whole mirror (text is
        -- committed rarely, so the one full copy on the next render is cheap)
        self:markCanvasDirty(0, 0, self.view.canvas_w, self.view.canvas_h)
        return
    end
    if op.kind == "smudge" then return self:composeCanvas() end   -- it reads the page around it
    local wash, wst = Wash.isWash(op)
    if wash then
        self:washInto(self.canvas_bb, op, wst)
        local x0, y0, x1, y1 = Wash.box(op)
        if op.sym and op.sym ~= "off" then x0, y0, x1, y1 = 0, 0, self.view.canvas_w, self.view.canvas_h end
        self:markCanvasDirty(math.max(0, x0), math.max(0, y0), x1, y1)
        return
    end
    -- one acc grows over every span written (base and symmetry mirrors), so the
    -- panel-order mirror is resynced over exactly the op's footprint
    local cacc = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    local put = spanWriter(self.canvas_bb, self.view.canvas_w, self.view.canvas_h,
        self:opColor(op), cacc)
    local fill_put
    if op.kind == "shape" and op.fill_color and not op.fill then
        fill_put = spanWriter(self.canvas_bb, self.view.canvas_w, self.view.canvas_h,
            displayColor(self:shownInk(op.fill_color, self:paperRGB()), op.fill_alpha or 255), cacc)
    end
    if op.sym and op.sym ~= "off" then
        local refx, refy = Symmetry.canvasRefs(self.view.canvas_w, self.view.canvas_h)
        put = Symmetry.wrap(put, op.sym, refx, refy)
        if fill_put then fill_put = Symmetry.wrap(fill_put, op.sym, refx, refy) end
    end
    Export.paintGeom(op, put, fill_put)
    self:markCanvasDirtyAcc(cacc)
end

-- Show an op just stamped into canvas_bb by re-rendering only its rectangle of
-- area_bb (a full render costs tens of ms in landscape). A symmetric op lands in
-- several places and gets a full redraw. sx0..sy1 are the op's screen bounds.
function InkAwayView:renderCommittedOp(op, sx0, sy0, sx1, sy1)
    if op and op.sym and op.sym ~= "off" then
        self:redraw()
        return
    end
    local v = self.view
    local pad = (op and op.width or 1) + (op and op.head or 0) + 6
    local ax0 = math.min(sx0, sx1) - v.area_x - pad
    local ay0 = math.min(sy0, sy1) - v.area_y - pad
    local ax1 = math.max(sx0, sx1) - v.area_x + pad
    local ay1 = math.max(sy0, sy1) - v.area_y + pad
    self:renderViewRect(ax0, ay0, ax1, ay1)   -- small rotated write, not the whole area
    self:refreshAreaBox("ui", v.area_x + ax0, v.area_y + ay0, v.area_x + ax1, v.area_y + ay1)
end

return InkAwayView
