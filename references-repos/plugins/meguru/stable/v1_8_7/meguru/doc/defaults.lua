-- Seeds a book's per-book settings on first open; a stored value always wins.

local logger = require("logger")

local SeriesState = require("meguru/seriesstate")
local Settings = require("meguru/settings")

local Defaults = {}

-- Semantic fit -> zoom mode; the "content" modes crop through the document box.
local FIT_TO_ZOOM_MODE = {
    full   = "content",
    width  = "contentwidth",
    height = "contentheight",
}
Defaults.FIT_TO_ZOOM_MODE = FIT_TO_ZOOM_MODE

-- The one mapping of kopt_ row names to plugin preferences; a row's own domain.
Defaults.PREFERENCE_FOR = {
    trim_page             = "trim_page",
    panel_view            = "panel_view",
    rotate_wide_pages     = "rotate_wide",
    page_scroll           = "page_scroll",
    opdsbook_fit          = "fit",
    opdsbook_manga        = "manga_order",
    rotation_mode         = "rotation_mode",
    contrast              = "contrast",
    saturation            = "saturation",
    derainbow             = "derainbow",
    sw_dithering          = "dither",
    hw_dithering          = "hw_dither",
    spread                = "spread",
    spread_offset         = "spread_offset",
    spread_gutter         = "spread_gutter",
}
local PREFERENCE_FOR = Defaults.PREFERENCE_FOR

-- A series answer is stored under the preference's name, so the two agree.
local function preferenceOf(name)
    return PREFERENCE_FOR[name] or name
end

local function seriesValue(series, name)
    return series and series[preferenceOf(name)]
end

local function configurableOf(ui)
    return ui and ui.document and ui.document.configurable
end

-- The three views the row offers; "off" is KOReader's own switch, not a view.
local function panelViewIsView(value)
    return value == "crop" or value == "window" or value == "zoom"
end

-- The 16 rows a series answers as one. Read live, never from the sidecar: a row
-- is what the reader sees, whichever writer moved it, and ReaderConfig's save
-- order never enters into it. Values come back in the store's own domain.
local SERIES_READERS = {
    trim_page = function(ui)
        local c = configurableOf(ui)
        return c and c.trim_page
    end,
    rotate_wide_pages = function(ui)
        local c = configurableOf(ui)
        return c and c.rotate_wide_pages
    end,
    page_scroll = function(ui)
        local c = configurableOf(ui)
        return c and c.page_scroll
    end,
    -- Stock etches the live screen rotation into this row at every save, and
    -- this plugin rotates the screen itself for a wide page: a turn it asked
    -- for is not the reader's answer for the series.
    rotation_mode = function(ui)
        local doc = ui and ui.document
        local state = ui and ui._meguru_rotate_state
        if doc and doc.spread_rotated_by_plugin and state and state.active ~= nil then
            return nil
        end
        local c = configurableOf(ui)
        return c and c.rotation_mode
    end,
    contrast = function(ui)
        local c = configurableOf(ui)
        return c and c.contrast
    end,
    saturation = function(ui)
        local c = configurableOf(ui)
        return c and c.saturation
    end,
    derainbow = function(ui)
        local c = configurableOf(ui)
        return c and c.derainbow
    end,
    sw_dithering = function(ui)
        local c = configurableOf(ui)
        return c and c.sw_dithering
    end,
    hw_dithering = function(ui)
        local c = configurableOf(ui)
        return c and c.hw_dithering
    end,
    spread = function(ui)
        local c = configurableOf(ui)
        return c and c.spread
    end,
    spread_gutter = function(ui)
        local c = configurableOf(ui)
        return c and c.spread_gutter
    end,
    -- The answer, never the anchor: a page number means nothing in another book.
    spread_offset = function(ui)
        local doc = ui and ui.document
        if not (doc and type(doc._spreadAnchor) == "function") then
            return nil
        end
        return doc:_spreadAnchor() ~= 0 and 1 or 0
    end,
    -- The file's own switch says off, else the view it is showing.
    panel_view = function(ui)
        local hl = ui and ui.highlight
        if hl and hl.panel_zoom_enabled == false then
            return "off"
        end
        local c = configurableOf(ui)
        return c and c.panel_view
    end,
    -- Only a question while Panels+ is the rival; the plugin decides that.
    panel_owner = function(ui)
        if not (ui and ui._meguru_panels_plus_active) then
            return nil
        end
        local c = configurableOf(ui)
        return c and c.panel_owner
    end,
    -- A zoom mode the reader reached some other way (page, free) is no fit.
    opdsbook_fit = function(ui)
        local mode = ui and ui.zooming and ui.zooming.zoom_mode
        for fit, zoom_mode in pairs(FIT_TO_ZOOM_MODE) do
            if zoom_mode == mode then
                return fit
            end
        end
        return nil
    end,
    opdsbook_manga = function(ui)
        local view = ui and ui.view
        if not (type(view) == "table" and view.inverse_reading_order ~= nil) then
            return nil
        end
        return view.inverse_reading_order and true or false
    end,
}

