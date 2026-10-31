--[[
The library: a full-screen grid of the folders and documents in the library
folder. Tap to open, hold for rename, duplicate, move and delete. New drawings,
notebooks and folders from its header; importing a PDF and sorting from its menu. Thumbnails are rendered from the files
and cached, so the grid only draws a document once per change.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local ImageProc = require("ink/imageproc")
local Layers = require("ink/layers")
local BookNotes = require("ink/reader/booknotes")
local Folder = require("ink/folder")
local FolderLook = require("ink/folderlook")
local Library = require("ink/library")
local Notebook = require("ink/notebook")
local Palette = require("ink/palette")
local Project = require("ink/project")
local Storage = require("ink/storage")
local Theme = require("ink/ui/theme")
local ThumbGrid = require("ink/ui/thumbgrid")

local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB
local Screen = Device.screen
local function S(px) return Screen:scaleBySize(px) end

local InkAwayView = {}

------------------------------------------------------------------------------
-- The library grid
------------------------------------------------------------------------------

-- The title for library folder `dir`: "Library" at the top, else its name.
function InkAwayView:libraryTitle(dir)
    if dir == self:libraryDir() then return _("Library") end
    return Storage.baseName(dir)
end

-- The looks of folder `dir`'s subfolders (from its binder file, read only
-- when it has subfolders), by name.
function InkAwayView:folderLooks(dir, folders)
    if #folders == 0 then return {} end
    return Folder.load(dir).folders
end

-- The cards for library folder `dir`: its folders, then its documents.
function InkAwayView:libraryItems(dir)
    local folders, docs, pics = Library.list(dir, self:libraryDir(), self:getSetting("inkaway_library_sort"))
    local looks = self:folderLooks(dir, folders)
    local items = {}
    for _, f in ipairs(folders) do
        items[#items + 1] = { label = f.name, path = f.path, folder = true, look = FolderLook.clean(looks[f.name]) }
    end
    for _, d in ipairs(docs) do
        items[#items + 1] = { label = Storage.stem(d.name), path = d.path, mtime = d.mtime,
            selected = (d.path == self.doc_path) }
    end
    -- pictures (sent from a phone, or copied in): seen here, placed with Add image
    for _, p in ipairs(pics or {}) do
        items[#items + 1] = { label = Storage.stem(p.name), path = p.path, mtime = p.mtime, picture = true }
    end
    return items
end

-- Open the library at folder `dir` (the open document's folder by default). The
-- open document is saved first, so the library shows it as it is. `over_grid`:
-- it replaces another full-screen grid (the overview), so it opens without the
-- flash that clears ink underneath.
function InkAwayView:openLibrary(dir, over_grid)
    self:leaveDocument()
    local root = self:libraryDir()
    dir = dir or self:docDir()
    if not Storage.within(dir, root) or not Storage.isDir(dir) then dir = root end
    self:closeSheet("_library")
    pcall(require("ink/trash").purge, root)   -- what has waited its 30 days goes
    pcall(self.sortImported, self)            -- (what older test versions put in Imported itself)
    self._lib_dir = dir
    local start = 1
    local items = self:libraryItems(dir)
    for i, it in ipairs(items) do if it.selected then start = i end end
    self._library = ThumbGrid:new{
        title = self:libraryTitle(dir),
        items = items,
        start = start,
        folder_icon = self:iconPath("folder"),
        folder_tile = self.folderTile,
        flash_open = not (over_grid or self:colourPanel()),   -- (see ThumbGrid:onShow)
        empty_text = _("Nothing here yet. Make a drawing, a notebook or a folder with + New."),
        actions = {
            -- one button for what can be made here, so a folder's name has room
            { "+ " .. _("New"), function() self:libraryNewSheet() end, true },
            { _("Search"), function() self:openSearch("library") end, icon = self:iconPath("search") },
            { "\u{22EF}", function() self:libraryMenu() end },
        },
        on_back = (dir ~= root) and function() self:libraryGo(Storage.dirName(self._lib_dir)) end or nil,
        on_back_top = (dir ~= root) and function() self:libraryGo(self:libraryDir()) end or nil,
        render = function(it, w, h)
            if it.picture then return self:pictureThumb(it.path, w, h) end
            return self:docThumb(it.path, w, h)
        end,
        on_pick = function(it) self:libraryPick(it) end,
        on_hold = function(it) self:libraryItemMenu(it) end,
        on_close = function() self._library = nil end,
    }
    UIManager:show(self._library)
end

-- Show folder `dir` in the open library.
function InkAwayView:libraryGo(dir)
    local lib = self._library
    if not lib then return self:openLibrary(dir) end
    self._lib_dir = dir
    lib.gpage = 0
    lib.on_back = (dir ~= self:libraryDir()) and function() self:libraryGo(Storage.dirName(self._lib_dir)) end or nil
    lib.on_back_top = (dir ~= self:libraryDir()) and function() self:libraryGo(self:libraryDir()) end or nil
    lib:setItems(self:libraryItems(dir), self:libraryTitle(dir))
end

-- Show the open library's folder again, after something in it changed.
function InkAwayView:refreshLibrary()
    if self._library then self._library:setItems(self:libraryItems(self._lib_dir)) end
end

-- A tap on a card: into a folder, or open a document and close the library.
function InkAwayView:libraryPick(it)
    if it.folder then return self:libraryGo(it.path) end
    if it.picture then return self:viewPicture(it.path) end
    if self._library then self._library:close() end
    self:openDocument(it.path)
end

-- What + New offers in the library: a drawing, a notebook or a folder, made in
-- the folder shown.
function InkAwayView:libraryNewSheet()
    local field = "_library_new"
    local content_w, gap = self:sheetWidth()
    local closeSelf = function() self:closeSheet(field) end
    local function drawing(from_image)
        closeSelf()
        local d = self._lib_dir
        if self._library then self._library:close() end
        if from_image then self:newFromImage(d) else self:newDrawing(d) end
    end
    local build = function()
        return VerticalGroup:new{ align = "left",
            self:sheetTitle(string.format(_("New in %s"), self:libraryTitle(self._lib_dir or self:libraryDir())),
                content_w, _("Cancel"), closeSelf),
            VerticalSpan:new{ width = S(14) },
            self:actionTile("pen", _("Drawing"), _("A blank page. Hold to start from a picture."), content_w,
                function() drawing(false) end, function() drawing(true) end),
            VerticalSpan:new{ width = gap },
            self:actionTile("notebook", _("Notebook"), _("Choose its paper, a PDF or a template"), content_w,
                function() closeSelf(); self:openNotebookPaper(self._lib_dir) end),
            VerticalSpan:new{ width = gap },
            self:actionTile("folder", _("Folder"), _("To keep notebooks and drawings together"), content_w,
                function()
                    closeSelf()
                    self:promptNewFolder(self._lib_dir, function() self:refreshLibrary() end)
                end) }
    end
    self:showSheet(field, build)
end

-- The library's menu (the ... button), as a sheet: Phone or computer over
-- Wi-Fi, writing on a PDF already on the reader, the order, and the trash,
-- each with a line saying what it does.
function InkAwayView:libraryMenu()
    local field = "_library_menu"
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet(field) end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        local function option(label, hint, cb, dark, icon)
            add(VerticalSpan:new{ width = S(12) })
            add(self:actionButton(label, content_w, function() closeSelf(); cb() end, dark, nil, icon))
            add(VerticalSpan:new{ width = S(4) })
            add(self:sheetHint(hint, content_w))
        end
        add(self:sheetTitle(self:libraryTitle(self._lib_dir or self:libraryDir()), content_w, _("Close"), closeSelf))
        option(_("Phone or computer (Wi-Fi)\u{2026}"),
            _("Send your notebooks and drawings to a phone or computer, or add PDFs and pictures from one, with a QR code."),
            function() self:openSend() end, true, "qr")
        option(_("Write on a PDF from this reader\u{2026}"),
            _("Pick a PDF that is already on this reader. It becomes a notebook in this folder."),
            function() self:openPdfAsNotebook(self._lib_dir) end, nil, "pdfpen")
        add(VerticalSpan:new{ width = S(16) })
        add(self:sheetLabel(_("Order"), true))
        add(VerticalSpan:new{ width = S(6) })
        add(self:segmentedRow({ { "recent", _("Newest first") }, { "name", _("By name") } },
            self:getSetting("inkaway_library_sort") == "name" and "name" or "recent", content_w, function(v)
                self:setSetting("inkaway_library_sort", v)
                self:refreshLibrary()
                self:rebuildSheet(field)
            end))
        option(_("Trash\u{2026}"), string.format(_("Deleted notebooks, drawings, pictures and folders wait here for %d days."),
            require("ink/trash").KEEP_DAYS), function() self:openTrash() end, nil, "trash")
        return content
    end
    self:showSheet(field, build)
end

-- The menu of one card, from a hold: a sheet of its actions, each with its icon.
function InkAwayView:libraryItemMenu(it)
    local function act(text, icon, fn) return { text, fn, icon = icon } end
    local open = act(_("Open"), "open", function() self:libraryPick(it) end)
    local rename = act(_("Rename\u{2026}"), "rename", function() self:promptRenameItem(it) end)
    local move = act(_("Move to\u{2026}"), "move", function() self:moveItem(it) end)
    local delete = act(_("Delete\u{2026}"), "trash", function() self:confirmDeleteItem(it) end)
    local rows
    if it.picture then
        rows = { { act(_("View"), "eye", function() self:viewPicture(it.path) end), rename }, { move, delete } }
    elseif it.folder then
        rows = { { open }, { rename, move },
            { act(_("Colour and icon\u{2026}"), "palette", function() self:folderLookSheet(it) end) },
            { act(_("Export as PDF\u{2026}"), "export", function() self:exportFolderPDF(it.path) end), delete } }
    else
        rows = { { open, act(_("Export\u{2026}"), "export", function()
                self:libraryPick(it)
                if self.doc_path == it.path then self:openExport() end
            end) },
            { rename, move },
            { act(_("Duplicate"), "duplicate", function() self:duplicateItem(it) end), delete } }
        -- a notebook's cover on a Bookshelf shelf, when Bookshelf is installed
        if require("ink/bookshelf").registered and Library.isNotebookFile(it.path) then
            rows[#rows + 1] = { act(_("Cover on the shelf\u{2026}"), "cover", function()
                require("ink/coverpicker").show{ path = it.path, view = self }
            end) }
        elseif require("ink/drawingshelf").registered and not Library.isNotebookFile(it.path) then
            -- a drawing's frame on a Bookshelf shelf
            rows[#rows + 1] = { act(_("Frame on the shelf\u{2026}"), "frame", function()
                require("ink/framepicker").show{ path = it.path }
            end) }
        end
    end
    self:openActionSheet("_item_menu", it.label, nil, rows)
end

------------------------------------------------------------------------------
-- Folders and files
------------------------------------------------------------------------------

-- Ask for a name and make that folder in `dir`; `after(path)` runs once it is made.
function InkAwayView:promptNewFolder(dir, after)
    local moved
    dir, moved = self:writableDir(dir)
    self:promptText{ title = _("New folder"), hint = _("Folder name"), ok_text = _("Create"),
        on_ok = function(text)
            local name = (text or ""):gsub("[/\\]", "_"):match("^%s*(.-)%s*$")
            if name == "" or name:sub(1, 1) == "." then return end
            local path = Storage.join(dir, name)
            if Storage.exists(path) then
                self:tell(string.format(
                    _("There is already something called \u{201C}%s\u{201D} here."), name))
                return
            end
            if not Storage.ensureDir(path) then
                self:tell(_("Could not create the folder."))
                return
            end
            if moved then self:noteNotImported("named", name) end
            if after then after(path) end
        end }
end

-- A file or folder moved from `old` to `new`: follow it with the open document
-- and the remembered last notebook, when either was in it.
function InkAwayView:pathMoved(old, new)
    local nb = self:getSetting("inkaway_last_notebook")
    if nb and Storage.within(nb, old) then self:setSetting("inkaway_last_notebook", new .. nb:sub(#old + 1)) end
    if self.doc_path and Storage.within(self.doc_path, old) then
        self.doc_path = new .. self.doc_path:sub(#old + 1)
        if self.doc_written then self:rememberDoc(self.doc_path) end
    end
    -- the Book notes folder (or a folder it is in) renamed or moved: new book
    -- notes go where it went, not into a new Book notes folder (#54)
    local notes = self:bookNotesFolder()
    if Storage.within(notes, old) then
        local root = self:libraryDir():gsub("/+$", "")
        local moved = new .. notes:sub(#old + 1)
        if Storage.within(moved, root) and moved ~= root then
            self:setSetting(BookNotes.SETTING, moved:sub(#root + 2))
        end
    end
end

-- The library folder book notes go in: Book notes, or where it was renamed or
-- moved to in the library since. bookNotesDir is that folder when it is there,
-- else a Book notes folder (made again with the first new notes).
function InkAwayView:bookNotesFolder()
    local root = self:libraryDir()
    local rel = self:getSetting(BookNotes.SETTING)
    if type(rel) == "string" and rel ~= "" and not rel:find("%.%.") then return Storage.join(root, rel) end
    return Storage.join(root, BookNotes.FOLDER)
end

function InkAwayView:bookNotesDir()
    local dir = self:bookNotesFolder()
    if Storage.isDir(dir) then return dir end
    return Storage.join(self:libraryDir(), BookNotes.FOLDER)
end

-- Drop the open document without saving it (its file was deleted), and start a
-- new drawing in `dir`.
function InkAwayView:discardDocument(dir)
    self.doc_path, self.doc_written = nil, false
    self:setSetting("inkaway_last_doc", nil)
    self:newDrawing(dir)
end

function InkAwayView:promptRenameItem(it)
    self:promptText{ title = _("Rename"), input = it.label, ok_text = _("Rename"),
        on_ok = function(text)
            local name = (text or ""):gsub("[/\\]", "_"):match("^%s*(.-)%s*$")
            if name == "" or name == it.label then return end
            local dir = Storage.dirName(it.path)
            local ext = it.picture and (Storage.baseName(it.path):match("%.([^.]+)$") or "jpg") or Project.EXT
            local new = it.folder and Storage.join(dir, name) or Storage.join(dir, Storage.fileName(name, ext))
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
            Folder.update(dir, function(d) Folder.rename(d, Storage.baseName(it.path), Storage.baseName(new)) end)
            self:pathMoved(it.path, new)
            self:refreshLibrary()
        end }
end

function InkAwayView:duplicateItem(it)
    local into, moved = self:writableDir(Storage.dirName(it.path))
    local copy, err = Library.duplicate(it.path, into)
    if not copy then
        self:tell(_("Could not duplicate.\n") .. tostring(err))
        return
    end
    Folder.update(Storage.dirName(copy), function(d) Folder.add(d, Storage.baseName(copy)) end)
    self:refreshLibrary()
    if moved then self:noteNotImported("copy") end
end

-- The question before something goes to the trash: a document or folder
-- called `label`, or a page when there is no label.
-- Ask before something goes to the trash: the item called `label` (a folder
-- with `is_folder`), or the page shown when there is no label. on_ok() deletes.
function InkAwayView:askDelete(label, is_folder, on_ok)
    local days = string.format(_("It stays in the trash for %d days."), require("ink/trash").KEEP_DAYS)
    self:ask{
        title = not label and _("Delete this page?") or string.format(_("Delete \u{201C}%s\u{201D}?"), label),
        text = is_folder and (_("The folder and everything in it go.") .. " " .. days) or days,
        ok_text = _("Delete"), ok_icon = "trash", on_ok = on_ok }
end

function InkAwayView:confirmDeleteItem(it)
    self:askDelete(it.label, it.folder, function()
        if self:trashPath(it.path, it.folder, self._lib_dir) then self:refreshLibrary() end
    end)
end

-- Pick a destination folder in the library and move the card's file or folder
-- there.
function InkAwayView:moveItem(it)
    self:chooseLibraryFolder(it.path, function(dir)
        local new, err = self:moveInto(it.path, dir)
        if not new then
            self:tell(_("Could not move it.\n") .. tostring(err))
            return
        end
        self:refreshLibrary()
    end)
end

-- Move the file or folder at `path` into folder `dir`, under a free name; its
-- tab colour, Bookshelf cover and folder look go with it, and the open
-- document follows. Returns the new path, or nil, err.
function InkAwayView:moveInto(path, dir)
    local new, err = Library.move(path, dir)
    if not new then return nil, err end
    if new ~= path then
        local old_name, new_name = Storage.baseName(path), Storage.baseName(new)
        local from = Folder.load(Storage.dirName(path))
        local color, cover, look = from.colors[old_name], from.covers[old_name], from.folders[old_name]
        Folder.update(Storage.dirName(path), function(d) Folder.forget(d, old_name) end)
        if not Library.isPicture(new_name) then
            Folder.update(dir, function(d)
                Folder.add(d, new_name)
                if color ~= nil then d.colors[new_name] = color end
                if cover ~= nil then d.covers[new_name] = cover end
                if look ~= nil then d.folders[new_name] = look end
            end)
        end
    end
    self:pathMoved(path, new)
    return new
end

-- A folder chooser inside the library: browse folders, make new ones, and pick
-- the one shown with the dark button. `moving` (a path) is left out, so a folder
-- cannot be moved into itself. The title names the folder shown.
function InkAwayView:chooseLibraryFolder(moving, on_pick)
    local root = self:libraryDir()
    local grid
    local cur = root
    local function items()
        local folders = Library.list(cur, root)
        local looks = self:folderLooks(cur, folders)
        local out = {}
        for _, f in ipairs(folders) do
            -- (never into Imported: it holds only what came from another device)
            if not (moving and Storage.within(f.path, moving)) and not self:inImported(f.path) then
                out[#out + 1] = { label = f.name, path = f.path, folder = true, look = FolderLook.clean(looks[f.name]) }
            end
        end
        return out
    end
    local function go(dir)
        cur = dir
        grid.gpage = 0
        grid.on_back = (dir ~= root) and function() go(Storage.dirName(cur)) end or nil
        grid:setItems(items(), string.format(_("Move to %s"), self:libraryTitle(dir)))
    end
    grid = ThumbGrid:new{
        items = {},
        folder_icon = self:iconPath("folder"),
        folder_tile = self.folderTile,
        flash_open = false,   -- it opens over the library
        close_label = _("Cancel"),
        empty_text = _("No folders here."),
        actions = {
            { "+ " .. _("Folder"), function() self:promptNewFolder(cur, function() go(cur) end) end },
            { _("Move here"), function() grid:close(); on_pick(cur) end, true },
        },
        on_pick = function(it) go(it.path) end,
    }
    go(root)
    UIManager:show(grid)
end

------------------------------------------------------------------------------
-- A folder's colour and icon
------------------------------------------------------------------------------

-- A card's or tab's folder in its own look, `w` wide on grey `bg`, or nil for
-- the plain folder icon (ThumbGrid's folder_tile; not a method).
function InkAwayView.folderTile(it, w, bg)
    return it.look and FolderLook.tile(it.look, w, bg) or nil
end

-- Change the look of the library folder `it` with fn(look) and show it.
function InkAwayView:setFolderLook(it, fn)
    local dir, name = Storage.dirName(it.path), Storage.baseName(it.path)
    local look
    Folder.update(dir, function(d)
        look = FolderLook.clean(d.folders[name]) or {}
        fn(look)
        look = FolderLook.clean(look)
        d.folders[name] = look
    end)
    it.look = look
    self:refreshLibrary()
    self:refreshOverview()   -- (when it is open, under the library)
end

-- The sheet for a folder's look: the twelve colours as folders (with its icon,
-- the one in use framed), its icon, and back to the plain folder.
function InkAwayView:folderLookSheet(it)
    local content_w, gap = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_folder_look") end
    local per_row = 6
    local cell = math.floor((content_w - (per_row - 1) * gap) / per_row)
    local bg = Theme.invert() and 0x00 or 0xFF
    local function swatch(key)
        local look = it.look or {}
        local selected = look.color == key
        local inner = cell - S(8)
        local bb = FolderLook.tile({ color = key, icon = look.icon }, inner - S(6), bg)
        local b = Button:new{ text = "", width = inner, height = inner, bordersize = 0,
            background = Blitbuffer.COLOR_WHITE, radius = S(11), margin = 0, padding = 0,
            callback = function()
                self:setFolderLook(it, function(l) l.color = key end)
                self:rebuildSheet("_folder_look")
            end, show_parent = self }
        if bb then
            self:setButtonLabel(b, ImageWidget:new{ image = bb, width = bb:getWidth(), height = bb:getHeight(),
                image_disposable = false, fgcolor = Blitbuffer.COLOR_BLACK })
        end
        return FrameContainer:new{ bordersize = selected and S(3) or 0, color = Blitbuffer.COLOR_BLACK,
            radius = S(14), padding = selected and S(1) or S(4), margin = 0, Theme.keep(b, S(11)) }
    end
    local build = function()
        local look = it.look or {}
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(it.label, content_w, _("Done"), closeSelf))
        add(VerticalSpan:new{ width = S(14) })
        for r = 0, 1 do
            local hg = HorizontalGroup:new{ align = "center" }
            for i = 1, per_row do
                if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
                table.insert(hg, swatch(FolderLook.COLORS[r * per_row + i].key))
            end
            add(hg)
            add(VerticalSpan:new{ width = S(8) })
        end
        add(VerticalSpan:new{ width = S(8) })
        local half = math.floor((content_w - gap) / 2)
        local icon_label = look.icon and string.format(_("Icon: %s"), FolderLook.iconName(look.icon))
            or _("Add an icon\u{2026}")
        local row = HorizontalGroup:new{ align = "center" }
        table.insert(row, self:actionButton(icon_label, look.icon and half or content_w,
            function() self:chooseFolderIcon(it) end))
        if look.icon then
            table.insert(row, HorizontalSpan:new{ width = gap })
            table.insert(row, self:actionButton(_("No icon"), half, function()
                self:setFolderLook(it, function(l) l.icon = nil end)
                self:rebuildSheet("_folder_look")
            end))
        end
        add(row)
        add(VerticalSpan:new{ width = S(10) })
        add(self:actionButton(_("Plain folder"), content_w, function()
            self:setFolderLook(it, function(l) l.color, l.icon = nil, nil end)
            self:rebuildSheet("_folder_look")
        end, it.look == nil))
        return content
    end
    self:showSheet("_folder_look", build)
end

-- A grid of the icons on offer (the reader's koreader/icons folder, Ink
-- Away's, KOReader's); a tap puts one on the folder. The sheet steps aside
-- (sheets stay above other windows) and comes back after.
function InkAwayView:chooseFolderIcon(it)
    self:closeSheet("_folder_look")
    local items, start = {}, 1
    for i, ic in ipairs(FolderLook.icons()) do
        local sel = it.look and it.look.icon == ic.id
        items[i] = { label = ic.label, id = ic.id, path = ic.path, selected = sel }
        if sel then start = i end
    end
    local wide = Screen:getWidth() > Screen:getHeight()
    local grid
    grid = ThumbGrid:new{
        title = _("Folder icon"),
        items = items,
        start = start,
        cols = wide and 6 or 4,
        rows = wide and 3 or 5,
        flash_open = false,   -- it opens over the library
        close_label = _("Cancel"),
        empty_text = _("No icons found."),
        render = function(ic, w, h)
            return FolderLook.iconPreview(ic.path, math.floor(math.min(w, h) * 0.7), 0xE6)
        end,
        on_pick = function(ic)
            self:setFolderLook(it, function(l) l.icon = ic.id end)
            grid:close()
        end,
        on_close = function() self:folderLookSheet(it) end,
    }
    UIManager:show(grid)
end

------------------------------------------------------------------------------
-- Thumbnails
------------------------------------------------------------------------------

-- Run fn with an empty placed-image cache, freeing whatever it decodes, so a
-- thumbnail of another document leaves the open one's images alone.
function InkAwayView:withOwnImageCache(fn)
    local saved = { self._img_bb, self._img_scaled, self._img_render, self._img_disp }
    self._img_bb, self._img_scaled, self._img_render, self._img_disp = nil, nil, nil, nil
    local ok, err = pcall(fn)
    self:freeImageCache()
    self._img_bb, self._img_scaled, self._img_render, self._img_disp = saved[1], saved[2], saved[3], saved[4]
    if not ok then error(err) end
end

-- Draw the document at `path` (a drawing, or a notebook's first page) the size
-- of the page, then shrink it to fit maxw x maxh. Returns a BlitBuffer or nil.
function InkAwayView:renderDocThumb(path, maxw, maxh)
    local data = Project.load(path)
    if not data then return nil end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local scratch = Blitbuffer.new(W, H, self.canvas_bb and self.canvas_bb:getType() or Blitbuffer.TYPE_BBRGB32)
    local ops, bg, template
    if Project.isNotebook(data) then
        local nb = Notebook.fromData(data)
        local page = nb.pages[1]
        ops, template = page.ops, nb:pageTemplate(1)
        if template.pdf_path and page.src then
            local doc = (self._nb_pdf_path == template.pdf_path) and self._nb_pdf_doc
            local own
            if not doc then
                local ok, d = pcall(function()
                    return require("document/documentregistry"):openDocument(template.pdf_path)
                end)
                doc, own = ok and d or nil, true
            end
            bg = doc and self:renderPdfPage(doc, page.src, W, H)
            if own and doc then pcall(function() doc:close() end) end
        end
    else
        ops = Layers.drawnOfFile(data.ops, data.layers)   -- (without a hidden layer's)
        -- a drawing on its paper (a template draws it, as for a notebook page)
        template = { style = "blank", paper = Palette.paperRGB(data.paper) }
        if type(data.bg) == "string" and Storage.exists(data.bg) then
            local ok, img = pcall(function() return RenderImage:renderImageFile(data.bg, false) end)
            if ok and img then bg = fitIntoCanvasBB(img, W, H) end
        end
    end
    self:trueColours(function()   -- (kept as a file, shown in day mode too)
        self:withOwnImageCache(function() self:composeInto(scratch, ops, bg, template) end)
    end)
    if bg then bg:free() end
    local scale = math.min(maxw / W, maxh / H)
    local thumb = RenderImage:scaleBlitBuffer(scratch, math.max(1, math.floor(W * scale)),
        math.max(1, math.floor(H * scale)), false)
    if thumb ~= scratch then scratch:free() end
    return thumb
end

-- The thumbnail of the document at `path`, from the cache when the file has not
-- changed since it was drawn, else drawn now and cached.
function InkAwayView:docThumb(path, maxw, maxh)
    local dir = Storage.cacheDir()
    local file = Storage.join(dir, Library.thumbName(path, Storage.mtime(path), maxw, maxh))
    if Storage.exists(file) then
        local ok, bb = pcall(function() return RenderImage:renderImageFile(file, false) end)
        if ok and bb then return bb end
    end
    local thumb = self:renderDocThumb(path, maxw, maxh)
    if thumb then
        self:dropThumbs(path)
        pcall(function() thumb:writePNG(file) end)
    end
    return thumb
end

-- The picture at `path` shrunk to fit maxw x maxh, from the thumbnail cache
-- when it hasn't changed, else drawn now and cached. Nil for a picture too
-- large to open on a reader (it says how large before anything is decoded).
function InkAwayView:pictureThumb(path, maxw, maxh)
    local dir = Storage.cacheDir()
    local file = Storage.join(dir, Library.thumbName(path, Storage.mtime(path), maxw, maxh))
    if Storage.exists(file) then
        local ok, bb = pcall(function() return RenderImage:renderImageFile(file, false) end)
        if ok and bb then return bb end
    end
    local f = io.open(path, "rb")
    local head = f and f:read(1024 * 1024) or ""
    if f then f:close() end
    local w, h = require("ink/share/http").imageSize(head)
    if not w or w * h > 40 * 1000 * 1000 then return nil end
    local ok, img = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if not (ok and img) then return nil end
    local s = math.min(maxw / img:getWidth(), maxh / img:getHeight(), 1)
    local thumb = RenderImage:scaleBlitBuffer(img, math.max(1, math.floor(img:getWidth() * s)),
        math.max(1, math.floor(img:getHeight() * s)), false)
    if thumb ~= img then img:free() end
    self:dropThumbs(path)
    pcall(function() thumb:writePNG(file) end)
    return thumb
end

-- Show the picture at `path` on the whole screen (KOReader's image viewer:
-- pinch to zoom, a tap or Back to close).
function InkAwayView:viewPicture(path)
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok then return end
    UIManager:show(ImageViewer:new{ file = path, fullscreen = true, with_title_bar = true,
        title_text = Storage.baseName(path), modal = true })
end

-- Delete every cached thumbnail of the document at `path`.
function InkAwayView:dropThumbs(path)
    local code = Library.pathCode(path) .. "-"
    local dir = Storage.cacheDir()
    for _, e in ipairs(Storage.list(dir)) do
        if e.name:sub(1, #code) == code then os.remove(e.path) end
    end
end

return InkAwayView
