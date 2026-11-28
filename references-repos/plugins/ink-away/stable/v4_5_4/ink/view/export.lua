--[[
Exporting: one sheet for drawings and notebooks, a PNG of the page (or a part
of it) or a PDF of some or all pages, then a file name in the export folder.
Titled pages become the PDF's bookmarks. Also a whole folder as one PDF, and
bookshelf ornaments.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("ink/l10n")
local RenderImage = require("ui/renderimage")
local Export = require("ink/export")
local ImageProc = require("ink/imageproc")
local Layers = require("ink/layers")
local Links = require("ink/links")
local Notebook = require("ink/notebook")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Project = require("ink/project")
local Storage = require("ink/storage")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local existingDir = Storage.existingDir
local strengthToLevel = Paint.strengthToLevel
local bbToRGBA = ImageProc.bbToRGBA
local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

-- The paper an export lays a page of paper `p` on ({r,g,b}, nil for white): `p`
-- itself, unless the export is set to White (`choice`) or the paper is left out
-- (`kept` false). A dark paper always stays, or the white ink on it would not
-- show.
local function exportPaperFor(p, choice, kept)
    p = Palette.paperRGB(p)
    if not p or Paint.darkPaper(p) then return p end
    if choice == "white" or not kept then return nil end
    return p
end

-- Give export template t the page's look (see ink/export.lua): paper `paper`
-- (nil for white), its ruling of `strength` in the paper's shade, and the text
-- black, or white on a dark paper.
local function dress(t, paper, strength)
    t.paper = paper or { 255, 255, 255 }
    t.gray = strengthToLevel(strength)
    t.rule = Paint.rulingRGB(paper, strength)
    t.dark = Paint.darkPaper(paper)
    local ink = t.dark and 255 or 0
    t.ink = { ink, ink, ink }
    return t
end

local InkAwayView = {}

------------------------------------------------------------------------------
-- Export area: drag a rectangle to export just part of the page
------------------------------------------------------------------------------

function InkAwayView:cropTouch(pos)
    self._crop_screen = { x0 = pos.x, y0 = pos.y, x1 = pos.x, y1 = pos.y }
    self:refreshArea()
    return true
end

function InkAwayView:cropMove(pos)
    if not (pos and self._crop_screen) then return true end
    local c = self._crop_screen
    local ox0, oy0, ox1, oy1 = c.x0, c.y0, c.x1, c.y1   -- previous box
    c.x1, c.y1 = pos.x, pos.y
    -- refresh only the union of the old and new boxes, with the fast waveform,
    -- so dragging stays smooth (on colour e-ink, once the panel showed the last)
    if c.shown then self:waitForPanel() end
    c.shown = true
    self:liveBox("fast", math.min(ox0, ox1, c.x0, c.x1) - 3, math.min(oy0, oy1, c.y0, c.y1) - 3,
        math.max(ox0, ox1, c.x0, c.x1) + 3, math.max(oy0, oy1, c.y0, c.y1) + 3)
    return true
end

function InkAwayView:cropRelease(pos)
    if pos and self._crop_screen then self._crop_screen.x1, self._crop_screen.y1 = pos.x, pos.y end
    self.selecting_crop = false
    local c = self._crop_screen
    self._crop_screen = nil
    if c then
        local ax0, ay0 = self:toCanvasClamped(c.x0, c.y0)
        local ax1, ay1 = self:toCanvasClamped(c.x1, c.y1)
        local x0, x1 = math.min(ax0, ax1), math.max(ax0, ax1)
        local y0, y1 = math.min(ay0, ay1), math.max(ay0, ay1)
        local w, h = math.floor(x1 - x0), math.floor(y1 - y0)
        self.save_area = (w >= 8 and h >= 8)
            and { x = math.floor(x0), y = math.floor(y0), w = w, h = h } or nil
    end
    self:refresh(self, "full")
    self:openExport()   -- back to the export sheet with the area now chosen
    return true
end

------------------------------------------------------------------------------
-- The export sheet
------------------------------------------------------------------------------

-- The open document's export settings, kept in its file: format, pages, paper,
-- whether the background or paper and page numbers are included, and the last
-- name (and folder, when one was picked) it was exported under.
function InkAwayView:exportOptions()
    if not self.export_opts then
        local nb = self.notebook
        local paged = nb or self.book
        -- a book starts from the pages with ink: what was written, not all of it
        self.export_opts = { fmt = paged and "pdf" or "png", scope = self.book and "ink" or "all",
            transparent = not paged, include_bg = true, on_paper = "page", numbers = false,
            pdf_type = "editable" }
    end
    return self.export_opts
end

-- The folder exports go to: the one picked for this document, else the export
-- folder from the settings, else "ink away/exports".
function InkAwayView:exportDir()
    local o = self:exportOptions()
    return existingDir(o.dir) or self:defaultExportDir()
end

function InkAwayView:defaultExportDir()
    local chosen = self:getSetting("inkaway_export_dir")
    if chosen and Storage.isDir(chosen) then return chosen end
    return Storage.appDir("exports") or self:libraryDir()
end

-- The notebook page indices the export covers: the page shown, all pages, only
-- pages that have ink, or a page range.
function InkAwayView:selectedNotebookPages()
    local nb = self.notebook
    local o = self:exportOptions()
    local sel = {}
    if o.scope == "page" then
        sel[1] = nb.index
    elseif o.scope == "ink" then
        for i = 1, nb:count() do
            if nb.pages[i].ops and #nb.pages[i].ops > 0 then sel[#sel + 1] = i end
        end
    elseif o.scope == "range" and o.range then
        local a = math.max(1, math.min(nb:count(), o.range.from or 1))
        local b = math.max(a, math.min(nb:count(), o.range.to or nb:count()))
        for i = a, b do sel[#sel + 1] = i end
    else
        for i = 1, nb:count() do sel[#sel + 1] = i end
    end
    return sel
end

-- One sheet for every export: PNG or PDF, then what goes in it, then Export. A
-- drawing's PNG holds the page shown (or the area chosen on it). A notebook or
-- a book can export the page shown, all pages, the ones with ink or a range,
-- as a PDF or as PNGs. A PDF (a PDF notebook, a PDF book) can instead be saved
-- as an editable PDF: a copy of the original with the ink and highlights as
-- annotations. What each source can do is decided here and in
-- ink/view/exportbook.lua, nowhere else.
function InkAwayView:openExport()
    self:flushPending()
    self:resetLasso()   -- drop any selection first
    if self.notebook then self:nbSyncOut() end
    if self.book then self:saveDocument() end
    if not self:exportHasContent() then
        self:showNotice(_("There is nothing to export yet."), 2)
        return
    end
    local o = self:exportOptions()
    local nb, book = self.notebook, self.book
    local paged = nb or book
    local count = paged and self:exportCount() or 1
    local pdf_src = paged and self:exportPdf() or nil
    local can_edit = pdf_src and o.fmt == "pdf" and self:exportEditable() or false
    local editable = can_edit and o.pdf_type ~= "pictures"
    -- a book that reflows is saved as pictures laid out as it is now
    local reflow = book and not pdf_src
    self:closeSheet("_save_dialog")
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_save_dialog") end
    local reopen = function() self:openExport() end   -- rebuild after a choice changes the layout
    local left, added, left_pages
    if editable then
        left, added, left_pages = select(2, self:editableWork())
    end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        local function toggle(label, key, after)
            add(vspan(10))
            add(ToggleRow:new{ label = label, is_on = o[key] and true or false, width = content_w, parent = menu,
                callback = function(on) o[key] = on; if after then after() end end })
        end
        add(self:sheetTitle(_("Export"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(self:sheetLabel(_("Format"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "png", _("PNG images") }, { "pdf", _("PDF") } }, o.fmt, content_w,
            function(v) o.fmt = v; reopen() end))
        if can_edit then
            add(vspan(12))
            add(self:sheetLabel(_("PDF type"), true))
            add(vspan(6))
            add(self:segmentedRow({ { "editable", _("Editable") }, { "pictures", _("Pictures") } },
                editable and "editable" or "pictures", content_w,
                function(v) o.pdf_type = v; reopen() end))
            add(vspan(4))
            add(self:sheetHint(editable
                and _("Adds your ink and highlights to a copy of the original PDF. The text stays real, the file stays small, and any PDF viewer can edit or remove them.")
                or _("Saves each page as a picture with your ink on it. It looks the same everywhere, but the file is bigger and its text can't be selected."), content_w))
            if editable and left.total + added > 0 then
                add(vspan(4))
                add(self:sheetHint(string.format(_("%d item(s) can't be kept editable. You'll choose what to do when you export."),
                    left.total + added), content_w))
            end
        end
        if paged and not editable then
            add(vspan(12))
            add(self:sheetLabel(_("Pages"), true))
            add(vspan(6))
            add(self:segmentedRow({ { "page", _("This page") }, { "all", _("All") }, { "ink", _("With ink") },
                    { "range", _("Range") } }, o.scope, content_w,
                function(v)
                    o.scope = v
                    if v == "range" and not o.range then o.range = { from = 1, to = count } end
                    reopen()
                end))
            if o.scope == "range" then
                add(vspan(8))
                add(self:actionButton(string.format(_("Pages %d\u{2013}%d (tap to change)"),
                    o.range.from or 1, o.range.to or count), content_w,
                    function() closeSelf(); self:promptExportRange() end))
            end
        end
        if o.fmt == "png" then
            if paged and o.scope ~= "page" then
                add(vspan(4))
                add(self:sheetHint(_("One PNG per page, in a folder of its own."), content_w))
            elseif not book then
                add(vspan(12))
                local area = self.save_area
                    and string.format(_("Area: %d\u{00D7}%d (tap for the whole page)"), self.save_area.w, self.save_area.h)
                    or _("Area: the whole page (tap to choose)")
                add(self:actionButton(area, content_w, function()
                    if self.save_area then self.save_area = nil; reopen()
                    else closeSelf(); self:beginCropSelect() end
                end))
                if nb and nb:count() > 1 then
                    add(vspan(4))
                    add(self:sheetHint(string.format(_("A PNG holds the page shown, page %d."), nb.index), content_w))
                end
            end
        elseif not editable and not book then
            -- a light paper can print on white instead (a dark one always goes,
            -- or its white ink would not show)
            local p = self:paperRGB()
            if p and not Paint.darkPaper(p) then
                add(vspan(12))
                add(self:sheetLabel(_("Paper"), true))
                add(vspan(6))
                add(self:segmentedRow({ { "page", Palette.paperName(p) }, { "white", _("White") } },
                    o.on_paper == "white" and "white" or "page", content_w,
                    function(v) o.on_paper = v; reopen() end))
            end
        end
        if not editable then
            if nb then
                toggle(pdf_src and _("Include the PDF page") or _("Include the paper"), "include_bg")
            elseif book then
                toggle(_("Include the book's pages"), "include_bg")
                if not o.include_bg then
                    add(vspan(4))
                    add(self:sheetHint(_("Only your ink, on white pages."), content_w))
                end
            elseif self.bg_bb then
                toggle(_("Include the background"), "include_bg")
            end
            if reflow and o.fmt == "pdf" then
                add(vspan(4))
                add(self:sheetHint(_("The pages are saved as pictures with their text under them, so it can be searched and selected. They are laid out as you read them now: your font, margins and page size."), content_w))
                -- a picture of a page is a few hundred KB: say what the PDF will weigh
                local mb = math.floor(#self:exportPageList() * 0.3 + 0.5)
                if mb >= 10 and o.include_bg then
                    add(vspan(4))
                    add(self:sheetHint(string.format(_("A picture of each page takes about 0.3 MB, so this PDF will be around %d MB."), mb), content_w))
                end
            end
            -- a drawing's grid can go into an export on a page (not a transparent one)
            local grid_row = not paged and self.grid_on
            if o.fmt == "png" then toggle(_("Transparent"), "transparent", grid_row and reopen or nil) end
            if grid_row and (o.fmt == "pdf" or not o.transparent) then toggle(_("Include the grid"), "include_grid") end
            if o.fmt == "pdf" then toggle(_("Page numbers"), "numbers") end
        end
        add(vspan(16))
        local label = _("Export PNG")
        if editable then
            label = _("Export editable PDF")
        elseif o.fmt == "pdf" then
            label = paged and string.format(_("Export %d page(s) to PDF"), #self:exportPageList())
                or _("Export PDF")
        elseif paged and o.scope ~= "page" then
            label = string.format(_("Export %d page(s) as PNGs"), #self:exportPageList())
        end
        add(self:actionButton(label, content_w, function()
            local function go() closeSelf(); self:promptExportName() end
            if editable then
                if left.total + added > 0 then
                    closeSelf()
                    self:exportLeftOutSheet(left, added, left_pages,
                        function() o.keep_pictures = false; self:promptExportName() end,
                        function() o.keep_pictures = true; self:promptExportName() end)
                    return
                end
            elseif paged and #self:exportPageList() == 0 then
                self:showNotice(o.scope == "ink" and _("None of the pages has ink.") or _("No pages match the chosen range."), 3)
                return
            end
            go()
        end, true))
        -- save straight into the bookshelf plugin's ornament folder, when that
        -- plugin is in use; always a transparent PNG
        if o.fmt == "png" and not paged and self:ornamentsDir() then
            add(vspan(10))
            add(self:actionButton(_("Save as bookshelf ornament"), content_w, function()
                closeSelf(); self:saveOrnament() end, nil, nil, "frame"))
        end
        -- (see ink/view/share.lua)
        if not book then
            add(vspan(10))
            add(self:actionButton(_("Send to phone or computer (Wi-Fi)\u{2026}"), content_w, function()
                closeSelf(); self:openSend() end, nil, nil, "qr"))
        end
        return content
    end
    self:showSheet("_save_dialog", build)
end

-- Enter the area-selection mode: the next drag marks the export rectangle.
function InkAwayView:beginCropSelect()
    self.selecting_crop = true
    self._crop_screen = nil
    self:showNotice(_("Drag a box around the part to export. A single tap keeps the whole page."), 3)
    self:refreshArea()
end

-- Ask for the first and last page of the export range.
function InkAwayView:promptExportRange()
    local count = self:exportCount()
    local o = self:exportOptions()
    self:promptText{
        title = string.format(_("Page range (1\u{2013}%d), e.g. 3-8"), count),
        input = string.format("%d-%d", o.range.from or 1, o.range.to or count),
        ok_text = _("Set"),
        on_ok = function(text)
            local s = text or ""
            local a, b = s:match("(%d+)%s*[%-\u{2013}to,%s]+(%d+)")
            if not a then a = s:match("(%d+)"); b = a end
            if a then o.range = { from = tonumber(a), to = tonumber(b) } end
            self:openExport()
        end,
        on_cancel = function() self:openExport() end,
    }
end

-- Ask for an export file name in folder o.dir, with a Folder button to pick
-- another, then call o.on_path(path) once writing there is fine (asking first
-- if it would replace a file). `o` holds title, name, default, dir, ext, and
-- on_dir(dir) for a folder picked on the way.
function InkAwayView:askExportPath(o)
    self:promptText{
        title = o.title, input = o.name, default = o.default,
        description = string.format(_("Into %s"), Storage.shortPath(o.dir)),
        ok_text = _("Export"),
        extra = { text = _("Folder\u{2026}"), callback = function(text)
            self:pickFolder(o.dir, function(d)
                if o.on_dir then o.on_dir(d) end
                o.dir, o.name = d, text
                self:askExportPath(o)
            end)
        end },
        on_ok = function(text)
            -- (a folder of images takes the name as it is)
            local path = o.ext and Storage.join(o.dir, Storage.fileName(text, o.ext))
                or Storage.join(o.dir, (text:gsub("[/\\]", "_")))
            self:confirmReplace(path, function() o.on_path(path) end)
        end,
    }
end

-- Ask for the file name, starting from the last export's name (else the
-- document's), in the export folder; Folder... picks another folder for this
-- document. Then write it.
function InkAwayView:promptExportName(name, dir)
    local o = self:exportOptions()
    local ext = o.fmt
    local paged = self.notebook or self.book
    -- PNGs of several pages go in a folder of their own, named here
    local folder = ext == "png" and paged and o.scope ~= "page" and #self:exportPageList() > 1
    local title = ext == "pdf" and _("Export as PDF") or folder and _("Export as images") or _("Export as PNG")
    self:askExportPath{
        title = title,
        name = name or o.name or self:exportName(), default = self:exportName(),
        dir = dir or self:exportDir(), ext = not folder and ext or nil,
        on_dir = function(d) o.dir = d end,
        on_path = function(path)
            o.name = Storage.stem(path)
            if ext == "pdf" then self:writeExport(path)
            elseif paged and (folder or self.book) then self:writePagesPNG(path)
            elseif paged and o.scope ~= "page" then self:writePagesPNG(path)
            else self:writePNG(path) end
        end,
    }
end

------------------------------------------------------------------------------
-- Writing the files
------------------------------------------------------------------------------

-- The template an export draws notebook page i with: the page's ruling, the
-- paper colour and ruling grey worked out, or no ruling when the paper is left
-- out. A copy, so nothing sticks to the notebook.
function InkAwayView:exportTemplate(i)
    local o = self:exportOptions()
    return self:pageExportTemplate(self.notebook, i, o.on_paper, o.include_bg)
end

-- The export template of page i of notebook nb: its paper (or white when
-- `choice` is "white"), with or without its paper and ruling (`ruled`).
function InkAwayView:pageExportTemplate(nb, i, choice, ruled)
    local template = {}
    for k, v in pairs(nb.template) do template[k] = v end
    template.style = nb:pageTemplate(i).style
    dress(template, exportPaperFor(nb.template.paper, choice, ruled), template.strength)
    if not ruled and not template.pdf_path then template.style = "blank" end
    return template
end

-- The drawing's grid as an export template, on its paper (or white when
-- `choice` is "white"), or nil when the grid is off or left out of the export.
function InkAwayView:drawingGridTemplate(choice)
    local o = self:exportOptions()
    if self.notebook or not (o.include_grid and self.grid_on) then return nil end
    local style = self.grid_style or "square"
    if style == "square" then style = "grid" end
    return dress({ style = style, size = self.grid_size },
        exportPaperFor(self.paper, choice or o.on_paper, true), self.grid_strength)
end

-- A drawing's export template without a grid: its paper (or white when
-- `choice` is "white") and the text's colour on it.
function InkAwayView:drawingPaperTemplate(choice)
    local o = self:exportOptions()
    return dress({ style = "blank" }, exportPaperFor(self.paper, choice or o.on_paper, true))
end

-- Bookmarks for the titled pages among `pages` (notebook pages, in export
-- order): { title, page } each.
function InkAwayView:titledPages(pages)
    local out = {}
    for j, page in ipairs(pages) do
        if page.title then out[#out + 1] = { title = page.title, page = j } end
    end
    return out
end

-- A blank export template on white, for a page with only ink on it.
function InkAwayView:exportDress(t)
    return dress(t, nil)
end

-- Export.savePNG options for the page shown: the area, the paper or background
-- when included, and white unless transparent.
function InkAwayView:pngOptions()
    local o = self:exportOptions()
    local opts = { rect = self.save_area, white = not o.transparent or nil }
    if o.include_bg then
        if self.notebook then opts.template = self:exportTemplate(self.notebook.index) end
        if self.bg_bb then opts.bg = self.bg_rgba or self:buildBgRGBA() end
    end
    if not o.transparent then opts.template = opts.template or self:drawingGridTemplate() end
    -- else the page's paper, to lay it on (and for the text's colour)
    if not opts.template then
        opts.template = self.notebook and dress({ style = "blank" },
            exportPaperFor(self.notebook.template.paper, o.on_paper, o.include_bg)) or self:drawingPaperTemplate()
    end
    return opts
end

function InkAwayView:writePNG(path)
    local ok, err = Export.savePNG(self:drawnCanvas(), path, self:pngOptions())
    if ok then
        self:markDirty()   -- keep the export settings with the document
        local ow = self.save_area and self.save_area.w or self.canvas.w
        local oh = self.save_area and self.save_area.h or self.canvas.h
        self:tell(string.format(_("Saved %d × %d image:\n%s"), ow, oh, path))
    else
        logger.warn("InkAway: export failed:", err)
        self:tell(string.format(_("Could not save the image.\n%s"), tostring(err)))
    end
end

-- Write the export as the sheet has it set: an editable PDF where that is
-- chosen and possible, else the pages as pictures.
function InkAwayView:writeExport(path)
    local o = self:exportOptions()
    if o.pdf_type ~= "pictures" and (self.notebook or self.book) and self:exportEditable() then
        return self:writeEditablePDF(path)
    end
    return self:writePDF(path)
end

-- Write the chosen pages (a drawing is one page) to a PDF as pictures.
function InkAwayView:writePDF(path)
    local o = self:exportOptions()
    if self.notebook or self.book then return self:runPdfJob(path, self:exportSpec()) end
    local bg
    if o.include_bg and self.bg_bb then bg = self.bg_rgba or self:buildBgRGBA() end
    self:runPdfJob(path, { pages = { self:drawnOps() }, w = self.canvas.w, h = self.canvas.h,
        template = self:drawingGridTemplate() or self:drawingPaperTemplate(), bg = bg,
        numbers = o.numbers, quality = 85 })
end

-- Add the pages of the document at `path` to `acc` (pages, templates, sources,
-- places): a notebook's pages on their own paper, or a drawing as one page.
-- Returns its bookmark (the titled pages of a notebook under it), or nil when
-- the file holds no document.
function InkAwayView:collectDocumentPages(path, acc)
    local data = Project.load(path)
    if not data then return nil end
    local pages, templates, sources = acc.pages, acc.templates, acc.sources
    acc.places = acc.places or {}
    local item = { title = Storage.stem(Storage.baseName(path)), page = #pages + 1, kids = {} }
    if Project.isNotebook(data) then
        local nb = Notebook.fromData(data)
        for i, page in ipairs(nb.pages) do
            pages[#pages + 1] = page.ops
            acc.places[#pages] = { path = path, id = page.id }
            templates[#pages] = self:pageExportTemplate(nb, i, "page", true)
            if nb.template.pdf_path and page.src then
                sources[#pages] = { pdf = nb.template.pdf_path, src = page.src }
            end
            if page.title then item.kids[#item.kids + 1] = { title = page.title, page = #pages } end
        end
    else
        pages[#pages + 1] = Layers.drawnOfFile(data.ops or {}, data.layers)
        acc.places[#pages] = { path = path }
        templates[#pages] = dress({ style = "blank" }, Palette.paperRGB(data.paper))
        if type(data.bg) == "string" and Storage.exists(data.bg) then sources[#pages] = { image = data.bg } end
    end
    return item
end

-- Add the pages of folder `dir` to `acc` (pages, templates, sources): its
-- subfolders first, then its documents, in the overview's tab order. Returns
-- the outline: a bookmark per folder and document, with the titled pages of a
-- notebook under it.
function InkAwayView:collectFolderPages(dir, acc)
    local folders, docs = self:binderEntries(dir)
    local pages = acc.pages
    acc.places = acc.places or {}   -- each page's document and id, for links
    local outline = {}
    for _, f in ipairs(folders) do
        local first = #pages + 1
        local kids = self:collectFolderPages(f.path, acc)
        if #pages >= first then outline[#outline + 1] = { title = f.name, page = first, kids = kids } end
    end
    for _, d in ipairs(docs) do
        local item = self:collectDocumentPages(d.path, acc)
        if item then outline[#outline + 1] = item end
    end
    return outline
end

-- The PDF job's spec (see runPdfJob) for the pages gathered in `acc` (see
-- collectDocumentPages): links between them kept, backgrounds rendered page by
-- page, and the PDFs they come from closed when the job ends.
function InkAwayView:pagesPdfSpec(acc, outline)
    local W, H = self.view.canvas_w, self.view.canvas_h
    -- links to pages in the folder become links in the PDF, across notebooks too
    local at = {}
    for j, p in ipairs(acc.places) do
        if p.id then at[p.path .. "\0" .. p.id] = j end
    end
    local function links(j)
        local here = acc.places[j] and acc.places[j].path
        return Links.pdfAnnots(acc.pages[j], H, function(to)
            local p = to.path or here
            return p and to.id and at[p .. "\0" .. to.id]
        end)
    end
    local pages, templates, sources = acc.pages, acc.templates, acc.sources
    -- page backgrounds are rendered as each page is written: a PDF page from its
    -- document (kept open until the export ends) or a drawing's picture
    local docs_open = {}
    local function bg(j, s)
        local b = sources[j]
        if not b then return nil end
        s = s or 1
        local img
        if b.pdf then
            if docs_open[b.pdf] == nil then
                local ok, doc = pcall(function() return require("document/documentregistry"):openDocument(b.pdf) end)
                docs_open[b.pdf] = ok and doc or false
            end
            img = docs_open[b.pdf] and self:renderPdfPage(docs_open[b.pdf], b.src, W * s, H * s)
        else
            local ok, raw = pcall(function() return RenderImage:renderImageFile(b.image, false) end)
            img = ok and raw and fitIntoCanvasBB(raw, W * s, H * s) or nil
        end
        if not img then return nil end
        local rgba = bbToRGBA(img, W * s, H * s)
        img:free()
        return rgba
    end
    local function closeDocs()
        for _, doc in pairs(docs_open) do if doc then pcall(function() doc:close() end) end end
        docs_open = {}
    end
    return { pages = pages, w = W, h = H, bg = bg, outline = outline, links = links,
        template = function(j) return templates[j] end, done = closeDocs }
end

-- Export folder `dir` with everything in it, its subfolders too, as one PDF:
-- each notebook's pages on their own paper, each drawing a page, and nested
-- bookmarks for the folders, documents and titled pages.
function InkAwayView:exportFolderPDF(dir)
    self:leaveDocument()   -- so the open document's latest changes are in its file
    local acc = { pages = {}, templates = {}, sources = {}, places = {} }
    local outline = self:collectFolderPages(dir, acc)
    if #acc.pages == 0 then
        self:showNotice(_("There is nothing to export in this folder."), 3)
        return
    end
    local spec = self:pagesPdfSpec(acc, outline)
    self:askExportPath{
        title = _("Export the folder as PDF"), name = Storage.baseName(dir), default = Storage.baseName(dir),
        dir = self:defaultExportDir(), ext = "pdf",
        on_path = function(path) self:runPdfJob(path, spec) end,
    }
end

-- Write a PDF of pictures one page per UI step, with a progress bar and a way to
-- stop, then offer to open it. `spec` holds pages (op lists, or a function of
-- the page), n (when pages is a function), w and h (or size, and box: each
-- page's own), template (one, or a function of the page), bg (one RGBA buffer,
-- or a function rendering each page's own), bg_opaque, numbers, quality,
-- outline, links, prepare and done(), called when the job ends however it ends
-- (see Export.notebookPDFJob).
function InkAwayView:runPdfJob(path, spec)
    local n = spec.n or #spec.pages
    -- each page streams to disk and is freed before the next, so a long
    -- imported PDF neither freezes the reader nor builds the whole file in memory
    local job, jerr = Export.notebookPDFJob(spec.pages, spec.w, spec.h, spec.template, path, spec.quality or 85,
        Storage.settingsDir(), spec.bg,
        { footer = spec.numbers or nil, bg_opaque = spec.bg_opaque or nil, outline = spec.outline,
          links = spec.links, n = spec.n, size = spec.size, box = spec.box, prepare = spec.prepare, text = spec.text })
    if not job then
        if spec.done then spec.done() end
        self:tell(_("Could not export PDF.\n") .. tostring(jerr))
        return
    end
    self:runExportJob(job, { path = path, n = n, done = spec.done, pdf = true,
        title = string.format(_("Exporting %d page(s) to PDF"), n),
        stop = _("Stop exporting? The PDF will not be saved.") })
end

-- Run an export job (anything with step() and cancel(), see Export.notebookPDFJob)
-- a step at a time under a progress sheet whose Stop ends it for good: the
-- job's partial files are deleted and `o.done` runs however it ends. `o`: path,
-- n (the steps shown), title, stop (what Stop asks), done(), pdf (offer to open
-- the PDF at the end) or images (the folder, to say where they went).
function InkAwayView:runExportJob(job, o)
    self._export_job = job
    local function finish()
        if self._export_job == job then self._export_job = nil end
        self._export_finish = nil
        if o.done then o.done() end
    end
    self._export_finish = finish   -- (for Ink Away closing under the job)
    local function stopped()
        job.cancel()
        finish()
    end
    self:runSteps{
        title = o.title, max = o.n, dismiss_text = o.stop,
        pause = 0.15,   -- (time to hear a touch between pages)
        step = function()
            if self._export_job ~= job then return "abort" end
            local state, a = job.step()
            if not state then return nil, a end
            if state == "done" then return "done" end
            return a or 0
        end,
        on_cancel = function()
            stopped()
            self:showNotice(_("Export stopped."), 2)
        end,
        on_error = function(err)
            stopped()
            self:tell(_("Could not export.\n") .. tostring(err))
        end,
        on_done = function()
            finish()
            self:markDirty()   -- keep the export settings with the document
            if o.pdf then
                -- make the PDF open as a full page with no auto-crop the first time
                self:seedPdfView(o.path)
                local note = o.note and o.note()
                self:ask{ title = _("PDF saved"), text = o.path .. (note and ("\n\n" .. note) or "") .. "\n\n" .. _("Open the PDF now?"),
                    ok_text = _("Open"), ok_icon = "open", on_ok = function() self:openExportedPDF(o.path) end }
            elseif o.images then
                self:tell(string.format(_("Saved %d page(s) as images:\n%s"), o.n, o.images))
            else
                self:tell(string.format(_("Saved image:\n%s"), o.path))
            end
        end,
    }
end

-- Seed a freshly exported PDF's sidecar so KOReader opens it as a whole page
-- with no margin cropping (its defaults would zoom into the ink and clip it).
-- Best effort.
function InkAwayView:seedPdfView(path)
    local dok, DocSettings = pcall(require, "docsettings")
    if not (dok and DocSettings) then return end
    pcall(function()
        local ds = DocSettings:open(path)
        if not ds then return end
        ds:saveSetting("kopt_trim_page", 3)         -- 3 = "none": no margin cropping at all
        ds:saveSetting("kopt_zoom_mode_genus", 4)   -- 4 = "page"
        ds:saveSetting("kopt_zoom_mode_type", 2)    -- 2 = full (not width/height)
        ds:flush()
    end)
end

-- Hand a freshly exported PDF to KOReader's reader, closing the plugin view.
function InkAwayView:openExportedPDF(path)
    local rok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not (rok and ReaderUI) then
        self:showNotice(_("Saved. Open it from your library."), 3)
        return
    end
    self:leaveDocument()
    self.closing = true
    UIManager:close(self)
    UIManager:nextTick(function() ReaderUI:showReader(path) end)
end

-- Is the bookshelf plugin present? Checks KOReader's loaded-plugin registry (found
-- wherever it is installed), then the folders next to this plugin and in the user
-- plugins folder. Cached for the session.
function InkAwayView:bookshelfInstalled()
    if self._bookshelf_seen ~= nil then return self._bookshelf_seen end
    local seen = false
    pcall(function()
        local PluginLoader = require("pluginloader")
        local groups = { PluginLoader.enabled_plugins }
        for _, group in ipairs(groups) do
            if type(group) == "table" then
                for _, p in ipairs(group) do
                    local path = type(p) == "table" and p.path
                    if type(path) == "string" and path:lower():find("bookshelf%.koplugin") then
                        seen = true; return
                    end
                end
            end
        end
    end)
    if not seen then
        local cand = { self:pluginDir() .. "../bookshelf.koplugin" }
        local data = Storage.dataDir()
        if data then cand[#cand + 1] = data .. "/plugins/bookshelf.koplugin" end
        for _, d in ipairs(cand) do
            if Storage.isDir(d) then seen = true; break end
        end
    end
    self._bookshelf_seen = seen
    return seen
end

-- The bookshelf plugin's ornament folder (koreader/icons/bookshelf.ornaments), or
-- nil when that plugin is not in use (neither the folder nor the plugin exists).
-- An ornament is a transparent PNG dropped in here. KOReader never creates icons/
-- itself, so callers create the folders.
function InkAwayView:ornamentsDir()
    local data = Storage.dataDir()
    if not data then return nil end
    local dir = data .. "/icons/bookshelf.ornaments"
    if Storage.isDir(dir) or self:bookshelfInstalled() then return dir end
    return nil
end

-- Save the canvas into the bookshelf ornament folder as a transparent PNG. The
-- folder is fixed, so this only asks for a name; it creates the folders if needed.
function InkAwayView:saveOrnament()
    local dir = self:ornamentsDir()
    if not dir then return end
    Storage.ensureDir(dir:match("^(.*)/"))   -- icons/
    if not Storage.ensureDir(dir) then
        self:tell(_("Could not create the bookshelf ornaments folder."))
        return
    end
    self:promptOrnamentName(dir)
end

-- Ask for an ornament name, then write it. A trailing ".invert" is kept (the
-- bookshelf plugin reads name.invert.png as the dark-mode variant); ".png" is
-- added when the name does not already end in it.
function InkAwayView:promptOrnamentName(dir)
    local default_name = os.date("ornament-%Y%m%d-%H%M%S")
    self:promptText{
        title = _("Ornament name"), input = default_name, hint = default_name, default = default_name,
        description = _("Saved as a transparent PNG in the bookshelf ornaments folder.\nEnd the name with .invert for a dark-mode version."),
        ok_text = _("Save"),
        on_ok = function(name)
            self:confirmReplace(Storage.join(dir, Storage.fileName(name, "png")),
                function() self:writeOrnament(dir, name) end)
        end,
    }
end

function InkAwayView:writeOrnament(dir, name)
    local path = Storage.join(dir, Storage.fileName(name, "png"))
    local opts = self:pngOptions()
    opts.white = nil   -- an ornament is always transparent
    if not self.notebook then opts.template = nil end   -- and has no grid
    local ok, err = Export.savePNG(self:drawnCanvas(), path, opts)
    if ok then
        self:tell(string.format(_("Saved bookshelf ornament:\n%s"), path))
    else
        logger.warn("InkAway: ornament save failed:", err)
        self:tell(string.format(_("Could not save the ornament.\n%s"), tostring(err)))
    end
end

-- The export area being chosen.
function InkAwayView:paintCropOverlay(bb, x, y)
    local v = self.view
    local c = self._crop_screen
    local cx0 = math.max(x + v.area_x, math.min(x + v.area_x + v.area_w, c.x0))
    local cy0 = math.max(y + v.area_y, math.min(y + v.area_y + v.area_h, c.y0))
    local cx1 = math.max(x + v.area_x, math.min(x + v.area_x + v.area_w, c.x1))
    local cy1 = math.max(y + v.area_y, math.min(y + v.area_y + v.area_h, c.y1))
    if cx1 < cx0 then cx0, cx1 = cx1, cx0 end
    if cy1 < cy0 then cy0, cy1 = cy1, cy0 end
    Paint.outline(bb, cx0, cy0, cx1 - cx0, cy1 - cy0, self:textInk(), 2)
end

return InkAwayView
