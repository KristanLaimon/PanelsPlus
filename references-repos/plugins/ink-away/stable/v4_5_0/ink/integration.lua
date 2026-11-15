--[[
The integration API for viewer plugins (PanelsPlus first): a plugin that shows
the book's pages its own way can give Ink Away a document surface (where its
pages are on the screen, see docs/INTEGRATION.md), and Ink Away's annotation
mode then draws, saves and paints the book's ink on that viewer. Experimental:
it may change before Ink Away 5.0, so a consumer checks the version numbers.

One instance per open book (main.lua makes it, Book keeps it). It registers the
widgets that provide a surface, picks the topmost visible one when annotation
mode opens, tells observers when annotation mode opens and closes, and keeps a
consumer's failures from reaching Ink Away (they are logged and handed to the
consumer's own error callback). No consumer is named here.

Based on Kristan Laimon's design in PR #80.
]]
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Delegate = require("ink/delegate")

---@class IntegrationAPI
---@field private _providers table<table, InkRenderingProvider>
---@field private _installations table<table, InkInstallation>
---@field private _events table<InkAnnotationEventName, InkDelegate<InkAnnotationEvent>>
---@field private _errors table<InkSurface, fun(err: unknown)>
---@field private _disposed boolean?
local IntegrationAPI = {}
IntegrationAPI.__index = IntegrationAPI

---@param surface unknown
---@param document table
---@return boolean
local function valid(surface, document)
    if type(surface) ~= "table" or surface.version ~= 1 or surface.document ~= document then return false end
    for _, method in ipairs({ "pages", "key", "toPage", "toScreen", "snapshot", "repaint", "clip" }) do
        if type(surface[method]) ~= "function" then return false end
    end
    for _, method in ipairs({ "begin", "finish", "turn", "setViewport", "readingDirection", "mapPath", "isAffine", "regions" }) do
        if surface[method] ~= nil and type(surface[method]) ~= "function" then return false end
    end
    return true
end

---@return IntegrationAPI
function IntegrationAPI.new()
    local self = setmetatable({ _providers = {}, _installations = {},
        _errors = setmetatable({}, { __mode = "k" }) }, IntegrationAPI)
    local function report(err) self:report(nil, err) end
    self._events = { opened = Delegate.new(report), closed = Delegate.new(report) }
    return self
end

---@param surface InkSurface?
---@param err unknown
function IntegrationAPI:report(surface, err)
    logger.warn("Ink Away: extension failed:", err)
    local callback = surface and self._errors[surface]
    if callback then
        local ok, callback_err = pcall(callback, err)
        if not ok then logger.warn("Ink Away: extension error callback failed:", callback_err) end
    end
end

-- A widget owns its provider; registration never changes an active session.
--- Register an owning widget; removal affects future sessions only.
---@param widget table
---@param factory InkSurfaceFactory
---@param on_error InkErrorHandler?
---@return InkUnsubscribe
function IntegrationAPI:registerRenderingView(widget, factory, on_error)
    assert(not self._disposed, "reader integration has closed")
    assert(type(widget) == "table", "a rendering view needs its owning widget")
    assert(type(factory) == "function", "a rendering view needs a surface factory")
    assert(on_error == nil or type(on_error) == "function", "on_error must be a function")
    assert(not self._providers[widget], "widget already has a rendering view")
    local entry = { factory = factory, on_error = on_error }
    self._providers[widget] = entry
    return function()
        if self._providers[widget] == entry then self._providers[widget] = nil end
    end
end

-- One consumer hookup: provider plus optional surface-scoped observers.
---@param ink InkIntegrationHost
---@param widget table
---@param surface InkSurface
---@param options InkIntegrationOptions?
---@return fun(release_surface: boolean?) cleanup
function IntegrationAPI:install(ink, widget, surface, options)
    assert(not self._disposed, "reader integration has closed")
    assert(type(widget) == "table", "an integration needs its owning widget")
    assert(valid(surface, ink.ui.document), "invalid annotation surface or different document")
    if options == nil then options = {} end
    assert(type(options) == "table", "integration options must be a table")
    for _, name in ipairs({ "on_open", "on_close", "on_error" }) do
        assert(options[name] == nil or type(options[name]) == "function", name .. " must be a function")
    end
    local existing = self._installations[widget]
    if existing then
        assert(not existing.closed, "widget integration is being disposed")
        assert(existing.surface == surface, "widget already has a different installed surface")
        return existing.cleanup
    end
    local on_open, on_close, on_error = options.on_open, options.on_close, options.on_error
    local unregister = self:registerRenderingView(widget, function() return surface end, on_error)
    local stop_open = on_open and self:onAnnotationOpened(function(event)
        if event.surface == surface then on_open(event) end
    end)
    local stop_close = on_close and self:onAnnotationClosed(function(event)
        if event.surface == surface then on_close(event) end
    end)
    local entry = { surface = surface }
    self._installations[widget] = entry
    entry.cleanup = function(release_surface)
        if entry.closed then return end
        entry.closed = true
        -- Keep close observers connected until release finishes.
        local ok, err = true, nil
        if release_surface ~= false then ok, err = pcall(ink.releaseDocumentSurface, ink, surface) end
        unregister()
        if stop_open then stop_open() end
        if stop_close then stop_close() end
        if self._installations[widget] == entry then self._installations[widget] = nil end
        if not ok then self:report(surface, err) end
    end
    return entry.cleanup
