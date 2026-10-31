--[[
Ink Away, a drawing canvas and notebook for e-ink readers. This file only plugs
it into KOReader (the Tools menu entry and the gesture actions) and opens the
view; everything else lives under ink/. In the reader it also brings the open
book's ink (ink/reader/): shown over the pages, and drawn in the annotation mode.
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
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
    Dispatcher:registerAction("inkaway_booknotes", {
        category = "none",
        event = "InkAwayBookNotes",
        title = _("Ink Away: book notes (Ink Away outside a book)"),
        general = true,
    })
end

function InkAway:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- Ink Away's gesture actions reach it even when another window covers the
    -- file browser (a home screen plugin): KOReader gives such windows' unused
    -- events to the modules listed here, as it does for screenshots
    if type(self.ui.active_widgets) == "table" then table.insert(self.ui.active_widgets, self) end
    -- book ink follows its book when KOReader moves, copies or deletes it
    local bok, BookInk = pcall(require, "ink/reader/bookink")
    if bok then BookInk.installFollow() end
    -- in the reader: the book's ink, painted over its pages (a book without ink
    -- costs a file check here and nothing per page)
    if self.ui.document and self.ui.view and self.ui.view.registerViewModule then
        local ok, Book = pcall(require, "ink/reader/book")
        if ok then
            self.book = Book.new(self.ui)
            self.book.plugin = self
            self.ui.view:registerViewModule("inkaway", self.book:overlay())
            -- highlighting with the pen's button while reading (see there)
            local hok, PenHighlight = pcall(require, "ink/reader/penhighlight")
            if hok then
                self.pen_highlight = PenHighlight.new(self.book)
                self.pen_highlight:attach()
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
    -- the book gestures, once, after every plugin (the gesture manager too) is up
    if (tonumber(G_reader_settings:readSetting("inkaway_gestures_setup")) or 0) < 2 then
        UIManager:nextTick(function() self:setupEntryGestures() end)
    end
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
                { text = _("Book notes"), keep_menu_open = false,
                  callback = function() self:onInkAwayBookNotes() end },
                { text = _("Export the book with its annotations\u{2026}"), keep_menu_open = false,
                  callback = function() self:onInkAwayExportBook() end },
                { text = _("Open Ink Away"), keep_menu_open = false,
                  callback = function() self:openCanvas() end },
            },
        }
        local file = self.ui.document and self.ui.document.file
        if file and file:lower():match("%.pdf$") then
            table.insert(menu_items.inkaway.sub_item_table, {
                text = _("Open as Ink Away notebook"), keep_menu_open = false,
                callback = function() self:openPdfAsNotebook(file) end,
            })
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

-- Set the book gestures in KOReader's gesture manager, where they are free
-- (see ink/reader/entrygestures.lua), and keep what was placed, and what held
-- the gestures that weren't, for the notice the first time Ink Away opens
-- (see ink/view/welcome.lua). With the gesture manager off that is all the
-- notice can say, and the setup runs again once it is on.
function InkAway:setupEntryGestures()
    if (tonumber(G_reader_settings:readSetting("inkaway_gestures_setup")) or 0) >= 2 then return end
    local g = self.ui and self.ui.gestures
    if not (g and type(g.data) == "table") then
        G_reader_settings:saveSetting("inkaway_entry_gestures", { off = true })
        return
    end
    local EntryGestures = require("ink/reader/entrygestures")
    local placed, busy, n = EntryGestures.apply(g.data)
    if n > 0 then
        g.updated = true
        pcall(g.onFlushSettings, g)
    end
    local held = {}
    for _i, b in ipairs(busy) do
        local what = ""
        pcall(function() what = Dispatcher:menuTextFunc(b.current) end)
        what = what:gsub(":.*$", "")   -- the action, without its settings
        held[#held + 1] = { feature = b.feature, section = b.section, ges = b.ges, what = what }
    end
    G_reader_settings:saveSetting("inkaway_entry_gestures", { placed = placed, held = held })
    G_reader_settings:saveSetting("inkaway_gestures_setup", 2)
end

-- Draw on the book being read (does nothing outside a book).
function InkAway:onInkAwayAnnotate()
    if self.book then self.book:annotate() end
    return true
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

-- The screen turned (or was resized) under the book: what Ink Away had open
-- over it was laid out for the old size, so it closes, keeping everything.
function InkAway:onSetDimensions()
    if self.book then self.book:closeViews() end
end

-- The book is closing: leave nothing of ours open over it.
function InkAway:onCloseDocument()
    if self.book then self.book:close() end
    -- (after the views over the book, which give the pen back as they close)
    if self.pen_highlight then self.pen_highlight:detach() end
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
