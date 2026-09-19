--[[
Panels+
File: src/native_panel_zoom.lua
Name: NativePanelZoom
Description: Patches and restores KOReader hold and panel-zoom entry points.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Native panel-zoom integration methods mixed into `PanelsPlus`.
---
--- @class PPNativePanelZoomMethods
local NativePanelZoom = {}

--- Replace KOReader's native panel zoom handler while this plugin is active.
function NativePanelZoom:patchNativePanelZoom()
    local highlight = self.ui.highlight
    if not highlight then
        return
    end
    if highlight._panels_plus_original_panel_zoom then
        -- Already patched (e.g. a second init() without an intervening
        -- onCloseWidget): still refresh the plugin reference so the hook
        -- doesn't keep driving a stale PanelsPlus instance.
        highlight._panels_plus_plugin = self
        return
    end

    highlight._panels_plus_plugin = self
    highlight._panels_plus_original_panel_zoom = highlight.onPanelZoom
    highlight._panels_plus_original_hold = highlight.onHold
    highlight.onPanelZoom = function(reader_highlight, arg, ges)
        local plugin = reader_highlight._panels_plus_plugin
        if plugin and plugin:isEnabled() and plugin:opensOnHold() then
            return plugin:showPanelSequence(reader_highlight, ges)
        end
        return reader_highlight:_panels_plus_original_panel_zoom(arg, ges)
    end
    highlight.onHold = function(reader_highlight, arg, ges)
        local plugin = reader_highlight._panels_plus_plugin
        if
            plugin
            and plugin:isEnabled()
            and plugin:opensOnHold()
            and plugin:showEmbeddedImagePanels(reader_highlight, ges)
        then
            return true
        end
        return reader_highlight:_panels_plus_original_hold(arg, ges)
    end
end

--- Whether panels open on a long press (the default) rather than another gesture.
---
--- @return boolean on_hold
function NativePanelZoom:opensOnHold()
    return self.settings.panel_gesture ~= "two_finger_tap"
end

--- Keep KOReader panel zoom active so disabling Panels+ focusing falls back to
--- native panel zoom. When panels open on another gesture, a long press is left
--- to KOReader's own settings.
function NativePanelZoom:applyNativePanelSetting()
    if self.ui.highlight and self.ui.paging and self:opensOnHold() then
        self.ui.highlight.panel_zoom_enabled = true
        self.ui.highlight.panel_zoom_fallback_to_text_selection = false
    end
end

--- Restore the reader's panel-zoom settings saved after it loaded the document.
function NativePanelZoom:restoreNativePanelSetting()
    local highlight = self.ui and self.ui.highlight
    local settings = self._panels_plus_native_panel_settings
    if highlight and settings then
        highlight.panel_zoom_enabled = settings.panel_zoom_enabled
        highlight.panel_zoom_fallback_to_text_selection = settings.panel_zoom_fallback_to_text_selection
    end
end

--- Register the touch zone for the chosen gesture, or remove it for long press.
--- KOReader's Gestures plugin claims two-finger taps in four large corner
--- zones (zoom in and out by default), so on a page Panels+ takes priority
--- over those; their actions are still available from other gestures.
function NativePanelZoom:applyPanelGesture()
    self:removePanelGestureZones()
    if not self:opensOnHold() then
        self:restoreNativePanelSetting()
    end
    local ui = self.ui
    if self:opensOnHold() or not ui or not ui.registerTouchZones then
        return
    end
    self._panels_plus_zones = {
        {
            id = "panels_plus_two_finger_tap",
            ges = "two_finger_tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = {
                "two_finger_tap_top_left_corner",
                "two_finger_tap_top_right_corner",
                "two_finger_tap_bottom_left_corner",
                "two_finger_tap_bottom_right_corner",
            },
            handler = function(ges)
                local highlight = self.ui and self.ui.highlight
                if not highlight or not self:isEnabled() then
                    return false
                end
                if self.ui.paging then
                    return self:showPanelSequence(highlight, ges)
                end
                return self:showEmbeddedImagePanels(highlight, ges)
            end,
        },
    }
    ui:registerTouchZones(self._panels_plus_zones)
end

--- Remove the gesture touch zone, if any.
function NativePanelZoom:removePanelGestureZones()
    if self._panels_plus_zones and self.ui and self.ui.unRegisterTouchZones then
        self.ui:unRegisterTouchZones(self._panels_plus_zones)
    end
    self._panels_plus_zones = nil
end

--- KOReader hook: reapply the native panel-zoom override after document load.
---
--- `ReaderHighlight:onReadSettings` only defaults `panel_zoom_enabled` to true
--- for cbz/cbt (false for pdf/cbr) and `panel_zoom_fallback_to_text_selection`
--- to true for pdf, then assigns those onto `self.ui.highlight` from the
--- per-document/per-extension settings. That assignment runs as part of the
--- same `ReadSettings` broadcast that follows plugin init, and since
--- `highlight` is registered before plugins it always runs first -- so it
--- silently overwrites the values `applyNativePanelSetting` set in `init()`,
--- which made pdf/cbr hold gestures fall through to dictionary/OCR lookup
--- instead of ever reaching `onPanelZoom`. Reapplying here, after that
--- broadcast reaches this module, restores the override.
function NativePanelZoom:onReadSettings()
    local highlight = self.ui and self.ui.highlight
    if highlight then
        self._panels_plus_native_panel_settings = {
            panel_zoom_enabled = highlight.panel_zoom_enabled,
            panel_zoom_fallback_to_text_selection = highlight.panel_zoom_fallback_to_text_selection,
        }
    end
    self:applyNativePanelSetting()
end

--- Restore the original native panel zoom handler.
---
--- Called from `PanelsPlus:onCloseWidget` rather than being one itself: mixin
--- methods are copied by name, so only one module can own that hook.
function NativePanelZoom:restoreNativePanelZoom()
    local highlight = self.ui and self.ui.highlight
    if highlight and highlight._panels_plus_original_panel_zoom then
        highlight.onPanelZoom = highlight._panels_plus_original_panel_zoom
        highlight.onHold = highlight._panels_plus_original_hold
        highlight._panels_plus_original_panel_zoom = nil
        highlight._panels_plus_original_hold = nil
        highlight._panels_plus_plugin = nil
    end
end

return NativePanelZoom
