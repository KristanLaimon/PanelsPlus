local _ = require("gettext")

--- Main-menu methods mixed into `PanelsPlus`.
---
--- @class PPMenuMethods
local Menu = {}

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
                text = _("Enable panel focus"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    self:setEnabled(not self:isEnabled())
                end,
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
                text = _("Gesture actions"),
                enabled = false,
                help_text = _("Assign gestures to the Panels+ actions from the gesture manager. Available actions: toggle, toggle manga/comic mode, set manga mode, set comic mode."),
            },
        },
    }
end

return Menu
