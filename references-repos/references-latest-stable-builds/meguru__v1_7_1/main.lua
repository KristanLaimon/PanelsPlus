-- SPDX-License-Identifier: AGPL-3.0-or-later

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local _ = require("gettext")

local Association = require("meguru/association")
local Bookshelf = require("meguru/bookshelf")
local Catalog = require("meguru/ui/catalog")
local Defaults = require("meguru/doc/defaults")
local Hook = require("meguru/hook")
local Icons = require("meguru/icons")
local Image = require("meguru/doc/image")
local MeguruDocument = require("meguru/doc/document")
local Menu = require("meguru/ui/menu")
local Open = require("meguru/ui/open")
local Paths = require("meguru/paths")
local Reader = require("meguru/ui/reader")
local Updater = require("meguru/updater")

-- addProvider only appends; this module can be required twice, so guard it.
local provider_registered = false

local Meguru = WidgetContainer:extend{
    -- `name` and `path` are assigned by pluginloader from the directory name.
    is_doc_only = false,

    -- A marker's own MIME type: not an archive, and nothing else claims it.
    mimetype = "application/x-koreader-meguru-stream",
}

function Meguru:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- pluginloader assigns path: the plugin dir's only reliable source.
    Paths.setPluginDir(self.path)

    -- version comes from _meta.lua via pluginloader and cannot be derived here.
    -- init runs per instance, so both calls below are idempotent by design.
    Updater.setInstalledVersion(self.version)
    Updater.checkAtStartup()

    -- Wrap the OPDS browser; failure disables the button, not the plugin.
    Hook.install()
    Open.setFallbackHost(self)
    -- File dialogs are the file manager's: the reader's first init has none.
    if not (self.ui and self.ui.document) then
        Catalog.installFileDialogRow(self.ui)
        -- Bookshelf's catalog window is the file manager's too, and it is the
        -- ui the marker is handed back to.
        Bookshelf.install(self)
    end
    self:registerProvider()

    -- Class-level, once per process: in place before any book's dialog builds.
    Icons.install()

    -- Before any document opens, and in the parent: see Image.rememberScreen.
    Image.rememberScreen()

    -- Both live on their classes, with no instance to hang them on: once per process.
    Reader.installStatusBarHook()
    Reader.installZoomPageHook()

    -- Reader plumbing only where this instance has a book of ours open.
    Reader.install(self)
end

-- Marker claimed outright; .cbz at weight 1, leaving MuPDF the default.
-- The association claim looks the provider up by key, so register it first.
function Meguru:registerProvider()
    if provider_registered then
        return
    end
    provider_registered = true
    local DocumentRegistry = require("document/documentregistry")
    DocumentRegistry:addProvider(Paths.MARKER_EXT, self.mimetype, MeguruDocument, 1)
    DocumentRegistry:addProvider("cbz", "application/vnd.comicbook+zip",
        MeguruDocument, 1)
    logger.info("Meguru: registered ." .. Paths.MARKER_EXT
        .. " and .cbz document providers")
    Association.claimOnce()
end

-- Seed per-book defaults here: stock defaults are wrong for a fixed layout.
function Meguru:onReadSettings(_config)
    local document = self.ui and self.ui.document
    -- Seeded here: the panel defaults need to know whether Panels+ owns the press.
    if self.ui then
        self.ui._meguru_panels_plus_active = Reader.panelsPlusActive(self.ui)
    end
    local ok, err = pcall(Defaults.apply, self.ui, document)
    if not ok then
        -- A stock-default book still reads, just wrong: never cost the open.
        logger.warn("Meguru: could not seed per-book defaults:", err)
    end
    -- After the seeds: the baseline is what the series answered, not the book.
    local ok_series, err_series = pcall(Defaults.beginSeries, self.ui, document)
    if not ok_series then
        logger.warn("Meguru: could not read the series' settings:", err_series)
    end
end

-- Panels+ re-asserts the live field at ReadSettings; apply the file's answer and owner.
function Meguru:onReaderReady()
    Reader.applyPanelZoomAnswer(self)
end

-- Same class on both surfaces; presence of a document picks the menu.
function Meguru:addToMainMenu(menu_items)
    if self.ui and self.ui.document then
        Menu.addReaderItems(self, menu_items)
    else
        Menu.addFileManagerItems(self, menu_items)
    end
end

return Meguru
