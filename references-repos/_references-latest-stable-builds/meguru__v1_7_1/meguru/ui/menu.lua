local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Association = require("meguru/association")
local Base = require("meguru/driver/base")
local Progress = require("meguru/progress")
local SeriesCover = require("meguru/seriescover")
local Marker = require("meguru/marker")
local Open = require("meguru/ui/open")
local Reader = require("meguru/ui/reader")
local SeriesState = require("meguru/seriesstate")
local Settings = require("meguru/settings")
local Updater = require("meguru/updater")

-- Idempotent, and `ui/open.lua` loads them too, so load order does not matter.
Base.loadDrivers()

local Menu = {}

-- Positioned by neighbour, not index: the list above it varies per device.
local function insertMeguruBefore(order, neighbour)
    local pos = 1
    for i, id in ipairs(order) do
        if id == neighbour then
            pos = i
            break
        end
    end
    table.insert(order, pos, "meguru")
end

-- These are the tables the builders require: one mutation serves every build.
-- nil, not a throw: an unsorted row beats a crash that takes the whole menu.
local function showUnderTools()
    local ok_fm, fm_order = pcall(require, "ui/elements/filemanager_menu_order")
    local ok_rd, rd_order = pcall(require, "ui/elements/reader_menu_order")
    if not (ok_fm and ok_rd
        and type(fm_order.tools) == "table" and type(rd_order.tools) == "table") then
        logger.warn("Meguru: no Tools menu in this build; the Meguru row is unsorted")
        return nil
    end
    insertMeguruBefore(fm_order.tools, "read_timer")
    insertMeguruBefore(rd_order.tools, "read_timer")
    return "tools"
end

-- The hint only appends to the page's end; the order-list edits above place it.
local TOOLS_HINT = showUnderTools()

-- Fresh tables per call: `menusorter` writes into the items it is given.
local function destinationRows()
    return {
        {
            text_func = function()
                -- The row must match where the open writes, not the stored key.
                return T(_("Main folder for .meguru streams: %1"), Marker.baseDir())
            end,
            -- keep_menu_open: the row is rebuilt, so the picked folder shows.
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                Open.chooseMarkerDir(function()
                    if touchmenu_instance
                        and type(touchmenu_instance.updateItems) == "function" then
                        touchmenu_instance:updateItems()
                    end
                end)
            end,
        },
        {
            text = _("Subfolder per server"),
            help_text = _("New streams go in a folder named after the OPDS server (e.g. \"kavita\"), then their series. Streams already saved are not moved."),
            keep_menu_open = true,
            -- Separator: the location rows above, Covers for folders below.
            separator = true,
            checked_func = function()
                return Settings.get("marker_server_dir")
            end,
            callback = function()
                Settings.toggle("marker_server_dir")
            end,
        },
    }
end

local function defaultReaderRow()
    return {
        text = _("Set Meguru as default reader for .cbz"),
        help_text = _("Every .cbz on this device opens in Meguru instead of KOReader's own reader, until you turn this off. A file you set individually with “Open with…” keeps its own choice."),
        keep_menu_open = true,
        -- Separator: the preference group ends; the one action row follows.
        separator = true,
        checked_func = Association.holds,
        callback = function()
            if Association.holds() then
                Association.release()
            else
                Association.claim()
            end
        end,
    }
end

-- Deferred and pcall'd: a throw must cost a dialog, not the whole menu.
local function updateRow()
    return {
        text = _("Check for updates"),
        keep_menu_open = true,
        callback = function()
            UIManager:nextTick(function()
                pcall(Updater.checkForUpdates)
            end)
        end,
    }
end

-- Rows come from `SeriesCover.KINDS`, so a new driver needs no change here.
local function coverRow()
    local rows = {}
    for _, kind in ipairs(SeriesCover.KINDS) do
        local key = SeriesCover.settingFor(kind)
        rows[#rows + 1] = {
            text = Base.kindLabel(kind),
            keep_menu_open = true,
            checked_func = function() return Settings.get(key) end,
            callback = function() Settings.toggle(key) end,
        }
    end
    return {
        text = _("Covers for folders"),
        help_text = _("Leaves a .cover.jpg in a series folder, once, for programs other than KOReader — a file browser, a backup, another reader. KOReader itself does not draw folder covers. Turning a server off stops new files and leaves the ones already written."),
        sub_item_table = rows,
    }
end

local function comicInfoRow()
    return {
        text = _("Read metadata from ComicInfo.xml"),
        help_text = _("A local .cbz is titled from the ComicInfo.xml inside it — its own title, author, series, language and summary — rather than from the file name. With this off, the file name is the only title."),
        keep_menu_open = true,
        checked_func = function() return Settings.get("comic_info") end,
        callback = function() Settings.toggle("comic_info") end,
    }
end

-- Rows come from `Progress.KINDS`, so a new driver needs no change here.
local function progressRows()
    local rows = {}
    -- Indexed, not ipairs: `for _, kind` would shadow the gettext `_`.
    for i = 1, #Progress.KINDS do
        local kind = Progress.KINDS[i]
        local key = Progress.settingFor(kind)
        rows[#rows + 1] = {
            text = T(_("Report reading progress to %1"), Base.kindLabel(kind)),
            help_text = _("Sends the page you have reached to the server as you read, so that server's own app keeps your place. Only a page you have actually turned to is sent: re-reading an earlier page never moves the server backwards, and a book the server has finished is never marked unread."),
            keep_menu_open = true,
            checked_func = function() return Settings.get(key) end,
            callback = function() Settings.toggle(key) end,
        }
    end
    return rows
end

