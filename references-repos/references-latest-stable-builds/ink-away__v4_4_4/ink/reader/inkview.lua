--[[
Annotating a book: the Ink Away canvas laid over the page being read. It is the
canvas itself (every pen, the eraser, shapes, text, pictures, the lasso, palm
rejection, gestures), started lean and laid out for a book:

  * its page is the screen at 1:1, its background the book's page as the reader
    draws it, and its ops the ink already on that page (ink/reader/book.lua);
  * a narrow toolbar runs down the left side, with the highlighter as a tool of
    its own and the book's page turns;
  * no zoom or pan: the book's own zoom is used;
  * the eraser takes whole strokes away, or (Erase whole strokes off) cuts the
    strokes it crosses into the parts left outside it (ink/cut.lua): ink on a
    book is kept as separate strokes anchored to its words, so a rubbed-out part
    cannot be a mask that would stay put while its stroke follows its word;
  * saving puts the page's ink back into the book, anchored (the canvas's
    autosave does it every few seconds of rest, a page turn and closing too).
Closing it leaves nothing running: the canvas's own close frees its buffers,
timers and input hooks.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("ink/l10n")
local Canvas = require("ink/canvas")
local InkAwayView = require("ink/view")
local ToggleRow = require("ink/ui/controls").ToggleRow
local VBar = require("ink/reader/vbar")

local Screen = Device.screen

local ReaderInkView = InkAwayView:extend{
    name = "inkaway_reader_view",
    reader_mode = true,
    over_book = true,    -- opened over a book: the reader keeps its orientation
    book = nil,          -- ink/reader/book.lua
}
VBar.into(ReaderInkView)

------------------------------------------------------------------------------
-- Start and layout
------------------------------------------------------------------------------

-- The reader decides the orientation.
function ReaderInkView:applyStartupOrientation() end
function ReaderInkView:orientationSupported() return false end

-- The side the toolbar runs along: down the left (the default) or right, or
-- across the top or bottom.
local SIDES = { left = true, right = true, top = true, bottom = true }
function ReaderInkView:toolbarSide()
    local s = self:getSetting("inkaway_book_toolbar_side", "left")
    return SIDES[s] and s or "left"
end

-- The toolbar along its side, the area beside it, the page at 1:1 under them:
-- a canvas point is the screen point, so ink lands exactly on the book's words.
function ReaderInkView:initLayout(W, H)
    self._bar_side = self:toolbarSide()
    self:buildToolbar()
    self.view = { canvas_w = W, canvas_h = H, zoom = 1 }
    self.zoom_min = 1
    -- hidden last time: start hidden
    self._toolbar_hidden = self:getSetting("inkaway_book_toolbar_hidden", false) and true or false
    self:placeToolbar()
end

-- Put the toolbar on its side (unless it is hidden) and the drawing area beside
-- it; the canvas is panned to the area's corner, so it stays 1:1 with the screen.
function ReaderInkView:placeToolbar()
    local v, W, H = self.view, self.screen_w, self.screen_h
    local side, t = self._bar_side, self._vb_thick or 0
    v.area_x, v.area_y, v.area_w, v.area_h = 0, 0, W, H
    self._bar_x, self._bar_y = 0, 0
    if not self._toolbar_hidden then
        if side == "left" then v.area_x, v.area_w = t, W - t
        elseif side == "right" then v.area_w = W - t; self._bar_x = W - t
        elseif side == "top" then v.area_y, v.area_h = t, H - t
        else v.area_h = H - t; self._bar_y = H - t end
    end
    v.pan_x, v.pan_y = v.area_x, v.area_y
    if self._toolbar_hidden then self[1] = nil else self[1] = self.toolbar end
end

-- After the toolbar moved or hid: a new on-screen buffer for the area, drawn.
function ReaderInkView:areaChanged()
    if self.area_bb then self.area_bb:free() end
    self.area_bb = self:newAreaBuffer()
    self:renderView()
    self._area_only = false
    self._paint_all = true
    UIManager:setDirty(self, "ui")
end

-- Move the toolbar to another side (from the book's settings).
function ReaderInkView:setToolbarSide(side)
    if not SIDES[side] or side == self._bar_side then return end
    self:flushPending()
    self:setSetting("inkaway_book_toolbar_side", side)
    self._bar_side = side
    self:buildToolbar()
    self:placeToolbar()
    self:areaChanged()
end

-- What the canvas would open (the last document) is the book's page here.
function ReaderInkView:openStartDocument()
    self.symmetry = "off"
    self.grid_on = false
    self.text_grid_snap = false  -- no ruling over a book (for this visit)
    self.snap_grid = false       -- no grid over a book (for this visit; the canvas keeps its setting)
    if self.pen_style == "smudge" then self:choosePenType("solid") end
    self:loadBookPage()
end

-- The page shown by the reader, and its ink.
function ReaderInkView:loadBookPage()
    local W, H = self.view.canvas_w, self.view.canvas_h
    if not self.bg_bb then self.bg_bb = Blitbuffer.new(W, H, Screen.bb:getType()) end
    self.book:snapshot(self.bg_bb)
    local placed = self.book:pageOps()
    local ops, from = {}, {}
    for i, op in ipairs(placed and placed.ops or {}) do
        local c = Canvas.cloneOp(nil, op)
        ops[i] = c
        from[c] = placed.items[i]
    end
    self._came_from = from
    self._shown = placed and placed.items or {}
    self.canvas:setOps(ops)
    self._committed_rev = self.canvas.rev
    self.dirty = false
end

------------------------------------------------------------------------------
-- Saving into the book
------------------------------------------------------------------------------

function ReaderInkView:docChanged()
    return self.canvas ~= nil and self.canvas.rev ~= self._committed_rev
end

-- Every change is anchored to the book at once (in memory; the file is written
-- by the autosave): anchoring reads the book's layout, which a turned screen
-- changes before anything here hears of it.
function ReaderInkView:markDirty()
    InkAwayView.markDirty(self)
    if self.book and self.canvas and self.canvas.rev ~= self._anchored_rev then
        local ok, map, shown = pcall(self.book.setPageOps, self.book, self.canvas.ops, self._came_from, self._shown)
        if ok then self._came_from, self._shown = map, shown end
        self._anchored_rev = self.canvas.rev
    end
end

function ReaderInkView:saveDocument()
    if not (self.book and self.canvas) or not self:docChanged() then return true end
    local ok, err = pcall(function()
        self._came_from, self._shown = self.book:setPageOps(self.canvas.ops, self._came_from, self._shown)
        self.book:save()
    end)
    if not ok then logger.warn("Ink Away: could not keep the page's ink:", err) end
    self._committed_rev = self.canvas.rev
    self.dirty = false
    return ok
end

------------------------------------------------------------------------------
-- The smart highlighter
------------------------------------------------------------------------------

-- A highlighter stroke along a line of text becomes the reader's own highlight
-- (unless the setting is off): the stroke goes, the highlight shows, and undo
-- and redo take it away and put it back like any stroke.
function ReaderInkView:takeStroke(op)
    if op.kind == "erase" then return self:cutWithEraser(op) end
    if not (op.kind == "ink" and op.style == "highlighter") then return false end
    if self:getSetting("inkaway_snap_text", true) == false then return false end
    local ok, item = pcall(self.book.highlight, self.book, op)
    if not (ok and item) then
        if not ok then logger.warn("Ink Away: highlight failed:", item) end
        return false
    end
    -- the stroke, out of the history as if never drawn; the highlight in its place
    self.canvas:undo()
    self.canvas.redo_stack = {}
    self.canvas:pushMark({ item = item })
    self:pageChanged()
    return true
end

-- A stroke of the eraser (not taking whole strokes): the strokes it crosses are
-- cut into the parts outside it, each anchored on its own when saved. One undo
-- step, as the stroke was.
function ReaderInkView:cutWithEraser(op)
    local Cut = require("ink/cut")
    self.canvas:undo()            -- the eraser's own stroke, as if never drawn
    self.canvas.redo_stack = {}
    local before = {}
    for i, o in ipairs(self.canvas.ops) do before[i] = o end
    local ops, changed = Cut.ops(self.canvas.ops, op.pts, (op.width or 1) / 2,
        { text = not self.text_erase_protect, pictures = self.erase_bg })
    -- the reader's highlights it crossed go too, in the same undo step (#21)
    local hls = self.book.highlightsAt and self.book:highlightsAt(op.pts, (op.width or 1) / 2) or {}
    if #hls > 0 then
        if changed then self.canvas.ops = ops end
        self:removeHighlights(hls, changed and before or nil, changed and ops or nil)
        return true
    end
    if changed then
        self.canvas:pushHistory()
        self.canvas.ops = ops
    end
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui")
    return true
end

function ReaderInkView:undoMark(mark)
    if mark.erased then   -- highlights an eraser or a hold took away: back, with the ink
        for i, it in ipairs(mark.erased) do
            local back = self.book:restoreHighlight(it)
            if back then mark.erased[i] = back end
        end
        if mark.before then self.canvas.ops = mark.before end
        self:pageChanged()
        return
    end
    if mark.item and self.book:removeHighlight(mark.item) then self:pageChanged() end
end

function ReaderInkView:redoMark(mark)
    if mark.erased then
        for _i, it in ipairs(mark.erased) do self.book:removeHighlight(it) end
        if mark.after then self.canvas.ops = mark.after end
        self:pageChanged()
        return
    end
    if not mark.item then return end
    local item = self.book:restoreHighlight(mark.item)
    if item then mark.item = item; self:pageChanged() end
end

-- Take the reader's highlights `items` off the book (#21: the eraser only
-- worked on ink, and a highlight could only go from KOReader's own menu once
-- Ink Away was closed): one undo step, with the ink the same stroke changed
-- (`before` and `after`, the page's ops then) when it did. Returns whether
-- anything went.
function ReaderInkView:removeHighlights(items, before, after)
    local gone = {}
    for _i, it in ipairs(items) do
        if self.book:removeHighlight(it) then gone[#gone + 1] = it end
    end
    if #gone == 0 and not before then return false end
    self.canvas.redo_stack = {}
    self.canvas:pushMark({ erased = gone, before = before, after = after })
    self:pageChanged()
    return #gone > 0
end

-- The whole-stroke eraser over a book: the highlights along its path go too,
-- in the same undo step as the strokes it took.
function ReaderInkView:wipeEnd()
    local w = self._wipe
    local path, removed = w and w.path, w and w.removed or 0
    InkAwayView.wipeEnd(self)
    if not (path and #path >= 2 and self.book.highlightsAt) then return end
    local hls = self.book:highlightsAt(path, (self.eraser_width or 1) / 2)
    if #hls == 0 then return end
    local before, after
    local top = removed > 0 and self.canvas.undo_stack[#self.canvas.undo_stack]
    if top and top.snap then
        table.remove(self.canvas.undo_stack)
        before = top.snap
        after = {}
        for i, o in ipairs(self.canvas.ops) do after[i] = o end
    end
    self:removeHighlights(hls, before, after)
end

-- A hold on a highlight with nothing of the ink under it (a navigating finger,
-- or the lasso): offer to take it away (#32's long press).
function ReaderInkView:highlightPromptAt(pos)
    if not (pos and self.book.highlightsAt) then return false end
    local items = self.book:highlightsAt({ pos.x, pos.y }, Screen:scaleBySize(3))
    if #items == 0 then return false end
    -- the highlighted words, cut short
    local quote
    if #items == 1 then
        local words, n = {}, 0
        for ch in tostring(items[1].text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            n = n + 1
            if n > 80 then words[#words + 1] = "\u{2026}"; break end
            words[#words + 1] = ch
        end
        quote = "\u{201C}" .. table.concat(words) .. "\u{201D}"
    end
    self:ask{ title = #items == 1 and _("Remove this highlight?") or _("Remove these highlights?"),
        text = quote, ok_text = _("Remove"), ok_icon = "trash",
        on_ok = function() self:removeHighlights(items) end }
    return true
end

function ReaderInkView:holdMenuAt(pos)
    if self:hitTestImage(pos.x, pos.y) or self:hitTestShape(pos.x, pos.y) or self:hitTestText(pos.x, pos.y) then
        return InkAwayView.holdMenuAt(self, pos)
    end
    self:highlightPromptAt(pos)
end

function ReaderInkView:selectAt(pos)
    if InkAwayView.selectAt(self, pos) then return true end
    return self:highlightPromptAt(pos)
end

-- The book's page changed under the ink (a highlight added or taken away):
-- draw it again, and the canvas over it.
function ReaderInkView:pageChanged()
    self.book:snapshot(self.bg_bb)
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui")
end

------------------------------------------------------------------------------
-- Turning the book's pages
------------------------------------------------------------------------------

function ReaderInkView:turnPage(dir)
    self:flushPending()
    self:cancelShape()
    if self.editing_text then self:finishTextEdit(true) end
    self:resetLasso()
    self:saveDocument()
    self.book:turn(dir)
    self:loadBookPage()
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "partial")
end

-- The canvas's page turns (a finger swipe with Finger on the page set to
-- Navigate, a two-finger swipe, the gestures) turn the book's pages.
function ReaderInkView:nbGo(dir) self:turnPage(dir) end
function ReaderInkView:pageSwipes() return true end
function ReaderInkView:sidewaysRoom() return false end

-- No zoom or pan over a book: the reader's own zoom is used.
function ReaderInkView:setZoom() return false end
function ReaderInkView:pinchZoom() end
function ReaderInkView:panByScreen() end

-- Gestures that mean pages or documents act on the book.
function ReaderInkView:runAction(id)
    if id == "next_page" then self:turnPage(1); return true end
    if id == "prev_page" then self:turnPage(-1); return true end
    if id == "browse" or id == "library" then self:openBookNotes(); return true end
    if id == "toolbar" then self:setToolbarHidden(not self._toolbar_hidden); return true end
    if id == "pan" or id == "fit" then return false end
    return InkAwayView.runAction(self, id)
end

-- Gestures named for what they do over a book; moving or fitting the page is
-- the reader's, so not offered.
function ReaderInkView:actionLabel(id)
    if id == "browse" or id == "library" then return _("Book notes") end
    return InkAwayView.actionLabel(self, id)
end

function ReaderInkView:actionOffered(id)
    return id ~= "pan" and id ~= "fit" and id ~= "library"
end

-- Sheets open beside the toolbar, so it stays in reach: right of it, left of
-- it, or under it.
function ReaderInkView:sheetLeftX()
    if self._toolbar_hidden or self._bar_side ~= "left" then return nil end
    return self._vb_thick
end

function ReaderInkView:sheetRightX()
    if self._toolbar_hidden or self._bar_side ~= "right" then return nil end
    return self.screen_w - (self._vb_thick or 0)
end

function ReaderInkView:sheetTopY()
    local t = (not self._toolbar_hidden and self._bar_side == "top") and (self._vb_thick or 0) or 0
    return t + Screen:scaleBySize(6)
end

-- Above a toolbar along the bottom.
function ReaderInkView:sheetBottomY()
    if self._toolbar_hidden or self._bar_side ~= "bottom" then return nil end
    return self.screen_h - (self._vb_thick or 0) - Screen:scaleBySize(6)
end

-- A new text box over a book starts where it was tapped (beside the toolbar,
-- at the least) and runs to the page's right edge; a tap too far right starts
-- it further left, so it is never a sliver.
function ReaderInkView:newTextAt(pos)
    local Text = require("ink/text")
    local v = self.view
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    local margin = math.max(6, math.floor(v.canvas_w * 0.02))
    local left, right = v.area_x + margin, v.area_x + v.area_w - margin
    local x = math.max(left, math.floor(cx))
    local min_w = math.floor((right - left) * 0.45)
    if right - x < min_w then x = math.max(left, right - min_w) end
    local size = self.text_size or math.max(16, math.floor(v.canvas_w / 32))
    local op = Text.new{ x = x, y = cy, w = right - x, size = size,
        font = self.text_font, align = "left" }
    self._text_tap_at = { op = op, x = math.floor(cx), y = cy }   -- where a turn on end starts it
    self:startTextEdit(op, { p = 1, o = 0 }, true, nil)
end

-- The book's notes (see ink/reader/booknotes.lua): leave the book's ink saved
-- and open them over the book.
function ReaderInkView:openBookNotes()
    local book = self.book
    self:closeCanvas()
    if book and book.openNotes then book:openNotes() end
end

-- A turned screen lays the book out again: keep the ink and leave.
function ReaderInkView:onSetDimensions()
    self:closeCanvas()
end

function ReaderInkView:onCloseWidget()
    -- the book lets go of this view first, so nothing that fails while closing
    -- can leave it thinking annotation mode is still open
    local book = self.book
    if book and book._view == self then book._view = nil end
    InkAwayView.onCloseWidget(self)
    if book then book:repaint() end
end

------------------------------------------------------------------------------
-- The toolbar, down the left side
------------------------------------------------------------------------------

-- The highlighter is a tool of its own here: the pen with the highlighter's
-- settings. The Pen goes back to the pen in hand before it, also when another
-- tool came in between (the highlighter is still the pen in hand then).
function ReaderInkView:highlighterActive()
    return self.tool == "pen" and self.pen_style == "highlighter"
end

function ReaderInkView:buildToolbar()
    local specs = {
        { id = "pen", icon = "pen", tool = true, cb = function()
            if self.pen_style == "highlighter" then
                if not self:swapPen() then self:choosePenType("solid") end
                self:setTool("pen"); self:refreshToolLabels()
            elseif self.tool == "pen" then self:openPenSettings()
            else self:setTool("pen") end
        end },
        { id = "highlight", icon = "highlighter", tool = true, cb = function()
            if self:highlighterActive() then self:openPenSettings()
            else self:choosePenType("highlighter"); self:setTool("pen"); self:refreshToolLabels() end
        end },
        { id = "erase", icon = "eraser", tool = true, cb = function()
            if self.tool == "erase" then self:openEraserSettings() else self:setTool("erase") end
        end },
        { id = "lasso", icon = "lasso", tool = true, cb = function() self:setTool("lasso") end },
        { id = "shape", icon = "shape", tool = true, cb = function()
            if self.tool == "shape" then self:openShapePicker() else self:setTool("shape") end
        end },
        { id = "text", icon = "text", tool = true, cb = function()
            if self.editing_text then self:finishTextEdit(true)
            elseif self.tool == "text" then self:openTextSettings()
            else self:setTool("text") end
        end },
        { id = "image", icon = "image", cb = function() self:chooseImage() end },
        { id = "undo", icon = "undo", cb = function() self:undo() end },
        { id = "redo", icon = "redo", cb = function() self:redo() end },
        { id = "prev", icon = "nav_prev", cb = function() self:turnPage(-1) end },
        { id = "next", icon = "nav_next", cb = function() self:turnPage(1) end },
        { id = "notes", icon = "booknotes", cb = function() self:openBookNotes() end },
        { id = "menu", icon = "menu", cb = function() self:openReaderSettings() end },
        { id = "exit", icon = "exit", cb = function() self:closeCanvas() end },
    }
    local across = self._bar_side == "top" or self._bar_side == "bottom"
    self:buildVBar(specs, across and Screen:getWidth() or Screen:getHeight(), self._bar_side, self:toolbarFit())
end

-- Is the toolbar sized to the book's margin (Book ink settings, off by default)?
function ReaderInkView:fitsMargin()
    return self:getSetting("inkaway_book_toolbar_fit", false) == true
end

-- The book's margin on `side`, in screen px, as the reader lays the text out:
-- its own margin setting, with the header above the text at the top and the
-- status bar under it at the bottom. nil for a book without margins of its
-- own (a PDF or a comic, whose margins are part of the page).
function ReaderInkView:bookMargin(side)
    local ui = self.book and self.book.ui
    local doc = ui and ui.document
    if not (doc and ui.rolling and doc.getPageMargins) then return nil end
    local ok, m = pcall(doc.getPageMargins, doc)
    if not (ok and type(m) == "table" and tonumber(m[side])) then return nil end
    local px = tonumber(m[side])
    if side == "top" and doc.getHeaderHeight then
        local okh, hh = pcall(doc.getHeaderHeight, doc)
        if okh and tonumber(hh) then px = px + tonumber(hh) end
    end
    return px
end

-- The toolbar's thickness when it fits the margin on its side, a little short of
-- the text (VBar.fitGap), or nil for the usual size (the setting off, or a book
-- without margins).
function ReaderInkView:toolbarFit()
    if not self:fitsMargin() then return nil end
    local m = self:bookMargin(self._bar_side or "left")
    return m and VBar.fitThickness(m - VBar.fitGap()) or nil
end

-- Turn the margin fit on or off (from the book's settings).
function ReaderInkView:setToolbarFit(on)
    self:flushPending()
    self:setSetting("inkaway_book_toolbar_fit", on and true or false)
    self:buildToolbar()
    self:placeToolbar()
    self:areaChanged()
end

-- The highlighter has its own button here.
function ReaderInkView:vbarActive()
    if self:highlighterActive() then return "highlight" end
    return VBar.vbarActive(self)
end

------------------------------------------------------------------------------
-- Hiding the toolbar
------------------------------------------------------------------------------

-- Over a book the only floating control is the toolbar's tab: a small chevron
-- beside the toolbar (it slides the toolbar away) or at that edge of the
-- screen once it is hidden (it brings it back): near the top of a side
-- toolbar, near the right end of one across the top or bottom. No zoom or Pan
-- buttons.
function ReaderInkView:fabRect(which)
    if which ~= "bar" or not self.view then return nil end
    local W, H = self.screen_w, self.screen_h
    local gap, len, wid, inset = Screen:scaleBySize(2), Screen:scaleBySize(40), Screen:scaleBySize(24), Screen:scaleBySize(8)
    local t = self._toolbar_hidden and 0 or (self._vb_thick or 0)
    local side = self._bar_side or "left"
    if side == "right" then return { x = W - t - gap - wid, y = inset, w = wid, h = len } end
    if side == "top" then return { x = W - inset - len, y = t + gap, w = len, h = wid } end
    if side == "bottom" then return { x = W - inset - len, y = H - t - gap - wid, w = len, h = wid } end
    return { x = t + gap, y = inset, w = wid, h = len }
end

function ReaderInkView:fabHit(px, py)
    if self._bar_toggle_hidden or self.editing_text then return nil end
    local r = self:fabRect("bar")
    if r and px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then return "bar" end
    return nil
end

-- The tab: a light rounded tab with a chevron pointing where the toolbar goes.
function ReaderInkView:drawFabs(bb)
    if self._bar_toggle_hidden or self.editing_text then return end
    local r = self:fabRect("bar")
    if not r then return end
    local fill, edge = Blitbuffer.Color8(0xF0), Blitbuffer.Color8(0xB4)
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, edge, Screen:scaleBySize(8))
    local b = Screen:scaleBySize(1)
    bb:paintRoundedRect(r.x + b, r.y + b, r.w - 2 * b, r.h - 2 * b, fill, Screen:scaleBySize(7))
    -- the chevron: two short strokes pointing to the toolbar's side while it is
    -- shown (hide it there) and away from it once hidden (bring it back)
    local cx, cy = r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2)
    local s = Screen:scaleBySize(6)
    local t = math.max(2, Screen:scaleBySize(2))
    local side = self._bar_side or "left"
    local toward = (side == "left" or side == "top") and -1 or 1   -- the toolbar's side: - left/up, + right/down
    local dir = self._toolbar_hidden and -toward or toward
    local across = side == "top" or side == "bottom"
    for i = 0, s do
        local a = -dir * math.floor(s / 2) + dir * i
        if across then
            bb:paintRect(cx - s + i, cy + a, t, t, Blitbuffer.COLOR_BLACK)
            bb:paintRect(cx + s - i - t + 1, cy + a, t, t, Blitbuffer.COLOR_BLACK)
        else
            bb:paintRect(cx + a, cy - s + i, t, t, Blitbuffer.COLOR_BLACK)
            bb:paintRect(cx + a, cy + s - i - t + 1, t, t, Blitbuffer.COLOR_BLACK)
        end
    end
end

-- Slide the toolbar away (or back): the page then fills the screen.
function ReaderInkView:setToolbarHidden(hidden)
    if (self._toolbar_hidden or false) == hidden then return end
    self:flushPending()
    self._toolbar_hidden = hidden
    self:setSetting("inkaway_book_toolbar_hidden", hidden)
    self:placeToolbar()
    self:areaChanged()
end

------------------------------------------------------------------------------
-- The book's settings
------------------------------------------------------------------------------

function ReaderInkView:openReaderSettings()
    if self:rebuildSheet("_settings_dialog") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local function closeSelf() self:closeSheet("_settings_dialog") end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Book ink"), content_w, _("Done"), closeSelf, nil, {
            { icon = "appearance", cb = function() closeSelf(); self:openAppearance() end },
            { label = _("Guide"), cb = function() self:openGuide() end } }))
        add(VerticalSpan:new{ width = Screen:scaleBySize(12) })
        add(ToggleRow:new{ label = _("Show ink while reading"), is_on = self:getSetting("inkaway_book_ink", true) ~= false,
            width = content_w, parent = menu,
            callback = function(on) self:setSetting("inkaway_book_ink", on) end })
        add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
        add(ToggleRow:new{ label = _("Highlighter snaps to the text"),
            is_on = self:getSetting("inkaway_snap_text", true) ~= false,
            width = content_w, parent = menu,
            callback = function(on) self:setSetting("inkaway_snap_text", on) end })
        add(VerticalSpan:new{ width = Screen:scaleBySize(4) })
        add(self:sheetHint(_("A highlighter stroke over text becomes the reader's own highlight of it, in the pen's colour: in your highlights list, and with the text at any font size. Over empty space it stays ink."), content_w))
        add(VerticalSpan:new{ width = Screen:scaleBySize(14) })
        add(self:sheetLabel(_("Toolbar")))
        add(VerticalSpan:new{ width = Screen:scaleBySize(6) })
        add(self:segmentedRow({ { "left", _("Left") }, { "right", _("Right") }, { "top", _("Top") },
                { "bottom", _("Bottom") } }, self._bar_side, content_w,
            function(side) closeSelf(); self:setToolbarSide(side); self:openReaderSettings() end))
        add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
        add(ToggleRow:new{ label = _("Fit the toolbar in the margin"), is_on = self:fitsMargin(),
            width = content_w, parent = menu,
            callback = function(on) self:setToolbarFit(on) end })
        add(VerticalSpan:new{ width = Screen:scaleBySize(4) })
        add(self:sheetHint(_("The toolbar takes the width of the book's margin on its side, with its icons sized to it, so it stays clear of the text. Widen the margins in the reader's settings to give it more room. PDFs and comics keep the usual size."), content_w))
        -- (Pen and input is in the Pen sheet, where the pen is)
        add(VerticalSpan:new{ width = Screen:scaleBySize(14) })
        add(self:actionButton(_("Export\u{2026}"), content_w, function()
            closeSelf(); self:openExport() end, nil, nil, "export"))
        add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
        add(self:actionButton(_("Gestures and pen buttons"), content_w, function()
            closeSelf(); self:openGestureSettings() end))
        add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
        add(self:actionButton(_("Refresh the screen"), content_w, function()
            closeSelf(); self:refreshScreen() end))
        if self.book and self.book:hasInk() then
            add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
            add(self:actionButton(_("Delete all annotations on this book\u{2026}"), content_w, function()
                closeSelf(); self:confirmDeleteBookInk() end))
        end
        return content
    end
    self:showSheet("_settings_dialog", build)
end

-- Deleting every annotation on the book takes two confirmations; they then
-- wait in Ink Away's trash for 30 days.
function ReaderInkView:confirmDeleteBookInk()
    self:ask{ field = "_delete_ink", title = _("Delete all annotations?"),
        text = _("Everything you drew, wrote and placed on this book goes, on every page. Highlights the highlighter turned into the reader's own stay, and so do the book's notes."),
        ok_text = _("Continue"), on_ok = function()
            self:ask{ field = "_delete_ink", title = _("Are you sure?"),
                text = _("All of this book's annotations will be deleted now. They wait in Ink Away's trash for 30 days in case you want them back."),
                ok_text = _("Delete"), ok_icon = "trash", on_ok = function() self:deleteBookInk() end }
        end }
end

-- Move the book's annotations to the trash and show the page without them; the
-- annotation mode stays open on the empty page, with nothing to undo.
function ReaderInkView:deleteBookInk()
    self:flushPending()
    self:cancelShape()
    if self.editing_text then self:finishTextEdit(true) end
    self:resetLasso()
    self:saveDocument()
    local item, err = self.book:trashInk(self:libraryDir())
    if not item then
        self:tell(_("Could not delete the annotations.\n") .. tostring(err))
        return
    end
    self:loadBookPage()
    self._anchored_rev = self.canvas.rev
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui")
    self:tell(_("This book's annotations wait in Ink Away's trash for 30 days. To put them back: Ink Away's library, its menu, Trash."),
        { title = _("Moved to the trash"), field = "_delete_ink" })
end

-- The gear in the canvas's sheets opens these over a book.
function ReaderInkView:openSettings() self:openReaderSettings() end

return ReaderInkView