end

-- Publish only once the reader and integration machinery are usable. The
-- registry key in ReaderUI may not have been assigned while plugin init runs.
--- Publish readiness and drain pending consumer configuration in either load order.
---@param ui table
---@param ink InkIntegrationHost
function IntegrationAPI:publish(ui, ink)
    assert(not self._disposed, "reader integration has closed")
    ui.inkAwayIntegrationAPI = ink
    local pending = ui.inkAwayPendingIntegrations
    if type(pending) ~= "table" then return end
    local snapshot = {}
    for consumer, requested in pairs(pending) do
        snapshot[#snapshot + 1] = { consumer = consumer, requested = requested }
    end
    for _, request in ipairs(snapshot) do
        if self._disposed or ui.inkAwayIntegrationAPI ~= ink then break end
        local consumer = request.consumer
        if pending[consumer] == request.requested then
            pending[consumer] = nil
            if request.requested == true and type(consumer) == "table"
                    and type(consumer.configureInkAway) == "function" then
                local previous = self._installations[consumer]
                local ok, err = pcall(consumer.configureInkAway, consumer, ink)
                if not ok then
                    local installed = self._installations[consumer]
                    if installed and installed ~= previous then installed.cleanup(false) end
                    self:report(nil, err)
                end
            else self:report(nil, "pending consumer needs configureInkAway(ink) and a true queue entry") end
        end
    end
    if ui.inkAwayPendingIntegrations == pending and next(pending) == nil then
        ui.inkAwayPendingIntegrations = nil
    end
end

---@param ui table
---@param ink InkIntegrationHost
function IntegrationAPI:unpublish(ui, ink)
    if ui.inkAwayIntegrationAPI == ink then
        ui.inkAwayIntegrationAPI = nil
        ui.inkAwayPendingIntegrations = nil
    end
end

--- Disconnect providers and observers after reader/editor shutdown; idempotent.
function IntegrationAPI:dispose()
    if self._disposed then return end
    self._disposed = true
    local installed = {}
    for _, entry in pairs(self._installations) do installed[#installed + 1] = entry end
    for _, entry in ipairs(installed) do entry.cleanup(false) end
    self._providers, self._installations = {}, {}
    for _, event in pairs(self._events) do event:dispose() end
    self._errors = setmetatable({}, { __mode = "k" })
end

---@param event InkAnnotationEventName
---@param callback fun(event: InkAnnotationEvent)
---@return InkUnsubscribe
function IntegrationAPI:subscribe(event, callback)
    assert(not self._disposed, "reader integration has closed")
    assert(self._events[event], "unknown annotation event")
    return self._events[event]:subscribe(callback)
end

---@param callback fun(event: InkAnnotationEvent)
---@return InkUnsubscribe
function IntegrationAPI:onAnnotationOpened(callback) return self:subscribe("opened", callback) end
---@param callback fun(event: InkAnnotationEvent)
---@return InkUnsubscribe
function IntegrationAPI:onAnnotationClosed(callback) return self:subscribe("closed", callback) end

---@param event InkAnnotationEventName
---@param document table
---@param surface InkSurface?
function IntegrationAPI:emit(event, document, surface)
    self._events[event]:emit(function() return { document = document, surface = surface } end)
end

-- Preserve the provider's error handler when asynchronous navigation replaces
-- its surface. Invalid handoffs keep the current document mapping.
---@param previous InkSurface?
---@param surface InkSurface?
---@param document table
---@return InkSurface?
function IntegrationAPI:handoff(previous, surface, document)
    if surface ~= nil and not valid(surface, document) then
        self:report(previous, "invalid annotation surface handoff")
        return previous
    end
    if surface and previous then self._errors[surface] = self._errors[previous] end
    return surface
end

--- Select the top eligible visible provider, stopping at unrelated fullscreen UI.
---@param ui table
---@return InkSurface?
function IntegrationAPI:select(ui)
    for i = #(UIManager._window_stack or {}), 1, -1 do
        local widget = UIManager._window_stack[i].widget
        local entry = widget and self._providers[widget]
        local factory = entry and entry.factory
        if type(factory) == "function" then
            local ok, result = pcall(factory, widget, { document = ui.document })
            ---@type unknown
            local failure = not ok and result or nil
            if ok and result ~= nil and not valid(result, ui.document) then
                ok, failure = false, "invalid annotation surface or different document"
            end
            if ok and result then
                ---@cast result InkSurface Validated above, including document identity.
                self._errors[result] = entry and entry.on_error or nil
                return result
            end
            if not ok then
                self:report(nil, failure)
                if entry and entry.on_error then
                    local reported, err = pcall(entry.on_error, failure)
                    if not reported then self:report(nil, err) end
                end
                return nil
            end
        end
        if widget and widget.covers_fullscreen and not widget.toast and not widget.invisible then return nil end
    end
end

return IntegrationAPI
