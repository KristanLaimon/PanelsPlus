--[[--
Panels+.

This plugin keeps KOReader's native panel detector and replaces the default
single-panel zoom viewer with a direction-aware sequence viewer.
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Actions = require("src.actions")
local Cache = require("src.cache")
local Menu = require("src.menu")
local NativePanelZoom = require("src.native_panel_zoom")
local Settings = require("src._settings")
local ViewerController = require("src.viewer_controller")

--- KOReader plugin that replaces native panel zoom with ordered panel reading.
---
--- The class owns plugin lifetime, settings state, and KOReader registration.
--- Feature-specific methods are mixed in from `src.*` modules to keep this
--- entry point small while preserving the method names KOReader events and
--- callbacks already call.
---
--- @class PanelsPlus : WidgetContainer
--- @field name string KOReader plugin id.
--- @field is_doc_only boolean Whether the plugin requires an opened document.
--- @field ui table KOReader reader UI object injected by WidgetContainer.
--- @field settings PPSettings Runtime plugin settings.
--- @field panel_cache table<string, PPPanel[]> Per-page panel cache.
--- @field panel_cache_order string[] LRU cache key order.
--- @field panel_cache_loading table<string, boolean> Scheduled prefetch guards.
local PanelsPlus = WidgetContainer:extend{
    name = "panels_plus",
    is_doc_only = true,
}

--- Copy module methods onto the plugin class without altering module tables.
---
--- @param class table KOReader class table.
--- @param module table<string, function> Method module.
local function include(class, module)
    for name, method in pairs(module) do
        class[name] = method
    end
end

include(PanelsPlus, Cache)
include(PanelsPlus, ViewerController)
include(PanelsPlus, Actions)
include(PanelsPlus, Menu)
include(PanelsPlus, NativePanelZoom)

--- Initialize settings, panel cache state, menu registration, actions, and hook.
function PanelsPlus:init()
    self.settings = Settings.load()
    self.panel_cache = {}
    self.panel_cache_order = {}
    self.panel_cache_loading = {}
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:patchNativePanelZoom()
    self:applyNativePanelSetting()
end

--- Persist current plugin settings to KOReader reader settings.
function PanelsPlus:saveSettings()
    Settings.save(self.settings)
end

--- Return whether panel focus is currently enabled.
---
--- @return boolean enabled `true` unless the stored setting is explicitly false.
function PanelsPlus:isEnabled()
    return self.settings.enabled ~= false
end

--- Enable or disable panel focus and synchronize KOReader's native setting.
---
--- @param enabled any Truthy value enables the feature.
function PanelsPlus:setEnabled(enabled)
    self.settings.enabled = enabled and true or false
    self:saveSettings()
    self:applyNativePanelSetting()
end

--- Set reading order mode and invalidate cached ordered panel lists.
---
--- @param mode PPReadingMode Requested mode; anything except `"comic"` maps to `"manga"`.
function PanelsPlus:setMode(mode)
    self.settings.mode = mode == "comic" and "comic" or "manga"
    self:clearPanelCache()
    self:saveSettings()
end

--- Set how tightly panel crops are rendered in the viewer.
---
--- @param crop_mode PPCropMode Requested crop mode; anything except `"loose"` maps to `"strict"`.
function PanelsPlus:setCropMode(crop_mode)
    self.settings.crop_mode = crop_mode == "loose" and "loose" or "strict"
    self:saveSettings()
end

--- Toggle whether swipe direction is inverted relative to reading order.
---
--- @param invert_swipe any Truthy value inverts left/right panel navigation.
function PanelsPlus:setInvertSwipe(invert_swipe)
    self.settings.invert_swipe = invert_swipe and true or false
    self:saveSettings()
end

--- KOReader save hook: persist current settings.
function PanelsPlus:onSaveSettings()
    self:saveSettings()
end

return PanelsPlus