-- Every row the reader can see, in the store's domain; a row with no answer is
-- absent rather than nil, so a diff never reads a value nobody holds.
local function seriesValues(ui)
    local values = {}
    for name, read in pairs(SERIES_READERS) do
        local ok, value = pcall(read, ui)
        if ok and value ~= nil then
            values[preferenceOf(name)] = value
        end
    end
    return values
end

-- The series' answer, else the book's own sidecar value, else the preference.
-- Read the sidecar, not configurable: that holds global kopt_* defaults.
-- Pass the value through untouched; 0 is valid and truthy, so never normalise.
local function seedRowValue(ds, name, series)
    local value = seriesValue(series, name)
    if value ~= nil then
        if ds then
            ds:saveSetting("kopt_" .. name, value)
        end
        return value
    end

    local current = ds and ds:readSetting("kopt_" .. name)
    if current ~= nil then
        return current
    end

    value = Settings.get(preferenceOf(name))
    if value == nil then
        return nil
    end
    if ds then
        ds:saveSetting("kopt_" .. name, value)
    end
    return value
end

-- Fixed layout always: a streamed page is a picture and must not reflow.
function Defaults.seedLayout(ui, configurable)
    configurable.text_wrap = 0
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_text_wrap", 0)
    end
end

-- Seeds the geometry rows; spread and offset are strings/numbers, not booleans.
function Defaults.seedGeometry(ui, configurable, series)
    local ds = ui.doc_settings
    for _, name in ipairs{
        "trim_page", "rotate_wide_pages", "spread", "spread_gutter",
    } do
        local value = seedRowValue(ds, name, series)
        if value ~= nil then
            configurable[name] = value
        end
    end
end

-- Three keys as one row: the view, KOReader's per-file on/off, and the owner.
function Defaults.seedPanelView(ui, configurable, series)
    local ds = ui.doc_settings
    local active = ui._meguru_panels_plus_active == true
    -- Only while Panels+ is the rival; the view is its own fallback either way.
    if active then
        local owner = seriesValue(series, "panel_owner")
        if owner ~= "panelsplus" and owner ~= "meguru" then
            owner = ds and ds:readSetting("kopt_panel_owner")
        end
        if owner ~= "panelsplus" and owner ~= "meguru" then
            owner = Settings.get("panel_owner")
        end
        if owner ~= "panelsplus" and owner ~= "meguru" then
            owner = "panelsplus"
        end
        configurable.panel_owner = owner
    else
        configurable.panel_owner = nil
    end

    local value = seriesValue(series, "panel_view")
    if value == nil then
        value = seedRowValue(ds, "panel_view", nil)
        if value ~= nil then
            configurable.panel_view = value
        end
        return
    end

    local hl = ui.highlight
    if value == "off" then
        -- The same three fields the row's off branch sets, so a turn-on later
        -- in this book has a view to come back to.
        if hl then
            hl.panel_zoom_enabled = false
            hl._meguru_panel_zoom_pinned = true
            hl._meguru_panel_zoom_answer = false
        end
        if ds then
            ds:saveSetting("panel_zoom_enabled", false)
        end
        local stored = ds and ds:readSetting("kopt_panel_view")
        if not panelViewIsView(stored) then
            stored = Settings.get("panel_view")
        end
        configurable.panel_view = panelViewIsView(stored) and stored or "window"
        return
    end

    if not panelViewIsView(value) then
        return
    end
    configurable.panel_view = value
    if ds then
        ds:saveSetting("kopt_panel_view", value)
    end
    -- Unpinned, so the save wrapper drops this file's own answer: the series'
    -- view is the one that stands.
    if hl then
        hl.panel_zoom_enabled = true
        hl._meguru_panel_zoom_pinned = false
    end
