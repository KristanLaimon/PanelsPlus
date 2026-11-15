--[[
Ink Away, a drawing canvas and notebook for e-ink readers. This file only plugs
it into KOReader (the Tools menu entry and the gesture actions) and opens the
view; everything else lives under ink/. In the reader it also brings the open
book's ink (ink/reader/): shown over the pages, and drawn in the annotation mode.
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("ink/l10n")

local InkAway = WidgetContainer:extend{
    name = "inkaway",
    is_doc_only = false,
}

function InkAway:onDispatcherRegisterActions()
    Dispatcher:registerAction("inkaway_open", {
        category = "none",
        event = "InkAwayOpen",
        title = _("Open Ink Away"),
        general = true,
    })
    Dispatcher:registerAction("inkaway_library", {
        category = "none",
        event = "InkAwayLibrary",
        title = _("Ink Away library"),
        general = true,
    })
    -- in a book: draw on it; book notes, or Ink Away itself outside a book
    Dispatcher:registerAction("inkaway_annotate", {
        category = "none",
        event = "InkAwayAnnotate",
        title = _("Ink Away: annotate the book"),
        reader = true,
    })
    -- the quick menu of the icon in the top menu bar (see ink/launcher.lua)
    Dispatcher:registerAction("inkaway_launcher", {
        category = "none",
        event = "InkAwayLauncher",
        title = _("Ink Away: quick menu"),
        general = true,
    })
    Dispatcher:registerAction("inkaway_capture", {
        category = "none",
        event = "InkAwayCapture",
        title = _("Ink Away: copy part of the screen"),
        reader = true,
    })
    Dispatcher:registerAction("inkaway_booknotes", {
        category = "none",
        event = "InkAwayBookNotes",
        title = _("Ink Away: book notes (Ink Away outside a book)"),
        general = true,
    })
end

-- The Ink Away module of each KOReader screen (the file browser, each open book),
-- found from the screen's menu. (KOReader names a plugin after its folder, which
-- is not always the same, so ui.inkaway cannot be relied on.)
InkAway.by_ui = setmetatable({}, { __mode = "k" })

function InkAway:init()
    InkAway.by_ui[self.ui] = self
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- Ink Away's gesture actions reach it even when another window covers the
    -- file browser (a home screen plugin): KOReader gives such windows' unused
    -- events to the modules listed here, as it does for screenshots
    if type(self.ui.active_widgets) == "table" then table.insert(self.ui.active_widgets, self) end
    -- cloud sync: set up once for the whole session (nothing happens unless the person connected)
    local sok, SyncManager = pcall(require, "ink/sync/manager")
    if sok and not SyncManager.started then pcall(SyncManager.start) end
    -- book ink follows its book when KOReader moves, copies or deletes it
    local bok, BookInk = pcall(require, "ink/reader/bookink")
    if bok then BookInk.installFollow() end
    -- room made in a book's text: its style rules go with KOReader's style tweaks
    -- (plugins start before the book is first laid out, so they are in from the start)
    if not InkAway._rooms_css then
        InkAway._rooms_css = true
        -- a book with words wrapped for exact room is read from its edited copy
        pcall(function() require("ink/reader/exactbook").install() end)
        pcall(function()
            local StyleTweak = require("apps/reader/modules/readerstyletweak")
            local orig = StyleTweak.getCssText
            StyleTweak.getCssText = function(tweak, ...)
                local css = orig(tweak, ...)
                local plugin = tweak.ui and InkAway.by_ui[tweak.ui]
                local book = plugin and plugin.book
                if not book then return css end
                local ok, extra = pcall(book.roomsCss, book)
                if not (ok and extra) then return css end
                return (css and css ~= "" and (css .. "\n") or "") .. extra
            end
            -- KOReader's "Zoom (dpi)" scales the book's pixels: the rules are written
            -- again so the rooms keep their size on the screen (the reader's own
            -- handler takes the event, so it is followed here)
            local Typeset = require("apps/reader/modules/readertypeset")
            local orig_dpi = Typeset.onSetRenderDPI
            Typeset.onSetRenderDPI = function(typeset, ...)
                local r = orig_dpi(typeset, ...)
                local plugin = typeset.ui and InkAway.by_ui[typeset.ui]
                local book = plugin and plugin.book
                if book and #book:rooms() > 0 then
                    UIManager:nextTick(function()
                        if plugin.book == book then book:relayout() end
                    end)
                end
                return r
            end
            -- the render mode decides how a box room is made (exact where the mode
            -- floats things, of whole paragraphs where it does not): its rules again
            local orig_mode = Typeset.onSetBlockRenderingMode
            if orig_mode then
                Typeset.onSetBlockRenderingMode = function(typeset, ...)
                    local r = orig_mode(typeset, ...)
                    local plugin = typeset.ui and InkAway.by_ui[typeset.ui]
                    local book = plugin and plugin.book
                    if book and #book:rooms() > 0 then
                        UIManager:nextTick(function()
                            if plugin.book == book then book:relayout() end
                        end)
                    end
                    return r
                end
            end
        end)
    end
    -- in the reader: the book's ink, painted over its pages (a book without ink
    -- costs a file check here and nothing per page)
    if self.ui.document and self.ui.view and self.ui.view.registerViewModule then
        local ok, Book = pcall(require, "ink/reader/book")
        if ok then
            -- (viewer plugins such as PanelsPlus can show its pages for annotation mode, see ink/integration.lua)
            local iok, Integration = pcall(require, "ink/integration")
            self.book = Book.new(self.ui, iok and Integration.new() or nil)
            self.book.plugin = self
            UIManager:nextTick(function() self:syncBook() end)   -- (cloud sync: match its ink with the other readers')
            self.ui.view:registerViewModule("inkaway", self.book:overlay())
            -- handwritten notes on the reader's highlights (see there)
            local nok, HlNotes = pcall(require, "ink/reader/hlnotes")
            if nok then pcall(HlNotes.install, self) end
            -- highlighting with the pen's button while reading (see there)
            local hok, PenHighlight = pcall(require, "ink/reader/penhighlight")
            if hok then
                self.pen_highlight = PenHighlight.new(self.book)
                self.pen_highlight:attach()
            end
            -- the integration API ready for viewer plugins, once the book is set up
            if self.book.integration then
                local pok, err = pcall(self.book.integration.publish, self.book.integration, self.ui, self:integrationFacade())
                if not pok then logger.warn("Ink Away: integration API:", err) end
            end
        end
    end
    -- a long press on a PDF in the file browser offers it as an Ink Away notebook
    if not self.ui.document and self.ui.addFileDialogButtons then
        self.ui:addFileDialogButtons("inkaway_pdf", function(file, is_file)
            if not (is_file and file:lower():match("%.pdf$")) then return nil end
            return { { text = _("Open as Ink Away notebook"), callback = function()
                local FileManager = require("apps/filemanager/filemanager")
                local fm = FileManager.instance
                if fm and fm.file_dialog then UIManager:close(fm.file_dialog) end
                self:openPdfAsNotebook(file)
            end } }
        end)
    end
    -- Ink Away's icon in KOReader's top menu bar, once for both menus (the file
    -- browser's and the reader's); see ink/topbar.lua
    if not InkAway._topbar then
        InkAway._topbar = true
        pcall(function()
            local lfs = require("libs/libkoreader-lfs")
            local dir = debug.getinfo(1, "S").source:match("^@(.*/)main%.lua$") or "./"
            require("ink/topbar").installIcon(lfs, dir, require("datastorage"):getDataDir(), lfs.currentdir())
        end)
        local Topbar = require("ink/topbar")
        local function get(k) return G_reader_settings:readSetting(k) end
        local function tap(menu)
            local plugin = menu.ui and InkAway.by_ui[menu.ui]
            if plugin then plugin:onInkAwayLauncher() end
        end
        for _i, mod in ipairs({ "apps/filemanager/filemanagermenu", "apps/reader/modules/readermenu" }) do
            local ok, class = pcall(require, mod)
            if ok then Topbar.patch(class, get, tap) end
        end
    end
    -- the book gestures, once, after every plugin (the gesture manager too) is up
    if (tonumber(G_reader_settings:readSetting("inkaway_gestures_setup")) or 0) < 3 then
        UIManager:nextTick(function() self:setupEntryGestures() end)
    end
    -- old screen clips go as the settings say, without waiting for the next one
    UIManager:nextTick(function()
        pcall(function()
            require("ink/clips").sweepAuto(function(k) return G_reader_settings:readSetting(k) end)
        end)
    end)
    -- the notebooks as a shelf source of the Bookshelf plugin, when it is
    -- installed; plugins load in name order, so it may come up after this one
    local Shelf = require("ink/bookshelf")
    if not Shelf.register(self.ui, self) then
        UIManager:nextTick(function() Shelf.register(self.ui, self) end)
    end
    -- and the drawings, in their frames, as another
    local DrawingShelf = require("ink/drawingshelf")
    if not DrawingShelf.register(self.ui, self) then
        UIManager:nextTick(function() DrawingShelf.register(self.ui, self) end)
    end
    -- emulator hook: INKAWAY_AUTOOPEN opens the canvas straight away, once; the
    -- variable is never set on a device
    if os.getenv("INKAWAY_AUTOOPEN") and not InkAway._autoopened then
        InkAway._autoopened = true
        UIManager:scheduleIn(1.2, function() self:openCanvas() end)
    end
end

function InkAway:addToMainMenu(menu_items)
    if self.book then
        menu_items.inkaway = {
            text = _("Ink Away"),
            sorting_hint = "tools",
            sub_item_table = {
                { text = _("Annotate the book"), keep_menu_open = false,
                  callback = function() self:onInkAwayAnnotate() end },
                { text = _("Copy part of the screen"), keep_menu_open = false,
                  enabled_func = function() return require("device"):isTouchDevice() end,
                  callback = function() self:onInkAwayCapture() end },
                { text = _("Book notes"), keep_menu_open = false,
                  callback = function() self:onInkAwayBookNotes() end },
                { text = _("Export the book with its annotations\u{2026}"), keep_menu_open = false,
                  callback = function() self:onInkAwayExportBook() end },
                { text = _("Open Ink Away"), keep_menu_open = false,
                  callback = function() self:openCanvas() end },
                { text = _("Icon in the top menu bar"), keep_menu_open = true,
                  help_text = _("Ink Away's icon in this bar opens a quick menu from any screen. It shows the next time the menu is opened."),
                  checked_func = function() return require("ink/topbar").enabled(function(k) return G_reader_settings:readSetting(k) end) end,
                  callback = function()
                      local Topbar = require("ink/topbar")
                      local on = not Topbar.enabled(function(k) return G_reader_settings:readSetting(k) end)
                      G_reader_settings:saveSetting(Topbar.SETTING, on)
                  end },
            },
        }
        local file = self.ui.document and self.ui.document.file
        if file and file:lower():match("%.pdf$") then
            table.insert(menu_items.inkaway.sub_item_table, {
                text = _("Open as Ink Away notebook"), keep_menu_open = false,
                callback = function() self:openPdfAsNotebook(file) end,
            })
        end
        local two = self:twoPage()
        if two then
            table.insert(menu_items.inkaway.sub_item_table, self:twoPageMenu(two))
        end
        local PenHighlight = self.pen_highlight and require("ink/reader/penhighlight")
        if PenHighlight and PenHighlight.penReader() then
            table.insert(menu_items.inkaway.sub_item_table, {
                text = _("Highlight with the pen's button"),
                help_text = _("Hold the pen's side button and run the pen over a line of text: it becomes a highlight, without opening the annotation mode. The button is the one set to Highlighter in Gestures and pen buttons."),
                checked_func = function() return PenHighlight.enabled() end,
                callback = function()
                    local on = not PenHighlight.enabled()
                    PenHighlight.setEnabled(on)
                    if PenHighlight.anyEnabled() then self.pen_highlight:attach() else self.pen_highlight:detach() end
                end,
            })
            table.insert(menu_items.inkaway.sub_item_table, {
                text = _("Erase with the pen's eraser end"),
                help_text = _("Run the pen's eraser end over a highlight or over Ink Away's ink on the page: it goes, without opening the annotation mode. The eraser settings of the annotation mode apply. The part of the pen is the one set to Eraser in Gestures and pen buttons."),
                checked_func = function() return PenHighlight.eraseEnabled() end,
                callback = function()
                    PenHighlight.setEraseEnabled(not PenHighlight.eraseEnabled())
                    if PenHighlight.anyEnabled() then self.pen_highlight:attach() else self.pen_highlight:detach() end
                end,
            })
        end
        return
    end
    menu_items.inkaway = {
        text = _("Ink Away (drawing canvas)"),
        sorting_hint = "tools",   -- top level of the Tools tab, not buried in "More tools"
        keep_menu_open = false,
        callback = function() self:openCanvas() end,
    }
end

-- Ink Away's two pages for this book (see ink/reader/twopage.lua), or nil where they
-- can't be: not a fixed-page book, or another plugin already shows it in two pages.
function InkAway:twoPage()
    if not (self.book and self.ui and self.ui.paging) then return nil end
    if self.two_page then return self.two_page end
    local ok, TwoPage = pcall(require, "ink/reader/twopage")
    if not (ok and TwoPage.available(self.ui)) then return nil end
    self.two_page = TwoPage.new(self.ui)
    return self.two_page
end

-- The menu of the two pages: when, the first page, and whether every PDF opens so.
function InkAway:twoPageMenu(two)
    local TwoPage = require("ink/reader/twopage")
    local function mode(text, value)
        return { text = text, radio = true, keep_menu_open = true,
            checked_func = function() return two.mode == value end,
            callback = function() two:setMode(value) end }
    end
    local items = {
        mode(_("Off"), TwoPage.OFF),
        mode(_("In landscape"), TwoPage.LANDSCAPE),
        mode(_("Always"), TwoPage.ALWAYS),
        { text = _("First page on its own"), keep_menu_open = true, separator = true,
          help_text = _("For a book with a cover: the pairs then start from its second page."),
          enabled_func = function() return two.mode ~= TwoPage.OFF end,
          checked_func = function() return two.first_alone end,
          callback = function() two:setFirstAlone(not two.first_alone) end },
    }
    local file = self.ui.document and self.ui.document.file
    if type(file) == "string" and file:lower():match("%.pdf$") then
        items[#items + 1] = { text = _("Open every PDF this way"), keep_menu_open = true,
            help_text = _("New PDFs open with this choice. A PDF you set yourself keeps its own."),
            enabled_func = function() return two.mode ~= TwoPage.OFF end,
            checked_func = function() return two.mode ~= TwoPage.OFF and G_reader_settings:readSetting(TwoPage.MODE) == two.mode end,
            callback = function()
                local on = G_reader_settings:readSetting(TwoPage.MODE) == two.mode
                G_reader_settings:saveSetting(TwoPage.MODE, (not on) and two.mode or nil)
            end }
    end
    return { text = _("Two pages side by side"), sub_item_table = items,
        help_text = _("Shows two pages next to each other, as a printed book falls open, also for a PDF whose pages are all single ones. Your ink stays on the page you drew it on. A page wider than tall is shown alone. This uses the page view, and switches to it.") }
end

-- Set the book gestures in KOReader's gesture manager, where they are free
-- (see ink/reader/entrygestures.lua), and keep what was placed, and what held
-- the gestures that weren't, for the notice the first time Ink Away opens
-- (see ink/view/welcome.lua). With the gesture manager off that is all the
-- notice can say, and the setup runs again once it is on.
function InkAway:setupEntryGestures()
    local version = tonumber(G_reader_settings:readSetting("inkaway_gestures_setup")) or 0
    if version >= 3 then return end
    local g = self.ui and self.ui.gestures
    if not (g and type(g.data) == "table") then
        if version < 2 then G_reader_settings:saveSetting("inkaway_entry_gestures", { off = true }) end
        return
    end
    local EntryGestures = require("ink/reader/entrygestures")
    -- An upgrade adds only capture: never restore a gesture the reader removed
    -- or moved after the previous setup, and keep its existing setup record.
    local placed, busy, n = EntryGestures.apply(g.data, version >= 2 and { EntryGestures.CAPTURE } or nil)
    local previous = G_reader_settings:readSetting("inkaway_entry_gestures") or {}
    if version >= 2 then
        for id, where in pairs(previous.placed or {}) do
            if not placed[id] then placed[id] = where end
        end
    end
    if n > 0 then
        g.updated = true
        pcall(g.onFlushSettings, g)
    end
    local held = {}
    if version >= 2 then
        for _i, item in ipairs(previous.held or {}) do
            if item.feature ~= "capture" then held[#held + 1] = item end
        end
    end
    for _i, b in ipairs(busy) do
        local what = ""
        pcall(function() what = Dispatcher:menuTextFunc(b.current) end)
        what = what:gsub(":.*$", "")   -- the action, without its settings
        held[#held + 1] = { feature = b.feature, section = b.section, ges = b.ges, what = what }
    end
    G_reader_settings:saveSetting("inkaway_entry_gestures", { placed = placed, held = held })
    G_reader_settings:saveSetting("inkaway_gestures_setup", 3)
end

-- The quick menu: from the icon in the top menu bar, or a gesture set to it.
-- A quick menu that can't be built (a partly copied install, say) must never take
-- KOReader down with it: it is logged, and Ink Away opens as usual instead.
function InkAway:onInkAwayLauncher()
    local ok, err = pcall(function() require("ink/launcher").show(self) end)
    if not ok then
        require("logger").warn("InkAway: quick menu:", err)
        pcall(function() self:openCanvas() end)
    end
    return true
end

-- The reader's gesture action uses the same quiet capture mode as the menu.
function InkAway:onInkAwayCapture()
    if self.book and require("device"):isTouchDevice() then
        require("ink/reader/capture").open(self.book)
    end
    return true
end

-- Draw on the book being read (does nothing outside a book).
function InkAway:onInkAwayAnnotate()
    if self.book then self.book:annotate() end
    return true
end

-- The integration API's public side, published as ui.inkAwayIntegrationAPI for
-- viewer plugins (docs/INTEGRATION.md): what they may call, and nothing else of
-- Ink Away. Experimental: it may change before Ink Away 5.0, so a consumer checks
-- the two version numbers.
function InkAway:integrationFacade()
    if self._facade then return self._facade end
    local plugin = self
    local function integration() return plugin.book and plugin.book.integration end
    local f = { integration_api_version = 1, document_surface_version = 1, ui = self.ui }
    -- a widget's surface for annotation mode, with optional on_open, on_close and
    -- on_error for that surface; returns the cleanup to call before the widget goes
    function f:installPluginIntegration(widget, surface, options)
        local api = assert(integration(), "Ink Away has no book open")
        return api:install(f, widget, surface, options)
    end
    -- the book's ink painted on the surface (in the viewer's own paint)
    function f:paintDocumentSurface(surface, bb)
        local book = plugin.book
        if book and book.integration and surface and surface.document == plugin.ui.document then
            local ok, err = pcall(book.paintSurface, book, surface, bb)
            if not ok then book.integration:report(surface, err) end
        end
    end
    -- the surface going away: annotation mode on it closes, its ink kept
    function f:releaseDocumentSurface(surface)
        local book = plugin.book
        if book and book.surface == surface then
            book:closeViews()
            book:setSurface(nil)
        end
    end
    function f:onAnnotationOpened(callback) return assert(integration(), "Ink Away has no book open"):onAnnotationOpened(callback) end
    function f:onAnnotationClosed(callback) return assert(integration(), "Ink Away has no book open"):onAnnotationClosed(callback) end
    -- open annotation mode (on the topmost viewer that gave a surface, else the reader)
    function f:onInkAwayAnnotate() return plugin:onInkAwayAnnotate() end
    self._facade = f
    return f
end

-- The export sheet of the book being read, over the annotation mode (the one
-- place a book is exported from, see ink/view/export.lua).
function InkAway:onInkAwayExportBook()
    if not self.book then return true end
    self.book:annotate()
    local view = self.book._view
    if view then
        UIManager:nextTick(function()
            if view == self.book._view then view:openExport() end
        end)
    end
    return true
end

-- The book's notes in a book; anywhere else, Ink Away as its settings open it.
function InkAway:onInkAwayBookNotes()
    if self.book and self.book.openNotes then
        self.book:openNotes()
    else self:openCanvas() end
    return true
end

-- The reader is going to sleep: cloud sync sends what is waiting, if the person asked for that.
function InkAway:onSuspend()
    local ok, SyncManager = pcall(require, "ink/sync/manager")
    if ok then pcall(SyncManager.noteSleep) end
end

-- The screen turned (or was resized) under the book: what Ink Away had open
-- over it was laid out for the old size, so it closes, keeping everything.
function InkAway:onSetDimensions()
    if self.book then self.book:closeViews() end
end

-- Cloud sync, for a book: newer ink from the other readers (a few seconds at most,
-- only if the person turned it on), then keep the sync's hands off the ink while
-- the book is open. The book is matched with the other readers' by its checksum.
function InkAway:syncBook()
    local ok, SyncManager = pcall(require, "ink/sync/manager")
    local book, ui = self.book, self.ui
    if not (ok and book and ui.document and book.sidecar) then return end
    local md5
    pcall(function() md5 = ui.doc_settings:readSetting("partial_md5_checksum") end)
    if not md5 then pcall(function() md5 = require("util").partialMD5(ui.document.file) end) end
    if not md5 then return end
    self.sync_md5 = md5
    local file = ui.document.file
    pcall(SyncManager.preOpenBook, md5, book.sidecar, file, function(fetched)
        -- (the answer can come after the book was closed or loaded again, when its
        -- reader has no document any more)
        if self.book ~= book or not ui.document then return end
        if fetched then pcall(book.reload, book) end
        pcall(SyncManager.bookOpened, md5, book.sidecar, file)
    end)
end

-- The book is up: one whose rooms need markers it was not laid out with (they
-- came with the cloud sync, or its saved layout is older) is loaded again with them.
function InkAway:onReaderReady()
    -- a book loaded again for rooms is ready (whatever became of KOReader's own callback)
    local bok, Book = pcall(require, "ink/reader/book")
    if bok and Book.pending_reload and self.book then pcall(Book.finishReload, self.ui) end
    -- two pages, for a book that shows them (with them off, nothing is installed)
    local two = self:twoPage()
    if two and two.mode ~= "off" then two:apply(true) end
    if self.book and self.book.checkMarkers then
        UIManager:scheduleIn(0.5, function()
            if self.book then pcall(self.book.checkMarkers, self.book) end
        end)
    end
end

-- The book is closing: leave nothing of ours open over it.
function InkAway:onCloseDocument()
    if self.sync_md5 then
        local ok, SyncManager = pcall(require, "ink/sync/manager")
        if ok then pcall(SyncManager.bookClosed) end
        self.sync_md5 = nil
    end
    -- viewer plugins see the API go first, and lose it for good after the close
    local integration = self.book and self.book.integration
    if integration then integration:unpublish(self.ui, self:integrationFacade()) end
    local ok, err = pcall(function()
        if self.book then self.book:close() end
        -- (after the views over the book, which give the pen back as they close)
        if self.pen_highlight then self.pen_highlight:detach() end
    end)
    if integration then integration:dispose() end
    if not ok then error(err) end
end

-- The gesture actions, when a gesture is mapped to Ink Away or its library.
function InkAway:onInkAwayOpen()
    self:openCanvas()
    return true
end

function InkAway:onInkAwayLibrary()
    self:openCanvas(true)
    return true
end

-- A new notebook from the PDF at `path`, in the library's top folder, written on
-- over the PDF's own pages.
function InkAway:openPdfAsNotebook(path)
    local view = self:openCanvas()
    view:startPdfNotebook(path, view:libraryDir())
end

-- Open the canvas, with the library on top when `library` is set, or on the
-- document at `path`. Returns the view.
function InkAway:openCanvas(library, path)
    -- Close any Ink Away view still open before opening a fresh one: a buried
    -- copy would keep painting and running its timers, and a reopen should start
    -- clean even if one got stuck. The stack is copied, as close() changes it.
    local stack = UIManager._window_stack or {}
    local existing = {}
    for i = 1, #stack do
        local w = stack[i] and stack[i].widget
        if w and w.name == "inkaway_view" then existing[#existing + 1] = w end
    end
    for _, w in ipairs(existing) do UIManager:close(w) end
    local InkAwayView = require("ink/view")
    local view = InkAwayView:new{ show_library = library or nil, open_path = path, kui = self.ui }
    UIManager:show(view)
    return view
end

return InkAway
