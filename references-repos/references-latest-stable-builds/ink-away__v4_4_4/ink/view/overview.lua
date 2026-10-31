--[[
The overview: the pages of a notebook as thumbnails, with the folders and
notebooks of its folder as tabs down the side, like dividers in a binder
(drawings stay in the library). Tap a notebook tab to see its pages, a folder tab
to go into it, the back arrow to go up, and a page to open it; hold any of them
for its menu. Pages can be renamed, starred, moved or copied to any notebook, and
the tabs put in order and given colours.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local Folder = require("ink/folder")
local FolderLook = require("ink/folderlook")
local Library = require("ink/library")
local Notebook = require("ink/notebook")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Project = require("ink/project")
local Storage = require("ink/storage")
local ThumbGrid = require("ink/ui/thumbgrid")

local uiFill = Paint.uiFill

local InkAwayView = {}

------------------------------------------------------------------------------
-- What the overview shows
------------------------------------------------------------------------------

-- Is the document at `path` (with modification time `mtime`) a notebook? Asked
-- of the file once per change.
function InkAwayView:isNotebookPath(path, mtime)
    if path == self.doc_path then return self.notebook ~= nil end
    self._nb_files = self._nb_files or {}
    local known = self._nb_files[path]
    if not (known and known.mtime == mtime) then
        known = { mtime = mtime, nb = Library.isNotebookFile(path) }
        self._nb_files[path] = known
    end
    return known.nb
end

-- Folder `dir` as a binder: its subfolders, then its documents, each in binder
-- order. Entries met for the first time keep the place they got from now on.
-- Returns the folders, the documents, the binder data and every entry in order.
function InkAwayView:binderEntries(dir)
    local data = Folder.load(dir)
    local folders, docs = Library.list(dir, self:libraryDir())
    local all = {}
    for i = 1, #folders do all[#all + 1] = folders[i] end
    for i = 1, #docs do all[#all + 1] = docs[i] end
    local arranged = Folder.arrange(data, all)
    if not Folder.knows(data, arranged) then
        Folder.setOrder(data, arranged)
        Folder.save(dir, data)
    end
    local fs, ds = {}, {}
    for _, e in ipairs(arranged) do
        if e.mode == "directory" then fs[#fs + 1] = e else ds[#ds + 1] = e end
    end
    return fs, ds, data, arranged
end

-- The tabs of folder `dir`: its subfolders, then its notebooks, the one at
-- `sel_path` marked. An open notebook with no file yet is a tab too, at the end.
-- Also returns the binder data and every entry of the folder in order.
function InkAwayView:overviewTabs(dir, sel_path)
    local folders, docs, data, arranged = self:binderEntries(dir)
    local function colour(name)
        local rgb = data.colors[name]
        return rgb and uiFill(rgb) or nil
    end
    local tabs = {}
    for _, f in ipairs(folders) do
        tabs[#tabs + 1] = { label = f.name, name = f.name, path = f.path, folder = true, color = colour(f.name),
            look = FolderLook.clean(data.folders[f.name]) }
    end
    local seen
    for _, d in ipairs(docs) do
        if self:isNotebookPath(d.path, d.mtime) then
            tabs[#tabs + 1] = { label = Storage.stem(d.name), name = d.name, path = d.path,
                color = colour(d.name), selected = (d.path == sel_path) }
        end
        if d.path == self.doc_path then seen = true end
    end
    if not seen and self.notebook and self.doc_path and Storage.dirName(self.doc_path) == dir then
        tabs[#tabs + 1] = { label = self:docName(), name = Storage.baseName(self.doc_path), path = self.doc_path,
            selected = (self.doc_path == sel_path) }
    end
    return tabs, data, arranged
end

-- The notebook a tab shows: the open one as it is in memory, any other loaded
-- from its file (kept while the overview is open). Returns { nb, open, data };
-- nb is nil when the file holds no notebook.
function InkAwayView:overviewDoc(path)
    if path == self.doc_path and self.notebook then
        self:nbSyncOut()
        return { nb = self.notebook, open = true }
    end
    local ov = self._ov
    if ov.docs[path] then return ov.docs[path] end
    local data = Project.load(path)
    local doc = { data = data }
    if data and Project.isNotebook(data) then
        doc.nb = Notebook.fromData(data)
        doc.nb.w, doc.nb.h = self.screen_w, self.screen_h
    end
    ov.docs[path] = doc
    return doc
end

-- The notebook in the file at `path`, read for a change outside the overview:
-- { data, nb }, nb nil when it is not a notebook.
function InkAwayView:notebookFileDoc(path)
    local data = Project.load(path)
    local doc = { data = data }
    if data and Project.isNotebook(data) then
        doc.nb = Notebook.fromData(data)
        doc.nb.w, doc.nb.h = self.screen_w, self.screen_h
    end
    return doc
end

-- The cards for the selected tab: its pages, or only the starred ones.
function InkAwayView:overviewItems()
    local ov = self._ov
    local nb = ov.path and self:overviewDoc(ov.path).nb
    local items = {}
    if not nb then return items end
    local here = ov.path == self.doc_path and nb.index
    for i, page in ipairs(nb.pages) do
        if not ov.starred or page.star then
            items[#items + 1] = { label = page.title and string.format("%d  %s", i, page.title) or tostring(i),
                index = i, star = page.star, selected = (i == here), page = page }
        end
    end
    return items
end

-- The name of folder `dir` in the overview: "Notebooks" at the top.
function InkAwayView:overviewFolderTitle(dir)
    if dir == self._ov.root then return _("Notebooks") end
    return Storage.baseName(dir)
end

function InkAwayView:overviewTitle()
    local ov = self._ov
    if ov.starred then return _("Starred pages") end
    return self:overviewFolderTitle(ov.dir)
end

-- The notebook to show in folder `dir`: the one last shown there, else its first.
function InkAwayView:overviewPickIn(dir)
    local last, first = self._ov.last[dir], nil
    for _, tab in ipairs((self:overviewTabs(dir))) do
        if not tab.folder then
            if tab.path == last then return last end
            first = first or tab.path
        end
    end
    return first
end

-- The back arrow's action: up a folder, unless at the top.
function InkAwayView:overviewUp()
    local ov = self._ov
    if ov.dir == ov.root or not Storage.within(ov.dir, ov.root) then return nil end
    return function() self:overviewGo(Storage.dirName(self._ov.dir)) end
end

------------------------------------------------------------------------------
-- The overview
------------------------------------------------------------------------------

-- Open the overview on the open notebook, with the folders and notebooks of its
-- folder as tabs. The library folder is the top it can go up to.
function InkAwayView:openOverview()
    self:flushPending()
    self:resetLasso()   -- drop any selection first
    if self.notebook then self:nbSyncOut() end
    local dir, root = self:docDir(), self:libraryDir()
    if not Storage.within(dir, root) then root = dir end
    self._ov = { dir = dir, root = root, path = self.notebook and self.doc_path or nil, last = {}, docs = {},
        starred = false }
    if not self._ov.path then self._ov.path = self:overviewPickIn(dir) end
    self._ov.last[dir] = self._ov.path
    local tabs = self:overviewTabs(dir, self._ov.path)
    local items = self:overviewItems()
    local start = 1
    for i, it in ipairs(items) do if it.selected then start = i end end
    local grid
    grid = ThumbGrid:new{
        title = self:overviewTitle(),
        items = items,
        start = start,
        tabs = tabs,
        folder_icon = self:iconPath("folder"),
        folder_tile = self.folderTile,
        flash_open = not self:colourPanel(),   -- (see ThumbGrid:onShow)
        empty_text = self:overviewEmptyText(),
        actions = {
            { "\u{2605}", function() self:overviewToggleStarred() end },
            { _("Library"), function() local d = self._ov.dir; grid:close(); self:openLibrary(d, true) end },
            { _("Search"), function() self:openSearch("overview") end, icon = self:iconPath("search") },
        },
        on_back = self:overviewUp(),
        render = function(it, w, h) return self:overviewThumb(it, w, h) end,
        on_pick = function(it) self:overviewPick(it) end,
        on_hold = function(it) self:overviewPageMenu(it) end,
        on_tab = function(tab)
            if tab.folder then self:overviewGo(tab.path) else self:overviewShowTab(tab.path) end
        end,
        on_tab_hold = function(tab) self:overviewTabMenu(tab) end,
        tab_footer = {
            { "+ " .. _("Folder"), function()
                self:promptNewFolder(self._ov.dir, function() self:refreshOverview() end)
            end },
            { "+ " .. _("Notebook"), function() self:openNotebookPaper(self._ov.dir) end },
        },
        on_close = function() self:closeOverviewDocs(); self._ov, self._overview = nil, nil end,
    }
    self._overview = grid
    UIManager:show(grid)
end

function InkAwayView:overviewEmptyText()
    if self._ov.starred then return _("No starred pages here.") end
    return _("No notebooks here yet.")
end

-- Show the pages of the tab at `path`.
function InkAwayView:overviewShowTab(path)
    local ov = self._ov
    if not ov then return end
    ov.path = path
    self:refreshOverview(true)
end

-- Show folder `dir`: its tabs, and the pages of the notebook last shown there.
function InkAwayView:overviewGo(dir)
    local ov = self._ov
    if not ov then return end
    ov.dir = dir
    ov.path = self:overviewPickIn(dir)
    self:refreshOverview(true)
end

-- Rebuild the tabs and cards after a change; `top` goes back to the first page
-- of cards, and to the tabs holding the chosen one.
function InkAwayView:refreshOverview(top)
    local ov, grid = self._ov, self._overview
    if not (ov and grid) then return end
    if ov.path then ov.last[ov.dir] = ov.path end
    local tabs = self:overviewTabs(ov.dir, ov.path)
    if top then grid.gpage = 0 end
    grid:setItems(self:overviewItems(), self:overviewTitle(), tabs)
    if top then
        grid.tpage = 0
        grid:showSelectedTab()
    end
    grid.on_back = self:overviewUp()
    grid.empty_text = self:overviewEmptyText()
    grid.actions[1][3] = ov.starred or nil   -- the star pill is dark while filtering
end

function InkAwayView:overviewToggleStarred()
    local ov = self._ov
    if not ov then return end
    ov.starred = not ov.starred
    self:refreshOverview(true)
end

-- A tap on a page: open it (switching document if it belongs to another tab).
function InkAwayView:overviewPick(it)
    local ov = self._ov
    local path, index = ov.path, it.index
    self._overview:close()
    if path ~= self.doc_path and not self:openDocument(path) then return end
    if self.notebook then self:nbGoTo(index) end
end

-- Close the PDFs opened to draw other tabs' thumbnails.
function InkAwayView:closeOverviewDocs()
    local ov = self._ov
    if not ov then return end
    for _, d in pairs(ov.pdfs or {}) do pcall(function() d:close() end) end
    ov.pdfs = nil
end

------------------------------------------------------------------------------
-- Thumbnails
------------------------------------------------------------------------------

-- A PDF page as a background, from the open notebook's document or one opened
-- for the overview (kept until it closes).
function InkAwayView:overviewPdfPage(pdf_path, src, W, H)
    local doc
    if pdf_path == self._nb_pdf_path and self._nb_pdf_doc then
        doc = self._nb_pdf_doc
    else
        local ov = self._ov
        ov.pdfs = ov.pdfs or {}
        doc = ov.pdfs[pdf_path]
        if not doc then
            local ok, d = pcall(function() return require("document/documentregistry"):openDocument(pdf_path) end)
            doc = ok and d or nil
            ov.pdfs[pdf_path] = doc
        end
    end
    return doc and self:renderPdfPage(doc, src, W, H) or nil
end

-- Draw one page of a notebook that is not open, the size of the page, shrunk to
-- fit maxw x maxh.
function InkAwayView:renderOtherPage(nb, i, maxw, maxh)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local page = nb.pages[i]
    local scratch = Blitbuffer.new(W, H, self.canvas_bb and self.canvas_bb:getType() or Blitbuffer.TYPE_BBRGB32)
    local bg = nb.template.pdf_path and page.src and self:overviewPdfPage(nb.template.pdf_path, page.src, W, H)
    self:trueColours(function()   -- (kept as a file, shown in day mode too)
        self:withOwnImageCache(function() self:composeInto(scratch, page.ops, bg, nb:pageTemplate(i)) end)
    end)
    if bg then bg:free() end
    local scale = math.min(maxw / W, maxh / H)
    local thumb = RenderImage:scaleBlitBuffer(scratch, math.max(1, math.floor(W * scale)),
        math.max(1, math.floor(H * scale)), false)
    if thumb ~= scratch then scratch:free() end
    return thumb
end


-- A thumbnail of page i of the open notebook, drawn from the page and kept for
-- the next time: the most recent two grid pages' worth, so turning between two
-- pages of thumbnails and opening the overview again draw nothing. The grid gets
-- a copy, as it frees what it is given. A page's copy goes when the page changes
-- (see dropPageThumb) or is drawn on other paper.
function InkAwayView:openPageThumb(i, maxw, maxh)
    local nb = self.notebook
    local page = nb and nb.pages[i]
    if not page then return nil end
    local t = nb:pageTemplate(i)
    local paper = type(t.paper) == "table" and table.concat(t.paper, ",") or "white"
    local sig = table.concat({ maxw, maxh, tostring(t.style), tostring(t.size), tostring(t.strength),
        tostring(t.pdf_path), tostring(page.src), paper }, "|")
    local kept = self._page_thumbs
    if not kept then kept = { order = {} }; self._page_thumbs = kept end
    local e = kept[page]
    if not (e and e.sig == sig) then
        self:dropPageThumb(page)
        local bb = self:renderPageThumb(i, maxw, maxh)
        if not bb then return nil end
        e = { sig = sig, bb = bb }
        kept[page] = e
        table.insert(kept.order, 1, page)
        local max = 2 * ((self._overview and self._overview.per) or 6)
        while #kept.order > max do self:dropPageThumb(kept.order[#kept.order]) end
    else
        -- the most recently used goes to the front
        for k, p in ipairs(kept.order) do if p == page then table.remove(kept.order, k); break end end
        table.insert(kept.order, 1, page)
    end
    return e.bb:copy()
end

-- Forget the kept thumbnail of `page` (it changed).
function InkAwayView:dropPageThumb(page)
    local kept = self._page_thumbs
    local e = kept and kept[page]
    if not e then return end
    e.bb:free()
    kept[page] = nil
    for k, p in ipairs(kept.order) do if p == page then table.remove(kept.order, k); break end end
end

-- Forget every kept thumbnail (another document, or closing).
function InkAwayView:freePageThumbs()
    local kept = self._page_thumbs
    if not kept then return end
    for _, p in ipairs(kept.order) do if kept[p] then kept[p].bb:free() end end
    self._page_thumbs = nil
end

-- The thumbnail of a card: a page of the open notebook is drawn from the page
-- (and kept for next time); a page of another notebook is cached on disk by its
-- id and when it last changed, with the paper it is on.
function InkAwayView:overviewThumb(it, maxw, maxh)
    local ov = self._ov
    local doc = self:overviewDoc(ov.path)
    if not doc.nb then return nil end
    if doc.open then return self:openPageThumb(it.index, maxw, maxh) end
    local page = it.page
    local t = doc.nb:pageTemplate(it.index)
    local name = string.format("%s-p%s-%d-%s%s%s-%dx%d.png", Library.pathCode(ov.path), tostring(page.id),
        page.modified or 0, tostring(t.style), tostring(t.size), tostring(t.strength), maxw, maxh)
    local file = Storage.join(Storage.cacheDir(), name)
    if Storage.exists(file) then
        local ok, bb = pcall(function() return RenderImage:renderImageFile(file, false) end)
        if ok and bb then return bb end
    end
    local thumb = self:renderOtherPage(doc.nb, it.index, maxw, maxh)
    if thumb then pcall(function() thumb:writePNG(file) end) end
    return thumb
end

------------------------------------------------------------------------------
-- Page menu
------------------------------------------------------------------------------

-- Change the notebook at `path`: fn(nb) edits it, and it is saved at once, so a
-- page moving between notebooks is always in a file. The open notebook is
-- changed in memory and saved (`page`, when its own fields change, is written
-- out again); another one is changed in its file. Returns whether it worked.
function InkAwayView:editNotebookAt(path, fn, page)
    if path == self.doc_path and self.notebook then
        self:nbSyncOut()
        local before = self.notebook.pages[self.notebook.index]
        fn(self.notebook)
        if page and self._page_cache then self._page_cache[page] = nil end
        if self.notebook.pages[self.notebook.index] ~= before then self:nbLoad() end
        self:markDirty()
        return self:saveDocument()
    end
    local doc = self._ov and self:overviewDoc(path) or self:notebookFileDoc(path)
    if not doc.nb then return false end
    fn(doc.nb)
    local ok, err = Project.saveNotebook(doc.nb, path, nil, { export = doc.data and doc.data.export })
    if not ok then
        self:tell(_("Could not save.\n") .. tostring(err))
        return false
    end
    self:dropThumbs(path)
    return true
end

-- Choose a notebook other than `except`, starting in folder `dir`: a list of
-- the folder's subfolders (to go into) and notebooks, with a way up.
-- on_pick(path, label) gets the one chosen.
function InkAwayView:chooseNotebook(title, dir, except, on_pick)
    local root = self._ov.root
    local function show(d)
        local items = {}
        if d ~= root and Storage.within(d, root) then
            local up = Storage.dirName(d)
            items[1] = { label = "\u{2039} " .. self:overviewFolderTitle(up), cb = function() show(up) end }
        end
        for _, tab in ipairs((self:overviewTabs(d))) do
            if tab.folder then
                items[#items + 1] = { label = tab.label .. "  \u{203A}", icon = "folder", cb = function() show(tab.path) end }
            elseif tab.path ~= except then
                items[#items + 1] = { label = tab.label, icon = "notebook", cb = function() on_pick(tab.path, tab.label) end }
            end
        end
        self:chooseFromList{ title = title, note = self:overviewFolderTitle(d), items = items,
            empty = _("No other notebook here"), close_text = _("Cancel") }
    end
    show(dir)
end

-- Hold on a page: rename, star, move or copy to another notebook, delete.
function InkAwayView:overviewPageMenu(it)
    local ov = self._ov
    local path = ov.path
    local doc = self:overviewDoc(path)
    if not doc.nb then return end
    local page = it.page
    self:openActionSheet("_ov_menu", page.title or string.format(_("Page %d"), it.index), nil, {
        { { _("Rename\u{2026}"), function() self:overviewRenamePage(path, page) end, icon = "rename" },
          { page.star and _("Unstar") or _("Star"), function()
              self:editNotebookAt(path, function() page.star = (not page.star) or nil end, page)
              self:refreshOverview()
          end, icon = "star" } },
        { { _("Move to\u{2026}"), function() self:overviewSendPage(path, page, true) end, icon = "move" },
          { _("Copy to\u{2026}"), function() self:overviewSendPage(path, page, false) end, icon = "duplicate" } },
        { { _("Delete\u{2026}"), function() self:overviewDeletePage(path, page) end, icon = "trash" } },
    })
end

function InkAwayView:overviewRenamePage(path, page)
    self:promptText{ title = _("Page title"), input = page.title or "", hint = _("Untitled"), ok_text = _("Rename"),
        on_ok = function(text)
            local title = (text or ""):match("^%s*(.-)%s*$")
            self:editNotebookAt(path, function() page.title = (title ~= "") and title or nil end, page)
            self:refreshOverview()
        end }
end

-- The index of `page` in notebook nb.
local function indexOf(nb, page)
    for i, p in ipairs(nb.pages) do if p == page then return i end end
end

function InkAwayView:overviewDeletePage(path, page)
    local nb = self:overviewDoc(path).nb
    if nb:count() <= 1 then
        self:showNotice(_("A notebook keeps at least one page."), 2)
        return
    end
    self:askDelete(nil, false, function()
        self:editNotebookAt(path, function(n)
            local i = indexOf(n, page)
            if i and self:trashPage(path, n, i) then n:takePage(i) end
        end)
        self:refreshOverview()
    end)
end

-- Move (or copy) a page to the end of another notebook, in this folder or any
-- other, chosen from a list.
function InkAwayView:overviewSendPage(path, page, move)
    local src_nb = self:overviewDoc(path).nb
    if move and src_nb:count() <= 1 then
        self:showNotice(_("A notebook keeps at least one page."), 2)
        return
    end
    self:chooseNotebook(move and _("Move the page to") or _("Copy the page to"), self._ov.dir, path,
        function(target, label)
            local dest = self:overviewDoc(target).nb
            if not dest then return end
            local same_pdf = src_nb.template.pdf_path ~= nil and src_nb.template.pdf_path == dest.template.pdf_path
            local style = src_nb:pageTemplate(indexOf(src_nb, page)).style
            if not self:editNotebookAt(target, function(n) n:putPage(page, same_pdf, style) end) then return end
            if move then self:editNotebookAt(path, function(n) n:takePage(indexOf(n, page)) end) end
            self:refreshOverview()
            self:showNotice(string.format(move and _("Moved to \u{201C}%s\u{201D}") or _("Copied to \u{201C}%s\u{201D}"),
                label))
        end)
end

------------------------------------------------------------------------------
-- Tab menu
------------------------------------------------------------------------------

-- Hold on a tab: open, export, rename, colour, move up or down, delete. A
-- folder opens in the overview and exports as one PDF.
function InkAwayView:overviewTabMenu(tab)
    local function act(text, icon, fn) return { text, fn, icon = icon } end
    local it = { label = tab.label, path = tab.path, folder = tab.folder }
    local open, export
    if tab.folder then
        open = act(_("Open"), "open", function() self:overviewGo(tab.path) end)
        export = act(_("Export as PDF\u{2026}"), "export", function() self:exportFolderPDF(tab.path) end)
    else
        open = act(_("Open"), "open", function() self._overview:close(); self:openDocument(tab.path) end)
        export = act(_("Export\u{2026}"), "export", function()
            self._overview:close()
            if tab.path == self.doc_path or self:openDocument(tab.path) then self:openExport() end
        end)
    end
    local rows = {
        { open, export },
        { act(_("Rename\u{2026}"), "rename", function() self:overviewRenameTab(it) end),
          act(_("Colour\u{2026}"), "palette", function() self:overviewTabColour(tab) end) },
        { act(_("Move up"), "arrow_up", function() self:overviewMoveTab(tab, -1) end),
          act(_("Move down"), "arrow_down", function() self:overviewMoveTab(tab, 1) end) },
        { act(_("Delete\u{2026}"), "trash", function() self:overviewDeleteTab(it) end) },
    }
    -- a notebook's cover on a Bookshelf shelf, when Bookshelf is installed
    if not tab.folder and require("ink/bookshelf").registered and Library.isNotebookFile(tab.path) then
        table.insert(rows, #rows, { act(_("Cover on the shelf\u{2026}"), "cover", function()
            require("ink/coverpicker").show{ path = tab.path, view = self }
        end) })
    end
    self:openActionSheet("_ov_menu", tab.label, nil, rows)
end

-- Move a tab up or down among the tabs of its kind (folders or notebooks).
function InkAwayView:overviewMoveTab(tab, delta)
    local dir = self._ov.dir
    local tabs, data, arranged = self:overviewTabs(dir)
    local is_tab = {}
    for i = 1, #tabs do is_tab[tabs[i].name] = true end
    local function counts(d) return is_tab[d.name] and (d.mode == "directory") == (tab.folder == true) end
    if Folder.move(data, arranged, tab.name, delta, counts) then
        Folder.save(dir, data)
        self:refreshOverview()
    end
end

-- A tab's colour, as swatches: the greys, and on a colour screen the colours
-- (the one in use framed), and No colour.
function InkAwayView:overviewTabColour(tab)
    local dir = self._ov.dir
    local current = Folder.load(dir).colors[tab.name]
    local S = function(px) return Device.screen:scaleBySize(px) end
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_chooser_dialog") end
    local function pick(rgb)
        closeSelf()
        local d = Folder.load(dir)
        d.colors[tab.name] = rgb and { rgb[1], rgb[2], rgb[3] } or nil
        Folder.save(dir, d)
        self:refreshOverview()
    end
    local function row(list)
        local hg = HorizontalGroup:new{ align = "center" }
        for i, c in ipairs(list) do
            if i > 1 then table.insert(hg, HorizontalSpan:new{ width = S(10) }) end
            table.insert(hg, self:swatchTile(c.rgb, Palette.sameColor(c.rgb, current) and true or false, S(56),
                function() pick(c.rgb) end, nil, S(48)))
        end
        return hg
    end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Tab colour"), content_w, _("Done"), closeSelf))
        add(VerticalSpan:new{ width = S(16) })
        add(row({ Palette.SHADES[2], Palette.SHADES[3], Palette.SHADES[4] }))
        if self:colorScreen() then
            add(VerticalSpan:new{ width = S(10) })
            add(row(Palette.COLORS))
        end
        add(VerticalSpan:new{ width = S(16) })
        add(self:actionButton(_("No colour"), content_w, function() pick(nil) end, current == nil))
        return content
    end
    self:showSheet("_chooser_dialog", build)
end

-- A file or folder in the overview moved from `old` to `new`: follow it.
function InkAwayView:overviewPathMoved(old, new)
    local ov = self._ov
    local function moved(p)
        if p and Storage.within(p, old) then return new .. p:sub(#old + 1) end
        return p
    end
    local docs, last = {}, {}
    for p, d in pairs(ov.docs) do docs[moved(p)] = d end
    for d, p in pairs(ov.last) do last[moved(d)] = moved(p) end
    ov.docs, ov.last, ov.path = docs, last, moved(ov.path)
end

-- Rename a tab's notebook or folder, keeping its place and colour in the binder.
function InkAwayView:overviewRenameTab(it)
    local dir = self._ov.dir
    self:promptText{ title = _("Rename"), input = it.label, ok_text = _("Rename"),
        on_ok = function(text)
            local name = (text or ""):gsub("[/\\]", "_"):match("^%s*(.-)%s*$")
            if name == "" or name == it.label or (it.folder and name:sub(1, 1) == ".") then return end
            local new = Storage.join(dir, it.folder and name or Storage.fileName(name, Project.EXT))
            if it.path == self.doc_path then
                self:renameDocument(name)
                if self.doc_path ~= new then return end
            else
                if Storage.exists(new) and new:lower() ~= it.path:lower() then
                    self:tell(string.format(
                        _("There is already something called \u{201C}%s\u{201D} here."), name))
                    return
                end
                local ok, err = os.rename(it.path, new)
                if not ok then
                    self:tell(_("Could not rename.\n") .. tostring(err))
                    return
                end
            end
            if it.path ~= self.doc_path then   -- renameDocument keeps the open one in place
                Folder.update(dir, function(d) Folder.rename(d, Storage.baseName(it.path), Storage.baseName(new)) end)
                self:pathMoved(it.path, new)   -- the open document may be inside a folder
            end
            self:overviewPathMoved(it.path, new)
            self:refreshOverview()
        end }
end

-- Delete a tab's notebook, or a folder with everything in it. If the open
-- document goes, a new drawing takes its place.
function InkAwayView:overviewDeleteTab(it)
    local dir = self._ov.dir
    self:askDelete(it.label, it.folder, function()
        if not self:trashPath(it.path, it.folder, dir) then return end
        local ov = self._ov
        for p in pairs(ov.docs) do if Storage.within(p, it.path) then ov.docs[p] = nil end end
        if ov.path and Storage.within(ov.path, it.path) then ov.path = self:overviewPickIn(dir) end
        self:refreshOverview(true)
    end)
end

return InkAwayView