end

-- The store keeps the answer; "on" is anchored at the page the book opens on.
function Defaults.seedSpreadOffset(ui, configurable, series)
    local ds = ui.doc_settings
    local value = seriesValue(series, "spread_offset")
    if value == nil then
        value = seedRowValue(ds, "spread_offset", nil)
        if value ~= nil then
            configurable.spread_offset = value
        end
        return
    end

    local on = value == 1 or value == "1" or value == true
    local anchor = 0
    if on then
        anchor = (ui.paging and ui.paging.current_page) or 1
    end
    configurable.spread_offset = anchor
    if ds then
        ds:saveSetting("kopt_spread_offset", anchor)
    end
end

-- Overwrites the tone a global kopt_* may have put in, from the series.
function Defaults.seedTone(ui, configurable, series)
    for _, name in ipairs{ "contrast", "saturation" } do
        local value = seedRowValue(ui.doc_settings, name, series)
        if value ~= nil then
            configurable[name] = value
        end
    end
end

-- Always has a preference and no stock key, so there is no global to displace.
function Defaults.seedDerainbow(ui, configurable, series)
    local value = seedRowValue(ui.doc_settings, "derainbow", series)
    if value ~= nil then
        configurable.derainbow = value
    end
end

-- The row's gate as well: an e-ink panel whose controller dithers is the one
-- stock offers the hardware row on, and the one this plugin asks to dither.
function Defaults.panelDithers()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" then
        return false
    end
    if type(Device.canHWDither) ~= "function"
        or type(Device.hasEinkScreen) ~= "function" then
        return false
    end
    return Device:canHWDither() and Device:hasEinkScreen() and true or false
end

-- Both dither rows, one rule: series, then the book, then the preference.
local function seedDitherRow(ui, configurable, series, name)
    local ds = ui.doc_settings
    local doc = ui.document
    local value = seriesValue(series, name)
    if value == nil then
        value = ds and ds:readSetting("kopt_" .. name)
    end
    if value == nil then
        value = Settings.get(preferenceOf(name))
    end
    if value ~= nil and ds then
        ds:saveSetting("kopt_" .. name, value)
    end
    if value ~= nil then
        -- Normalise by comparison, never "and 1 or 0", which reads 0 as "on".
        value = (value == 1 or value == true) and 1 or 0
    end
    if value == nil then
        -- Nothing chosen: ask a panel that dithers itself, else show what the
        -- page is drawn with, not a stock 0.
        local asked = name == "hw_dithering" and Defaults.panelDithers()
        local on = (doc and doc[name]) and true or asked
        configurable[name] = on and 1 or 0
        if on and doc then
            doc[name] = true
        end
        return
    end
    -- Row domain is 0/1, the document field boolean; converted here only.
    configurable[name] = value
    if doc then
        doc[name] = value == 1
    end
end

-- Three answers each; the software one's device answer is forced in document.lua.
-- The hardware one is the row's own default where the panel dithers itself.
function Defaults.seedDither(ui, configurable, series)
    seedDitherRow(ui, configurable, series, "sw_dithering")
    seedDitherRow(ui, configurable, series, "hw_dithering")
end

-- Page view, not stock continuous scroll; the live view must be switched too.
function Defaults.seedScrollMode(ui, configurable, series)
    -- Already 0 or 1; 0 is truthy in Lua, so pass it through unchanged.
    local value = seedRowValue(ui.doc_settings, "page_scroll", series)
    configurable.page_scroll = value

    local view = ui.view
    if value == 0 and view and view.page_scroll
        and type(view.onSetScrollMode) == "function" then
        view:onSetScrollMode(false)
    end
end

-- Only for a reader who chose one: unset keeps whatever KOReader decided.
function Defaults.seedRotation(ui, configurable, series)
    local ds = ui.doc_settings
    local mode = seriesValue(series, "rotation_mode")
    if mode == nil then
        if ds and ds:readSetting("kopt_rotation_mode") ~= nil then
            return
        end
        mode = Settings.get("rotation_mode")
    end
    if mode == nil then
        return
    end
    configurable.rotation_mode = mode
    if ds then
        ds:saveSetting("kopt_rotation_mode", mode)
    end

    local view = ui.view
    local locked = false
    local g = rawget(_G, "G_reader_settings")
    if g and type(g.isTrue) == "function" then
        locked = g:isTrue("lock_rotation")
    end
    if not locked and view and type(view.onSetRotationMode) == "function" then
        view:onSetRotationMode(mode)
    end
