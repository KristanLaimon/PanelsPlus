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
local Timing = require("src._timing")
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
--- @field panel_prefetch_actions table<string, function> Scheduled prefetch jobs, by cache key.
--- @field panel_prerender_action function|nil Scheduled next-panel warm-up, if any.
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
    Timing.enabled = self.settings.debug_mode == true
    self.panel_cache = {}
    self.panel_cache_order = {}
    self.panel_prefetch_actions = {}
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:patchNativePanelZoom()
    self:applyNativePanelSetting()
end

--- Persist current plugin settings to KOReader reader settings.
function PanelsPlus:saveSettings()
    Settings.save(self.settings)
end

--- Return whether Panels+ panel focusing is currently enabled.
---
--- @return boolean enabled `true` unless the stored setting is explicitly false.
function PanelsPlus:isEnabled()
    return self.settings.enabled ~= false
end

--- Enable or disable Panels+ panel focusing and synchronize KOReader's native setting.
---
--- @param enabled any Truthy value enables Panels+ focusing; false uses native panel zoom.
function PanelsPlus:setEnabled(enabled)
    self.settings.enabled = enabled and true or false
    Timing.log("enabled -> " .. tostring(self.settings.enabled))
    self:saveSettings()
    self:applyNativePanelSetting()
end

--- Set reading order mode.
---
--- The panel cache is keyed by mode (see `Cache:getPanelCacheKey`), so
--- switching modes does not need to invalidate anything: pages already
--- detected under the other mode simply stay cached under their own key.
---
--- @param mode PPReadingMode Requested mode; anything except `"comic"` maps to `"manga"`.
function PanelsPlus:setMode(mode)
    self.settings.mode = mode == "comic" and "comic" or "manga"
    Timing.log("mode -> " .. self.settings.mode)
    self:saveSettings()
end

--- Set how tightly panel crops are rendered in the viewer.
---
--- @param crop_mode PPCropMode Requested crop mode; anything except `"loose"`/`"margin"` maps to `"strict"`.
function PanelsPlus:setCropMode(crop_mode)
    if crop_mode == "loose" or crop_mode == "margin" then
        self.settings.crop_mode = crop_mode
    else
        self.settings.crop_mode = "strict"
    end
    self:saveSettings()
end

--- Set the zoom-out amount the "With margin" crop mode applies.
---
--- @param ratio number Requested margin ratio; clamped to [0, 0.4].
function PanelsPlus:setMarginRatio(ratio)
    ratio = tonumber(ratio) or Settings.defaults.panel_margin_ratio
    self.settings.panel_margin_ratio = math.max(0, math.min(0.4, ratio))
    self:saveSettings()
end

--- Set how much page area outside each panel "Loose crop" reveals.
---
--- @param ratio number Requested bleed ratio; clamped to [0, 0.4].
function PanelsPlus:setBleedRatio(ratio)
    ratio = tonumber(ratio) or Settings.defaults.panel_bleed_ratio
    self.settings.panel_bleed_ratio = math.max(0, math.min(0.4, ratio))
    self:saveSettings()
end

--- Toggle whether swipe direction is inverted relative to reading order.
---
--- @param invert_swipe any Truthy value inverts left/right panel navigation.
function PanelsPlus:setInvertSwipe(invert_swipe)
    self.settings.invert_swipe = invert_swipe and true or false
    self:saveSettings()
end

--- Set whether the panel viewer bottom progress bar is visible.
---
--- @param visible any Truthy value shows the progress bar.
function PanelsPlus:setProgressBarVisible(visible)
    self.settings.progress_bar_visible = visible and true or false
    self:saveSettings()
end

--- Set whether panel-to-panel navigation animates a camera pan or swaps instantly.
---
--- @param mode PPNavTransitionMode Requested mode; anything except "smooth" maps to "classic".
function PanelsPlus:setNavTransitionMode(mode)
    self.settings.nav_transition_mode = mode == "smooth" and "smooth" or "classic"
    Timing.log("nav_transition_mode -> " .. self.settings.nav_transition_mode)
    self:saveSettings()
end

--- Set how long the smooth-navigation camera pan takes.
---
--- @param seconds number Requested duration; clamped to [0.15, 0.9].
function PanelsPlus:setNavTransitionDuration(seconds)
    seconds = tonumber(seconds) or Settings.defaults.nav_transition_duration
    self.settings.nav_transition_duration = math.max(0.15, math.min(0.9, seconds))
    self:saveSettings()
end

--- Choose which detector finds panels.
---
--- The panel cache is keyed by detector (see `Cache:getPanelCacheKey`), so
--- switching detectors does not need to invalidate anything: results from
--- the other detector simply stay cached under their own key, and cycling
--- back to a detector already used on this page returns instantly instead
--- of paying for another detection pass.
---
--- @param detector PPDetector Requested detector; anything unknown maps to `"auto"`.
function PanelsPlus:setDetector(detector)
    self.settings.detector = (detector == "fast" or detector == "exact") and detector or "auto"
    Timing.log("detector -> " .. self.settings.detector .. string.format(
        " (cache: %d pages)", #(self.panel_cache_order or {})
    ))
    self:saveSettings()
end

--- Enable or disable warming the next panel's render while idle.
---
--- @param enabled any Truthy value pre-renders the next panel.
function PanelsPlus:setPanelPrerender(enabled)
    self.settings.panel_prerender = enabled and true or false
    if not self.settings.panel_prerender then
        self:cancelPanelPrerender()
    end
    self:saveSettings()
end

--- Enable or disable debugging logs for the panel pipeline.
---
--- @param enabled any Truthy value writes debugging logs to the KOReader log.
function PanelsPlus:setDebugMode(enabled)
    self.settings.debug_mode = enabled and true or false
    Timing.enabled = self.settings.debug_mode
    self:saveSettings()
end

--- KOReader save hook: persist current settings.
function PanelsPlus:onSaveSettings()
    self:saveSettings()
end

--- KOReader close hook: drop scheduled work and restore native panel zoom.
---
--- This lives here rather than in a mixin because `include()` copies methods by
--- name: several modules need teardown, but only one could own the hook name.
--- Every step must be safe to run when the matching feature never started.
function PanelsPlus:onCloseWidget()
    self:cancelPanelPrerender()
    self:clearPanelCache()
    self:restoreNativePanelZoom()
end

return PanelsPlus
