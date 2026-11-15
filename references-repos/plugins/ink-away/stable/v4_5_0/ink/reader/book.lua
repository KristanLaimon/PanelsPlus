--[[
Ink Away in the book being read: one of these per open book (made by main.lua
in KOReader's reader). It keeps the book's ink (ink/reader/bookink.lua), knows
where it goes on the page shown (ink/reader/place.lua), paints it over the page
while reading (a KOReader view module), and opens the annotation mode
(ink/reader/inkview.lua).

It costs nothing on a book without ink: opening the book only checks whether
the ink file exists, and painting a page then returns at once. With ink, the
items of the page shown are found from an index built once per layout, and
placed once per page.
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local BookInk = require("ink/reader/bookink")
local Canvas = require("ink/canvas")
local Place = require("ink/reader/place")
local Rooms = require("ink/reader/rooms")
local Snap = require("ink/reader/snap")

local Screen = Device.screen

local Book = {}
Book.__index = Book

-- The book open in each reader (weakly: a closed reader goes).
Book.by_ui = setmetatable({}, { __mode = "k" })

-- `integration` (ink/integration.lua): the viewer plugins that can show its pages.
function Book.new(ui, integration)
    local self = setmetatable({ ui = ui, rev = 0, integration = integration }, Book)
    Book.by_ui[ui] = self
    -- the book's KOReader folder (see ink/reader/bookink.lua for where)
    local file = ui.document and ui.document.file
    local ok, where = pcall(BookInk.locate, file)
    if ok and where then self.sidecar, self.dirs = where.dir, where.dirs
    else logger.warn("Ink Away: could not find the book's folder:", where) end
    self.has_file = self.sidecar ~= nil and BookInk.exists(self.sidecar)
    return self
end

-- The book's ink, read the first time it is needed.
function Book:data()
    if not self._data then
        self._data = self.has_file and BookInk.load(self.sidecar) or BookInk.new()
    end
    return self._data
end

function Book:hasInk()
    if self._data then return #self._data.items > 0 end
    return self.has_file
end

function Book:save()
    local data = self:data()
    if data.read_only then return end
    local dirs = { self.sidecar }
    for _i, d in ipairs(self.dirs or {}) do if d ~= self.sidecar then dirs[#dirs + 1] = d end end
    local kept = BookInk.saveAny(dirs, data)
    if kept then self.sidecar = kept
    else
        logger.warn("Ink Away: could not save the book's ink in", self.sidecar)
        if not self._save_warned then
            self._save_warned = true
            local _ = require("ink/l10n")
            require("ink/view").tellAnywhere(_("Ink Away could not save this book's ink: its folder can't be written to."))
        end
    end
    self.has_file = kept ~= nil and not BookInk.empty(data)
    if kept then
        local ok, Sync = pcall(require, "ink/sync/manager")   -- (cloud sync: a change is waiting to be sent)
        if ok then pcall(Sync.bookSaved) end
    end
    return kept ~= nil
end

------------------------------------------------------------------------------
-- The book, as place.lua asks about it
------------------------------------------------------------------------------

-- The adapter between place.lua and KOReader's document and view (Book:doc; while
-- annotation mode is on a viewer plugin's surface, the surface's, see setSurface).
function Book:readerDoc()
    if self._doc then return self._doc end
    local ui = self.ui
    local document, view = ui.document, ui.view
    local d = {}
    if ui.paging then
        d.kind = "paging"
        function d.toPage(_, x, y)
            local pos = view:screenToPageTransform({ x = x, y = y })
            if not (pos and pos.page) then return nil end
            -- (each page of a spread can have its own scale, which the position gives)
            local zoom = not view.page_scroll and pos.zoom or (view.state and view.state.zoom) or 1
            return pos.page, pos.x, pos.y, zoom
        end
        -- the page's place on the screen, as the reader draws it (its own
        -- transform gives nothing for a point just off the screen, which
        -- would hide a stroke that starts above the visible part)
        function d.toScreen(_, page, px, py)
            if view.page_scroll then
                local y = 0
                for _i, st in ipairs(view.page_states or {}) do
                    if st.page == page then
                        return st.offset.x + px * st.zoom - st.visible_area.x,
                            y + st.offset.y + py * st.zoom - st.visible_area.y, st.zoom
                    end
                    y = y + st.visible_area.h + (view.page_gap and view.page_gap.height or 0)
                end
                return nil
            end
            if self:spreadPages() then
                local ox, oy, s = self:spreadOrigin(page)
                if not ox then return nil end
                return ox + px * s, oy + py * s, s
            end
            local st = view.state
            if not (st and st.page == page and view.visible_area) then return nil end
            return st.offset.x + px * st.zoom - view.visible_area.x,
                st.offset.y + py * st.zoom - view.visible_area.y, st.zoom
        end
    else
        d.kind = "rolling"
        function d.width() return Screen:getWidth() end
        function d.size() return Screen:getWidth(), Screen:getHeight() end
        function d.pageCount()
            local ok, n = pcall(document.getPageCount, document)
            return ok and n or nil
        end
        function d.wordAt(_, x, y)
            local ok, w = pcall(document.getWordFromPosition, document, { x = x, y = y }, true)
            if ok and w and w.sbox and w.pos0 then return { xp0 = w.pos0, xp1 = w.pos1, box = w.sbox } end
        end
        function d.nearestWord(_, x, y)
            if not document.getNearestWordAndBoxFromPosition then return nil end
            local ok, w = pcall(document.getNearestWordAndBoxFromPosition, document, { x = x, y = y })
            if ok and w and w.sbox and w.pos0 then return { xp0 = w.pos0, xp1 = w.pos1, box = w.sbox } end
        end
        function d.pageTop() return document:getXPointer() end
        function d.pageOf(_, xp)
            local ok, p = pcall(document.getPageFromXPointer, document, xp)
            return ok and p or nil
        end
        -- a word a hyphen splits over two lines comes with the box of both
        -- lines together: the part nearest (x, y) instead, and which it is
        function d.partOf(_, w, x, y)
            local ok, boxes = pcall(document.getScreenBoxesFromPositions, document, w.xp0, w.xp1, true)
            if not (ok and boxes and #boxes > 1) then return w end
            local best, bd
            for k, b in ipairs(boxes) do
                local dx = math.max(b.x - x, 0, x - (b.x + b.w))
                local dy = math.max(b.y - y, 0, y - (b.y + b.h))
                local dd = dx * dx + dy * dy
                if not bd or dd < bd then best, bd = k, dd end
            end
            return { xp0 = w.xp0, xp1 = w.xp1, box = boxes[best], seg = best }
        end
        -- the word's box (part `seg` of a split word; the whole word, or what
        -- of it is on the screen, when it is not split now)
        function d.boxOf(_, xp0, xp1, seg)
            local ok, boxes = pcall(document.getScreenBoxesFromPositions, document, xp0, xp1, true)
            if not (ok and boxes and #boxes > 0) then return nil end
            return boxes[math.min(seg or 1, #boxes)]
        end
        -- room made in the text (see "Room" below)
        function d.roomAt(_, x0, y0, x1, y1) return self:roomAt(x0, y0, x1, y1) end
        function d.roomBox(_, id) return self:roomBox(id) end
        function d.roomPage(_, id) return self:roomPage(id) end
        function d.roomX(_, id) return self:roomX(id) end
    end
    self._doc = d
    return d
end

-- The page shown now (the first, when more than one is): Book:currentPage.
function Book:readerPage()
    local ui = self.ui
    if ui.paging then return ui.view.state and ui.view.state.page or ui.paging.current_page end
    local ok, p = pcall(ui.document.getCurrentPage, ui.document)
    return ok and p or nil
end

-- The pages of the spread shown, when a fixed-page book shows two side by side
-- (Ink Away's own two pages, or another plugin's, such as MuPDFtwoPages): nil for
-- one page. The view says, as it does for KOReader's highlights; both replace the
-- method on this book's view, so a book showing one page isn't even asked.
function Book:spreadPages()
    local view = self.ui.view
    local list = rawget(view, "getCurrentPageList")
    if not list or view.page_scroll or not self.ui.paging then return nil end
    local pages = list(view)
    if pages and #pages > 1 then return pages end
    return nil
end

-- Where page `page` of the spread is: the screen place of its top-left corner, and
-- its scale. Asked for the whole page, as the view gives nothing for a point off
-- the screen, and it knows each page's crop, gutter and scale.
function Book:spreadOrigin(page)
    local ui = self.ui
    local ok, dims = pcall(ui.document.getNativePageDimensions, ui.document, page)
    if not (ok and dims and dims.w and dims.w > 0) then return nil end
    local r = ui.view:pageToScreenTransform(page, { x = 0, y = 0, w = dims.w, h = dims.h })
    if not (r and r.x and r.w) then return nil end
    return r.x, r.y, r.w / dims.w
end

-- Can what is drawn be pinned to its page (kept at its spot on that page number
-- whatever the text does)? Only in a reflowing book showing one page at a time.
function Book:canPin()
    local ui = self.ui
    if ui.paging then return false end
    if ui.view and ui.view.view_mode == "scroll" then return false end
    return #self:visiblePages() == 1
end

-- Every page on the screen: one, or two side by side, or the pages a
-- continuous scroll shows (Book:visiblePages).
function Book:readerPages()
    local ui = self.ui
    if ui.paging then
        local view = ui.view
        if view.page_scroll and view.page_states and #view.page_states > 0 then
            local pages = {}
            for _i, st in ipairs(view.page_states) do pages[#pages + 1] = st.page end
            return pages
        end
        return self:spreadPages() or { self:readerPage() }
    end
    local p = self:readerPage()
    if not p then return {} end
    local doc = ui.document
    local two = (ui.view and ui.view.view_mode == "scroll")
        or (doc.getVisiblePageCount and doc:getVisiblePageCount() == 2)
    if two and p < (doc:getPageCount() or p) then return { p, p + 1 } end
    return { p }
end

-- What changes where a page's ink goes: for a reflowing book its layout (font,
-- margins, size...), for a fixed-page one its zoom and position on the screen
-- (Book:layoutKey).
function Book:readerLayoutKey()
    local ui = self.ui
    if ui.paging then
        local view = ui.view
        local parts = { "p", Screen:getWidth(), Screen:getHeight() }
        local states = view.page_scroll and view.page_states or { view.state or {} }
        for _i, st in ipairs(states) do
            local va = view.page_scroll and st.visible_area or view.visible_area or {}
            local off = st.offset or {}
            parts[#parts + 1] = table.concat({ st.page or 0, st.zoom or 0, st.rotation or 0,
                va.x or 0, va.y or 0, off.x or 0, off.y or 0 }, ",")
        end
        -- (a spread: where each of its pages is, which its crop and gutter change)
        local spread = self:spreadPages()
        if spread then
            for _i, page in ipairs(spread) do
                local ox, oy, s = self:spreadOrigin(page)
                parts[#parts + 1] = table.concat({ page, ox or 0, oy or 0, s or 0 }, ",")
            end
        end
        return table.concat(parts, "|")
    end
    local ok, hash = pcall(ui.document.getDocumentRenderingHash, ui.document, false)
    local top = ui.view and ui.view.view_mode == "scroll" and ui.document:getCurrentPos() or ""
    return table.concat({ "r", ok and tostring(hash) or "", ui.document:getPageCount() or 0,
        Screen:getWidth(), Screen:getHeight(), top }, "|")
end

-- The book as the reader shows it. A book whose annotation mode is on a viewer
-- plugin's surface answers these for the surface instead (setSurface), so the
-- reader's own way costs nothing more than it always did.
Book.doc, Book.currentPage, Book.visiblePages, Book.layoutKey =
    Book.readerDoc, Book.readerPage, Book.readerPages, Book.readerLayoutKey

-- The items on the pages shown, as screen ops with the item each came from:
-- { ops = {...}, items = {...} }. Cached until the page, the layout or the ink
-- changes. `on`: a viewer plugin's surface, or false for KOReader's own view
-- (nil: whichever annotation mode is on).
function Book:pageOps(on)
    if not self:hasInk() then return nil end
    local s = on
    if s == nil then s = self.surface end
    if s then return self:surfaceOps(s) end
    local data = self:data()
    local pages = self:readerPages()
    local layout = self:readerLayoutKey()
    local key = table.concat({ table.concat(pages, ","), layout, self.rev }, "#")
    local c = self._placed
    if c and c.key == key then return c end
    local doc = self:readerDoc()
    -- the page index is built once per layout (for a fixed-page book it is just
    -- the page numbers, so it does not depend on the zoom; for a reflowing one
    -- the scroll position, the layout key's last part, does not count)
    if layout ~= self._layout_last then
        self._layout_last = layout
        self._ikey_base = doc.kind == "paging" and "paging" or (layout:gsub("|[^|]*$", ""))
    end
    local ikey = self._ikey_base .. "#" .. self.rev
    if not (self._index and self._index_key == ikey) then
        self._index = Place.index(data.items, doc)
        self._index_key = ikey
    end
    local out = { key = key, pages = pages, ops = {}, items = {} }
    local W, H = Screen:getWidth(), Screen:getHeight()
    for _p, page in ipairs(pages) do
        for _i, item in ipairs(self._index[page] or {}) do
            local ok, op = pcall(Place.place, item, doc)
            if ok and op and op.kind == "image" then op.path = BookInk.picturePath(self.sidecar, op.path) end
            -- only what reaches the screen (a page scrolled half away keeps
            -- the rest of its ink out of the way, untouched)
            local x0, y0, x1, y1
            if ok and op then x0, y0, x1, y1 = Canvas.opBox(op) end
            if x0 and x1 >= 0 and y1 >= 0 and x0 < W and y0 < H then
                out.ops[#out.ops + 1] = op
                out.items[#out.items + 1] = item
            end
        end
    end
    self._placed = out
    return out
end

-- Replace the ink shown (`shown`, the items the annotation mode was given) with
-- `ops` (screen ops). An op that came back unchanged keeps its item (and its
-- anchor), so ink never drifts from being opened and closed again; ink that
-- was not shown is never touched. Returns the item of each op and the items
-- now shown, for the next time the page is saved.
function Book:setPageOps(ops, came_from, shown)
    local data = self:data()
    local doc = self:doc()
    local keep, map = {}, {}
    local shape_anchor = {}   -- a cut shape's anchor, shared by its pieces
    for _i, op in ipairs(ops) do
        -- (an eraser stroke, a link or a smudge is never kept over a book: the
        -- eraser cuts strokes instead, see ink/cut.lua)
        local k = op.kind
        local src = op.cut_of
        if src then op.cut_of = nil end   -- a passing note, never saved
        local item = came_from and came_from[op]
        if not item and (k == "erase" or k == "link" or k == "smudge") then item = false end
        if item == nil and src then
            local a = shape_anchor[src]
            if not a then
                local base = (came_from and came_from[src]) or Place.anchor(src, doc)
                a = base and base.a or false
                shape_anchor[src] = a
            end
            if a then item = Place.anchorWith(op, doc, a) end
        end
        if item == nil and op.pin and self:canPin() then
            item = Place.pinned(op, doc, self:visiblePages()[1])   -- pinned: it keeps this page number
        end
        if item == nil then
            item = Place.anchor(op, doc)
            -- a picture is kept in the book's folder, so the book's ink never
            -- loses it (see ink/reader/bookink.lua)
            if item and item.op.kind == "image" then item.op.path = BookInk.keepPicture(self.sidecar, item.op.path) end
        end
        if item then keep[#keep + 1] = item; map[op] = item end
    end
    local old, n_old = {}, 0
    for _i, item in ipairs(shown or {}) do
        if not old[item] then old[item] = true; n_old = n_old + 1 end
    end
    local items = {}
    for _i, item in ipairs(data.items) do if not old[item] then items[#items + 1] = item end end
    for _i, item in ipairs(keep) do items[#items + 1] = item end
    data.items = items
    -- the page index follows, changed only on the pages shown, so it is not
    -- built again for the whole book after every stroke (it is when an old
    -- item is not where it was expected)
    local idx = self._index
    if idx then
        local page_of, found = {}, 0
        for _p, p in ipairs(self:visiblePages()) do
            local l = idx[p]
            if l then
                local rest = {}
                for _i, it in ipairs(l) do
                    if old[it] then page_of[it] = p; found = found + 1 else rest[#rest + 1] = it end
                end
                idx[p] = rest
            end
        end
        if found < n_old then
            idx = nil
        else
            for _i, it in ipairs(keep) do
                local p = page_of[it] or Place.pageOf(it, doc)
                if p then
                    local l = idx[p]
                    if not l then l = {}; idx[p] = l end
                    l[#l + 1] = it
                end
            end
        end
    end
    self.rev = self.rev + 1
    self._index = idx
    if idx and self._ikey_base then self._index_key = self._ikey_base .. "#" .. self.rev end
    self._placed = nil
    return map, keep
end

------------------------------------------------------------------------------
-- Room made in the text (see ink/reader/rooms.lua)
------------------------------------------------------------------------------

-- The rooms made in this book (none in a fixed-page one).
function Book:rooms()
    if self.ui.paging or not (self.has_file or self._data) then return {} end
    return self:data().rooms or {}
end

-- Are the rooms shown (they can all be hidden for plain reading)?
function Book:roomsShown()
    if not (self.has_file or self._data) then return true end
    return not self:data().rooms_off
end

-- The room with this id as the book lays it out now, if it is shown: a box room
-- is made of paragraphs in a render mode that does not float (Rooms.asParagraphs).
function Book:roomById(id)
    if not self:roomsShown() then return nil end
    for _i, r in ipairs(self:rooms()) do
        if r.id == id then
            if r.kind == "box" and not (self:floats() and self:roomsReady()) then return Rooms.asParagraphs(r) end
            return r
        end
    end
end

-- Does the book's render mode float things (book and web do; legacy and flat lay
-- floats out as plain blocks)? Box rooms are exact there.
function Book:floats()
    local ts = self.ui.typeset
    local mode = ts and tonumber(ts.block_rendering_mode)
    if mode == nil then
        local c = self.ui.document and self.ui.document.configurable
        mode = tonumber(c and c.block_rendering_mode)
    end
    return mode == nil or mode >= 2
end

-- Has the book its markers (laid out once with them, see ink/reader/rooms.lua)?
function Book:roomsReady()
    if self.ui.paging or not (self.has_file or self._data) then return false end
    return self:data().rooms_ready == true
end

-- CSS pixels per screen pixel: KOReader's "Zoom (dpi)" scales the book's pixels
-- (1 at its default of 96, or when it is off).
function Book:cssScale()
    local c = self.ui.document and self.ui.document.configurable
    local dpi = tonumber(c and c.render_dpi)
    if not dpi or dpi <= 0 or dpi == 96 then return 1 end
    return 96 / dpi
end

-- The style rules that make the rooms, for KOReader's style tweaks (main.lua
-- adds them), or nil. Reads the book's ink file only when there is one.
function Book:roomsCss()
    if self.ui.paging or not (self.has_file or self._data) then return nil end
    local data = self:data()
    local ready = data.rooms_ready == true
    local shown = not data.rooms_off and data.rooms and #data.rooms > 0
    if not (shown or ready) then return nil end
    -- (a book with markers keeps them, its rooms hidden or gone: taking them out
    -- would need the book loaded again)
    local list = shown and data.rooms or {}
    if self._hidden_room and shown then
        list = {}
        for _i, r in ipairs(data.rooms or {}) do if r.id ~= self._hidden_room then list[#list + 1] = r end end
    end
    local css = Rooms.css(list, self:cssScale(), { ready = ready, floats = self:floats(), inline = ready and data.room_marks == 2 })
    return css ~= "" and css or nil
end

-- Lay the book out without room `id` (nil: with all of them again), while the
-- Make room tool changes it: its box and what is in it stay where they are.
function Book:hideRoom(id)
    if self._hidden_room == id then return end
    self._hidden_room = id
    self:relayout()
end

-- Can room be made here? In a reflowing book showing one page at a time (as
-- pinning).
function Book:canRoom()
    return not self.ui.paging and self:canPin()
end

-- The page's text area on the screen: { x0, y0, x1, y1 }.
function Book:textArea()
    local document = self.ui.document
    local W, H = Screen:getWidth(), Screen:getHeight()
    local ok, m = pcall(document.getPageMargins, document)
    m = ok and type(m) == "table" and m or {}
    local hok, header = pcall(document.getHeaderHeight, document)
    header = hok and tonumber(header) or 0
    return { x0 = m.left or 0, y0 = (m.top or 0) + header, x1 = W - (m.right or 0), y1 = H - (m.bottom or 0) }
end

-- Where a paragraph's text starts (its first word), as an xpointer. The same
-- in any layout, so it is kept.
function Book:textStartOf(elem)
    self._text_starts = self._text_starts or {}
    local c = self._text_starts[elem]
    if c ~= nil then return c or nil end
    local document = self.ui.document
    local found
    local ok, x = pcall(document.getNextVisibleWordStart, document, elem)
    if ok and type(x) == "string" and x:sub(1, #elem + 1) == elem .. "/" then found = x end
    if not found then
        local cand = elem .. "/text().0"
        local iok, inside = pcall(document.isXPointerInDocument, document, cand)
        if iok and inside then found = cand end
    end
    self._text_starts[elem] = found or false
    return found
end

-- The paragraphs on the page shown, top to bottom (Rooms.blocksFromWords), found
-- once per page and layout from its words.
function Book:pageBlocks()
    local page = self:currentPage()
    if not page or self.ui.paging then return {} end
    local key = self:layoutKey() .. "#" .. page
    local c = self._blocks
    if c and c.key == key then return c.list end
    local document = self.ui.document
    local area = self:textArea()
    local words = {}
    local beyond   -- (the first word after the page's: in which paragraph it is)
    pcall(function()
        local start = document:getPageXPointer(page)
        local stop = page < document:getPageCount() and document:getPageXPointer(page + 1) or nil
        -- (the page may begin inside a word: from that word's start)
        local xp = document:getNextVisibleWordStart(start)
        local before = xp and document:getPrevVisibleWordStart(xp)
        if before then xp = before end
        local lh
        for _n = 1, 4000 do
            if not xp then break end
            if stop and (document:compareXPointers(xp, stop) or 0) <= 0 then beyond = xp; break end
            local y = document:getScreenPositionFromXPointer(xp)
            if y and y > area.y1 then beyond = xp; break end
            if y and y >= area.y0 - 2 then
                if not lh then
                    local bok, boxes = pcall(document.getScreenBoxesFromPositions, document, xp,
                        document:getNextVisibleWordEnd(xp), false)
                    lh = bok and boxes and boxes[1] and boxes[1].h or nil
                end
                words[#words + 1] = { xp = xp, y = y, h = lh or 0 }
            end
            local nxt = document:getNextVisibleWordStart(xp)
            if not nxt or nxt == xp then break end
            xp = nxt
        end
    end)
    local list = Rooms.blocksFromWords(words, function(elem, first)
        -- the page's first paragraph began here if its first word is the page's first
        return self:textStartOf(elem) == first
    end, function(elem)
        return not beyond or Rooms.blockOf(beyond) ~= elem
    end)
    if self:floats() then self:findIndents(list, words) end
    if self:inlineMarks() then self:findAnchors(list, words) end
    self._blocks = { key = key, list = list, words = words, first = words[1] and words[1].xp, last = words[#words] and words[#words].xp }
    return list
end

-- The paragraphs starting on the page whose first word is indented: where it is
-- (ex) and their second line (ny0, nl1), as Rooms.spots takes them: a box too wide
-- to share the first line with the indent starts on the second.
function Book:findIndents(blocks, words)
    local document = self.ui.document
    local by = {}
    for _i, b in ipairs(blocks) do if b.starts then by[b.xp] = b end end
    local seen = {}
    for i, w in ipairs(words) do
        local block = Rooms.blockOf(w.xp)
        local b = block and by[block]
        if b and not seen[block] then
            seen[block] = true
            pcall(function()
                local boxes = document:getScreenBoxesFromPositions(w.xp, document:getNextVisibleWordEnd(w.xp), false)
                b.ex = boxes and boxes[1] and boxes[1].x
            end)
            for j = i + 1, #words do
                local n = words[j]
                if Rooms.blockOf(n.xp) ~= block then break end
                if n.y > w.y then b.ny0, b.nl1 = n.y, n.y + (n.h or 0); break end
            end
        end
    end
end

-- Is the book laid out with markers on its inline elements too (Rooms.INLINE_MARKERS)?
-- Books given their first room from this version on are; books given one before
-- keep the markers they have (adding these would need the book loaded again).
function Book:inlineMarks()
    if not self:roomsReady() or not self:floats() then return false end
    return self:data().room_marks == 2
end

-- The inline elements beginning inside the page's paragraphs (not at a
-- paragraph's first word, where its own marker is): each block's anchors, top to
-- bottom, { xp, y0, l1 (the top and bottom of the line it begins on), ex (where on
-- it), at_start (it begins the line), ny0, nl1 (the next line's, in its paragraph
-- on this page) }. Whether a box's float there starts on that line or the next
-- depends on the box (Rooms.spots).
function Book:findAnchors(blocks, words)
    local by = {}
    for _i, b in ipairs(blocks) do by[b.xp] = b end
    local prev_inline
    local function nextLine(i)
        local y = words[i].y
        for j = i + 1, #words do
            if words[j].y > y then return words[j] end
        end
    end
    for i, w in ipairs(words) do
        local block = Rooms.blockOf(w.xp)
        local b = block and by[block]
        local path = w.xp:gsub("/text%(%).*$", ""):gsub("%.%d+$", "")
        local inline = b and path ~= block and path or nil
        if inline and inline ~= prev_inline and self:textStartOf(block) ~= w.xp then
            -- the outermost inline element that begins at this word (one that
            -- began before it may hold one that begins here)
            local rest = inline:sub(#block + 1)
            local cur = block
            for seg in rest:gmatch("/[^/]+") do
                cur = cur .. seg
                if Rooms.isInline(cur) and self:textStartOf(cur) == w.xp then
                    local at_start = not (i > 1 and words[i - 1].y == w.y)
                    local ex
                    local document = self.ui.document
                    pcall(function()
                        local boxes = document:getScreenBoxesFromPositions(w.xp, document:getNextVisibleWordEnd(w.xp), false)
                        ex = boxes and boxes[1] and boxes[1].x
                    end)
                    local nx = nextLine(i)
                    if nx and Rooms.blockOf(nx.xp) ~= block then nx = nil end
                    if ex or at_start then
                        b.anchors = b.anchors or {}
                        b.anchors[#b.anchors + 1] = { xp = cur, y0 = w.y, l1 = w.y + (w.h or 0), ex = ex,
                            at_start = at_start, ny0 = nx and nx.y, nl1 = nx and (nx.y + (nx.h or 0)) }
                    end
                    break
                end
            end
        end
        prev_inline = inline
    end
end

-- Where a marker is on the page, as an xpointer to ask the document about: a
-- paragraph's is the paragraph (its top); an inline element's is its first word
-- (its line). A room whose float starts a line further down (nl, Rooms.spots) is
-- that many pixels below it: the words of the line it starts on are moved by it.
function Book:markerPos(xp)
    if Rooms.isInline(xp) then return self:textStartOf(xp) end
    return xp
end

-- The lines of text on the page shown, as the reader lays them out: { { x, y, w,
-- h }, ... } (a line split by something beside it can be two). Found once per page
-- and layout.
function Book:pageLines()
    self:pageBlocks()
    local c = self._blocks
    if not c then return {} end
    if c.segs then return c.segs end
    c.segs = {}
    if c.first and c.last then
        local document = self.ui.document
        pcall(function()
            local stop = document:getNextVisibleWordEnd(c.last) or c.last
            c.segs = document:getScreenBoxesFromPositions(c.first, stop, true) or {}
        end)
    end
    return c.segs
end

-- Fit box room `r`'s float to the text laid out beside it (Book:calibrateBox), as
-- many times as the text asks, a few at most: text that re-wraps around a wider
-- float can come up to it again (ragged text shows its column's edge only where
-- a line reaches it).
function Book:fitBox(r)
    for _i = 1, 4 do
        if not self:calibrateBox(r) then return end
        self:setRooms(self:rooms(), self:data().rooms_off)
    end
end

-- The lines beside box `box` (the room's side of them): where each starts, for a
-- box at the left, or ends, for one at the right.
local function besideEdges(lines, side, box)
    local out = {}
    for _i, b in ipairs(lines) do
        if b.y < box.y + box.h and b.y + b.h > box.y then
            out[#out + 1] = math.floor((side == "left" and b.x or (b.x + b.w)) + 0.5)
        end
    end
    return out
end

-- Where most of `edges` are, a pixel either way (glyphs end a little apart), when
-- at least two and most of them are there (ragged text ends anywhere).
local function mostAt(edges)
    local count = {}
    for _i, e in ipairs(edges) do count[e] = (count[e] or 0) + 1 end
    local best, bn
    for e in pairs(count) do
        local n = (count[e - 1] or 0) + count[e] + (count[e + 1] or 0)
        if not bn or n > bn or (n == bn and e < best) then best, bn = e, n end
    end
    return (bn or 0) >= math.max(2, math.ceil(#edges * 0.6)) and best or nil
end

-- Where the side of a box room's float is, from the lines beside its box `box`:
-- they start just after a box at the left, and end just before one at the right
-- (most of them: a paragraph's last line ends short, a first line may be
-- indented). nil when no line says.
function Book:floatEdge(r, box)
    if r.side ~= "left" and r.side ~= "right" then return nil end
    return mostAt(besideEdges(self:pageLines(), r.side, box))
end

-- Box room `r` laid out now: does the text keep out of its box, and come up to it?
-- A paragraph's own column (side margins, a hanging indent that takes its first
-- line further out) is only known once laid out: the float is widened where text
-- still reaches into the box, or narrowed where most lines stop short of it. Its
-- box stays the box drawn. Returns whether it changed (the book is then to be laid
-- out again).
function Book:calibrateBox(r)
    if r.side ~= "left" and r.side ~= "right" then return false end
    local box = self:boxRect(r, true)
    if not box then return false end
    local edges = besideEdges(self:pageLines(), r.side, box)
    if #edges == 0 then return false end
    local cw = r.cw or r.w
    local d = r.side == "left" and (box.x + box.w) or box.x
    local grow = 0
    if r.side == "left" then
        local m = math.huge
        for _i, e in ipairs(edges) do m = math.min(m, e) end
        if m < d - 1 then grow = d - m + 1
        else
            local most = mostAt(edges)
            if most and most > d + 1 then grow = d - most end
        end
    else
        local m = -math.huge
        for _i, e in ipairs(edges) do m = math.max(m, e) end
        if m > d + 1 then grow = m - d + 1
        else
            local most = mostAt(edges)
            if most and most < d - 1 then grow = most - d end
        end
    end
    if grow == 0 or cw + grow < Rooms.MIN_BOX then return false end
    r.cw = cw + grow
    return true
end

-- The page shown, as Rooms.planBox takes it: its text area, paragraphs, the left
-- and right of its text column (where most lines start, where the longest end),
-- the bottom of its last line, and the markers rooms use (but room `except`'s).
function Book:pageModel(except)
    local area = self:textArea()
    local blocks = self:pageBlocks()
    local c = self._blocks or {}
    local model = { area = area, blocks = blocks, cl = area.x0, cr = area.x1, bottom = area.y1, used = {} }
    local document = self.ui.document
    if c.first and c.last then
        pcall(function()
            local segs = self:pageLines()
            local lefts, best, right, bottom = {}, nil, nil, nil
            for _i, b in ipairs(segs) do
                local l = math.floor(b.x + 0.5)
                lefts[l] = (lefts[l] or 0) + 1
                if not best or lefts[l] > lefts[best] or (lefts[l] == lefts[best] and l < best) then best = l end
                right = math.max(right or 0, b.x + b.w)
                bottom = math.max(bottom or 0, b.y + b.h)
            end
            if best then model.cl = math.max(area.x0, best) end
            if right then model.cr = math.min(area.x1, math.floor(right + 0.5)) end
            if bottom then model.bottom = math.min(area.y1, bottom) end
            -- each paragraph's own column (a box room's marker sits in it: a
            -- paragraph in a block with side margins is narrower than the page's)
            for _i, bl in ipairs(blocks) do
                local ls, n, lb, rmax = {}, 0, nil, nil
                for _j, b in ipairs(segs) do
                    if b.y >= bl.y0 - 1 and b.y < bl.y1 - 1 then
                        n = n + 1
                        if b.y > bl.y0 + 1 or not bl.starts then   -- (a first line may be indented)
                            local l = math.floor(b.x + 0.5)
                            ls[l] = (ls[l] or 0) + 1
                            if not lb or ls[l] > ls[lb] or (ls[l] == ls[lb] and l < lb) then lb = l end
                        end
                        rmax = math.max(rmax or 0, b.x + b.w)
                    end
                end
                if n >= 2 and lb then
                    bl.cl = math.max(area.x0, lb)
                    bl.cr = math.min(area.x1, math.floor(rmax + 0.5))
                end
            end
        end)
    end
    -- the other box rooms: their markers, and where those are in the page's order
    -- (before it: -1; after it: past every one on it)
    local index, anchor_slot = {}, {}
    for i, b in ipairs(blocks) do index[b.xp] = i end
    for _i, s in ipairs(Rooms.spots(blocks)) do anchor_slot[s.xp] = s.slot end
    local function key(xp, pseudo)
        if Rooms.isInline(xp) and anchor_slot[xp] then return anchor_slot[xp] end
        local i = index[xp]
        if i then return Rooms.slot(i, pseudo) end
        local ok, below = pcall(function()
            return document:compareXPointers(c.last or c.first, self:textStartOf(xp) or xp) == 1
        end)
        return (ok and below) and math.huge or -1
    end
    model.rooms = {}
    for _i, r in ipairs(self:rooms()) do
        if r.kind == "box" and r.id ~= except then
            model.used[r.xp .. "::before"] = true
            if r.sp then model.used[r.sp .. "::" .. (r.spp or "after")] = true end
            local box = self:roomBox(r.id)
            if box then
                local top = box.y - (r.off or 0)
                model.rooms[#model.rooms + 1] = { side = r.side, top = top, bottom = box.y + box.h,
                    x0 = box.x, x1 = box.x + box.w, b = key(r.xp, "before"),
                    s = r.sp and key(r.sp, r.spp or "after") or nil }
            end
        end
    end
    return model
end

-- What a box drawn on the page makes (Rooms.planBox where the render mode floats,
-- else a room of whole paragraphs, Rooms.plan), with `except` the room being
-- changed. Returns the room, the box it keeps, the area it frees; or nil and why.
function Book:planRoom(rect, except)
    if self:floats() then
        local room, box, free, loose = Rooms.planBox(rect, self:pageModel(except))
        -- where no room starts at the box's top, a word of that line wrapped does
        if (loose or (not room and box == "no_break")) and self:exactOn() then
            local r2, b2, f2 = self:exactPlan(rect, except)
            if r2 then return r2, b2, f2 end
        end
        return room, box, free, loose
    end
    local room, box = Rooms.plan(rect, self:pageBlocks(), self:textArea())
    return room, box, box
end

-- A box drawn where no room can start as drawn, moved to the nearest place on the
-- page where one does (Rooms.snapTop; `keep` "height" or "bottom"), or nil when it
-- is fine as it is, or nothing near would be. Only where the render mode floats
-- (rooms of whole paragraphs have no such places).
function Book:snapRoomRect(rect, keep, except)
    if not self:floats() then return nil end
    local snapped = Rooms.snapTop(rect, self:pageModel(except), keep)
    -- (with exact lines on, a word of the top line is wrapped instead: no move)
    if snapped and self:exactOn() and self:exactPlan(rect, except) then return nil end
    return snapped
end

-- Where a box room's marker is pushed down from: the last word of the paragraph
-- before its own (the top of that line), or its own paragraph's first word.
function Book:boxAnchor(r)
    -- (with nothing pushing it down, the marker is at the top of its paragraph:
    -- the paragraph's own top, which stays where it is when a box across the
    -- page moves its first line below it)
    if not r.sp then return self:markerPos(r.xp), tonumber(r.nl) or 0 end
    -- (pushed from the start of a paragraph above, or of an inline element: its line's top)
    if r.spp == "before" then return self:markerPos(r.sp), r.sh or 0 end
    -- (the paragraph before its own ends: the box's own paragraph's first word)
    local ts = self:textStartOf(Rooms.isInline(r.xp) and Rooms.blockOf(r.xp) or r.xp)
    if not ts then return nil end
    local document = self.ui.document
    local ok, prev = pcall(document.getPrevVisibleWordStart, document, ts)
    if not (ok and prev) then return nil end
    return prev, r.sh or 0
end

-- The page a box room's top is on.
function Book:boxPage(r)
    local anchor, push = self:boxAnchor(r)
    if not anchor then return nil end
    local document = self.ui.document
    local ok, p = pcall(function()
        local top = document:getPosFromXPointer(anchor) + push + (r.off or 0)
        local page = document:getPageFromXPointer(anchor)
        local n = document:getPageCount()
        for _i = 1, 4 do
            if page >= n then break end
            local nxt = document:getPosFromXPointer(document:getPageXPointer(page + 1))
            if not nxt or nxt > top then break end
            page = page + 1
        end
        return page
    end)
    return ok and p or nil
end

-- A box room's box on the screen, wherever its page is: { x, y, w, h }.
-- On the page shown, a side box goes where its float is (the lines beside it
-- say: the column can move with the font), unless `as_kept`.
function Book:boxRect(r, as_kept)
    local anchor, push = self:boxAnchor(r)
    if not anchor then return nil end
    local document = self.ui.document
    local ok, y = pcall(document.getScreenPositionFromXPointer, document, anchor)
    if not (ok and y) then return nil end
    local box = { x = r.x, y = y + push + (r.off or 0), w = r.w, h = r.h }
    if not as_kept and r.id ~= self._hidden_room and (r.side == "left" or r.side == "right") then
        local area = self:textArea()
        if box.y >= area.y0 - 1 and box.y < area.y1 then
            -- (the float is cw wide; the box keeps its far edge, w from the column's)
            local e = self:floatEdge(r, box)
            local cw = r.cw or r.w
            if e then box.x = r.side == "left" and (e - cw) or (e + cw - r.w) end
        end
    end
    return box
end

-- The page a room is on (its first paragraph's), or nil when it is hidden.
function Book:roomPage(id)
    local r = self:roomById(id)
    if not r then return nil end
    if r.kind == "box" then return self:boxPage(r) end
    local ts = self:textStartOf(r.xp)
    if not ts then return nil end
    local ok, p = pcall(self.ui.document.getPageFromXPointer, self.ui.document, ts)
    return ok and p or nil
end

-- The left edge of a side room on the screen (the band's too).
function Book:roomX(id)
    local r = self:roomById(id)
    if not r then return nil end
    if r.kind == "box" then return r.x end
    local a = self:textArea()
    if r.kind == "side" and r.side == "right" then return a.x1 - r.w end
    return a.x0
end

-- A room's box on the page shown: { x, y, w, h }, or nil when it is not on it.
-- Side space shows beside the paragraphs it covers on this page.
function Book:roomBox(id)
    local r = self:roomById(id)
    if not r then return nil end
    -- (the book's first room, before the book is loaded again with it: the box as
    -- planned, so what is put in it is kept with the room, not with the words;
    -- the reader loaded again has a Book of its own, without it)
    local held = self._held_box
    if r.kind == "box" and held and held.id == id then
        local b = held.box
        return { x = b.x, y = b.y, w = b.w, h = b.h }
    end
    if r.kind == "box" then
        local cur = self:currentPage()
        if not cur or self:boxPage(r) ~= cur then return nil end
        return self:boxRect(r)
    end
    local a = self:textArea()
    if r.kind == "band" then
        local ts = self:textStartOf(r.xp)
        if not ts then return nil end
        local document = self.ui.document
        local ok, p = pcall(document.getPageFromXPointer, document, ts)
        if not (ok and p) then return nil end
        local shown = false
        for _i, v in ipairs(self:visiblePages()) do if v == p then shown = true end end
        if not shown then return nil end
        local yok, y = pcall(document.getScreenPositionFromXPointer, document, ts)
        if not (yok and y) then return nil end
        return { x = a.x0, y = y - r.h, w = a.x1 - a.x0, h = r.h }
    end
    local want = {}
    for _i, x in ipairs(r.xps or { r.xp }) do want[x] = true end
    local y0, y1
    for _i, b in ipairs(self:pageBlocks()) do
        if want[b.xp] then
            y0 = y0 and math.min(y0, b.y0) or b.y0
            y1 = y1 and math.max(y1, b.y1) or b.y1
        end
    end
    if not y0 then return nil end
    return { x = self:roomX(id), y = y0, w = r.w, h = y1 - y0 }
end

-- Until the book is loaded again for its first room `id`, its box is `box`, the
-- one planned (see Book:roomBox): before that, the room is not laid out, and its
-- box from the old layout is not where it will be.
function Book:holdBox(id, box)
    self._held_box = box and { id = id, box = { x = box.x, y = box.y, w = box.w, h = box.h } } or nil
end

-- The boxes of the rooms on the page shown: { { room, box }, ... }.
function Book:roomBoxes()
    local out = {}
    if not self:roomsShown() then return out end
    for _i, r in ipairs(self:rooms()) do
        local b = self:roomBox(r.id)
        if b then out[#out + 1] = { room = r, box = b } end
    end
    return out
end

-- The room whose box holds the middle of the box (x0, y0)-(x1, y1), and that box.
function Book:roomAt(x0, y0, x1, y1)
    local rooms = self:rooms()
    if #rooms == 0 or not self:roomsShown() then return nil end
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    for _i, e in ipairs(self:roomBoxes()) do
        local b = e.box
        if e.room.id ~= self._no_rooms and cx >= b.x and cx <= b.x + b.w and cy >= b.y and cy <= b.y + b.h then return e.room, b end
    end
end

-- Lay the book out again with the rooms as they are now (KOReader keeps the
-- reading position), and forget what was placed for the old layout.
function Book:relayout()
    self._blocks, self._index, self._placed = nil, nil, nil
    self.rev = self.rev + 1
    local Event = require("ui/event")
    self.ui:handleEvent(Event:new("ApplyStyleSheet"))
    local document = self.ui.document
    pcall(document.getPageCount, document)
    -- With KOReader's partial re-layout (on by default), a part of the book is
    -- laid out again only when a page of it is drawn, and until then everything
    -- asked of it is from the old layout. The page shown is drawn here (off the
    -- screen), and KOReader is told, as after its own drawing.
    local dok, delayed = pcall(document.isRerenderingDelayed, document)
    local view, rolling = self.ui.view, self.ui.rolling
    if dok and delayed and view and view.visible_area and rolling and rolling.handlePartialRerendering then
        pcall(function()
            self._scratch_bb = self._scratch_bb or require("ffi/blitbuffer").new(1, 1)
            document:drawCurrentView(self._scratch_bb, 0, 0, view.visible_area)
            rolling:handlePartialRerendering()
        end)
    end
    -- (markers that came with the rooms, from the cloud: the book loaded again)
    if self:roomsReady() then
        local sok, stale = pcall(document.isBuiltDomStale, document)
        if sok and stale then UIManager:nextTick(function() self:checkMarkers() end) end
    end
end

-- A book whose rooms need markers it is not laid out with (KOReader builds a
-- book's elements when it loads it) is loaded again with them.
function Book:checkMarkers()
    if not self:roomsReady() or self._reloading then return end
    local document = self.ui.document
    local ok, stale = pcall(document.isBuiltDomStale, document)
    if ok and stale then
        self._reloading = true
        self:reloadForRooms()
    end
end

-- Keep `rooms` (and whether they are hidden) and lay the book out with them.
function Book:setRooms(rooms, off)
    local data = self:data()
    if data.read_only then return false end
    data.rooms = rooms and #rooms > 0 and rooms or nil
    data.rooms_off = data.rooms and off or nil
    self:save()
    self:relayout()
    return true
end

-- Where a room's first paragraph is now: the gap above its text (to the word
-- before it, in the book's own pixels) and its first line's right end.
function Book:roomProbe(r)
    local document = self.ui.document
    local ts = self:textStartOf(r.xp)
    if not ts then return nil end
    local out = {}
    pcall(function()
        local y, x = document:getPosFromXPointer(ts)
        local prev = document:getPrevVisibleWordStart(ts)
        local py = prev and document:getPosFromXPointer(prev)
        out.gap = py and (y - py) or nil
        out.x = x
        local stop = ts
        for _n = 1, 12 do stop = document:getNextVisibleWordEnd(stop) or stop end
        local boxes = document:getScreenBoxesFromPositions(ts, stop, false)
        local b = boxes and boxes[1]
        out.right = b and (b.x + b.w) or nil
    end)
    return out
end

-- Did room `r` take, from before (Book:roomProbe) to now? A band moves its
-- paragraph down by its height; side space narrows its first line (or moves it
-- along, on the left). A paragraph too short to tell counts as taken.
local function took(r, before, after, area)
    if not (before and after) then return false end
    if r.kind == "band" then
        return before.gap and after.gap and after.gap - before.gap >= r.h * 0.9 - 2
    end
    if r.side == "left" then
        if not (before.x and after.x) then return false end
        -- moved along by the room, or (a centred line moves half as far) now
        -- starting past it; x is from the text area's left edge
        return after.x - before.x >= r.w * 0.9 - 2 or (after.x > before.x and after.x >= r.w * 0.9 - 2)
    end
    if not (before.right and after.right) then return true end
    if before.right < area.x1 - r.w then return true end   -- (a short first line)
    return after.right <= area.x1 - r.w * 0.9 + 2
end

-- Did box room `r` take, made on page `page` whose top was `top`: the page still
-- begins where it did (nothing before it moved), the room is on it, and no line of
-- text crosses its box?
function Book:boxTook(r, page, top)
    local document = self.ui.document
    if top then
        -- (the page found by its first word, not its number: with KOReader's partial
        -- re-layout, the pages of chapters before it are numbered anew as those are
        -- laid out again, though nothing on this page moved)
        local ok, p = pcall(document.getPageFromXPointer, document, top)
        local nok, now = false, nil
        if ok and p then nok, now = pcall(document.getPageXPointer, document, p) end
        if not nok or now ~= top then logger.dbg("Ink Away: room: the page moved", top, now); return false end
        if p ~= page then
            logger.dbg("Ink Away: room: the page is numbered", p, "now, was", page)
            page = p
            if self:currentPage() ~= page then self:gotoPage(page) end
        end
    end
    if self:currentPage() ~= page then logger.dbg("Ink Away: room: on another page", page, self:currentPage()); return false end
    local box = self:roomBox(r.id)
    if not box then logger.dbg("Ink Away: room: not on the page", self:roomPage(r.id)); return false end
    self:pageBlocks()
    local c = self._blocks or {}
    if not (c.first and c.last) then return true end
    local clear = true
    pcall(function()
        for _i, b in ipairs(self:pageLines()) do
            -- (a line's measured end varies by a pixel or two with the glyphs)
            if b.x < box.x + box.w - 3 and b.x + b.w > box.x + 3 and b.y < box.y + box.h - 1 and b.y + b.h > box.y + 1 then
                logger.dbg("Ink Away: room: text across it", b.x, b.y, b.w, b.h)
                clear = false
            end
        end
    end)
    return clear
end

-- Lay the book out again with its markers, the first time it has a box room: the
-- book is loaded again (KOReader builds its elements once, when it loads it), with
-- a notice meanwhile, and `after(book)` is called on the book loaded again.
function Book:reloadForRooms(after)
    local ui = self.ui
    local document = ui.document
    local _ = require("ink/l10n")
    local InfoMessage = require("ui/widget/infomessage")
    local note = InfoMessage:new{ text = _("Preparing this book for rooms…"), dismissable = false }
    UIManager:show(note)
    UIManager:forceRePaint()
    pcall(document.invalidateCacheFile, document)
    -- The reload is finished by whichever of KOReader's callback and the new reader's
    -- own "ready" event comes first (Book.finishReload): a plugin that wraps
    -- ReaderUI.showReader with fewer arguments (the Kobo plugin does) drops the
    -- callback, and the note would stay over the book for ever.
    local pending = { note = note, after = after }
    pending.watchdog = function()
        if Book.pending_reload == pending then
            logger.warn("Ink Away: the book did not report that it was ready, closing the note")
            Book.finishReload(nil)
        end
    end
    Book.pending_reload = pending
    UIManager:scheduleIn(60, pending.watchdog)
    UIManager:nextTick(function()
        ui:reloadDocument(nil, true, function(new_ui) Book.finishReload(new_ui) end)
    end)
end

-- The book is loaded again (see reloadForRooms): close the note and run what was
-- to follow, once. `new_ui` is the new reader, when known.
function Book.finishReload(new_ui)
    local pending = Book.pending_reload
    if not pending then return end
    Book.pending_reload = nil
    UIManager:unschedule(pending.watchdog)
    UIManager:close(pending.note)
    local book = new_ui and Book.by_ui[new_ui]
    if book and pending.after then
        -- (once the reader is up and has drawn its page)
        UIManager:scheduleIn(0.2, function() pending.after(book) end)
    end
end

-- Add room `r` (from Rooms.plan), or change the room with its id, and lay the
-- book out with it (the rooms shown, if they were hidden). A band before a
-- paragraph that already has one takes its place. A room on a paragraph it was
-- not on is checked: if the book's layout did not take it, everything is put back.
-- Returns the room, or nil and why ("failed", "read_only").
function Book:putRoom(r)
    r.id = r.id or Rooms.newId()
    local rooms, was = {}, nil
    for _i, o in ipairs(self:rooms()) do
        if o.id == r.id then was = o
        elseif not (r.kind == "band" and o.kind == "band" and o.xp == r.xp) then rooms[#rooms + 1] = o end
    end
    -- (a new paragraph is checked; the same one resized needs not be)
    local check = not (was and was.xp == r.xp and was.kind == r.kind)
    local area = self:textArea()
    local before = check and self:roomProbe(r)
    -- in its old place in the list, or last
    local placed = false
    if was then
        for i, o in ipairs(self:rooms()) do
            if o.id == r.id then table.insert(rooms, math.min(i, #rooms + 1), r); placed = true; break end
        end
    end
    if not placed then rooms[#rooms + 1] = r end
    local data = self:data()
    local old, old_off = data.rooms, data.rooms_off
    if r.kind == "box" then
        if data.read_only then return nil, "read_only" end
        -- the book's first exact room: kept now, laid out when the book is loaded
        -- again with its markers (Book:reloadForRooms)
        local pending = self._exact_pending
        local wraps = pending and pending.xp == r.xp
        if not data.rooms_ready or wraps then
            -- (a word wrapped moves the xpointers, and is laid out when the book is
            -- loaded again from its edited copy)
            if wraps then self:addExactMark(r) end
            data.rooms, data.rooms_off, data.rooms_ready = rooms, nil, true
            data.room_marks = 2   -- (inline elements carry markers too: Book:inlineMarks)
            self:save()
            self._awaiting_reload = r.id
            return r, "reload"
        end
        local page = self:currentPage()
        local document = self.ui.document
        local tok, top = pcall(document.getPageXPointer, document, page)
        self:setRooms(rooms, nil)
        self:fitBox(r)
        if not self:boxTook(r, page, tok and top) then
            logger.warn("Ink Away: the room did not take in this book:", r.xp)
            self:setRooms(old, old_off)
            return nil, "failed"
        end
        return r
    end
    if not self:setRooms(rooms, nil) then return nil, "read_only" end
    if check and not took(r, before, self:roomProbe(r), area) then
        logger.warn("Ink Away: the room did not take in this book:", r.xp)
        self:setRooms(old, old_off)
        return nil, "failed"
    end
    return r
end
Book.addRoom = Book.putRoom

-- Go to page `p` of the book.
function Book:gotoPage(p)
    local Event = require("ui/event")
    self.ui:handleEvent(Event:new("GotoPage", p))
end

-- Show or hide every room (hidden, the book reads as it was made, and the ink
-- in the rooms hides with them).
function Book:showRooms(on)
    local rooms = self:rooms()
    if #rooms == 0 then return end
    self:setRooms(rooms, not on or nil)
end

-- The items kept in room `id`.
function Book:roomItems(id)
    local out = {}
    for _i, it in ipairs(self:hasInk() and self:data().items or {}) do
        if it.a and it.a.room == id then out[#out + 1] = it end
    end
    return out
end

-- Remove room `id`. What is in it goes (`ink` "delete") or stays where it is on
-- the page now and follows the text from there ("follow").
function Book:removeRoom(id, ink)
    local data = self:data()
    local doc = self:doc()
    local items = {}
    for _i, it in ipairs(data.items) do
        local a = it.a
        if a and a.room == id then
            if ink ~= "delete" then
                local ok, op = pcall(Place.place, it, doc)
                local kept
                if ok and op then
                    local saved = self._no_rooms
                    self._no_rooms = id
                    local aok, item = pcall(Place.anchor, op, doc)
                    self._no_rooms = saved
                    if aok and item then kept = item end
                end
                if not kept and a.xp0 then
                    -- (not on this page: side space ink keeps its word, in the margin it was in)
                    local na = {}
                    for k, v in pairs(a) do na[k] = v end
                    na.room, na.rx = nil, nil
                    local x = (self:roomX(id) or 0) + (a.rx or 0)
                    if x > Screen:getWidth() / 2 then na.mr = Screen:getWidth() - x else na.ml = x end
                    kept = { op = it.op, a = na }
                end
                if kept then items[#items + 1] = kept end
            end
        else
            items[#items + 1] = it
        end
    end
    data.items = items
    local rooms = {}
    for _i, o in ipairs(self:rooms()) do if o.id ~= id then rooms[#rooms + 1] = o end end
    return self:setRooms(rooms, data.rooms_off)
end

-- Are there pinned items on pages from `page` on (a room before them changes the
-- text under them)?
function Book:pinnedFrom(page)
    for _i, it in ipairs(self:hasInk() and self:data().items or {}) do
        if it.a and it.a.pg and it.a.pg >= (page or 1) then return true end
    end
    return false
end

------------------------------------------------------------------------------
-- The smart highlighter: the reader's own highlights
------------------------------------------------------------------------------

-- A highlighter stroke over text, made the reader's own highlight of that text
-- (in the reader's highlight style, in the pen's colour as the reader names it).
-- Returns the highlight, or nil when it is not over text (it stays ink).
function Book:highlight(op)
    local ui = self.ui
    local hl, document = ui.highlight, ui.document
    if not (hl and hl.saveHighlight and ui.annotation and document.getTextFromPositions) then return nil end
    if not (op and op.kind == "ink" and op.pts) then return nil end
    -- a word just above or below the stroke's centre counts: the highlighter is thick
    local reach = math.max(4, (op.width or 8) * 0.5)
    local sel
    if ui.paging then sel = self:pageSelection(op, reach) else sel = self:flowSelection(op, reach) end
    if not sel then return nil end
    local hv = ui.view.highlight or {}
    local Blitbuffer = require("ffi/blitbuffer")
    sel.drawer = hv.saved_drawer
    sel.color = Snap.colourName(op.color, hv.saved_color, Blitbuffer.HIGHLIGHT_COLORS)
    return self:addHighlight(sel)
end

-- The text a highlighter stroke snaps to in a reflowing book (see
-- ink/reader/snap.lua): { text, pos0, pos1 } from the first word it ran over to
-- the last, or nil.
function Book:flowSelection(op, reach)
    local document = self.ui.document
    local doc = self:doc()
    local words, share = Snap.hits(op, function(x, y) return doc:wordAt(x, y) end, reach,
        function(w) return w.xp0 end)
    if not Snap.snaps(words, share) then return nil end
    local first, last = Snap.ends(words, function(a, b)
        local ok, c = pcall(document.compareXPointers, document, a.xp0, b.xp0)
        return ok and c == 1
    end)
    local ok, text = pcall(document.getTextFromXPointers, document, first.xp0, last.xp1)
    if ok and type(text) == "string" and text:match("%S") then
        return { text = text, pos0 = first.xp0, pos1 = last.xp1 }
    end
    -- else the text between the two words' boxes
    local a, b = first.box, last.box
    local ok2, r = pcall(document.getTextFromPositions, document, { x = a.x + 1, y = a.y + a.h / 2 },
        { x = b.x + b.w - 1, y = b.y + b.h / 2 }, true)
    if ok2 and r and r.pos0 and r.pos1 and type(r.text) == "string" and r.text:match("%S") then
        return { text = r.text, pos0 = r.pos0, pos1 = r.pos1 }
    end
end

-- The same on a fixed page (a PDF): { text, pos0, pos1, pboxes, ext } on the
-- page most of the stroke's words are on, or nil. The reader gives the nearest
-- word to any point, so a word only counts where the stroke is on it.
function Book:pageSelection(op, reach)
    local document, view = self.ui.document, self.ui.view
    local doc = self:doc()
    local surface = self.surface
    local function wordAt(x, y)
        local pos
        if surface then   -- (a viewer plugin's page: through its mapping)
            local page, px, py = doc:toPage(x, y)
            pos = page and { page = page, x = px, y = py } or nil
        else
            pos = view:screenToPageTransform({ x = x, y = y })
        end
        if not (pos and pos.page) then return nil end
        local ok, w = pcall(document.getWordFromPosition, document, pos)
        local pb = ok and w and w.pbox
        if not (pb and type(w.word) == "string" and w.word:match("%S")) then return nil end
        local sx, sy, zoom = doc:toScreen(pos.page, pb.x, pb.y)
        if not sx then return nil end
        return { page = pos.page, pbox = pb, box = { x = sx, y = sy, w = pb.w * zoom, h = pb.h * zoom } }
    end
    local words, share = Snap.hits(op, wordAt, reach,
        function(w) return w.page .. ":" .. w.pbox.x .. ":" .. w.pbox.y end)
    if not Snap.snaps(words, share) then return nil end
    local count, page = {}, nil
    for _i, w in ipairs(words) do
        count[w.page] = (count[w.page] or 0) + 1
        if not page or count[w.page] > count[page] then page = w.page end
    end
    local on = {}
    for _i, w in ipairs(words) do if w.page == page then on[#on + 1] = w end end
    local first, last = Snap.ends(on, Snap.pageBefore)
    local a = { page = page, x = first.pbox.x + 1, y = first.pbox.y + first.pbox.h / 2 }
    local b = { page = page, x = last.pbox.x + last.pbox.w - 1, y = last.pbox.y + last.pbox.h / 2 }
    local ok, sel = pcall(document.getTextFromPositions, document, a, b)
    if not (ok and sel and sel.pos0 and sel.pos1 and type(sel.text) == "string" and sel.text:match("%S")) then return nil end
    return { text = sel.text, pos0 = sel.pos0, pos1 = sel.pos1, pboxes = sel.pboxes, ext = sel.ext }
end

function Book:addHighlight(sel)
    local ui = self.ui
    local hl = ui.highlight
    hl.selected_text = sel
    local ok, index = pcall(hl.saveHighlight, hl)
    hl.selected_text = nil
    if ui.rolling then pcall(ui.document.clearSelection, ui.document) end
    if not (ok and index) then
        if not ok then logger.warn("Ink Away: could not save the highlight:", index) end
        return nil
    end
    return ui.annotation.annotations[index]
end

-- Take a highlight away again (undo).
function Book:removeHighlight(item)
    local ui = self.ui
    for i, it in ipairs(ui.annotation and ui.annotation.annotations or {}) do
        if it == item then
            pcall(ui.highlight.deleteHighlight, ui.highlight, i)
            return true
        end
    end
    return false
end

-- The reader's custom highlight colours (name -> { code }), or nil where the
-- reader has none (an older one).
function Book:customColours()
    local hl = self.ui and self.ui.highlight
    local t = hl and hl.custom_colors
    return type(t) == "table" and t or nil
end

-- Is `item` still one of the book's highlights (it is not once deleted).
function Book:hasHighlight(item)
    for _i, it in ipairs(self.ui and self.ui.annotation and self.ui.annotation.annotations or {}) do
        if it == item then return true end
    end
    return false
end

-- Give a highlight another colour, as the reader's own colour menu does: the
-- PDF's annotation is written again (a PDF keeps its highlights in the file),
-- the boxes the reader drew are dropped, and the reader is told the item
-- changed. `name` is a colour name the reader knows (nil, with `clear`, puts back
-- a highlight that had none). Returns whether it was set.
function Book:setHighlightColour(item, name, clear)
    local ui = self.ui
    if not (item and (name or clear) and ui and ui.highlight and self:hasHighlight(item)) then return false end
    local hl = ui.highlight
    local pdf = ui.paging and hl.writePdfAnnotation
    local ok, err = pcall(function()
        if pdf then hl:writePdfAnnotation("delete", item) end
        item.color = name
        if pdf then
            hl:writePdfAnnotation("save", item)
            if item.note then hl:writePdfAnnotation("content", item, item.note) end
        end
    end)
    if not ok then
        logger.warn("Ink Away: could not recolour the highlight:", err)
        return false
    end
    -- (each of these is the reader's own, and an older one may not have it)
    if ui.view and ui.view.resetHighlightBoxesCache then pcall(ui.view.resetHighlightBoxesCache, ui.view) end
    local Event = require("ui/event")
    pcall(ui.handleEvent, ui, Event:new("AnnotationsModified", { item }))
    return true
end

-- The highlights the path `pts` (flat x, y, ... on the screen, the canvas's own
-- points in annotation mode) comes within `r` px of: their annotation items,
-- each once. It uses what KOReader drew on the page shown and its own tap test
-- (view.highlight.visible_boxes, in page coordinates on a fixed page), walking
-- each segment in small steps so a short highlight between two points counts.
function Book:highlightsAt(pts, r)
    local out = {}
    -- (KOReader's highlight boxes are its own view's: none reached on a viewer
    -- plugin's page, so the reader's highlights are never touched through it)
    if self.surface then return out end
    local ui = self.ui
    local view = ui and ui.view
    local vis = view and view.highlight and view.highlight.visible_boxes
    local anns = ui and ui.annotation and ui.annotation.annotations
    if not (vis and anns and #vis > 0 and view.screenToPageTransform and pts and #pts >= 2) then return out end
    local zoom = (ui.paging and view.state and view.state.zoom) or 1
    local rr = (r or 0) / zoom
    local seen = {}
    local function at(x, y)
        local ok, pos = pcall(view.screenToPageTransform, view, { x = x, y = y })
        if not (ok and pos and pos.x) then return end
        for _k, box in ipairs(vis) do
            local b = box.rect
            if b and not seen[box.index] and pos.x >= b.x - rr and pos.x <= b.x + b.w + rr
                    and pos.y >= b.y - rr and pos.y <= b.y + b.h + rr then
                seen[box.index] = true
                local it = anns[box.index]
                if it then out[#out + 1] = it end
            end
        end
    end
    local step = math.max(2, r or 0)
    at(pts[1], pts[2])
    for i = 3, #pts - 1, 2 do
        local x0, y0, x1, y1 = pts[i - 2], pts[i - 1], pts[i], pts[i + 1]
        local n = math.max(1, math.ceil(math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2) / step))
        for k = 1, n do at(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n) end
    end
    return out
end

-- Erase along the screen path `pts` with radius `r`, while reading (the pen's
-- eraser end, see ink/reader/penhighlight.lua): the highlights it reaches go,
-- and the book's ink it crosses is cut as the annotation mode's eraser cuts it,
-- with that mode's eraser settings. Returns how many highlights and strokes went
-- or changed.
function Book:eraseAlong(pts, r)
    if not (pts and #pts >= 2) then return 0 end
    local n = 0
    for _i, it in ipairs(self:highlightsAt(pts, r)) do
        if self:removeHighlight(it) then n = n + 1 end
    end
    local placed = self:pageOps()
    if placed and #placed.ops > 0 then
        local G = rawget(_G, "G_reader_settings")
        local function get(k, d)
            local v = G and G.readSetting and G:readSetting(k)
            if v == nil then return d end
            return v
        end
        local Cut = require("ink/cut")
        local opts = { text = not get("inkaway_text_erase_protect", true), pictures = get("inkaway_erase_bg", false) }
        local ops, changed = Cut.ops(placed.ops, pts, r, opts)
        if changed and get("inkaway_erase_whole", false) then
            -- the whole-stroke eraser: what it reached goes entirely
            ops = {}
            for _i, op in ipairs(placed.ops) do
                local _o, hit = Cut.ops({ op }, pts, r, opts)
                if not hit then ops[#ops + 1] = op end
            end
        end
        if changed then
            local came_from = {}
            for i, op in ipairs(placed.ops) do came_from[op] = placed.items[i] end
            for _i, op in ipairs(ops) do if not came_from[op] then n = n + 1 end end
            self:setPageOps(ops, came_from, placed.items)
            self:save()
            if n == 0 then n = 1 end
        end
    end
    return n
end

-- Put a removed highlight back (redo). Returns it as saved now.
function Book:restoreHighlight(item)
    return self:addHighlight({ text = item.text, pos0 = item.pos0, pos1 = item.pos1, pboxes = item.pboxes,
        ext = item.ext, drawer = item.drawer, color = item.color, note = item.note })
end

------------------------------------------------------------------------------
-- Painting the ink while reading
------------------------------------------------------------------------------

-- The view module KOReader paints after each page. Returns its widget.
function Book:overlay()
    if self._overlay then return self._overlay end
    local book = self
    self._overlay = {
        hidden = false,
        paintTo = function(this, bb, x, y)
            if this.hidden or not book:hasInk() then return end
            local G = rawget(_G, "G_reader_settings")
            if G and G.readSetting and G:readSetting("inkaway_book_ink") == false then return end
            local ok, err = pcall(book.paintInk, book, bb, x, y, false)
            if not ok then logger.warn("Ink Away: could not paint the book's ink:", err) end
        end,
    }
    return self._overlay
end

-- (`on`: as pageOps; the reader's view paints with false)
function Book:paintInk(bb, x, y, on)
    local placed = self:pageOps(on)
    if not (placed and #placed.ops > 0) then return end
    require("ink/reader/paint").ops(bb, placed.ops, x, y, self)
end

-- Open the annotation mode over the page shown (once: a second call while it is
-- open does nothing).
-- Is `w` still shown?
local function shown(w)
    for _i, e in ipairs(UIManager._window_stack or {}) do if e.widget == w then return true end end
    return false
end

function Book:annotate()
    if self._view and shown(self._view) then return end
    self._view = nil
    if self:data().read_only then
        local _ = require("ink/l10n")
        require("ink/view").tellAnywhere(_("This book's ink was saved by a newer Ink Away. Update Ink Away to change it."))
        return
    end
    local ok, ReaderInkView = pcall(require, "ink/reader/inkview")
    if not ok then logger.warn("Ink Away: annotation mode unavailable:", ReaderInkView); return end
    -- a viewer plugin showing the page (PanelsPlus...) gives its surface: annotation
    -- mode draws on it, over it (modal, as the viewer is), else on the reader's page
    local surface = self.integration and self.integration:select(self.ui)
    if surface and surface.begin then
        local begun, err = pcall(surface.begin, surface)
        if not begun then
            self.integration:report(surface, err)
            if surface.finish then pcall(surface.finish, surface) end
            surface = nil
        end
    end
    local view
    if surface then
        self:setSurface(surface)
        local created, v = pcall(ReaderInkView.new, ReaderInkView, { book = self, modal = true })
        local shown_ok, err = created, v
        if created then shown_ok, err = pcall(UIManager.show, UIManager, v) end
        if not shown_ok then
            if created then pcall(v.closeCanvas, v) end
            self._view = nil
            self:finishAnnotation()
            self.integration:report(surface, err)
            logger.warn("Ink Away: annotation mode unavailable on the viewer:", err)
            return
        end
        view = v
        self._view = view
    else
        view = ReaderInkView:new{ book = self }
        self._view = view
        UIManager:show(view)
    end
    if self._view == view and self.integration then
        self._annotation_session = true
        self.integration:emit("opened", self.ui.document, self.surface)
    end
end

-- Close what Ink Away has open over the book (keeping everything): the screen
-- turned, and they were laid out for the old one.
function Book:closeViews()
    if self._capture then self._capture:onCancel() end
    if self._view then pcall(function() self._view:closeCanvas() end) end
    if self._notes_view then pcall(function() self._notes_view:closeCanvas() end) end
end

-- The book is closing: close the annotation mode (keeping its ink) and let go.
function Book:close()
    if self._capture then self._capture:onCancel() end
    if self._view then pcall(function() self._view:closeCanvas() end) end
    if self._notes_view then pcall(function() self._notes_view:closeCanvas() end) end
    self._view, self._notes_view = nil, nil
    -- pictures no longer shown go now (not at each save, so an undo could still
    -- bring one back while the book was open)
    if self._data and not self._data.read_only then pcall(BookInk.prunePictures, self.sidecar, self._data.items) end
    self._placed, self._index, self._painter, self._placed_s = nil, nil, nil, nil
    require("ink/wash").clearCache()
end

-- Turn the book's page (dir 1 forward, -1 back), as KOReader does; `done()` once
-- the new page is shown. On a viewer plugin's surface the viewer turns it (it may
-- animate: `frame()` asks for a picture of each step) and says when it is done,
-- maybe with the surface of its next page.
function Book:turn(dir, done, frame)
    local surface = self.surface
    if not surface then
        local Event = require("ui/event")
        self.ui:handleEvent(Event:new("GotoViewRel", dir))
        if done then done() end
        return
    end
    local view, completed = self._view, false
    local function completedTurn(next_surface)
        if completed or self._view ~= view or (view and view.closing) then return end
        completed = true
        -- (none given: the same surface, on its new page)
        next_surface = self.integration:handoff(surface, next_surface or surface, self.ui.document)
        self:setSurface(next_surface)
        if next_surface and next_surface.begin and next_surface ~= surface then
            local ok, err = pcall(next_surface.begin, next_surface)
            if not ok then self.integration:report(next_surface, err) end
        end
        if done then done() end
    end
    -- (a viewer that does not turn pages stays on this one)
    local ok, err = pcall(function()
        if surface.turn then surface:turn(dir, completedTurn, frame) else completedTurn(surface) end
    end)
    if not ok then
        self.integration:report(surface, err)
        completedTurn(surface)
    end
end

-- Annotation mode closed (its ink kept): the viewer plugin's surface, if it was
-- on one, is let go, then those listening are told.
function Book:finishAnnotation()
    local surface = self.surface
    self:setSurface(nil)
    if surface and surface.finish then
        local ok, err = pcall(surface.finish, surface)
        if not ok and self.integration then self.integration:report(surface, err) end
    end
    if self._annotation_session then
        self._annotation_session = nil
        if self.integration then self.integration:emit("closed", self.ui.document, surface) end
    end
end

-- Paint the page shown into `bb` (screen-sized), without the ink unless
-- `with_ink` (`force_ink`: even with the book's ink hidden in the settings). The Paper
-- Dots plugin adds its texture only where the page is painted on the screen's own
-- buffer: `bb` stands in for it, so the page looks the same.
function Book:snapshot(bb, with_ink, force_ink)
    local surface = self.surface
    if surface then
        self._snapshotting = true   -- (the viewer paints itself: not its ink, painted here)
        local ok, err = pcall(surface.snapshot, surface, bb)
        self._snapshotting = nil
        if ok and with_ink then
            local pok, perr = pcall(self.paintSurface, self, surface, bb, force_ink)
            if not pok then self.integration:report(surface, perr) end
        end
        if not ok then
            self.integration:report(surface, err)
            logger.warn("Ink Away: could not draw the viewer's page:", err)
        end
        return ok
    end
    local ov = self:overlay()
    ov.hidden = not with_ink
    local real_bb = Screen._paper_dots_hooked and Screen.bb
    if real_bb then Screen.bb = bb end
    local ok, err = pcall(self.ui.view.paintTo, self.ui.view, bb, 0, 0)
    if real_bb then Screen.bb = real_bb end
    ov.hidden = false
    if not ok then logger.warn("Ink Away: could not draw the page:", err) end
    return ok
end

------------------------------------------------------------------------------
-- Book notes (ink/reader/notesview.lua)
------------------------------------------------------------------------------

-- What the notes need to know: the book's title and author, its checksum, and
-- the chapter shown ({ key = its place in the contents, chapter = its title }).
function Book:notesInfo(at)
    local ui = self.ui
    local props = ui.doc_props or {}
    local file = ui.document and ui.document.file or ""
    local title = props.display_title or props.title
    if not title or title == "" then title = file:match("([^/]+)%.[^./]*$") or file:match("[^/]+$") or "Book" end
    local md5
    pcall(function() md5 = ui.doc_settings:readSetting("partial_md5_checksum") end)
    local info = { title = title, author = props.authors, md5 = md5 }
    local toc = ui.toc
    if toc and toc.getTocIndexByPage then
        local pos = at or (ui.rolling and ui.document:getXPointer() or self:currentPage())
        local ok, idx = pcall(toc.getTocIndexByPage, toc, pos, toc.toc_chapter_title_bind_to_ticks)
        if ok and idx and toc.toc and toc.toc[idx] then
            info.key = idx
            local t = toc.toc[idx].title
            info.chapter = toc.cleanUpTocTitle and toc:cleanUpTocTitle(t) or t
        end
    end
    return info
end

-- The book's notebook, as last saved (nil before it has one).
function Book:notesPath()
    local path = self:data().notes
    -- a notebook path from another reader (the ink came with the cloud sync) is found again
    local ok, Portable = pcall(require, "ink/sync/portable")
    local root = ok and Portable.root and Portable.root()
    if path and root then return Portable.resolve(path, root) end
    return path
end

function Book:setNotesPath(path)
    local data = self:data()
    if data.notes == path or data.read_only then return end
    data.notes = path
    self:save()
end

-- Open the book's notes in a window over the page (once: a second call while
-- they are open does nothing); with `hl` (Book:highlightKey) on that highlight's
-- handwritten note.
function Book:openNotes(hl)
    if self._notes_view and shown(self._notes_view) then return end
    self._notes_view = nil
    local ok, NotesView = pcall(require, "ink/reader/notesview")
    if not ok then logger.warn("Ink Away: book notes unavailable:", NotesView); return end
    -- the page as it is, to show around the window
    local Blitbuffer = require("ffi/blitbuffer")
    local behind = Blitbuffer.new(Screen:getWidth(), Screen:getHeight(), Screen.bb:getType())
    -- (a viewer plugin showing the page, which is modal: its page around the
    -- window, and the window on top of it)
    local viewer = self.integration and self.integration:select(self.ui)
    if viewer and self.surface == nil then
        self:setSurface(viewer)
        self:snapshot(behind, true)
        self:setSurface(nil)
    else
        self:snapshot(behind, true)
    end
    local view = NotesView:new{ book = self, behind_bb = behind, highlight = hl, modal = viewer and true or nil }
    self._notes_view = view
    UIManager:show(view)
end

------------------------------------------------------------------------------
-- Handwritten notes on the reader's highlights (a page of the book's notes each,
-- see ink/reader/booknotes.lua and ink/reader/hlnotes.lua)
------------------------------------------------------------------------------

-- What finds highlight `anno` (one of KOReader's annotations) again: its date
-- and time, its ends, its words, and its chapter's place in the contents.
function Book:highlightKey(anno)
    local function copy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = copy(x) end
        return c
    end
    local info = self:notesInfo(anno.page or anno.pos0)
    return { dt = anno.datetime, pos0 = copy(anno.pos0), pos1 = copy(anno.pos1), text = anno.text,
        key = info.key, chapter = info.chapter }
end

-- The reader's highlight with this key, and its place in its list (nil if gone).
function Book:findHighlight(hl)
    local list = self.ui.annotation and self.ui.annotation.annotations
    for i, a in ipairs(list or {}) do
        if (hl.dt and a.datetime == hl.dt) or (not hl.dt and a.pos0 == hl.pos0 and a.pos1 == hl.pos1) then
            return a, i
        end
    end
end

-- Has highlight `anno` a handwritten note?
function Book:hasHandNote(anno)
    if not (anno and anno.datetime) or not (self.has_file or self._data) then return false end
    local notes = self:data().hl_notes
    return notes ~= nil and notes[anno.datetime] ~= nil
end

-- Open the handwritten note of the highlight at `index` in the reader's list
-- (a new one when it has none).
function Book:openHighlightNote(index)
    local list = self.ui.annotation and self.ui.annotation.annotations
    local anno = list and list[index]
    if not anno then return end
    if self:data().read_only then
        local _ = require("ink/l10n")
        require("ink/view").tellAnywhere(_("This book's ink was saved by a newer Ink Away. Update Ink Away to change it."))
        return
    end
    self:openNotes(self:highlightKey(anno))
end

-- The handwritten note of highlight `hl` has ink (`has`) or none now: the book
-- keeps which highlights have one, and the highlight gets KOReader's note
-- "(Handwritten note)" when it has no other, so it shows as a highlight with a
-- note in KOReader's lists and exports (and loses it again with the ink).
function Book:linkHighlightNote(hl, has)
    if not (hl and hl.dt) then return end
    local data = self:data()
    if data.read_only then return end
    data.hl_notes = data.hl_notes or {}
    local marker = data.hl_notes[hl.dt]
    local _ = require("ink/l10n")
    local anno = self:findHighlight(hl)
    if has then
        if marker then return end
        local text = _("(Handwritten note)")
        data.hl_notes[hl.dt] = text
        self:save()
        if anno and (anno.note == nil or anno.note == "") then
            anno.note = text
            self:highlightsChanged(anno, 1)
        end
    else
        if not marker then return end
        data.hl_notes[hl.dt] = nil
        if next(data.hl_notes) == nil then data.hl_notes = nil end
        self:save()
        if anno and anno.note == marker then
            anno.note = nil
            self:highlightsChanged(anno, -1)
        end
    end
end

-- Tell KOReader a highlight's note was added (1) or taken away (-1), as its own
-- note editing does: it saves it, and redraws the note's mark.
function Book:highlightsChanged(anno, notes)
    local Event = require("ui/event")
    pcall(function()
        self.ui:handleEvent(Event:new("AnnotationsModified", { anno, nb_highlights_added = 1, nb_notes_added = notes }))
    end)
    UIManager:setDirty(self.ui.dialog or "all", "ui")
end

------------------------------------------------------------------------------
-- Deleting the book's annotations
------------------------------------------------------------------------------

-- Move the book's annotations (its ink file and pictures) to the trash of the
-- Ink Away library `root` (see Trash.putBookInk), and show the book without
-- them at once. The link to the book's notes stays. Returns the trash item, or
-- nil, err.
function Book:trashInk(root)
    local data = self:data()
    if data.read_only then return nil, "saved by a newer Ink Away" end
    if #data.items > 0 then self:save() end      -- what is in memory goes too
    if not (self.sidecar and BookInk.exists(self.sidecar)) then return nil, "no annotations" end
    local Trash = require("ink/trash")
    local item, err = Trash.putBookInk(root, self.sidecar,
        { name = self:notesInfo().title, book = self.ui.document and self.ui.document.file })
    if not item then return nil, err end
    local notes = data.notes
    local css = self:roomsCss() or false
    self._data = BookInk.new()
    self.has_file = false
    if notes then
        self._data.notes = notes
        self:save()
    end
    self:reload(true, css)
    return item
end

-- Read the book's ink again (it came back from the trash, or from the cloud), or
-- with `keep` just show what is in memory now. When that changes the rooms made
-- in the text, the book is laid out again.
function Book:reload(keep, css_before)
    local before = css_before
    if before == nil then before = self:roomsCss() or false end
    if not keep then
        self._data = nil
        self.has_file = self.sidecar ~= nil and BookInk.exists(self.sidecar)
    end
    self.rev = self.rev + 1
    self._placed, self._index, self._index_key = nil, nil, nil
    if (self:roomsCss() or false) ~= before then self:relayout() end
    self:repaint()
end

-- Repaint the reader (after the ink changed), or the viewer plugin showing the page.
function Book:repaint()
    local surface = self.surface
    if surface then
        local ok, err = pcall(surface.repaint, surface)
        if not ok then self.integration:report(surface, err) end
        return
    end
    UIManager:setDirty(self.ui.dialog or "all", "ui")
end

------------------------------------------------------------------------------
-- A viewer plugin's surface (see ink/integration.lua, docs/INTEGRATION.md)
------------------------------------------------------------------------------

-- Annotation mode is on surface `s` (nil: on the reader's own page again). The
-- placement made for the reader's view stays; the surfaces' own is dropped.
local surfaceAsk   -- (the four questions, for a surface: below)
function Book:setSurface(s)
    if self.surface == s then return end
    self.surface = s
    self._placed_s = nil
    if s then
        self.doc, self.currentPage, self.visiblePages, self.layoutKey =
            surfaceAsk.doc, surfaceAsk.currentPage, surfaceAsk.visiblePages, surfaceAsk.layoutKey
    else   -- (the reader's own again: the class's)
        self.doc, self.currentPage, self.visiblePages, self.layoutKey = nil, nil, nil, nil
    end
end

-- The reading direction the viewer gives ("rtl" for manga), or nil (the reader's
-- page: the toolbar's arrows and swipes are as they always were).
function Book:readingDirection()
    local s = self.surface
    if not (s and s.readingDirection) then return nil end
    local ok, dir = pcall(s.readingDirection, s)
    return ok and dir or nil
end

-- A call to the viewer's surface that may fail: its failure goes to the viewer
-- (and the log), and `fallback` comes back instead.
local function ask(self, s, name, fallback, ...)
    local ok, r = pcall(s[name], s, ...)
    if ok and r ~= nil then return r end
    if not ok and self.integration then self.integration:report(s, r) end
    return fallback
end

function Book:surfacePages(s) return ask(self, s, "pages", {}) end

-- Its geometry, as layoutKey is the reader's (the key alone: a viewer makes a new
-- table for each part of a folded spread, so the table itself must not count).
function Book:surfaceKey(s) return "s|" .. tostring(ask(self, s, "key", "")) end

surfaceAsk = {
    doc = function(self) return self:surfaceDoc(self.surface) end,
    currentPage = function(self) return self:surfacePages(self.surface)[1] end,
    visiblePages = function(self) return self:surfacePages(self.surface) end,
    layoutKey = function(self) return self:surfaceKey(self.surface) end,
}

-- Its placement adapter (ink/reader/surface.lua), made once per surface.
function Book:surfaceDoc(s)
    local docs = self._sdocs
    if not docs then docs = setmetatable({}, { __mode = "k" }); self._sdocs = docs end
    local d = docs[s]
    if not d then d = require("ink/reader/surface").doc(s); docs[s] = d end
    return d
end

-- pageOps for surface `s`: kept apart from the reader's own placement (a folded
-- spread has two surfaces, painted one after the other: each keeps its own), a
-- few at a time, until the ink changes.
function Book:surfaceOps(s)
    local pages, layout = self:surfacePages(s), self:surfaceKey(s)
    local key = table.concat({ table.concat(pages, ","), layout, self.rev }, "#")
    local cache = self._placed_s
    if not (cache and cache.rev == self.rev) then cache = { rev = self.rev, n = 0, by = {} }; self._placed_s = cache end
    local hit = cache.by[key]
    if hit then return hit end
    local doc = self:surfaceDoc(s)
    -- (the page index is the one the reader's fixed pages use: by page number)
    self._ikey_base = self._ikey_base or "paging"
    local ikey = self._ikey_base .. "#" .. self.rev
    if not (self._index and self._index_key == ikey) then
        self._index = Place.index(self:data().items, doc)
        self._index_key = ikey
    end
    local out = { key = key, pages = pages, ops = {}, items = {} }
    local W, H = Screen:getWidth(), Screen:getHeight()
    for _p, page in ipairs(pages) do
        for _i, item in ipairs(self._index[page] or {}) do
            local ok, op = pcall(Place.place, item, doc)
            if ok and op and op.kind == "image" then op.path = BookInk.picturePath(self.sidecar, op.path) end
            local x0, y0, x1, y1
            if ok and op then x0, y0, x1, y1 = Canvas.opBox(op) end
            if x0 and x1 >= 0 and y1 >= 0 and x0 < W and y0 < H then
                out.ops[#out.ops + 1] = op
                out.items[#out.items + 1] = item
                -- (where the ink reaches, for keeping it inside the viewer's clip)
                out.x0, out.y0 = math.min(out.x0 or x0, x0), math.min(out.y0 or y0, y0)
                out.x1, out.y1 = math.max(out.x1 or x1, x1), math.max(out.y1 or y1, y1)
            end
        end
    end
    if cache.n >= 8 then cache.by, cache.n = {}, 0 end
    cache.by[key], cache.n = out, cache.n + 1
    return out
end

-- The parts of rect a (x0, y0, x1, y1) outside rect c ({ x, y, w, h }), as rects.
local function outside(a, c)
    local out = {}
    local cx0, cy0, cx1, cy1 = c.x, c.y, c.x + c.w, c.y + c.h
    if a.y0 < cy0 then out[#out + 1] = { x = a.x0, y = a.y0, w = a.x1 - a.x0, h = math.min(a.y1, cy0) - a.y0 } end
    if a.y1 > cy1 then out[#out + 1] = { x = a.x0, y = math.max(a.y0, cy1), w = a.x1 - a.x0, h = a.y1 - math.max(a.y0, cy1) } end
    local my0, my1 = math.max(a.y0, cy0), math.min(a.y1, cy1)
    if my1 > my0 then
        if a.x0 < cx0 then out[#out + 1] = { x = a.x0, y = my0, w = math.min(a.x1, cx0) - a.x0, h = my1 - my0 } end
        if a.x1 > cx1 then out[#out + 1] = { x = math.max(a.x0, cx1), y = my0, w = a.x1 - math.max(a.x0, cx1), h = my1 - my0 } end
    end
    return out
end

-- Paint the book's ink on surface `s` into `bb` (the screen, in the viewer's own
-- paint), each part of it (the halves of a folded spread) within its clip: ink
-- outside a part's clip never covers the viewer's controls or the other part.
-- The ink is painted straight into bb; only what of it reaches past the clip is
-- kept first and put back after (usually nothing: no copy of the screen is made).
function Book:paintSurface(s, bb, force_ink)
    if self._snapshotting or not self:hasInk() then return end
    local G = rawget(_G, "G_reader_settings")
    if not force_ink and G and G.readSetting and G:readSetting("inkaway_book_ink") == false then return end
    local Blitbuffer = require("ffi/blitbuffer")
    local PaintInk = require("ink/reader/paint")
    local BW, BH = bb:getWidth(), bb:getHeight()
    local regions = s.regions and ask(self, s, "regions", nil) or { s }
    for _i, region in ipairs(regions) do
        local clip = ask(self, region, "clip", nil)
        local placed = clip and clip.w > 0 and clip.h > 0 and self:pageOps(region)
        if placed and #placed.ops > 0 then
            -- (a margin for what is drawn just past an op's box: a stroke's smoothing)
            local pad = 16
            local reach = { x0 = math.max(0, math.floor(placed.x0) - pad), y0 = math.max(0, math.floor(placed.y0) - pad),
                x1 = math.min(BW, math.ceil(placed.x1) + pad), y1 = math.min(BH, math.ceil(placed.y1) + pad) }
            local kept = {}
            for _k, r in ipairs(outside(reach, clip)) do
                if r.w > 0 and r.h > 0 then
                    local keep = Blitbuffer.new(r.w, r.h, bb:getType())
                    keep:blitFrom(bb, 0, 0, r.x, r.y, r.w, r.h)
                    kept[#kept + 1] = { keep, r }
                end
            end
            local ok, err = pcall(PaintInk.ops, bb, placed.ops, 0, 0, self)
            for _k, e in ipairs(kept) do
                bb:blitFrom(e[1], e[2].x, e[2].y, 0, 0, e[2].w, e[2].h)
                e[1]:free()
            end
            if not ok then error(err) end
        end
    end
end

require("ink/reader/exactrooms").into(Book)

return Book