end

-- Forced every open: ReaderConfig may have loaded an old stored "off".
function Defaults.seedNightMode(ui, configurable)
    if not Settings.get("night_mode") then
        return
    end
    configurable.nightmode_document = 1
    local ds = ui.doc_settings
    if ds and ds:readSetting("kopt_nightmode_document") ~= 1 then
        ds:saveSetting("kopt_nightmode_document", 1)
    end
end

-- The series' fit first, then the book's own zoom, then the plugin-wide one.
function Defaults.seedFit(ui, series)
    local zooming = ui.zooming
    if not (zooming and type(zooming.setZoomMode) == "function") then
        return
    end
    local ds = ui.doc_settings
    local fit = seriesValue(series, "opdsbook_fit")
    local desired
    if fit ~= nil then
        desired = FIT_TO_ZOOM_MODE[fit]
    else
        desired = ds and ds:readSetting("zoom_mode")
        if desired == nil then
            desired = FIT_TO_ZOOM_MODE[Settings.get("fit")]
        end
    end
    if desired and zooming.zoom_mode ~= desired then
        zooming:setZoomMode(desired)
        if ds then
            ds:saveSetting("zoom_mode", desired)
        end
    end
end

-- Applies every seed; a no-op for any non-Meguru document.
function Defaults.apply(ui, doc)
    if not (ui and doc and doc.provider == "meguru" and doc.configurable) then
        return false
    end
    local configurable = doc.configurable
    -- Read once: a series answer comes before anything the book has of its own.
    local key = SeriesState.keyFor(doc)
    local series = key and SeriesState.answersFor(doc) or nil
    Defaults.seedLayout(ui, configurable)
    Defaults.seedPanelView(ui, configurable, series)
    Defaults.seedGeometry(ui, configurable, series)
    Defaults.seedSpreadOffset(ui, configurable, series)
    Defaults.seedTone(ui, configurable, series)
    Defaults.seedDerainbow(ui, configurable, series)
    Defaults.seedDither(ui, configurable, series)
    Defaults.seedScrollMode(ui, configurable, series)
    Defaults.seedRotation(ui, configurable, series)
    Defaults.seedNightMode(ui, configurable)
    Defaults.seedFit(ui, series)

    -- The reader derived the page's box before these seeds; re-derive it now.
    if type(ui.handleEvent) == "function" then
        local Event = require("ui/event")
        ui:handleEvent(Event:new("ReZoom"))
    end

    logger.dbg("Meguru: seeded per-book defaults for", doc.file,
        series and ("from series " .. key) or "with no series answers")
    return true
end

-- What the rows say as the book opens: a save compares against this, so only a
-- row the reader actually moved becomes the series' answer.
function Defaults.beginSeries(ui, doc)
    if not (ui and doc and doc.provider == "meguru") then
        return false
    end
    local key = SeriesState.keyFor(doc)
    ui._meguru_series_key = key
    ui._meguru_series_seed = key and seriesValues(ui) or nil
    return true
end

-- Publishes the rows this session moved; returns how many the series learned.
function Defaults.publishSeries(ui)
    local key = ui and ui._meguru_series_key
    local seed = ui and ui._meguru_series_seed
    if not (key and seed) then
        return 0
    end
    local current = seriesValues(ui)
    local changes = {}
    local count = 0
    for name, value in pairs(current) do
        -- tostring: a value read back as "1" is the 1 that was written.
        if tostring(value) ~= tostring(seed[name]) then
            changes[name] = value
            count = count + 1
        end
    end
    -- Re-baselined either way: a second save publishes nothing again.
    ui._meguru_series_seed = current
    if count > 0 then
        SeriesState.learn(ui.document, changes)
    end
    return count
end

-- The long-press names a preference; a series already answering that row would
-- otherwise mask the new default in every book of the series.
function Defaults.learnSeries(ui, name, value)
    return SeriesState.learn(ui and ui.document, { [name] = value })
end

return Defaults
