--[[
Panels+
File: src/menu.lua
Name: Menu
Description: Builds the Panels+ main-menu entries and reports the active detector namespace.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local DoubleSpread = require("src._doublespread")
local Settings = require("src._settings")
local NavEasing = require("src._naveasing")
local _ = require("gettext")
local NATIVE_TEXT_LABEL = _("Prefer native-text layer in PDF files over Panels+ text recognition")

--- Main-menu methods mixed into `PanelsPlus`.
---
--- @class PPMenuMethods
local Menu = {}

--- Return the active component detector and cache namespace.
---
--- @return PPDetector detector Current detector selection.
function Menu:getDetector()
    return "components"
end

--- Return the spread rotation choice shown in the menus (see `DoubleSpread.rotationMode`).
---
--- @return string mode `"off"`, `"viewer"`, `"reading"` or `"both"`.
function Menu:getSpreadRotationMode()
    return DoubleSpread.rotationMode(self.settings)
end

--- Return the main-menu label for the current reading mode.
---
--- @return string text Localized menu label.
function Menu:getModeText()
    if self.settings.mode == "comic" then
        return _("Panels+: comic mode")
    end
    return _("Panels+: manga mode")
end

--- Shared optional panel zoom choices for the reader and viewer menus.
--- @param self PanelsPlus Host plugin; both menu entry points share its settings and persistence.
--- @return table[] items Gesture/mode choices plus multipliers when In-config is selected.
function Menu.panelZoomItems(self)
    local items = {
        {
            text = _("Enable panel gesture zoom"),
            mandatory_func = function()
                return self.settings.panel_zoom_enabled == true and _("Enabled") or _("Disabled")
            end,
            checked_func = function()
                return self.settings.panel_zoom_enabled == true
            end,
            callback = function()
                self.settings.panel_zoom_enabled = not self.settings.panel_zoom_enabled
                self:saveSettings()
            end,
        },
        { text = _("Zoom gesture"), bold = true, select_enabled = false },
    }
    local hold_help = _(
        "Important Note: Now long press is used for zoom-in and zoom-out, but OCR Text dictionary look up was using that shortcut, now, to select a word, try with long press + dragging (in any direction). This shortcut override only applies while using long press as zoom-gesture"
    )
    for _, choice in ipairs({
        { "hold", _("Long press") },
        { "two_finger_tap", _("Two-finger tap") },
        { "spread", _("Spread gesture") },
    }) do
        local gesture, label = choice[1], choice[2]
        local selected = (self.settings.panel_zoom_gesture_type or "spread") == gesture
        items[#items + 1] = {
            text = (selected and "◉ " or "○ ") .. label,
            text_func = function()
                return ((self.settings.panel_zoom_gesture_type or "spread") == gesture and "◉ " or "○ ") .. label
            end,
            radio = true,
            bold = selected,
            checked_func = function()
                return (self.settings.panel_zoom_gesture_type or "spread") == gesture
            end,
            callback = function()
                self.settings.panel_zoom_gesture_type = gesture
                self:saveSettings()
                if gesture == "hold" then
                    local UIManager = require("ui/uimanager")
                    UIManager:nextTick(function()
                        UIManager:show(require("ui/widget/infomessage"):new({
                            text = hold_help,
                        }))
                    end)
                end
            end,
        }
    end
    items[#items + 1] = { text = _("Zooming mode"), bold = true, select_enabled = false }
    local updateZoomAmounts
    for _, choice in ipairs({ { "slider", _("Slider (Long press to config)") }, { "in_config", _("In-config") } }) do
        local mode, label = choice[1], choice[2]
        items[#items + 1] = {
            text_func = function()
                return ((self.settings.panel_zoom_mode or "slider") == mode and "◉ " or "○ ") .. label
            end,
            text = ((self.settings.panel_zoom_mode or "slider") == mode and "◉ " or "○ ") .. label,
            radio = true,
            hold_callback = mode == "slider" and function()
                if self.showZoomSliderOptions then
                    self:showZoomSliderOptions()
                end
            end or nil,
            checked_func = function()
                return (self.settings.panel_zoom_mode or "slider") == mode
            end,
            callback = function()
                self.settings.panel_zoom_mode = mode
                if mode == "slider" then
                    local zoom = require("src._panelzoom")
                    local min, max = zoom.range(self.settings)
                    self.settings.panel_zoom_factor =
                        math.max(min, math.min(max, zoom.factor(self.settings.panel_zoom_factor)))
                end
                self:saveSettings()
                updateZoomAmounts()
            end,
        }
    end
    local base_item_count = #items
    updateZoomAmounts = function()
        while #items > base_item_count do
            table.remove(items)
        end
        if self.settings.panel_zoom_mode ~= "in_config" then
            return
        end
        items[#items + 1] = { text = _("Zoom amount"), bold = true, select_enabled = false }
        for _, factor in ipairs({ 1.25, 1.5, 1.75, 2, 3, 4, 5 }) do
            items[#items + 1] = {
                text = tostring(factor) .. "×",
                radio = true,
                checked_func = function()
                    return (self.settings.panel_zoom_factor or 1.5) == factor
                end,
                callback = function()
                    self.settings.panel_zoom_factor = factor
                    self:saveSettings()
                end,
            }
        end
    end
    updateZoomAmounts()
    return items
end

--- Shared gesture choices remain accessible before opening any panel viewer.
--- @param self PanelsPlus
--- @return table[] items
function Menu.panelGestureItems(self)
    return {
        {
            text = _("Long press"),
            checked_func = function()
                return self.settings.panel_gesture ~= "two_finger_tap"
            end,
            radio = true,
            callback = function()
                self:setPanelGesture("hold")
            end,
            help_text = _(
                "A long press on the page opens the panel under it. Panels+ takes over KOReader's long press on comic pages."
            ),
        },
        {
            text = _("Two-finger tap"),
            checked_func = function()
                return self.settings.panel_gesture == "two_finger_tap"
            end,
            radio = true,
            callback = function()
                self:setPanelGesture("two_finger_tap")
            end,
            help_text = _(
                "A tap with two fingers opens the panel under them, and a long press is left to KOReader or other plugins. Needs a multi-touch screen."
            ),
        },
    }
end

--- Advanced controls share the same setters whether entered from the viewer or reader.
function Menu:applyAdvancedSetting(setter, value, key)
    self[setter](self, value)
    local viewer = self.getOpenPanelViewer and self:getOpenPanelViewer()
    if viewer and key then
        viewer[key] = self.settings[key]
    end
    if viewer and setter == "setSpreadRotationDirection" then
        self._panels_plus_spread_options_changed = true
    end
end

--- Build advanced animation controls for either menu entry point.
--- @param self PanelsPlus
--- @return table[] items
function Menu.animationItems(self)
    local items = {}
    local function currentPage(menu)
        -- TouchMenu passes itself to callbacks; keyboard Menu does not.
        local reader_menu = self.ui and self.ui.menu
        local container = reader_menu and reader_menu.menu_container
        menu = menu or (container and container[1])
        return menu and menu.page
    end
    local function preview(page, skip_preview)
        local viewer = self.getOpenPanelViewer and self:getOpenPanelViewer()
        return self.previewSmoothSettings and self:previewSmoothSettings(viewer, page, skip_preview)
    end
    local function toggle(label, key, setter)
        items[#items + 1] = {
            text = _(label),
            checked_func = function()
                return self.settings[key] ~= false
            end,
            callback = function(menu)
                Menu.applyAdvancedSetting(self, setter, self.settings[key] == false, key)
                preview(currentPage(menu))
            end,
        }
    end
    toggle("Animate between panels", "nav_animated_panels", "setNavAnimatedPanels")
    toggle("Animate between pages", "nav_animated_pages", "setNavAnimatedPages")
    toggle("Animate page-to-page transitions", "nav_transition_cross_page", "setNavTransitionCrossPage")
    local function adjustment(label, key, setter, minimum, maximum, step, multiplier, unit)
        items[#items + 1] = {
            text = _(label),
            mandatory_func = function()
                return tostring(math.floor((self.settings[key] or Settings.defaults[key]) * multiplier + 0.5))
                    .. " "
                    .. unit
            end,
            callback = function(menu)
                local UIManager = require("ui/uimanager")
                local page = currentPage(menu)
                UIManager:nextTick(function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new({
                        title_text = _(label),
                        value = math.floor((self.settings[key] or Settings.defaults[key]) * multiplier + 0.5),
                        value_min = minimum,
                        value_max = maximum,
                        value_step = step,
                        default_value = Settings.defaults[key] * multiplier,
                        unit = unit,
                        callback = function(spin)
                            Menu.applyAdvancedSetting(self, setter, spin.value / multiplier, key)
                            preview(page)
                        end,
                        cancel_callback = function()
                            preview(page, true)
                        end,
                    }))
                end)
            end,
        }
    end
    adjustment(
        "Pan animation duration",
        "nav_transition_duration",
        "setNavTransitionDuration",
        150,
        900,
        50,
        1000,
        "ms"
    )
    adjustment("Transition frames", "nav_transition_frames", "setNavTransitionFrames", 1, 60, 1, 1, _("frames"))
    items[#items + 1] = {
        text_func = function()
            return _("Smooth style") .. ": " .. NavEasing.label(self.settings.nav_smooth_style)
        end,
        keep_menu_open = true,
        callback = function(menu)
            local style = NavEasing.next(self.settings.nav_smooth_style)
            Menu.applyAdvancedSetting(self, "setNavSmoothStyle", style, "nav_smooth_style")
            local previewing = preview(currentPage(menu))
            if menu and not previewing then
                menu:updateItems()
            end
        end,
        help_text = _("Cycle CSS timing functions for pan and zoom, or select Classic for the earlier camera pan."),
    }
    items[#items + 1] = {
        text = _("Preview smooth transitions"),
        checked_func = function()
            return self.settings.nav_smooth_preview ~= false
        end,
        callback = function(menu)
            self:setNavSmoothPreview(self.settings.nav_smooth_preview == false)
            if not menu then
                preview(currentPage(), true)
            end
        end,
        help_text = _(
            "After changing Smooth settings, preview the next panel and return here. At the last panel, preview the previous panel instead. A preview needs at least two panels."
        ),
    }
    return items
end

--- Add the plugin's submenu to KOReader's main menu.
---
--- @param menu_items table<string, table> Mutable KOReader menu item table.
function Menu:addToMainMenu(menu_items)
    menu_items.panels_plus = {
        text_func = function()
            return self:getModeText()
        end,
        sorting_hint = "tools",
        panels_plus_menu = true,
        sub_item_table = {
            {
                text = _("Disable plugin panel focusing"),
                checked_func = function()
                    return not self:isEnabled()
                end,
                callback = function()
                    self:setEnabled(not self:isEnabled())
                    if not self:isEnabled() then
                        self:closePanelViewers()
                    end
                end,
                help_text = _("Use KOReader's native panel zoom instead of the Panels+ panel sequence viewer."),
            },
            {
                text = _("Kobo-like edge vertical gesture"),
                checked_func = function()
                    return self.settings.kobo_vertical_gesture ~= false
                end,
                callback = function()
                    Menu.applyAdvancedSetting(
                        self,
                        "setKoboVerticalGesture",
                        self.settings.kobo_vertical_gesture == false,
                        "kobo_vertical_gesture"
                    )
                end,
                separator = false,
            },
            {
                text = _("Open panels with"),
                sub_item_table = Menu.panelGestureItems(self),
                separator = true,
            },
            {
                text = _("Remember per-document settings"),
                checked_func = function()
                    return self.settings.remember_doc_settings ~= false
                end,
                callback = function()
                    Menu.applyAdvancedSetting(
                        self,
                        "setRememberDocSettings",
                        self.settings.remember_doc_settings == false,
                        "remember_doc_settings"
                    )
                end,
                separator = true,
            },
            {
                text = _("Spread rotation direction"),
                help_text = _(
                    'Which way double-page spreads are rotated, in the panel viewer and while reading. The first choice follows "Invert default rotation in portrait mode" in KOReader\'s rotation settings.'
                ),
                sub_item_table = {
                    {
                        text = _("Same as KOReader's image viewer"),
                        checked_func = function()
                            return (self.settings.spread_rotation_direction or "auto") == "auto"
                        end,
                        radio = true,
                        callback = function()
                            Menu.applyAdvancedSetting(self, "setSpreadRotationDirection", "auto")
                        end,
                    },
                    {
                        text = _("Clockwise"),
                        checked_func = function()
                            return (self.settings.spread_rotation_direction or "auto") == "cw"
                        end,
                        radio = true,
                        callback = function()
                            Menu.applyAdvancedSetting(self, "setSpreadRotationDirection", "cw")
                        end,
                    },
                    {
                        text = _("Counter-clockwise"),
                        checked_func = function()
                            return (self.settings.spread_rotation_direction or "auto") == "ccw"
                        end,
                        radio = true,
                        callback = function()
                            Menu.applyAdvancedSetting(self, "setSpreadRotationDirection", "ccw")
                        end,
                    },
                },
            },
            {
                text = NATIVE_TEXT_LABEL,
                font_func = function(size)
                    local Font = require("ui/font")
                    return Font:getFace("smallinfofont", math.min(size, math.max(12, math.floor(size * 0.6))))
                end,
                checked_func = function()
                    return self.settings.prefer_native_text_layer ~= false
                end,
                callback = function()
                    Menu.applyAdvancedSetting(
                        self,
                        "setPreferNativeTextLayer",
                        self.settings.prefer_native_text_layer == false,
                        "prefer_native_text_layer"
                    )
                end,
                help_text = NATIVE_TEXT_LABEL
                    .. "\n\n"
                    .. _(
                        "Use a word from the document's own text layer when it covers the pressed position. Otherwise, try KOReader's word detection and Panels+ text recognition."
                    ),
            },
            {
                text = _("Pre-render next panel"),
                checked_func = function()
                    return self.settings.panel_prerender ~= false
                end,
                callback = function()
                    Menu.applyAdvancedSetting(
                        self,
                        "setPanelPrerender",
                        self.settings.panel_prerender == false,
                        "panel_prerender"
                    )
                end,
                separator = true,
            },
            {
                text = _("Animation"),
                panels_plus_section = "animation",
                sub_item_table = Menu.animationItems(self),
                separator = true,
            },
            {
                text = _("Zoom settings"),
                sub_item_table = Menu.panelZoomItems(self),
            },
            {
                text = _("Enable debugging logs"),
                checked_func = function()
                    return self.settings.debug_mode == true
                end,
                callback = function()
                    self:setDebugMode(not self.settings.debug_mode)
                end,
                help_text = _(
                    "Write panel detection, render timings, and memory usage to KOReader's log. Useful for diagnosing slowness or crashes, otherwise leave off."
                ),
            },
        },
    }
end

return Menu
