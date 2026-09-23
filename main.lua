--[[
Panels+
File: main.lua
Name: PanelsPlus
Description: Defines the plugin class, composes feature modules, owns settings, and manages lifecycle teardown.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--[[--
Panels+ KOReader plugin entry point.

The plugin runs the component-based Deep detection pipeline and replaces
KOReader's single-panel zoom with a direction-aware sequence viewer. KOReader's
native detector remains an internal compatibility fallback when a reduced map
cannot be built.
--]]
--

local i18n = require("src.i18n")
i18n.install()

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Actions = require("src.actions")
local Cache = require("src.cache")
local EmbeddedImage = require("src.embedded_image")
local Menu = require("src.menu")
local Memory = require("src._memory")
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
local PanelsPlus = WidgetContainer:extend({
    name = "panelsplus",
    is_doc_only = true,
})

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
include(PanelsPlus, EmbeddedImage)
include(PanelsPlus, ViewerController)
include(PanelsPlus, Actions)
include(PanelsPlus, Menu)
include(PanelsPlus, NativePanelZoom)

--- Initialize settings, panel cache state, menu registration, actions, and hook.
function PanelsPlus:init()
    self.settings = Settings.load()
    Timing.enabled = self.settings.debug_mode == true
    self:loadDocSettings()
    self.panel_cache = {}
    self.panel_cache_order = {}
    self.panel_prefetch_actions = {}
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:patchNativePanelZoom()
    self:applyNativePanelSetting()
end

--- KOReader hook: event sent when document loading is ready.
function PanelsPlus:onReaderReady()
    self:loadDocSettings()
    self:applyPanelGesture()
end

--- Return the file path or key for the active document.
---
--- @return string|nil path Document file path or key.
function PanelsPlus:getDocKey()
    if self.ui and self.ui.doc_settings and self.ui.doc_settings.file then
        return self.ui.doc_settings.file
    end
    if self.ui and self.ui.document and self.ui.document.file then
        return self.ui.document.file
    end
    return nil
end

--- Read per-document settings for the active document if present.
---
--- @return table|nil doc_settings Table containing per-document overrides.
function PanelsPlus:getDocSettings()
    if self.ui and self.ui.doc_settings and type(self.ui.doc_settings.readSetting) == "function" then
        local saved = self.ui.doc_settings:readSetting("panelsplus")
        if type(saved) ~= "table" then
            saved = self.ui.doc_settings:readSetting("panels_plus")
        end
        if type(saved) == "table" then
            return saved
        end
    end
    local doc_key = self:getDocKey()
    if doc_key and self.settings.doc_settings and type(self.settings.doc_settings[doc_key]) == "table" then
        return self.settings.doc_settings[doc_key]
    end
    return nil
end

--- Save current per-document settings (mode, nav_transition_mode, progress_bar_visible, crop_mode).
---
--- @param force boolean|nil Save even if the document hasn't had explicit per-document settings set yet.
function PanelsPlus:saveDocSettings(force)
    if self.settings.remember_doc_settings == false then
        return
    end
    if not force and not self.doc_has_custom_settings then
        return
    end
    local doc_key = self:getDocKey()
    local doc_data = {
        mode = self.settings.mode,
        nav_transition_mode = self.settings.nav_transition_mode,
        progress_bar_visible = self.settings.progress_bar_visible,
        crop_mode = self.settings.crop_mode,
    }
    if self.ui and self.ui.doc_settings and type(self.ui.doc_settings.saveSetting) == "function" then
        self.ui.doc_settings:saveSetting("panelsplus", doc_data)
        self.ui.doc_settings:saveSetting("panels_plus", doc_data)
    end
    if doc_key then
        self.settings.doc_settings = self.settings.doc_settings or {}
        self.settings.doc_settings[doc_key] = doc_data
        self:saveSettings()
    end
    self.doc_has_custom_settings = true
end

--- Load per-document settings for the active document if enabled.
function PanelsPlus:loadDocSettings()
    self.doc_has_custom_settings = false
    if self.settings.remember_doc_settings == false then
        return
    end
    local doc_data = self:getDocSettings()
    if doc_data then
        self.doc_has_custom_settings = true
        if doc_data.mode ~= nil then
            self.settings.mode = doc_data.mode == "comic" and "comic" or "manga"
        end
        if doc_data.nav_transition_mode ~= nil then
            local m = doc_data.nav_transition_mode
            self.settings.nav_transition_mode = (m == "smooth" or m == "animated") and m or "classic"
        end
        if doc_data.progress_bar_visible ~= nil then
            self.settings.progress_bar_visible = doc_data.progress_bar_visible ~= false
        end
        if doc_data.crop_mode ~= nil then
            local c = doc_data.crop_mode
            self.settings.crop_mode = (c == "loose" or c == "margin" or c == "none") and c or "strict"
        end
    end
end

--- Toggle whether per-document settings (reading mode, navigation mode, crop mode, progress bar) are remembered.
---
--- @param enabled any Truthy value enables per-document settings memory.
function PanelsPlus:setRememberDocSettings(enabled)
    self.settings.remember_doc_settings = enabled and true or false
    self:saveSettings()
    if self.settings.remember_doc_settings then
        self:saveDocSettings(false)
    end
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
    self:saveDocSettings(true)
end

--- Set how tightly panel crops are rendered in the viewer.
---
--- @param crop_mode PPCropMode Requested crop mode; anything except `"loose"`/`"margin"`/`"none"` maps to `"strict"`.
function PanelsPlus:setCropMode(crop_mode)
    if crop_mode == "loose" or crop_mode == "margin" or crop_mode == "none" then
        self.settings.crop_mode = crop_mode
    else
        self.settings.crop_mode = "strict"
    end
    self:saveSettings()
    self:saveDocSettings(true)
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
--- @param ratio number Requested bleed ratio; clamped to [0, 1.0].
function PanelsPlus:setBleedRatio(ratio)
    ratio = tonumber(ratio) or Settings.defaults.panel_bleed_ratio
    self.settings.panel_bleed_ratio = math.max(0, math.min(1.0, ratio))
    self:saveSettings()
end

--- Persist the plugin's own zoomed-view image rotation, independent of
--- KOReader's device/screen rotation.
---
--- @param angle number|boolean|nil `false`/`nil` for no rotation, or 90/180/270.
function PanelsPlus:setImageRotation(angle)
    self.settings.image_rotation = angle
    self:saveSettings()
end

--- Toggle whether swipe direction is inverted relative to reading order.
---
--- @param invert_swipe any Truthy value inverts left/right panel navigation.
function PanelsPlus:setInvertSwipe(invert_swipe)
    self.settings.invert_swipe = invert_swipe and true or false
    self:saveSettings()
end

--- Toggle whether side tap direction is inverted relative to reading order.
---
--- @param invert_taps any Truthy value inverts left/right tap navigation.
function PanelsPlus:setInvertTaps(invert_taps)
    self.settings.invert_taps = invert_taps and true or false
    self:saveSettings()
end

--- Enable or disable tapping the left/right screen edges to navigate between panels.
---
--- @param enabled any Truthy value enables tap-to-navigate on the screen edges.
function PanelsPlus:setTapNavigation(enabled)
    self.settings.tap_navigation = enabled and true or false
    self:saveSettings()
end

--- Enable or disable swiping left/right to navigate between panels.
---
--- @param enabled any Truthy value enables swipe-to-navigate.
function PanelsPlus:setSwipeNavigation(enabled)
    self.settings.swipe_navigation = enabled and true or false
    self:saveSettings()
end

--- Enable or disable Kobo-like vertical edge gestures for zooming in/out.
---
--- @param enabled any Truthy value enables Kobo-style left-edge vertical zoom.
function PanelsPlus:setKoboVerticalGesture(enabled)
    self.settings.kobo_vertical_gesture = enabled and true or false
    self:saveSettings()
end

--- Set which gesture opens panels on a page.
---
--- @param gesture string "hold" (long press) or "two_finger_tap".
function PanelsPlus:setPanelGesture(gesture)
    self.settings.panel_gesture = gesture == "two_finger_tap" and "two_finger_tap" or "hold"
    Timing.log("panel_gesture -> " .. self.settings.panel_gesture)
    self:saveSettings()
    self:applyNativePanelSetting()
    self:applyPanelGesture()
end

--- Set whether the panel viewer bottom progress bar is visible.
---
--- @param visible any Truthy value shows the progress bar.
function PanelsPlus:setProgressBarVisible(visible)
    self.settings.progress_bar_visible = visible and true or false
    self:saveSettings()
    self:saveDocSettings(true)
end

--- Set whether touch and hold on text in zoomed panels triggers text selection / dictionary.
---
--- @param enabled any Truthy value enables text selection & dictionary lookup on hold.
function PanelsPlus:setHoldTextSelection(enabled)
    self.settings.hold_text_selection = enabled and true or false
    self:saveSettings()
end

--- Select Classic, Smooth camera-pan, or framebuffer Animated navigation.
---
--- @param mode PPNavTransitionMode Requested mode; anything unknown maps to "classic".
function PanelsPlus:setNavTransitionMode(mode)
    self.settings.nav_transition_mode = (mode == "smooth" or mode == "animated") and mode or "classic"
    Timing.log("nav_transition_mode -> " .. self.settings.nav_transition_mode)
    self:saveSettings()
    self:saveDocSettings(true)
end

--- Enable or disable framebuffer animation between panels in Animated mode.
--- @param enabled any Truthy value animates panel-to-panel switches.
function PanelsPlus:setNavAnimatedPanels(enabled)
    self.settings.nav_animated_panels = enabled and true or false
    self:saveSettings()
end

--- Enable or disable framebuffer animation between pages in Animated mode.
--- @param enabled any Truthy value animates page-boundary switches.
function PanelsPlus:setNavAnimatedPages(enabled)
    self.settings.nav_animated_pages = enabled and true or false
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

--- Enable or disable animating panel transitions across page boundaries.
---
--- Only takes effect when the adjacent page's panels are already cached at the
--- moment of the swipe; otherwise the crossing always falls back to the
--- classic instant cut, so this never blocks a gesture on detection.
---
--- @param enabled any Truthy value animates page-boundary crossings too.
function PanelsPlus:setNavTransitionCrossPage(enabled)
    self.settings.nav_transition_cross_page = enabled and true or false
    self:saveSettings()
end

--- Set how many steps the smooth-navigation camera pan is split into.
---
--- @param frames number Requested step count; clamped to [1, 24].
function PanelsPlus:setNavTransitionFrames(frames)
    frames = tonumber(frames) or Settings.defaults.nav_transition_frames
    self.settings.nav_transition_frames = math.max(1, math.min(24, math.floor(frames + 0.5)))
    self:saveSettings()
end

--- Normalize a legacy detector request to Deep mode's component pipeline.
---
--- @param _detector PPDetector Ignored legacy detector value.
function PanelsPlus:setDetector(_detector)
    self.settings.detector = "components"
    Timing.log(
        "detector -> " .. self.settings.detector .. string.format(" (cache: %d pages)", #(self.panel_cache_order or {}))
    )
    self:saveSettings()
end

--- Normalize a legacy embedded-detector request to the component pipeline.
--- @param _detector PPDetector Ignored legacy detector value.
function PanelsPlus:setEmbeddedDetector(_detector)
    self.settings.embedded_detector = "components"
    Timing.log("embedded detector -> " .. self.settings.embedded_detector)
    self:saveSettings()
end

--- Choose the transition mode used only while viewing an extracted EPUB/KEPUB/MOBI image.
--- @param mode PPNavTransitionMode Requested mode; anything unknown maps to `"classic"`.
function PanelsPlus:setEmbeddedNavTransitionMode(mode)
    self.settings.embedded_nav_transition_mode = (mode == "smooth" or mode == "animated") and mode or "classic"
    Timing.log("embedded navigation transition -> " .. self.settings.embedded_nav_transition_mode)
    self:saveSettings()
end

--- Enable or disable splitting comic panels on their drawn border strokes.
---
--- Experimental, and off by default: the stroke between two edge-to-edge
--- panels and a black line drawn through a single panel are indistinguishable
--- in the ink map, so turning this on splits real panels in half on any page
--- with a horizon, caption rule or letterbox band. See `src._segmenter`.
---
--- The panel cache is keyed on this (see `Cache:getPanelCacheKey`), so pages
--- already detected under the other setting stay cached under their own key
--- and toggling back returns them instantly.
---
--- @param enabled any Truthy value splits comic panels on drawn border strokes.
function PanelsPlus:setBorderSplit(enabled)
    self.settings.segment_border_split = enabled and true or false
    Timing.log("border split -> " .. tostring(self.settings.segment_border_split))
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
    self:saveDocSettings()
end

--- KOReader close hook: drop scheduled work and restore native panel zoom.
---
--- This lives here rather than in a mixin because `include()` copies methods by
--- name: several modules need teardown, but only one could own the hook name.
--- Every step must be safe to run when the matching feature never started.
---
--- This hook fires on every `ReaderUI` teardown -- closing a document, going
--- home, switching documents, and quitting KOReader all go through it, not
--- just the low-memory device case a full collect was meant for. A full
--- `collectgarbage("collect")` is a blocking, stop-the-world pass whose cost
--- scales with how much the plugin's heap has grown that session; running it
--- unconditionally stalls teardown (and, on app exit, freezes the screen on
--- whatever was last drawn) even when memory is not actually tight. Only pay
--- for it when headroom is genuinely low; otherwise let Lua's normal
--- incremental GC reclaim this cache without a synchronous pause.
function PanelsPlus:onCloseWidget()
    self:cancelEmbeddedImageSearch()
    self:cancelPanelPrefetch()
    self:cancelPanelPrerender()
    self:clearPanelCache()
    self:removePanelGestureZones()
    self:restoreNativePanelZoom()

    local ok, ComponentDetector = pcall(require, "src._componentdetector")
    if ok and ComponentDetector.clearScratch then
        ComponentDetector.clearScratch()
    end

    local minimum = self.settings.prerender_min_free_bytes or Settings.defaults.prerender_min_free_bytes
    if not Memory.hasHeadroom(minimum) then
        collectgarbage("collect")
    end
end

return PanelsPlus
