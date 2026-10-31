--[[
The open document. Every drawing and notebook is a file in the library that
saves itself: a few seconds after a change, and whenever it is left (another
document, closing, the reader going to sleep). Also the File and New sheets,
rename and duplicate, and the folders files are offered in.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("ink/l10n")
local Folder = require("ink/folder")
local Library = require("ink/library")
local Palette = require("ink/palette")
local Project = require("ink/project")
local Storage = require("ink/storage")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local existingDir = Storage.existingDir

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

-- Seconds without a change before the document saves itself, and the longest a
-- save waits while changes keep coming.
local SAVE_IDLE = 8
local SAVE_MAX_WAIT = 60

local InkAwayView = {}

------------------------------------------------------------------------------
-- The document and its state
------------------------------------------------------------------------------

-- The name shown for a kind of document.
function InkAwayView:docKindLabel(kind)
    return kind == "notebook" and _("Notebook") or _("Drawing")
end

-- The open document's name: its file name without the extension.
function InkAwayView:docName()
    return self.doc_path and Storage.stem(self.doc_path) or ""
end

-- The library folder (see Library.root).
function InkAwayView:libraryDir()
    return Library.root(self:getSetting("inkaway_library_dir"))
end

-- The folder new documents go in: the open document's, else the library.
function InkAwayView:docDir()
    local dir = self.doc_path and existingDir(Storage.dirName(self.doc_path))
    return dir or self:libraryDir()
end

-- Is `dir` the Imported folder or inside it? Imported holds only what came from
-- another device.
function InkAwayView:inImported(dir)
    return dir ~= nil and Storage.within(dir, self:importedFolder())
end

-- The folder something new or copied goes in when asked for `dir`: the library
-- itself instead of anywhere in Imported. The second result is true when it
-- moved there.
function InkAwayView:writableDir(dir)
    if self:inImported(dir) then return self:libraryDir(), true end
    return dir, false
end

-- Say that something meant for Imported went in the library instead. `what` is "new" (a
-- new document), "copy", "copy_named" (a copy called `name`) or anything else for a
-- document called `name`; each is a whole sentence, so a translation can agree its words.
function InkAwayView:noteNotImported(what, name)
    local text
    if what == "new" then
        text = _("The new document is in Library: Imported only holds what you sent")
    elseif what == "copy" then
        text = _("The copy is in Library: Imported only holds what you sent")
    elseif what == "copy_named" then
        text = string.format(_("The copy, \u{201C}%s\u{201D}, is in Library: Imported only holds what you sent"), name)
    else
        text = string.format(_("\u{201C}%s\u{201D} is in Library: Imported only holds what you sent"), name)
    end
    self:showNotice(text)
end

-- Is there anything in the document worth a file: ink, a background picture,
-- more than one page, or pages over an imported PDF?
function InkAwayView:docHasContent()
    local nb = self.notebook
    if nb then
        return (nb.template and nb.template.pdf_path) ~= nil or nb:count() > 1
            or nb:hasInk() or not self.canvas:isEmpty()
    end
    return not self.canvas:isEmpty() or self.bg_path ~= nil
end

-- Has the document changed since it was last saved? Ops changes are counted by
-- the canvas; everything else (pages, paper, background) marks it dirty.
function InkAwayView:docChanged()
    return self.dirty or self.canvas.rev ~= self._page_rev
end

-- Note a change the canvas does not count, and make sure a save follows.
function InkAwayView:markDirty()
    self.dirty = true
    self:wakeAutosave()
end

-- Drop what was kept about each page (the save cache, the overview's
-- thumbnails), for a document just started or opened.
function InkAwayView:resetSaveState()
    self:freePageThumbs()
    self._page_cache = setmetatable({}, { __mode = "k" })
    self._page_rev = self.canvas.rev
    self.dirty = false
end

------------------------------------------------------------------------------
-- Saving
------------------------------------------------------------------------------

-- Schedule the save check, unless one is already waiting.
function InkAwayView:wakeAutosave()
    if self._autosave_pending or self.closing then return end
    self._autosave_pending = true
    UIManager:scheduleIn(SAVE_IDLE, self._autosave_tick)
end

-- Save once the document has been left alone for a moment. Never while a stroke
-- or text box is in progress; changes that keep coming delay the save, but only
-- up to SAVE_MAX_WAIT. Stops checking once everything is saved.
function InkAwayView:autosaveTick()
    self._autosave_pending = false
    if self.closing or not self:docChanged() then
        self._save_waited = 0
        return
    end
    local busy = self.capturing or (self._pen_state and self._pen_state.down)
        or self.editing_text or self._export_job
    local active = self.canvas.rev ~= self._tick_rev
    self._tick_rev = self.canvas.rev
    self._save_waited = (self._save_waited or 0) + SAVE_IDLE
    if not busy and (not active or self._save_waited >= SAVE_MAX_WAIT) then
        self:saveDocument()
    end
    if self:docChanged() then self:wakeAutosave() end
end

-- Save the open document if it changed, or always with `force`. A document with
-- nothing in it gets no file until it has something, so an untouched new one
-- leaves nothing behind. Returns false only when the write failed.
function InkAwayView:saveDocument(force)
    if not self.doc_path then return true end
    if self.notebook then self:nbSyncOut() end
    if not (force or self:docChanged()) then return true end
    if not self.doc_written and not self:docHasContent() then return true end
    local path = self.doc_path
    if not self.doc_written and Storage.exists(path) then
        -- the name it was started with has been taken since
        path = Storage.uniquePath(Storage.dirName(path), Storage.stem(path), Project.EXT)
    end
    local ok, err
    if self.notebook then
        ok, err = Project.saveNotebook(self.notebook, path, self._page_cache, { export = self.export_opts })
    else
        ok, err = Project.save(self.canvas, path, { bg = self.bg_path, export = self.export_opts, paper = self.paper,
            layers = self:layersForFile() })
    end
    if not ok then
        logger.warn("InkAway: saving failed:", path, err)
        if not self._save_failed then   -- once, not on every retry
            self._save_failed = true
            self:tell(string.format(_("Could not save:\n%s\n\n%s"), path, tostring(err)))
        end
        return false
    end
    self._save_failed = nil
    if not self.doc_written then   -- a new document joins the end of its folder's tabs
        Folder.update(Storage.dirName(path), function(d) Folder.add(d, Storage.baseName(path)) end)
    end
    self.doc_path, self.doc_written = path, true
    self.dirty = false
    self._page_rev = self.canvas.rev
    self._save_waited = 0
    self:rememberDoc(path)
    return true
end

-- Remember `path` as the document to reopen, and as the last notebook when the
-- open document is one (what Ink Away opens on when set to start on Notebooks).
function InkAwayView:rememberDoc(path)
    self:setSetting("inkaway_last_doc", path)
    if self.notebook then self:setSetting("inkaway_last_notebook", path) end
end

-- KOReader asks every widget to save before the reader sleeps and before a
-- widget closes.
function InkAwayView:onFlushSettings()
    if self.closing then return end
    self:flushPending()
    self:saveDocument()
end

------------------------------------------------------------------------------
-- New, open and rename
------------------------------------------------------------------------------

-- Settle anything half-done (a stroke, a text box, a selected image) and save
-- the open document, before another one replaces it.
function InkAwayView:leaveDocument()
    self:flushPending()
    if self.editing_text then self:finishTextEdit(true) end
    self:resetLasso()   -- drop any selection first
    self:saveDocument()
    self:shelfSnapshot()
    self:layerCachesDrop()   -- a layered drawing's caches go with it
end

-- Keep the snapshot its Bookshelf cover shows: a notebook's first page, if the
-- canvas shows that page (the current one unless `shows_first` says) and it
-- changed (see Shelf.takeSnapshot), or a drawing, if it changed since (see
-- DrawingShelf.takeSnapshot). Called once the document is saved. Nothing
-- without Bookshelf. Remembers the covers that follow it.
function InkAwayView:shelfSnapshot(shows_first)
    if self.notebook then
        local Shelf = require("ink/bookshelf")
        if Shelf.registered and Shelf.takeSnapshot(self, shows_first) then self._shelf_snapped = Shelf.covers end
    else
        local DShelf = require("ink/drawingshelf")
        if DShelf.registered and DShelf.takeSnapshot(self) then self._shelf_snapped = DShelf.covers end
    end
end

-- Start a new, empty document of `kind` in folder `dir` (the open document's by
-- default), named `name` (a dated default when nil). `setup` builds it: it
-- clears the canvas or enters notebook mode.
function InkAwayView:beginDocument(kind, name, setup, dir)
    local moved
    dir, moved = self:writableDir(dir or self:docDir())
    self:leaveDocument()
    self.doc_path = Storage.uniquePath(dir, name or Library.defaultName(self:docKindLabel(kind)), Project.EXT)
    self.doc_written = false
    self.save_area, self.export_opts = nil, nil
    setup()
    self:resetSaveState()
    if moved then self:noteNotImported("new") end
end

-- Replace the drawing with `ops`, dropping every selection and cached image.
function InkAwayView:loadOps(ops)
    self.canvas:setOps(ops)
    self:resetLasso()
    self:freeImageCache()
    self:layerCachesDrop()
end

-- Load a project's ops into the canvas. Returns false when there are none.
function InkAwayView:loadProjectData(data)
    if not data or not data.ops then return false end
    self:loadOps(data.ops)
    return true
end

-- Put a saved drawing's background picture back, if the file is still there.
function InkAwayView:restoreBackground(path)
    if Storage.exists(path) then
        self:loadBackground(path)
    else
        self:tell(string.format(
            _("The background picture could not be found:\n%s"), path))
    end
end

-- Open the document at `path`, saving the open one first. Returns whether it
-- opened; on failure the open document stays as it was.
function InkAwayView:openDocument(path)
    if path == self.doc_path and self.doc_written then return true end
    local data, err = Project.load(path)
    if not data then
        self:tell(_("Could not open that file.\n") .. tostring(err))
        return false
    end
    self:leaveDocument()
    self.save_area = nil
    self.export_opts = type(data.export) == "table" and data.export or nil
    if Project.isNotebook(data) then
        self:openNotebookData(data)
    else
        self:exitNotebook()
        self:clearBackground()
        self.paper = Palette.paperRGB(data.paper)
        self:loadProjectData(data)
        self:loadLayers(data.layers)
        if type(data.bg) == "string" then self:restoreBackground(data.bg) end
        self:composeCanvas(); self:renderView()
        self:resetTransientMemory()
        UIManager:setDirty(self, "full")
    end
    self.doc_path, self.doc_written = path, true
    self:resetSaveState()
    self:rememberDoc(path)
    return true
end

-- The document to show when Ink Away opens: the old session file of an earlier
-- version (once), else the last notebook when it starts on Notebooks, else the
-- last document, else a new drawing.
function InkAwayView:openStartDocument()
    -- a document asked for by path (a notebook tapped on a Bookshelf shelf)
    if self.open_path and Storage.exists(self.open_path) and self:openDocument(self.open_path) then return end
    self:mergeLegacyFolders()
    local path = self:adoptOldSession()
    if not path and self:getSetting("inkaway_start") == "notebooks" then
        local nb = self:getSetting("inkaway_last_notebook")
        if nb and Storage.exists(nb) then path = nb end
    end
    path = path or self:getSetting("inkaway_last_doc")
    if path and Storage.exists(path) and self:openDocument(path) then return end
    self.doc_path = Storage.uniquePath(self:libraryDir(), Library.defaultName(self:docKindLabel("drawing")), Project.EXT)
    self.doc_written = false
    self:resetSaveState()
end

-- Earlier versions kept the work in one "last session" file and could autosave
-- it or not. That file becomes a library document of its own, the first time
-- this version runs. Returns its path, or nil.
function InkAwayView:adoptOldSession()
    if self:getSetting("inkaway_session_migrated") then return nil end
    self:setSetting("inkaway_session_migrated", true)
    for _, key in ipairs({ "inkaway_autosave", "inkaway_last_dproj_dir", "inkaway_last_nproj_dir",
            "inkaway_last_dir", "inkaway_last_notebook_dir", "inkaway_last_project_dir" }) do
        self:setSetting(key, nil)
    end
    local old = Storage.join(Storage.settingsDir(), "inkaway_session." .. Project.EXT)
    if not Storage.exists(old) then return nil end
    return Library.adoptSession(old, self:libraryDir(), Library.defaultName(_("Recovered")))
end

-- Earlier versions saved drawings and notebooks in two folders of their own,
-- "drawing projects" and "notebook projects". Left as they were, they would look
-- like folders the reader made, and a new drawing started from an old notebook
-- would land in "notebook projects". Their documents join the library folder
-- instead, once, when the library is the "ink away" folder they sit in.
function InkAwayView:mergeLegacyFolders()
    if self:getSetting("inkaway_legacy_merged") then return end
    local root = self:libraryDir()
    if root ~= Storage.appRootPath() then return end
    self:setSetting("inkaway_legacy_merged", true)
    local moves = Library.mergeLegacy(root)
    if #moves == 0 then return end
    local last = self:getSetting("inkaway_last_doc")
    for _, m in ipairs(moves) do
        if last and Storage.within(last, m.old) then
            self:setSetting("inkaway_last_doc", m.new .. last:sub(#m.old + 1))
        end
        if not Storage.isDir(m.new) then self:dropThumbs(m.old) end
    end
    logger.info("InkAway: moved", #moves, "items from the old project folders into", root)
    self._note_on_show = _("Drawings and notebooks from the old \u{201C}drawing projects\u{201D} and \u{201C}notebook projects\u{201D} folders are now in the library.")
end

-- Start a new drawing in folder `dir` (the open document's by default). It
-- starts plain, without the grid, which keeps drawings apart from notebook
-- pages at a glance; the grid is a tap away in the settings.
function InkAwayView:newDrawing(dir)
    self.grid_on = false
    self:setSetting("inkaway_grid", false)
    self:beginDocument("drawing", nil, function()
        self:exitNotebook()
        self:clearBackground()
        self.paper = self:defaultPaper()
        self:loadOps({})
        self:composeCanvas(); self:renderView()
        self:resetTransientMemory()     -- reclaim the previous document's memory now
        UIManager:setDirty(self, "full")
    end, dir)
end

-- Start a new notebook with paper `style` in folder `dir`, ruled like the last
-- notebook (else like the drawing grid), so a new notebook matches the last one.
function InkAwayView:newNotebook(style, dir)
    self.nb_style = style
    self:setSetting("inkaway_nb_style", style)
    self:beginDocument("notebook", nil, function()
        self:startNotebook({ style = style,
            size = self.nb_size or self.grid_size or 40,
            strength = self.nb_strength or self.grid_strength or 45,
            paper = self:defaultPaper() })
    end, dir)
end

-- Pick a picture and start a drawing over it, named after it and saved at once.
function InkAwayView:newFromImage(dir)
    self:pickImageFile(function(path)
        self:beginDocument("drawing", Storage.stem(path), function()
            self:exitNotebook()
            self:clearBackground()
            self.paper = self:defaultPaper()
            self:loadOps({})
            self:loadBackground(path)
            self:resetTransientMemory()
        end, dir)
        self:saveDocument(true)
    end)
end

-- Where pictures and PDFs are picked from: KOReader's home folder.
function InkAwayView:homeDir()
    local home = self:getSetting("home_dir")
    if home and Storage.isDir(home) then return home end
    local ok, util = pcall(require, "apps/filemanager/filemanagerutil")
    return ok and util.getDefaultDir and util.getDefaultDir() or "/"
end

-- Copy the open document next to it and carry on in the copy.
function InkAwayView:duplicateDocument()
    self:leaveDocument()
    if not self.doc_written then
        self:showNotice(_("There is nothing to copy yet."), 2)
        return
    end
    local into, moved = self:writableDir(Storage.dirName(self.doc_path))
    local copy, err = Library.duplicate(self.doc_path, into)
    if not copy then
        self:tell(_("Could not duplicate.\n") .. tostring(err))
        return
    end
    Folder.update(Storage.dirName(copy), function(d) Folder.add(d, Storage.baseName(copy)) end)
    if self:openDocument(copy) then
        if moved then
            self:noteNotImported("copy_named", Storage.stem(copy))
        else
            self:showNotice(string.format(_("Now in the copy, \u{201C}%s\u{201D}"), Storage.stem(copy)))
        end
    end
end

function InkAwayView:promptRename()
    self:promptText{ title = _("Rename"), input = self:docName(), ok_text = _("Rename"),
        on_ok = function(text) self:renameDocument(text) end }
end

-- Rename the open document within its folder. Its file is renamed now if it has
-- one, else it is simply written under the new name.
function InkAwayView:renameDocument(name)
    name = (name or ""):match("^%s*(.-)%s*$")
    if name == "" or not self.doc_path then return end
    local new = Storage.join(Storage.dirName(self.doc_path), Storage.fileName(name, Project.EXT))
    if new == self.doc_path then return end
    -- a change of case only is the same file on a case-blind file system
    if Storage.exists(new) and new:lower() ~= self.doc_path:lower() then
        self:tell(string.format(
            _("There is already a file called \u{201C}%s\u{201D} here."), Storage.baseName(new)))
        return
    end
    if self.doc_written then
        local ok, err = os.rename(self.doc_path, new)
        if not ok then
            self:tell(_("Could not rename.\n") .. tostring(err))
            return
        end
        self:rememberDoc(new)
        local old = self.doc_path
        Folder.update(Storage.dirName(new), function(d) Folder.rename(d, Storage.baseName(old), Storage.baseName(new)) end)
    end
    self.doc_path = new
end

------------------------------------------------------------------------------
-- The File and New sheets
------------------------------------------------------------------------------

-- Folder `dir` as the library shows it: "Library / School".
function InkAwayView:placeOf(dir)
    local root = self:libraryDir()
    if not Storage.within(dir, root) then return dir end
    local place = _("Library")
    for part in dir:sub(#root + 2):gmatch("[^/]+") do place = place .. " / " .. part end
    return place
end

-- Where the open document is, as the library shows it.
function InkAwayView:docPlace()
    return self:placeOf(self.doc_path and Storage.dirName(self.doc_path) or self:libraryDir())
end

-- The File sheet (toolbar): the document's name and where it is kept; rename,
-- duplicate and export in a row; then the two ways to start something new as
-- large tiles. The library has its own toolbar button.
function InkAwayView:openDocumentSheet()
    self:flushPending()
    self:resetLasso()   -- drop any selection first
    self:saveDocument()   -- so the sheet tells the truth about where it is saved
    self:closeSheet("_doc_dialog")
    local content_w, gap = self:sheetWidth()
    local thirdW = math.floor((content_w - 2 * gap) / 3)
    local closeSelf = function() self:closeSheet("_doc_dialog") end
    local function act(label, w, cb, dark, icon)
        return self:actionButton(label, w, function() closeSelf(); cb() end, dark, nil, icon)
    end
    local status = self.doc_written
        and string.format(_("Saved automatically in %s"), self:docPlace())
        or string.format(_("Saved in %s once there is something in it"), self:docPlace())
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(self:docName(), content_w, _("Done"), closeSelf))
        add(vspan(4))
        add(self:sheetHint(status, content_w, 15))
        add(vspan(16))
        add(HorizontalGroup:new{ align = "center",
            act(_("Rename\u{2026}"), thirdW, function() self:promptRename() end, nil, "rename"),
            HorizontalSpan:new{ width = gap },
            act(_("Duplicate"), thirdW, function() self:duplicateDocument() end, nil, "duplicate"),
            HorizontalSpan:new{ width = gap },
            act(_("Export\u{2026}"), thirdW, function() self:openExport() end, nil, "export") })
        -- a drawing's layers (view/layers.lua): off until turned on
        if self:layersAllowed() then
            add(vspan(12))
            add(ToggleRow:new{ label = _("Layers"), is_on = self:layered(), width = content_w, parent = menu,
                callback = function(on)
                    closeSelf()
                    if on then self:layersOn() else self:confirmLayersOff() end
                end })
        end
        add(vspan(16))
        add(self:actionTile("pen", _("New drawing"), _("A blank page. Hold to start from a picture."), content_w,
            function() closeSelf(); self:newDrawing() end,
            function() closeSelf(); self:newFromImage() end))
        add(VerticalSpan:new{ width = gap })
        add(self:actionTile("notebook", _("New notebook"), _("Choose its paper, a PDF or a template"), content_w,
            function() closeSelf(); self:openNotebookPaper() end))
        return content
    end
    self:showSheet("_doc_dialog", build)
end

return InkAwayView
