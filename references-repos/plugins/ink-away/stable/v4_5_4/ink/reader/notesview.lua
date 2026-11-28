--[[
Book notes: the book's notebook (ink/reader/booknotes.lua) in a window over the
page being read, with the book still showing around it. It is the canvas
itself, laid out small:

  * the page is the notebook's real page (the size of the screen, as every Ink
    Away page), shown whole at about two thirds of its size, so what is written
    in the window is the same page the app shows; Fullscreen turns this same
    view into the normal app, with nothing reopened;
  * the narrow toolbar down the left (ink/reader/vbar.lua), a strip with the
    chapter and the page number above the page;
  * opening it in a chapter goes to that chapter's last page, or to a new page
    titled with the chapter, put where the chapter comes in the book; a new
    page left empty is taken out again on closing;
  * a tap outside the window closes it, saved;
  * opened on one of the reader's highlights (a handwritten note on it, from
    ink/reader/hlnotes.lua), it goes to that highlight's page, or a new one after
    its chapter's pages, titled with the highlighted words; closing tells the book
    whether the note has ink (Book:linkHighlightNote). On a highlight's page the
    strip ends in a Highlight menu button: a tap on the strip opens KOReader's
    menu for that highlight (to delete it, among others).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local BookNotes = require("ink/reader/booknotes")
local InkAwayView = require("ink/view")
local Theme = require("ink/ui/theme")
local InkGeom = require("ink/geom")
local Library = require("ink/library")
local Project = require("ink/project")
local Search = require("ink/search")
local Storage = require("ink/storage")
local VBar = require("ink/reader/vbar")

local Screen = Device.screen

local NotesView = InkAwayView:extend{
    name = "inkaway_booknotes",
    over_book = true,    -- the reader keeps its orientation; no start sheets
    floating = true,     -- a window over the book, until Fullscreen
    book = nil,          -- ink/reader/book.lua
    behind_bb = nil,     -- the book's page as it was, shown around the window
    highlight = nil,     -- opened on a highlight's note: Book:highlightKey
}

-- The window uses the narrow toolbar; once full screen, the canvas's own.
NotesView.buildVBar = VBar.buildVBar
NotesView.vbarActive = VBar.vbarActive
NotesView.vbarHas = VBar.vbarHas
NotesView.vbarCell = VBar.vbarCell
for _i, k in ipairs({ "updateToolbarActive", "drawActiveToolPill", "drawToolbarIcons" }) do
    NotesView[k] = function(self, ...)
        if self.floating then return VBar[k](self, ...) end
        return InkAwayView[k](self, ...)
    end
end

local SCALE = 0.70        -- the page in the window, of its full size at most

function NotesView:init()
    InkAwayView.init(self)
    -- over a book the notes are what opens, never the library
    self._library_on_show, self._overview_on_show = nil, nil
end

-- The reader decides the orientation.
function NotesView:applyStartupOrientation() end
function NotesView:orientationSupported() return false end

------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------

function NotesView:initLayout(W, H)
    if not self.floating then return InkAwayView.initLayout(self, W, H) end
    self:layoutWindow()
end

-- The window: the toolbar, then the strip over the page shown whole, centred
-- on the screen.
function NotesView:layoutWindow()
    local W, H = self.screen_w, self.screen_h
    local strip = Screen:scaleBySize(30)
    local z = math.min(SCALE, (H * 0.94 - strip) / H)
    for _pass = 1, 2 do
        self._panel_h = math.floor(H * z) + strip
        self:buildToolbar()
        local room = (W * 0.96 - self._bar_w) / W   -- the toolbar beside the page must fit too
        if z <= room then break end
        z = room
    end
    local aw, ah = math.floor(W * z), math.floor(H * z)
    local pw, ph = self._bar_w + aw, strip + ah
    local px, py = math.floor((W - pw) / 2), math.floor((H - ph) / 2)
    self._panel = { x = px, y = py, w = pw, h = ph }
    self._strip = { x = px + self._bar_w, y = py, w = aw, h = strip }
    self._bar_x, self._bar_y = px, py
    self.view = {
        area_x = px + self._bar_w, area_y = py + strip, area_w = aw, area_h = ah,
        canvas_w = W, canvas_h = H,
        zoom = math.min(aw / W, ah / H), pan_x = 0, pan_y = 0,
    }
    self.zoom_min = self.view.zoom
    InkGeom.clampPan(self.view)
    self[1] = self.toolbar
