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
local _ = require("gettext")

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

--- Return the main-menu label for the current reading mode.
---
--- @return string text Localized menu label.
function Menu:getModeText()
    if self.settings.mode == "comic" then
        return _("Panels+: comic mode")
    end
    return _("Panels+: manga mode")
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
        sub_item_table = {
            {
                text = _("Disable plugin panel focusing"),
                checked_func = function()
                    return not self:isEnabled()
                end,
                callback = function()
                    self:setEnabled(not self:isEnabled())
                end,
                help_text = _("Use KOReader's native panel zoom instead of the Panels+ panel sequence viewer."),
            },
            {
                text = _("Manga mode (right to left)"),
                checked_func = function()
                    return self.settings.mode == "manga"
                end,
                radio = true,
                callback = function()
                    self:setMode("manga")
                end,
            },
            {
                text = _("Comic mode (left to right)"),
                checked_func = function()
                    return self.settings.mode == "comic"
                end,
                radio = true,
                callback = function()
                    self:setMode("comic")
                end,
                separator = true,
            },
            {
                text = _("Open panels with"),
                sub_item_table = {
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
                },
                separator = true,
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
            {
                text = _("OCR debug review mode"),
                checked_func = function()
                    return self.settings.ocr_debug_mode == true
                end,
                callback = function()
                    self:setOcrDebugMode(self.settings.ocr_debug_mode ~= true)
                end,
                help_text = _(
                    "After each dictionary lookup that used OCR in a zoomed panel, ask whether the word was read correctly. If not, draw the correct word box and type what it actually says. Everything -- including the exact long-press point -- is appended to OCR.debug.session.log for later review. Off by default."
                ),
            },
        },
    }
end

return Menu
