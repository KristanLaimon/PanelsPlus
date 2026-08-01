local _ = require("gettext")

--- Main-menu methods mixed into `PanelsPlus`.
---
--- @class PPMenuMethods
local Menu = {}

--- Return the active detector, defaulting unset or unknown values to automatic.
---
--- @return PPDetector detector Current detector selection.
function Menu:getDetector()
    local detector = self.settings.detector
    if detector == "fast" or detector == "exact" then
        return detector
    end
    if detector == "native" then
        return "exact" -- pre-rename value, in case migration has not run yet
    end
    return "auto"
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
            },
            {
                text = _("Invert panel swipe direction"),
                checked_func = function()
                    return self.settings.invert_swipe == true
                end,
                callback = function()
                    self:setInvertSwipe(not self.settings.invert_swipe)
                end,
                help_text = _("Use this if panel navigation feels reversed on your device. It changes swipe direction only, not panel order."),
            },
            {
                text = _("Touch & hold text selection in zoom"),
                checked_func = function()
                    return self.settings.hold_text_selection ~= false
                end,
                callback = function()
                    self:setHoldTextSelection(self.settings.hold_text_selection == false)
                end,
                help_text = _("Allow touch and hold on text inside zoomed panels to select text and trigger dictionary lookups."),
                separator = true,
            },
            {
                text = _("Panel detection"),
                sub_item_table = {
                    {
                        text = _("Smart Mode"),
                        checked_func = function()
                            return self:getDetector() == "auto"
                        end,
                        radio = true,
                        callback = function()
                            self:setDetector("auto")
                        end,
                        help_text = _("Use fast detection, falling back to exact detection on layouts it cannot split. Recommended."),
                    },
                    {
                        text = _("Quick mode"),
                        checked_func = function()
                            return self:getDetector() == "fast"
                        end,
                        radio = true,
                        callback = function()
                            self:setDetector("fast")
                        end,
                        help_text = _("Always detect panels from a reduced-size page. Quickest, and the only mode that works on pages with a dark background, but it cannot split interlocking panel layouts."),
                    },
                    {
                        text = _("Deep mode"),
                        checked_func = function()
                            return self:getDetector() == "exact"
                        end,
                        radio = true,
                        callback = function()
                            self:setDetector("exact")
                        end,
                        help_text = _("Always use KOReader's own panel detector. Slower and unable to find panels on pages with a dark background, but more literal about panel edges."),
                    },
                },
            },
            {
                text = _("Pre-render next panel"),
                checked_func = function()
                    return self.settings.panel_prerender ~= false
                end,
                callback = function()
                    self:setPanelPrerender(self.settings.panel_prerender == false)
                end,
                help_text = _("Render the next panel while you read the current one, so swiping to it is instant. Skipped automatically when the device is low on memory."),
            },
            {
                text = _("Enable debugging logs"),
                checked_func = function()
                    return self.settings.debug_mode == true
                end,
                callback = function()
                    self:setDebugMode(not self.settings.debug_mode)
                end,
                help_text = _("Write panel detection, render timings, and memory usage to KOReader's log. Useful for diagnosing slowness or crashes, otherwise leave off."),
            },
        },
    }
end

return Menu