-- Named for the unit the reader has: a local book's series is its folder, and a
-- stream's is the series the feed gave it. nil when a book has neither.
local function shareRow(plugin)
    local doc = plugin.ui and plugin.ui.document
    if not SeriesState.keyFor(doc) then
        return nil
    end
    local function shared()
        return SeriesState.sharedFor(plugin.ui and plugin.ui.document)
    end
    -- Two texts, not one with a word swapped: the folder is the whole rule for a
    -- local book, and the reason to turn this off is a different one there.
    local text, help_text
    if doc and doc.local_cbz then
        text = _("Remember settings for this folder")
        help_text = _("Settings you change are remembered for every .cbz in this folder.")
    else
        text = _("Remember settings for this series")
        help_text = _("Settings you change are remembered for the whole series.")
    end
    return {
        text = text,
        help_text = help_text,
        keep_menu_open = true,
        checked_func = shared,
        callback = function()
            SeriesState.setShared(plugin.ui and plugin.ui.document, not shared())
        end,
    }
end

-- Meguru's own switch, scoped to Meguru books: KOReader's rate is left alone.
local function fullRefreshRow()
    return {
        text = _("Full refresh on every page turn"),
        help_text = _("Flashes the screen on each page turn, so a page cannot leave its ghost on the next one. This covers Meguru books only — other books, and the menus, keep KOReader's own full refresh rate."),
        keep_menu_open = true,
        checked_func = function() return Settings.get("refresh_each_page") end,
        callback = function() Settings.toggle("refresh_each_page") end,
    }
end

local function settingsRow(rows)
    return {
        text = _("Settings"),
        sub_item_table = rows,
    }
end

-- The servers' group: what a server is told, and what is written for it.
-- `report_rows` is empty on the FileManager, which has no book to report from.
local function opdsRow(report_rows)
    local rows = {}
    for i = 1, #report_rows do
        rows[#rows + 1] = report_rows[i]
    end
    local locations = destinationRows()
    for i = 1, #locations do
        rows[#rows + 1] = locations[i]
    end
    rows[#rows + 1] = coverRow()

    return {
        text = _("OPDS"),
        help_text = _("The rows whose subject is a server rather than the book on screen: where a stream's files are saved on this device, and the cover files written beside the series folder for other programs."),
        -- Separator: the servers' group ends; the rows about this book follow.
        separator = true,
        sub_item_table = rows,
    }
end

function Menu.addFileManagerItems(plugin, menu_items)
    local settings = { opdsRow({}) }
    settings[#settings + 1] = fullRefreshRow()
    settings[#settings + 1] = comicInfoRow()
    settings[#settings + 1] = defaultReaderRow()
    settings[#settings + 1] = updateRow()

    menu_items.meguru = {
        text = _("Meguru"),
        sorting_hint = TOOLS_HINT,
        sub_item_table = { settingsRow(settings) },
    }
end

-- nil for a marker that names no series (a flat book) or a v1 marker.
local function seriesOf(ui)
    local doc = ui and ui.document
    if not (doc and type(doc.seriesContext) == "function") then
        return nil
    end
    local context = doc:seriesContext()
    if not (context and context.server_name) then
        return nil
    end
    return context
end

-- Drawn from the series, not a neighbour: a possible next is one walk away.
-- The `.cbz` list is built once per document: a new volume shows next open.
local function addNeighborRow(plugin, rows, which, separator)
    rows[#rows + 1] = {
        text = which == "next"
            and _("Open next in series")
            or _("Open previous in series"),
        separator = separator,
        callback = function()
            -- Deferred: the walk may replace this document and this handler.
            UIManager:nextTick(function()
                pcall(Reader.openNeighbor, plugin, which)
            end)
        end,
    }
end

function Menu.addReaderItems(plugin, menu_items)
    local ui = plugin.ui
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru") then
        return
    end

    -- One lookup: a book's series is either a feed's or a folder's, never both.
    local context = seriesOf(ui) or Reader.localSeriesOf(ui)

    local rows = {}
    if context then
        addNeighborRow(plugin, rows, "next")
        -- Separator: the series rows end here; Meguru's settings follow below.
        addNeighborRow(plugin, rows, "previous", true)
    end

    local settings = {}

    -- Gated on the series, not a neighbour: a known series always has a next.
    if context then
        settings[#settings + 1] = {
            text = _("Auto-open next in series"),
            help_text = _("Automatically opens the next volume or chapter when you finish this one."),
            keep_menu_open = true,
            checked_func = function()
                return Settings.get("auto_next_item")
            end,
            callback = function()
                local on = Settings.toggle("auto_next_item")
                UIManager:show(Notification:new{
                    text = on and _("auto-open on") or _("auto-open off"),
                    timeout = 2,
                })
            end,
        }
    end

    -- A behaviour row, so it joins the group above the separator.
    local share = shareRow(plugin)
    if share then
        settings[#settings + 1] = share
    end
    settings[#settings + 1] = fullRefreshRow()

    settings[#settings + 1] = {
        text = _("Hide status bar"),
        keep_menu_open = true,
        -- Separator ends the behaviour group; the servers' group follows.
        separator = true,
        checked_func = function()
            return Settings.get("hide_status_bar")
        end,
        callback = function()
            local on = Settings.toggle("hide_status_bar")
            -- Applies to the open book now, not only the next one.
            plugin:onMeguruHideStatusBar(on)
        end,
    }
    settings[#settings + 1] = opdsRow(progressRows())
    settings[#settings + 1] = comicInfoRow()
    settings[#settings + 1] = defaultReaderRow()
    settings[#settings + 1] = updateRow()

    rows[#rows + 1] = settingsRow(settings)

    menu_items.meguru = {
        text = _("Meguru"),
        sorting_hint = TOOLS_HINT,
        sub_item_table = rows,
    }
end

return Menu
