--[[
Panels+
File: src/viewer_controller/menus.lua
Name: ViewerController
Description: Viewer orchestration: menus.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Device = require("device")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local DoubleSpread = require("src._doublespread")
local PanelViewer = require("src._panelviewer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

return function(ViewerController)
    function ViewerController:showInkAwaySettings(viewer, parent_page)
        local _ = require("gettext")
        local menu
        local items = {}
        for _, choice in ipairs({
            { true, _("Keep spread fold joined while annotating") },
            { false, _("Show original fold while annotating") },
        }) do
            local joined = choice[1]
            items[#items + 1] = {
                text = ((self.settings.inkaway_join_spread_fold ~= false) == joined and "◉ " or "○ ") .. choice[2],
                callback = function()
                    self.settings.inkaway_join_spread_fold = joined
                    viewer.inkaway_join_spread_fold = joined
                    self:saveSettings()
                    menu.close_callback = nil
                    UIManager:close(menu)
                    self:showInkAwaySettings(viewer, parent_page)
                end,
            }
        end
        items[#items + 1] = {
            id = "inkaway_fit_viewport",
            help_text = _(
                "Cycle between fitting panels beside the annotator toolbar and keeping the full viewport. Fitting follows the toolbar when it moves or hides."
            ),
            text = _("Panel viewport: ")
                .. (self.settings.inkaway_fit_viewport ~= false and _("Fit beside toolbar") or _("Full viewport")),
            callback = function()
                local fit = self.settings.inkaway_fit_viewport == false
                self.settings.inkaway_fit_viewport = fit
                if viewer.setInkAwayFitViewport then
                    viewer:setInkAwayFitViewport(fit)
                else
                    viewer.inkaway_fit_viewport = fit
                end
                self:saveSettings()
                menu.close_callback = nil
                UIManager:close(menu)
                self:showInkAwaySettings(viewer, parent_page)
            end,
        }
        menu = require("ui/widget/menu"):new({
            title = _("Ink-away Settings…"),
            item_table = items,
            close_callback = function()
                UIManager:close(menu)
                self:showMoreConfigMenu(viewer, parent_page)
            end,
        })
        UIManager:show(menu)
        return true
    end

    --- Find a live viewer, including embedded-image viewers which are not tracked
    --- by active_panel_viewer. The explicit context also supports menus in tests.
    function ViewerController:getOpenPanelViewer()
        for i = #(UIManager._window_stack or {}), 1, -1 do
            local widget = UIManager._window_stack[i].widget
            if
                widget
                and widget.reader_ui == self.ui
                and widget.name == PanelViewer.name
                and not widget._panels_plus_closed
            then
                return widget
            end
        end
        local viewer = self._panels_plus_config_viewer or self.active_panel_viewer
        return viewer and not viewer._panels_plus_closed and viewer or nil
    end

    local function submenuPath(items, predicate)
        for index, item in ipairs(items or {}) do
            item.idx = index
            if predicate(item) then
                return { item }
            end
            local children = item.sub_item_table or item
            if children ~= items then
                local path = submenuPath(children, predicate)
                if path then
                    table.insert(path, 1, item)
                    return path
                end
            end
        end
    end

    --- Enter the real reader menu before showing it; no translated labels or
    --- hardcoded tab positions. Both TouchMenu and keyboard Menu keep their own
    --- normal Back stack through onMenuSelect.
    function ViewerController:showAdvancedOptions(viewer, section, page)
        local reader_menu = self.ui and self.ui.menu
        if not reader_menu then
            return false
        end
        self._panels_plus_config_viewer = viewer
        reader_menu:onShowMenu(nil, true)
        local container = reader_menu.menu_container
        local menu = container[1]
        local predicate = function(item)
            return section and item.panels_plus_section == section or (not section and item.panels_plus_menu)
        end
        local path
        if menu.switchMenuTab then
            for tab, items in ipairs(menu.tab_item_table) do
                path = submenuPath(items, predicate)
                if path then
                    menu.bar:switchToTab(tab)
                    break
                end
            end
        else
            path = submenuPath(menu.item_table, predicate)
        end
        if not path then
            reader_menu:onCloseReaderMenu()
            self._panels_plus_config_viewer = nil
            UIManager:show(require("ui/widget/infomessage"):new({
                text = require("gettext")("Panels+ advanced options are unavailable."),
            }))
            return false
        end
        for _, item in ipairs(path) do
            menu:onMenuSelect(item)
        end
        if page and page > 1 then
            menu.page = page
            menu:updateItems()
        end
        local original_close = menu.close_callback
        menu.close_callback = function()
            original_close()
            local current = self:getOpenPanelViewer()
            self._panels_plus_config_viewer = nil
            local rebuild = self._panels_plus_spread_options_changed
            self._panels_plus_spread_options_changed = nil
            if rebuild and current then
                self:rebuildViewerForSpreadOptions(current)
            end
        end
        menu.not_shown = false
        UIManager:show(container)
        return true
    end

    --- Show a multi-options menu popup for miscellaneous panel viewer settings
    --- that don't need their own dedicated button.
    ---
    --- @param viewer PanelViewer Active panel viewer instance.
    --- @return boolean handled Always true for viewer callback dispatch.
    function ViewerController:showMoreConfigMenu(viewer, page)
        local _ = require("gettext")
        local container = CenterContainer:new({
            dimen = Geom:new({ w = Screen:getWidth(), h = Screen:getHeight() }),
        })
        local menu
        local function close()
            -- A selection callback may open a replacement menu. Prevent KOReader's
            -- trailing close callback from closing or reopening that replacement.
            menu.close_callback = nil
            UIManager:close(container)
        end
        local function reopen(current_viewer)
            close()
            self:showMoreConfigMenu(current_viewer or viewer, menu.page)
        end
        local function toggle(id, text, key, callback)
            return {
                id = id,
                text = _(text),
                mandatory = self.settings[key] ~= false and _("On") or _("Off"),
                callback = function()
                    callback()
                    reopen()
                end,
            }
        end
        local tap = toggle("tap", "Tap screen sides to navigate", "tap_navigation", function()
            self:toggleViewerTapNavigation(viewer)
        end)
        tap.mandatory = self.settings.tap_navigation == true and _("On") or _("Off")
        local invert_swipe = toggle("invert_swipe", "Invert panel swipe direction", "invert_swipe", function()
            self:setInvertSwipe(self.settings.invert_swipe ~= true)
            viewer.invert_swipe = self.settings.invert_swipe
        end)
        invert_swipe.mandatory = self.settings.invert_swipe == true and _("On") or _("Off")
        local invert_taps = toggle("invert_taps", "Invert tap direction", "invert_taps", function()
            self:setInvertTaps(self.settings.invert_taps ~= true)
            viewer.invert_taps = self.settings.invert_taps
        end)
        invert_taps.mandatory = self.settings.invert_taps == true and _("On") or _("Off")
        local labels = { off = _("Off"), viewer = _("Viewer"), reading = _("Reading"), both = _("Viewer + reading") }
        local items = {
            tap,
            toggle("swipe", "Swipe to navigate", "swipe_navigation", function()
                self:toggleViewerSwipeNavigation(viewer)
            end),
            invert_swipe,
            invert_taps,
            {
                id = "panel_gesture",
                text = _("Open panels with"),
                mandatory = self.settings.panel_gesture == "two_finger_tap" and _("Two-finger tap") or _("Long press"),
                callback = function()
                    close()
                    local picker
                    picker = require("ui/widget/menu"):new({
                        title = _("Open panels with"),
                        item_table = require("src.menu").panelGestureItems(self),
                        close_callback = function()
                            UIManager:close(picker)
                            self:showMoreConfigMenu(viewer, menu.page)
                        end,
                    })
                    UIManager:show(picker)
                end,
            },
            {
                id = "rotate",
                text = _("Rotate spreads"),
                mandatory = labels[DoubleSpread.rotationMode(self.settings)],
                callback = function()
                    close()
                    self:showMoreConfigMenu(self:cycleViewerSpreadRotationMode(viewer), menu.page)
                end,
            },
            {
                id = "fold",
                text = _("Remove spread fold line"),
                mandatory = self.settings.join_spread_fold ~= false and _("On") or _("Off"),
                callback = function()
                    close()
                    self:showMoreConfigMenu(self:toggleViewerJoinSpreadFold(viewer), menu.page)
                end,
            },
            toggle("text_selection", "Touch & hold text selection", "hold_text_selection", function()
                self:setHoldTextSelection(self.settings.hold_text_selection == false)
                viewer.hold_text_selection = self.settings.hold_text_selection
                viewer:replaceButtonTable()
                viewer:update()
            end),
            {
                id = "advanced",
                text = _("Open advanced options"),
                bold = true,
                mandatory = "›",
                separator = true,
                callback = function()
                    close()
                    self:showAdvancedOptions(viewer)
                end,
            },
        }
        if self.ui and (self.ui["ink-away"] or self.ui.inkaway) then
            table.insert(items, #items, {
                id = "inkaway_settings",
                text = _("Ink-away Settings…"),
                mandatory = "›",
                callback = function()
                    close()
                    self:showInkAwaySettings(viewer, menu.page)
                end,
            })
        end
        menu = require("src._configmenu").new({
            title = _("More Config"),
            item_table = items,
            show_parent = container,
            close_callback = function()
                UIManager:close(container)
            end,
        })
        container[1] = menu
        if page and page > 1 then
            -- Menu:init() always starts at page one. Restore after construction;
            -- updateItems also clamps the page if a rotation changed pagination.
            menu.page = page
            menu:updateItems()
        end
        UIManager:show(container)
        return true
    end
end
