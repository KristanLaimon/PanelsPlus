--[[
What an export is made of, for notebooks and for books alike: which pages, what
each page is drawn from, and the three ways it is written. The export sheet
(ink/view/export.lua) only asks this file; it holds no rule of its own about
which source can be written which way.

  * editable PDF: a copy of the original PDF with the ink and highlights added
    as annotations (ink/export/pdfedit.lua). PDF notebooks and PDF books.
  * pictures: each page as a picture with the ink on it, as a PDF or as PNGs
    (ink/export.lua). Every source, and the way to get a reflowing book (EPUB,
    MOBI...) into a PDF: its pages as the reader draws them now, so the ink is
    exactly where it is on the screen.

A source's spec is { n, pages, size, box, template, bg, bg_opaque, quality,
prepare, done, ... }: see Export.notebookPDFJob, which also reads it.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local ffi = require("ffi")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local _ = require("ink/l10n")
local Annots = require("ink/export/annots")
local BookInk = require("ink/reader/bookink")
local Canvas = require("ink/canvas")
local Export = require("ink/export")
local Overlay = require("ink/export/pdfoverlay")
local PageText = require("ink/reader/pagetext")
local BookExport = require("ink/reader/bookexport")
local ImageProc = require("ink/imageproc")
local Links = require("ink/links")
local Pdfedit = require("ink/export/pdfedit")
local Storage = require("ink/storage")

local Screen = Device.screen
local bbToRGBA = ImageProc.bbToRGBA

local InkAwayView = {}

------------------------------------------------------------------------------
-- What there is to export
------------------------------------------------------------------------------

-- The PDF an export can be an edit of: a PDF notebook's own, or a PDF book's.
function InkAwayView:exportPdf()
    if self.book then return BookExport.pdfPath(self.book) end
    local t = self.notebook and self.notebook.template
    return t and t.pdf_path or nil
end

-- Can this KOReader write annotations into a copy of that PDF? (Found out once.)
function InkAwayView:exportEditable()
    local path = self:exportPdf()
    if not (path and Storage.exists(path)) then return false end
    if InkAwayView._can_edit then return true end
    local ok = Pdfedit.available(path)
    InkAwayView._can_edit = ok or nil
    return ok
end

-- Is there anything to export? A book: ink or a highlight, on any page.
function InkAwayView:exportHasContent()
    if self.book then return BookExport.hasContent(self.book) end
    return self:docHasContent()
end

-- How many pages the export can cover.
function InkAwayView:exportCount()
    if self.book then return BookExport.count(self.book) end
    return self.notebook and self.notebook:count() or 1
end

-- The name an export starts from: a book's title, else the document's name.
function InkAwayView:exportName()
    if self.book then
        local info = self.book:notesInfo()
        return require("ink/reader/booknotes").fileName(info and info.title)
    end
    return self:docName()
end

-- How many pages the reader shows at once (two side by side count as one step).
local function stride(book)
    local d = book.ui.document
    if not book.ui.paging and d.getVisiblePageCount and d:getVisiblePageCount() == 2 then return 2 end
    return 1
end

-- The pages the export covers: a notebook's page indices, or a book's page numbers.
function InkAwayView:exportPageList()
    local o = self:exportOptions()
    if self.book then return BookExport.pages(self.book, o.scope, o.range, stride(self.book)) end
    return self:selectedNotebookPages()
end

------------------------------------------------------------------------------
-- The editable PDF
------------------------------------------------------------------------------

-- Where a notebook page's ink lands on the PDF page it covers: the page is shown
-- fitted and centred in the notebook's page (see InkAwayView:renderPdfPage).
local function fitMap(doc, src, W, H)
    local Document = require("document/document")
    local native = Document.getNativePageDimensions(doc, src)
    if not (native and native.w and native.h) then return nil end
    local zoom = math.min(W / native.w, H / native.h)
    local dw, dh = math.floor(native.w * zoom + 0.5), math.floor(native.h * zoom + 0.5)
    local fit = math.min(W / dw, H / dh)
    dw, dh = math.max(1, math.floor(dw * fit + 0.5)), math.max(1, math.floor(dh * fit + 0.5))
    return { s = dw / native.w, ox = math.floor((W - dw) / 2), oy = math.floor((H - dh) / 2) }
end

-- A page's ink as a picture to lay over the page: `ops` drawn on a transparent
-- canvas of cw x ch px, cut to what shows inside the page (the page covers
-- m.ox, m.oy, then pw*m.s, ph*m.s px of it), and packed (see Overlay.pack) with the
-- box it covers in the page's units. Returns nil when nothing shows.
function InkAwayView:overlayPicture(ops, cw, ch, m, pw, ph)
    local c = Canvas.new(cw, ch)
    c:setOps(ops)
    local buf, _n, ow, oh = Export.buildRGBA(c, nil, nil, self:exportDress({ style = "blank" }))
    local x0, y0 = math.max(0, math.floor(m.ox)), math.max(0, math.floor(m.oy))
    local x1, y1 = math.min(ow, math.ceil(m.ox + pw * m.s)), math.min(oh, math.ceil(m.oy + ph * m.s))
    local bx0, by0, bx1, by1 = math.huge, math.huge, -1, -1
    for y = y0, y1 - 1 do
        local row = y * ow
        for x = x0, x1 - 1 do
            if buf[(row + x) * 4 + 3] > 0 then
                if x < bx0 then bx0 = x end
                if x > bx1 then bx1 = x end
                if y < by0 then by0 = y end
                if y > by1 then by1 = y end
            end
        end
    end
    if bx1 < 0 then return nil end
    local w, h = bx1 - bx0 + 1, by1 - by0 + 1
    local rgb, al = ffi.new("uint8_t[?]", w * h * 3), ffi.new("uint8_t[?]", w * h)
    local solid = 0
    for y = by0, by1 do
        for x = bx0, bx1 do if buf[(y * ow + x) * 4 + 3] == 255 then solid = solid + 1 end end
    end
    -- a picture with a good deal of solid colour (a photo) has its colour as a JPEG, a
    -- fifth of the size; ink on nothing stays lossless. Where nothing shows, the colour
    -- of the pixel before it fills in, so the JPEG has no hard edge to fringe.
    local jpeg = w * h >= 20000 and solid >= 15000
    local k = 0
    for y = by0, by1 do
        local r, g, b = 128, 128, 128
        for x = bx0, bx1 do
            local o = (y * ow + x) * 4
            local a = buf[o + 3]
            if a > 0 or not jpeg then r, g, b = buf[o], buf[o + 1], buf[o + 2] end
            rgb[k * 3], rgb[k * 3 + 1], rgb[k * 3 + 2], al[k] = r, g, b, a
            k = k + 1
        end
    end
    local bytes = ffi.string(rgb, w * h * 3)
    if jpeg then
        local tmp = Storage.settingsDir() .. "/inkaway_overlay.jpg"
        local ok = pcall(function()
            return require("ffi/jpeg").encodeToFile(tmp, rgb, w, h, 3, 88, w * 3)
        end)
        local f = ok and io.open(tmp, "rb")
        if f then bytes = f:read("*a"); f:close() else jpeg = false end
        os.remove(tmp)
    end
    return Overlay.pack(w, h, bytes, ffi.string(al, w * h),
        (bx0 - m.ox) / m.s, (by0 - m.oy) / m.s, (bx1 + 1 - m.ox) / m.s, (by1 + 1 - m.oy) / m.s, jpeg)
end

-- Everything an editable PDF holds: the pages' annotations (see Pdfedit.job), how
-- many items it cannot hold as annotations (Annots.leftOut) and on how many pages,
-- and how many notebook pages were added that the original does not have. A page
-- with such items gets a picture of its ink over it (`overlay`) unless the export
-- is set to leave them out (`keep_pictures` false).
function InkAwayView:editableWork()
    local o = self:exportOptions()
    local keep = o.keep_pictures ~= false
    local lists, by, work, added = {}, {}, {}, 0
    local function page(p)
        local w = by[p]
        if not w then w = { page = p, groups = {}, marks = {}, ops = {}, geo = nil }; by[p] = w; work[#work + 1] = w end
        return w
    end
    if self.book then
        local book = self.book
        local items, marks = BookExport.inkByPage(book), BookExport.marksByPage(book)
        local seen = {}
        for p in pairs(items) do seen[p] = true end
        for p in pairs(marks) do seen[p] = true end
        local pages = {}
        for p in pairs(seen) do pages[#pages + 1] = p end
        table.sort(pages)
        local picture = function(path) return BookInk.picturePath(book.sidecar, path) end
        local Document = require("document/document")
        local W, H = self.view.canvas_w, self.view.canvas_h
        for _i, p in ipairs(pages) do
            local ops = BookExport.pageOps(items[p], nil, 1, picture)
            lists[#lists + 1] = ops
            local w = page(p)
            for _j, g in ipairs(Annots.convert(ops, { s = 1, ox = 0, oy = 0 })) do w.groups[#w.groups + 1] = g end
            for _j, h in ipairs(marks[p] or {}) do
                local _c, hex = BookExport.colour(h.color)
                w.marks[#w.marks + 1] = { pboxes = h.pboxes, drawer = h.drawer, color = hex, note = h.note }
            end
            if #ops > 0 then
                -- the picture is drawn at the screen's resolution, as a picture PDF's pages are
                local native = Document.getNativePageDimensions(book.ui.document, p)
                if native and native.w and native.h then
                    local z = math.min(W / native.w, H / native.h)
                    w.geo = { cw = math.max(1, math.floor(native.w * z + 0.5)), ch = math.max(1, math.floor(native.h * z + 0.5)),
                        m = { s = z, ox = 0, oy = 0 }, pw = native.w, ph = native.h,
                        ops = function() return BookExport.pageOps(items[p], nil, z, picture) end }
                end
            end
        end
    else
        local nb = self.notebook
        self:ensureNotebookPDF()
        for i = 1, nb:count() do
            local pg = nb.pages[i]
            local ops = pg.ops or {}
            if #ops > 0 then
                if pg.src then
                    local m = self._nb_pdf_doc and fitMap(self._nb_pdf_doc, pg.src, nb.w, nb.h)
                    local native = m and require("document/document").getNativePageDimensions(self._nb_pdf_doc, pg.src)
                    if m and native then
                        lists[#lists + 1] = ops
                        local w = page(pg.src)
                        for _j, g in ipairs(Annots.convert(ops, m)) do w.groups[#w.groups + 1] = g end
                        for _j, op in ipairs(ops) do w.ops[#w.ops + 1] = op end
                        w.geo = { cw = nb.w, ch = nb.h, m = m, pw = native.w, ph = native.h, ops = function() return w.ops end }
                    end
                elseif #Annots.settle(ops) > 0 then
                    added = added + 1
                end
            end
        end
        table.sort(work, function(a, b) return a.page < b.page end)
    end
    -- the pages with something an annotation cannot hold
    local left_pages = 0
    for _i, w in ipairs(work) do
        if w.geo and Annots.leftOut({ w.geo.ops() }).total > 0 then
            left_pages = left_pages + 1
            if keep then
                local g = w.geo
                w.overlay = function() return self:overlayPicture(g.ops(), g.cw, g.ch, g.m, g.pw, g.ph) end
            end
        end
    end
    return work, Annots.leftOut(lists), added, left_pages
end

-- The sheet that says what an editable PDF cannot hold, with the two ways on:
-- keep those pages' ink as a picture over them, or leave the items out. When no
-- page can take a picture (only ink on pages added to a notebook), there is just
-- the one way on.
function InkAwayView:exportLeftOutSheet(left, added, left_pages, on_leave, on_pictures)
    local field = "_export_left"
    self:closeSheet(field)
    local content_w, gap = self:sheetWidth()
    local lines = {}
    local names = { text = _("Text boxes: %d"), image = _("Pictures: %d"),
        fill = _("Filled shapes and fills: %d"), smudge = _("Smudges: %d") }
    for _i, k in ipairs(Annots.LEFT_OUT) do
        if left[k] > 0 then lines[#lines + 1] = string.format(names[k], left[k]) end
    end
    local parts = {}
    if #lines > 0 then
        parts[#parts + 1] = _("An editable PDF can't hold these as annotations:") .. "\n\n" .. table.concat(lines, "\n")
        parts[#parts + 1] = string.format(_("Keep as pictures puts a picture of your ink over the %d page(s) that have them, so they look as you drew them. Their ink there can't be edited stroke by stroke; every other page stays editable. Leave them out writes the PDF without them."), left_pages)
    end
    if added > 0 then
        parts[#parts + 1] = string.format(_("Pages you added to the notebook aren't in the original PDF, so their ink is left out either way: %d"), added)
    end
    local text = table.concat(parts, "\n\n")
    local function close() self:closeSheet(field) end
    local build = function()
        local w = math.floor((content_w - gap) / 2)
        local g = VerticalGroup:new{ align = "left",
            self:sheetTitle(_("Some items can't stay editable"), content_w, _("Cancel"), close) }
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(g, TextBoxWidget:new{ text = text, width = content_w, face = Font:getFace("cfont", 16) })
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(18) })
        if left_pages > 0 then
            table.insert(g, HorizontalGroup:new{ align = "center",
                self:actionButton(_("Leave them out"), w, function() close(); on_leave() end),
                HorizontalSpan:new{ width = gap },
                self:actionButton(_("Keep as pictures"), w, function() close(); on_pictures() end, true) })
        else
            table.insert(g, self:actionButton(_("Leave them out"), content_w, function() close(); on_leave() end, true))
        end
        return g
    end
    self:showSheet(field, build)
end

-- Write the editable PDF to `path`.
function InkAwayView:writeEditablePDF(path)
    local src = self:exportPdf()
    local work = self:editableWork()
    if #work == 0 then
        self:showNotice(_("There is nothing to export yet."), 3)
        return
    end
    local job, err = Pdfedit.job(src, path, work)
    if not job then
        self:tell(_("Could not export PDF.\n") .. tostring(err))
        return
    end
    self:runExportJob(job, { path = path, n = #work + 1, title = _("Adding your annotations to the PDF"),
        stop = _("Stop exporting? The PDF will not be saved."), pdf = true,
        note = function()
            return job.fell_back and _("Some pages could not be kept as pictures in this PDF, so the items on them were left out.")
        end })
end

------------------------------------------------------------------------------
-- Pictures: what each page is drawn from
------------------------------------------------------------------------------

-- A notebook's pages (the chosen ones) as a spec. An imported PDF's pages are
-- rendered one at a time as each is written, so memory stays flat however long;
-- left out (`include_bg` off) they are just the ink.
function InkAwayView:notebookSpec(o)
    local nb = self.notebook
    self:nbSyncOut()
    local sel = self:selectedNotebookPages()
    local pages_ops, pages = {}, {}
    for j = 1, #sel do pages[j] = nb.pages[sel[j]]; pages_ops[j] = pages[j].ops end
    local spec = { pages = pages_ops, n = #sel, w = nb.w, h = nb.h, quality = 85, numbers = o.numbers,
        outline = self:titledPages(pages),
        template = function(j) return self:exportTemplate(sel[j]) end }
    -- links between the exported pages become links in the PDF
    local at = {}
    for j, p in ipairs(pages) do if p.id then at[p.id] = j end end
    spec.links = function(j)
        return Links.pdfAnnots(pages_ops[j], nb.h, function(to)
            if to.path and to.path ~= self.doc_path then return nil end
            return to.id and at[to.id]
        end)
    end
    if nb.template.pdf_path then
        self:ensureNotebookPDF()
        local doc = self._nb_pdf_doc
        -- the PDF's own page size: a page added to the notebook takes the one before's
        local per_px
        spec.box = function(j)
            local src = nb.pages[sel[j]] and nb.pages[sel[j]].src
            local m = src and doc and fitMap(doc, src, nb.w, nb.h)
            if m then per_px = 1 / m.s end
            return nb.w * (per_px or 1), nb.h * (per_px or 1)
        end
    end
    if nb.template.pdf_path and o.include_bg then
        local doc = self._nb_pdf_doc
        spec.bg = function(j, s)
            s = s or 1
            local src = nb.pages[sel[j]] and nb.pages[sel[j]].src
            local img = src and self:renderPdfPage(doc, src, nb.w * s, nb.h * s) or nil
            if not img then return nil end
            local rgba = bbToRGBA(img, nb.w * s, nb.h * s)
            img:free()
            return rgba
        end
        spec.bg_opaque, spec.quality = true, 80   -- rendered PDF pages are drawn on white
    end
    return spec
end

-- A PDF book's pages (the chosen ones) as a spec, each at its own size: the
-- ink and highlights as ops at the size the page is drawn at, the page itself
-- rendered as it is written. The PDF is opened a second time for it, and
-- closed when the export ends.
function InkAwayView:pdfBookSpec(o)
    local book = self.book
    local pages = self:exportPageList()
    local items, marks = BookExport.inkByPage(book), BookExport.marksByPage(book)
    local picture = function(path) return BookInk.picturePath(book.sidecar, path) end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local doc
    local ok, d = pcall(function() return require("document/documentregistry"):openDocument(BookExport.pdfPath(book)) end)
    if ok then doc = d end
    local Document = require("document/document")
    local geo = {}   -- per step: the page's drawn size and zoom
    local function geom(i)
        local g = geo[i]
        if g then return g end
        local native = doc and Document.getNativePageDimensions(doc, pages[i])
        if not (native and native.w and native.h) then native = { w = W, h = H } end
        local z = math.min(W / native.w, H / native.h)
        g = { w = math.max(1, math.floor(native.w * z + 0.5)), h = math.max(1, math.floor(native.h * z + 0.5)),
            z = z, pw = native.w, ph = native.h }
        geo = { [i] = g }   -- (only the page in hand is kept)
        return g
    end
    local spec = { n = #pages, quality = 80, numbers = o.numbers, template = self:exportDress({ style = "blank" }),
        size = function(i) local g = geom(i); return g.w, g.h end,
        box = function(i) local g = geom(i); return g.pw, g.ph end,
        pages = function(i)
            local g = geom(i)
            return BookExport.pageOps(items[pages[i]], marks[pages[i]], g.z, picture)
        end,
        done = function() if doc then pcall(function() doc:close() end); doc = nil end end }
    if o.include_bg and doc then
        spec.bg = function(i, s)
            local g = geom(i)
            local img = self:renderPdfPage(doc, pages[i], g.w * (s or 1), g.h * (s or 1))
            if not img then return nil end
            local rgba = bbToRGBA(img, g.w * (s or 1), g.h * (s or 1))
            img:free()
            return rgba
        end
        spec.bg_opaque = true
    end
    return spec
end

-- Run fn with the reader's screen refreshes switched off. Moving the reader to a page
-- asks for a refresh of the whole screen, which on e-ink is a flash that holds up
-- the touch screen for as long as it takes: a page at a time that is a flash a
-- page and a Stop that cannot be pressed. The export has its own progress sheet to
-- show; the reader is drawn again when it ends. Returns what fn returns.
local function quietly(fn)
    local set = UIManager.setDirty
    UIManager.setDirty = function() end
    local ok, a, b = pcall(fn)
    UIManager.setDirty = set
    if not ok then error(a, 0) end
    return a, b
end

-- A reflowing book's pages (the chosen ones) as a spec, laid out as the reader
-- has them now: each is the reader's own picture of the page with the ink drawn
-- on it by the same code that draws it while reading (or the ink alone), so it
-- is exactly where it is on the screen. The reader is taken to each page in
-- turn and put back where it was when the export ends.
function InkAwayView:reflowBookSpec(o)
    local book = self.book
    local doc = book.ui.document
    local pages = self:exportPageList()
    local W, H = self.view.canvas_w, self.view.canvas_h
    local Blitbuffer = require("ffi/blitbuffer")
    local shot
    local home = doc:getXPointer()
    local pt = 72 / (Screen:getDPI() or 160)   -- px to points: a page as big as the reader's own
    local spec = { n = #pages, quality = 75, numbers = o.numbers, w = W, h = H,
        template = self:exportDress({ style = "blank" }),
        box = function() return W * pt, H * pt end,
        -- (the reader's own event: moving its document directly does not take)
        prepare = function(i)
            quietly(function() book.ui:handleEvent(Event:new("GotoPage", pages[i])) end)
        end,
        pages = function()
            if o.include_bg then return {} end   -- (the ink is on the page's picture)
            local placed = book:pageOps()
            return placed and placed.ops or {}
        end,
        done = function()
            if shot then shot:free(); shot = nil end
            quietly(function() book.ui:handleEvent(Event:new("GotoXPointer", home)) end)
            book._placed = nil
            if self.loadBookPage then
                self:loadBookPage()
                self:composeCanvas()
                self:renderView()
                self:refresh(self, "partial")
            end
        end }
    if o.include_bg then
        spec.bg = function()
            shot = shot or Blitbuffer.new(W, H, Screen.bb:getType())
            quietly(function() book:snapshot(shot, true) end)
            return bbToRGBA(shot, W, H)
        end
        spec.bg_opaque = true
        -- the page's text laid invisibly under its picture, to search, select and copy
        spec.text = function()
            return PageText.forPdf(PageText.lines(doc, W, H), pt, H * pt)
        end
    end
    return spec
end

-- The spec for the pages the export covers, whatever they are in.
function InkAwayView:exportSpec()
    local o = self:exportOptions()
    if self.book then
        return BookExport.pdfPath(self.book) and self:pdfBookSpec(o) or self:reflowBookSpec(o)
    end
    return self:notebookSpec(o)
end

-- Save the chosen pages as PNGs: one file, or "page-001.png" and on in a folder
-- of the chosen name, white pages unless `transparent`.
function InkAwayView:writePagesPNG(path)
    local o = self:exportOptions()
    local spec = self:exportSpec()
    local one = spec.n == 1
    local dir = one and Storage.dirName(path) or path
    if not one and not Storage.isDir(dir) then
        local ok = pcall(function() require("libs/libkoreader-lfs").mkdir(dir) end)
        if not ok then
            if spec.done then spec.done() end
            self:tell(_("Could not make the folder.\n") .. path)
            return
        end
    end
    local job, err = Export.pagesPNGJob(spec.pages, spec.w, spec.h, spec.template, dir, spec.bg, {
        n = spec.n, size = spec.size, prepare = spec.prepare, bg_opaque = spec.bg_opaque,
        white = not o.transparent or nil, file = one and function() return path end or nil })
    if not job then
        if spec.done then spec.done() end
        self:tell(_("Could not save the images.\n") .. tostring(err))
        return
    end
    self:runExportJob(job, { path = path, n = spec.n, done = spec.done, images = not one and dir or nil,
        title = string.format(_("Saving %d page(s) as images"), spec.n),
        stop = _("Stop exporting? The images saved so far will be deleted.") })
end

return InkAwayView