end

function NotesView:buildToolbar()
    if not self.floating then return InkAwayView.buildToolbar(self) end
    local specs = {
        { id = "pen", icon = "pen", tool = true, cb = function()
            if self.tool == "pen" then self:openPenSettings() else self:setTool("pen") end
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
        { id = "prev", icon = "nav_prev", cb = function() self:nbGo(-1) end },
        { id = "next", icon = "nav_next", cb = function() self:nbGo(1) end },
        { id = "add", icon = "newpage", cb = function() self:nbAddPage() end },
        { id = "full", icon = "fullscreen", cb = function() self:expand() end },
        { id = "exit", icon = "exit", cb = function() self:closeCanvas() end },
    }
    self:buildVBar(specs, self._panel_h or self.screen_h)
end

-- In the window there is no page bar (the toolbar turns the pages) and no zoom.
function NotesView:nbBarHeight()
    if self.floating then return 0 end
    return InkAwayView.nbBarHeight(self)
end

function NotesView:recomputeArea()
    if not self.floating then return InkAwayView.recomputeArea(self) end
    self:layoutWindow()
    if self.area_bb then self.area_bb:free() end
    self.area_bb = self:newAreaBuffer()
end

function NotesView:relayout()
    if not self.floating then return InkAwayView.relayout(self) end
    self:recomputeArea()
    self:renderView()
    self._area_only = false
end

function NotesView:setToolbarHidden(hidden)
    if not self.floating then return InkAwayView.setToolbarHidden(self, hidden) end
end

function NotesView:setNbBarHidden(hidden)
    if not self.floating then return InkAwayView.setNbBarHidden(self, hidden) end
end

function NotesView:setZoom(...)
    if self.floating then return false end
    return InkAwayView.setZoom(self, ...)
end

function NotesView:pinchZoom(...)
    if not self.floating then return InkAwayView.pinchZoom(self, ...) end
end

function NotesView:panByScreen(...)
    if not self.floating then return InkAwayView.panByScreen(self, ...) end
end

-- No floating buttons in the window.
function NotesView:fabRect(which)
    if self.floating then return nil end
    return InkAwayView.fabRect(self, which)
end

function NotesView:fabHit(px, py)
    if self.floating then return nil end
    return InkAwayView.fabHit(self, px, py)
end

function NotesView:drawFabs(...)
    if not self.floating then return InkAwayView.drawFabs(self, ...) end
end

-- A turned screen lays the book out again: keep the notes and leave.
function NotesView:onSetDimensions()
    self:closeCanvas()
end

------------------------------------------------------------------------------
-- Painting the window
------------------------------------------------------------------------------

-- The book around the window, the window's frame, and the strip with the
-- chapter and the page number.
function NotesView:paintSurround(bb, x, y)
    if not self.floating then return InkAwayView.paintSurround(self, bb, x, y) end
    local W, H = self.screen_w, self.screen_h
    if self.behind_bb then bb:blitFrom(self.behind_bb, x, y, 0, 0, W, H)
    else bb:paintRect(x, y, W, H, Blitbuffer.COLOR_WHITE) end
    local p = self._panel
    local b = Screen:scaleBySize(2)
    bb:paintRect(x + p.x - b, y + p.y - b, p.w + 2 * b, p.h + 2 * b, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + p.x, y + p.y, p.w, p.h, Blitbuffer.COLOR_WHITE)
    local s = self._strip
    local menu = self:stripMenuButton()
    local tw = self:stripText(menu and menu.w + Screen:scaleBySize(8) or 0)
    if tw then
        local sz = tw:getSize()
        tw:paintTo(bb, x + s.x + Screen:scaleBySize(8), y + s.y + math.floor((s.h - sz.h) / 2))
    end
    if menu then
        local pad, r = Screen:scaleBySize(3), Screen:scaleBySize(4)
        local bx, by = x + s.x + s.w - menu.w - Screen:scaleBySize(6), y + s.y + pad
        local bh = s.h - 2 * pad
        bb:paintBorder(bx, by, menu.w, bh, Screen:scaleBySize(1), Blitbuffer.COLOR_BLACK, r)
        local sz = menu.text:getSize()
        menu.text:paintTo(bb, bx + math.floor((menu.w - sz.w) / 2), by + math.floor((bh - sz.h) / 2))
    end
    bb:paintRect(x + s.x, y + s.y + s.h - 1, s.w, 1, Blitbuffer.COLOR_GRAY_9)
    if Theme.invert() then bb:invertRect(x + s.x, y + s.y, s.w, s.h) end   -- dark: the strip is a control
end

-- The title the strip shows for page i: its own, else that of the page before
-- it with one (a page added by hand belongs to the chapter page before it).
local function titleFor(pages, i)
    for k = i, 1, -1 do
        local t = pages[k] and pages[k].title
        if t and t ~= "" then return t end
    end
end

-- "Chapter · 2/5", made again only when it changes; `room`: px kept free at its
-- right (the highlight's menu button).
function NotesView:stripText(room)
    local nb = self.notebook
    if not nb then return nil end
    local name = titleFor(nb.pages, nb.index) or self:docName()
    local text = string.format("%s \u{00B7} %d/%d", name, nb.index, nb:count())
    local max_w = self._strip.w - Screen:scaleBySize(16) - (room or 0)
    if self._strip_w and self._strip_text == text and self._strip_max == max_w then return self._strip_w end
    if self._strip_w then self._strip_w:free() end
    self._strip_text, self._strip_max = text, max_w
    self._strip_w = TextWidget:new{ text = text, face = Font:getFace("smallinfofont"), max_width = max_w }
    return self._strip_w
end

-- The reader's highlight the page shown is the note of: its place in the
-- reader's list (nil on any other page, or once the highlight is gone).
function NotesView:pageHighlightIndex()
    local nb = self.notebook
    local page = nb and nb.pages[nb.index]
    local hl = page and type(page.book) == "table" and page.book.hl
    if not (hl and self.book and self.book.findHighlight) then return nil end
    local ok, _anno, index = pcall(self.book.findHighlight, self.book, hl)
    return ok and index or nil
end

-- On a highlight's page the strip ends in a button for KOReader's menu for that
-- highlight (delete it, its colour, its typed note...): { w, text } or nil.
function NotesView:stripMenuButton()
    if not self:pageHighlightIndex() then return nil end
    if not self._strip_menu then
        local text = TextWidget:new{ text = _("Highlight menu"), face = Font:getFace("x_smallinfofont"),
            max_width = math.floor(self._strip.w * 0.45) }
        self._strip_menu = { text = text, w = text:getSize().w + Screen:scaleBySize(16) }
    end
    return self._strip_menu
end

function NotesView:freeStrip()
    if self._strip_w then self._strip_w:free(); self._strip_w = nil end
    if self._strip_menu then self._strip_menu.text:free(); self._strip_menu = nil end
end

-- A page turn changes the strip, which is chrome: paint it all.
function NotesView:nbLoad(...)
    InkAwayView.nbLoad(self, ...)
    if self.floating then self._paint_all = true; UIManager:setDirty(self, "ui") end
end

------------------------------------------------------------------------------
-- Touch
------------------------------------------------------------------------------

local function inRect(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- A tap outside the window closes it; on a highlight's page, a tap on the strip
-- opens KOReader's menu for that highlight.
function NotesView:onIaTap(arg, ges)
    if self.floating and ges and ges.pos and not inRect(ges.pos, self._panel) then
        self:closeCanvas()
        return true
    end
    if self.floating and ges and ges.pos and inRect(ges.pos, self._strip) then
        local book = self.book
        local index = self:pageHighlightIndex()
        if index then
            self:closeCanvas()
            UIManager:nextTick(function()
                local h = book.ui.highlight
                if h and h.showHighlightDialog then h:showHighlightDialog(index) end
            end)
            return true
        end
    end
    return InkAwayView.onIaTap(self, arg, ges)
end

-- A swipe that starts on the book around the window does nothing.
function NotesView:onIaSwipe(arg, ges)
    if self.floating and ges and ges.pos and not inRect(ges.pos, self._panel) then return true end
    return InkAwayView.onIaSwipe(self, arg, ges)
end

------------------------------------------------------------------------------
-- The book's notebook
------------------------------------------------------------------------------

-- The notebook the book's notes are in: the one it was last saved as (found
-- again when it was renamed or moved in the library since), else one named
-- after the book in the Book notes folder (with the author when another book
-- of that name has it).
function NotesView:notesPathFor(info)
    local linked = self.book:notesPath()
    if linked and Storage.exists(linked) then return linked end
    if linked then
        local found = self:findMovedNotes(linked, info.md5)
        if found then
            self.book:setNotesPath(found)
            return found
        end
    end
    local dir = self:bookNotesDir()
    local path = Storage.join(dir, BookNotes.fileName(info.title) .. "." .. Project.EXT)
    if Storage.exists(path) then
        local data = Project.load(path)
        if data and BookNotes.otherBook(data.pages, info.md5) then
            local name = BookNotes.fileName(info.author and (info.title .. " (" .. info.author .. ")") or info.title)
            path = Storage.join(dir, name .. "." .. Project.EXT)
            if Storage.exists(path) then
                local d2 = Project.load(path)
                if d2 and BookNotes.otherBook(d2.pages, info.md5) then
                    path = Storage.uniquePath(dir, name, Project.EXT)
                end
            end
        end
    end
    return path
end

-- Does the file at `path` hold `needle`? Read a piece at a time, so a big
-- notebook is not held whole just to look.
local function fileHas(path, needle)
    local f = io.open(path, "rb")
    if not f then return false end
    local tail = ""
    while true do
        local chunk = f:read(256 * 1024)
        if not chunk then break end
        local s = tail .. chunk
        if s:find(needle, 1, true) then f:close(); return true end
        tail = s:sub(-(#needle - 1))
    end
    f:close()
    return false
end

-- The book's notes, saved at `lost` before and not there now: their folder or
-- the notebook itself was renamed or moved in the library (#54). Looks through
-- the library's notebooks (not the trash) for the one whose chapter pages are
-- this book's (`md5`); for a book without a checksum, only a notebook of the
-- same name that is the only one and says it is for no book. Only reads.
function NotesView:findMovedNotes(lost, md5)
    local docs = {}
    for _i, e in ipairs(Search.walk(self:libraryDir(), Library.INTERNAL)) do
        if e.kind == "doc" then docs[#docs + 1] = e end
    end
    local order, name = BookNotes.searchOrder(docs, lost)
    if md5 then
        for _i, d in ipairs(order) do
            if fileHas(d.path, md5) then
                local data = Project.load(d.path)
                if data and BookNotes.ofBook(data.pages, md5) then return d.path end
            end
        end
        return nil
    end
    local same = {}
    for _i, d in ipairs(order) do
        if (d.path:match("([^/]+)$") or "") == name then same[#same + 1] = d end
    end
    if #same ~= 1 then return nil end
    local data = Project.load(same[1].path)
    if data and data.pages and not BookNotes.tagged(data.pages) then return same[1].path end
    return nil
end

function NotesView:openStartDocument()
    local info = self.book:notesInfo()
    local path = self:notesPathFor(info)
    if not (Storage.exists(path) and self:openDocument(path)) then
        self:startNotebook({ style = self.nb_style,
            size = self.nb_size or self.grid_size or 40,
            strength = self.nb_strength or self.grid_strength or 45 })
        self.doc_path, self.doc_written = path, false
        self:resetSaveState()
    end
    if self.notebook then
        if self.highlight then self:goToHighlight(info) else self:goToChapter(info) end
    end
end

-- The highlight's note: its page, or a new one titled with its words, after its
-- chapter's pages.
function NotesView:goToHighlight(info)
    local nb, hl = self.notebook, self.highlight
    local place = BookNotes.placeForHighlight(nb.pages, hl.key, hl)
    if place.index and not place.claim then return self:nbGoTo(place.index) end
    local tag = { toc = hl.key, md5 = info.md5, hl = { dt = hl.dt, pos0 = hl.pos0, pos1 = hl.pos1 } }
    local title = BookNotes.quote(hl.text)
    if place.claim then
        local p = nb.pages[1]
        p.book, p.title = tag, title
        self._fresh_page = p
        self:nbLoad()
    else
        local page = nb:newPage()
        page.title, page.book = title, tag
        local at = nb:insertPage(page, place.insert)
        self._fresh_page = page
        self:markDirty()
        self:nbGoTo(at)
    end
end

-- Has the highlight's note ink now (after closing, its page left empty went)?
function NotesView:highlightNoteHasInk()
    local nb, hl = self.notebook, self.highlight
    if not (nb and hl) then return false end
    for _i, p in ipairs(nb.pages) do
        if BookNotes.isNoteOf(p.book, hl) then return #(p.ops or {}) > 0 end
    end
    return false
end

-- The chapter's last page, or a new page for it in the book's order.
function NotesView:goToChapter(info)
    local nb = self.notebook
    local place = BookNotes.placeFor(nb.pages, info.key)
    local tag = info.key and { toc = info.key, md5 = info.md5 } or nil
    local title = info.chapter and info.chapter ~= "" and info.chapter or nil
    if place.claim then
        local p = nb.pages[1]
        p.book, p.title = tag, p.title or title
        self:nbLoad()
    elseif place.insert then
        local page = nb:newPage()
        page.title, page.book = title, tag
        local at = nb:insertPage(page, place.insert)
        self._fresh_page = page
        self:markDirty()
        self:nbGoTo(at)
    else
        self:nbGoTo(place.index)
    end
end

-- A chapter page opened for this visit goes again if it was left empty, with
-- the pages added by hand after it, as long as they are all empty: a page
-- written on keeps the chapter page it belongs to.
function NotesView:pruneFreshPage()
    local nb, page = self.notebook, self._fresh_page
    self._fresh_page = nil
    if not (nb and page) then return end
    self:nbSyncOut()
    local first
    for i, p in ipairs(nb.pages) do
        if p == page then first = i; break end
    end
    if not first then return end
    local last = first
    while nb.pages[last + 1] and not nb.pages[last + 1].book do last = last + 1 end
    if last - first + 1 >= nb:count() then return end   -- a notebook keeps a page
    for i = first, last do
        if #(nb.pages[i].ops or {}) > 0 then return end
    end
    for i = last, first, -1 do table.remove(nb.pages, i) end
    if nb.index > last then nb.index = nb.index - (last - first + 1)
    elseif nb.index >= first then nb.index = first - 1 end
    nb.index = math.max(1, math.min(nb.index, #nb.pages))
    -- the canvas follows, so the save that comes with closing keeps that page
    self.canvas:setOps(nb:currentOps())
    self._page_rev = self.canvas.rev
    self.dirty = true
end

-- The "Book notes" folder is made with the notebook's first save.
function NotesView:saveDocument(force)
    if self.doc_path and not self.doc_written then Storage.ensureDir(Storage.dirName(self.doc_path)) end
    return InkAwayView.saveDocument(self, force)
end

-- In the window the notes are not the app's last document; full screen they are.
function NotesView:rememberDoc(path)
    if not self.floating then return InkAwayView.rememberDoc(self, path) end
end

------------------------------------------------------------------------------
-- Full screen, and closing
------------------------------------------------------------------------------

-- The same view, now the normal app over the whole screen: its toolbar, page
-- bar and zoom, the same page.
function NotesView:expand()
    if not self.floating then return end
    self:flushPending()
    self:resetLasso()
    self.floating = false
    self._bar_x, self._bar_y = nil, nil
    if self.behind_bb then self.behind_bb:free(); self.behind_bb = nil end
    self:freeStrip()
    InkAwayView.initLayout(self, self.screen_w, self.screen_h)
    self.nb_bar_h = self:nbBarHeight()
    InkAwayView.recomputeArea(self)
    self:renderView()
    self:updateToolbarActive()
    if self.doc_written then InkAwayView.rememberDoc(self, self.doc_path) end
    self._paint_all = true
    UIManager:setDirty(self, "full")
end

function NotesView:onCloseWidget()
    local book = self.book
    if book and book._notes_view == self then book._notes_view = nil end   -- first (see ReaderInkView)
    self:pruneFreshPage()
    if self.notebook then self:nbSyncOut() end
    local has = self.highlight and self:highlightNoteHasInk()
    InkAwayView.onCloseWidget(self)
    if book and self.doc_written and self.doc_path then book:setNotesPath(self.doc_path) end
    if book and self.highlight then pcall(book.linkHighlightNote, book, self.highlight, has and self.doc_written) end
end

function NotesView:free()
    if self.behind_bb then self.behind_bb:free(); self.behind_bb = nil end
    self:freeStrip()
    InkAwayView.free(self)
end

return NotesView
