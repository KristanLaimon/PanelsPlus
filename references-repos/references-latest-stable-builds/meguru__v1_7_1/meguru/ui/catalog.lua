-- The OPDS window: closing it, and opening it on a book's own series.
-- The other direction of "Meguru this series", which opens a book from there.

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("meguru/driver/base")
local Marker = require("meguru/marker")
local Paths = require("meguru/paths")
local Sources = require("meguru/sources")

Base.loadDrivers()

local Catalog = {}

-- One row per feature: a repeated registration of the same id is a no-op.
local ROW_ID = "meguru_show_in_opds"

-- Every widget whose long-press dialog carries the plugin rows.
-- The reader draws History and Collections through these same classes.
local FILE_DIALOG_WIDGETS = {
    "apps/filemanager/filemanager",
    "apps/filemanager/filemanagerhistory",
    "apps/filemanager/filemanagercollection",
    "apps/filemanager/filemanagerfilesearcher",
}

-- Close the OPDS window a book is being opened from.
-- Left open it stays under the reader and shows again as the reader exits.
-- host is the OPDS plugin on this path; a file-manager host has no browser.
function Catalog.closeBrowser(host)
    local browser = host and host.opds_browser
    if type(browser) ~= "table" then
        return
    end
    -- The plugin's own close, which also drops any open download list.
    local close = browser.close_callback
    if type(close) ~= "function" then
        UIManager:close(browser)
        return
    end
    local ok, err = pcall(close)
    if not ok then
        logger.warn("Meguru: could not close the OPDS browser:", err)
        UIManager:close(browser)
    end
end

-- The widget classes, required lazily: loading the file manager is not ours.
local function fileDialogWidgets()
    local widgets = {}
    for _, name in ipairs(FILE_DIALOG_WIDGETS) do
        local ok, widget = pcall(require, name)
        if ok and type(widget) == "table" then
            widgets[#widgets + 1] = widget
        end
    end
    return widgets
end

-- The open long-press dialog and its owner, or nil.
-- Asked on the tap, and only a shown dialog counts: the field outlives it.
local function fileDialogOwner()
    for _, widget in ipairs(fileDialogWidgets()) do
        -- pcall'd: a class with no instance of its own raises the lookup.
        local ok, menu = pcall(widget.getMenuInstance)
        if ok and type(menu) == "table"
            and UIManager:isWidgetShown(menu.file_dialog) then
            return menu, menu.ui
        end
    end
    return nil, nil
end

-- The address to open, and whether it is the series' own feed.
-- Falls back to the server root: a flat marker names no series.
local function seriesTarget(desc, conn)
    local kind = desc.server_kind or Base.kindFromTemplate(desc.template)
    local driver = kind and Base.forKind(kind)
    if driver and desc.series_remote_id then
        -- lang travels: Suwayomi picks the translation by it.
        local url = driver.catalogURL(conn.url, desc.series_remote_id,
            { lang = desc.lang })
        if type(url) == "string" and url ~= "" then
            return url, true
        end
    end
    return conn.url, false
end

-- Show a book in the OPDS browser, on its series' feed where there is one.
-- subject is a marker path or a marker table; nothing is written.
function Catalog.showIn(ui, subject)
    local opds = ui and ui.opds
    -- Truthiness, not type(): pluginloader wraps every "on*" handler in a
    -- callable sandbox table, so a method is never a function here.
    if type(opds) ~= "table" or not opds.onShowOPDSCatalog then
        logger.warn("Meguru: the OPDS plugin is not loaded, so no catalog to show")
        UIManager:show(InfoMessage:new{
            text = _("the OPDS catalog is not available."),
        })
        return false
    end

    local path = type(subject) == "string" and subject or nil
    local desc = path and Marker.load(path) or subject
    if type(desc) ~= "table" then
        logger.warn("Meguru: no marker to show a catalog for:", tostring(subject))
        UIManager:show(InfoMessage:new{
            text = T(_("could not read the book file.\n%1"), tostring(subject)),
        })
        return false
    end

    local conn = Sources.connection(desc.server_name)
    if not conn or type(conn.url) ~= "string" or conn.url == "" then
        -- The wording the series row refuses with, so the two cannot drift.
        UIManager:show(InfoMessage:new{
            text = T(_("no catalog entry with this title in settings/opds.lua: %1"),
                tostring(desc.server_name)),
        })
        return false
    end

    -- Session memory first, so a password typed this run is the one used.
    local username, password = Sources.credentials(desc.server_name, path)
    local url, is_series = seriesTarget(desc, conn)

    NetworkMgr:runWhenConnected(function()
        -- A second browser would leave the first one on the stack unowned.
        Catalog.closeBrowser(opds)
        opds:onShowOPDSCatalog()
        local browser = opds.opds_browser
        if type(browser) ~= "table" then
            logger.warn("Meguru: the OPDS browser did not open")
            return
        end
        -- Every fetch is authenticated with these, and our own feed
        -- retention keys `last_feed` on the title.
        browser.root_catalog_title = conn.name
        browser.root_catalog_username = username
        browser.root_catalog_password = password
        -- A fetched OPDS 1 feed sets no title, and the plus button needs one.
        browser.catalog_title = desc.series_name or conn.name
        browser:updateCatalog(url)
        -- Never the URL: Kavita's key is a path segment of it.
        logger.info("Meguru: showed", tostring(desc.series_name or desc.title),
            "in the OPDS catalog of", tostring(conn.name),
            is_series and "(the series feed)" or "(the server root)")
    end)
    return true
end

-- The file dialog's row: markers only, and nothing else is ours.
local function fileDialogRow(fallback_ui)
    local suffix = "." .. Paths.MARKER_EXT
    return function(file, is_file)
        if not is_file or type(file) ~= "string" then
            return nil
        end
        if file:sub(-#suffix) ~= suffix then
            return nil
        end
        return {
            {
                text = _("Show in OPDS"),
                callback = function()
                    -- Closed first: the browser opens over it.
                    local menu, owner = fileDialogOwner()
                    if menu then
                        UIManager:close(menu.file_dialog)
                    end
                    Catalog.showIn(owner or fallback_ui, file)
                end,
            },
        }
    end
end

-- Add the row to every file dialog the file manager and the reader draw.
-- host is only a fallback: a dialog's own owner is preferred at tap time.
function Catalog.installFileDialogRow(host)
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or type(FileManager) ~= "table"
        or type(FileManager.addFileDialogButtons) ~= "function" then
        logger.info("Meguru: no file dialog to add the OPDS row to")
        return false
    end

    local row = fileDialogRow(host)
    for _, widget in ipairs(fileDialogWidgets()) do
        -- Dot call: the registry is on the widget class, not an instance.
        FileManager.addFileDialogButtons(widget, ROW_ID, row)
    end
    logger.dbg("Meguru: added the \"Show in OPDS\" row to the file dialogs")
    return true
end

return Catalog
