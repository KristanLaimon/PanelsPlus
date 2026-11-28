local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local Settings = require("src._settings")
local ViewerController = require("src.viewer_controller")
local UIManager = require("ui/uimanager")

describe("Panel refresh cadence", function()
    it("defaults new installations to KOReader while preserving saved choices", function()
        assert.equals("koreader", Settings.withDefaults({}).panel_refresh_mode)
        assert.equals("interval", Settings.withDefaults({ panel_refresh_mode = "interval" }).panel_refresh_mode)
        assert.is_true(Settings.withDefaults({}).panel_refresh_on_page_change)
        assert.is_false(Settings.withDefaults({ panel_refresh_on_page_change = false }).panel_refresh_on_page_change)
    end)

    it("persists a refresh choice and applies it to the open viewer", function()
        local saves = 0
        local controller = setmetatable({
            settings = Settings.withDefaults({}),
            saveSettings = function()
                saves = saves + 1
            end,
        }, { __index = ViewerController })
        local viewer = { _panel_refresh_count = 5 }
        controller:showMoreConfigMenu(viewer)
        local items = UIManager._last_shown[1].item_table
        for _, item in ipairs(items) do
            if item.id == "panel_refresh" then
                item.callback()
            end
        end
        local menu = UIManager._last_shown
        assert.equals(5, #menu.item_table)
        menu.item_table[2].callback()
        assert.equals("every", controller.settings.panel_refresh_mode)
        assert.equals(controller.settings, viewer.panel_refresh_settings)
        assert.equals(0, viewer._panel_refresh_count)
        assert.equals(1, saves)
    end)

    it("toggles page refresh independently of the panel cadence and persists both states", function()
        local saves = 0
        local controller = setmetatable({
            settings = Settings.withDefaults({ panel_refresh_mode = "never" }),
            saveSettings = function()
                saves = saves + 1
            end,
        }, { __index = ViewerController })
        local viewer = {}
        controller:showPanelRefreshSettings(viewer)
        assert.equals("☑ Refresh on full page change", UIManager._last_shown.item_table[5].text)
        UIManager._last_shown.item_table[5].callback()
        assert.is_false(controller.settings.panel_refresh_on_page_change)
        assert.equals("☐ Refresh on full page change", UIManager._last_shown.item_table[5].text)
        assert.equals(controller.settings, viewer.panel_refresh_settings)
        UIManager._last_shown.item_table[5].callback()
        assert.is_true(controller.settings.panel_refresh_on_page_change)
        assert.equals("never", controller.settings.panel_refresh_mode)
        assert.equals(2, saves)
    end)

    it("uses the page refresh preference when the viewer is shown", function()
        local original_dirty = UIManager.setDirty
        local repaint
        UIManager.setDirty = function(_, _, callback)
            repaint = callback
        end
        local viewer = setmetatable({
            main_frame = { dimen = {} },
            isOpen = function()
                return true
            end,
            requestPanelPrerender = function() end,
        }, { __index = PanelViewer })
        viewer:onShow()
        assert.equals("full", repaint())
        viewer.panel_refresh_settings = { panel_refresh_on_page_change = false }
        viewer:onShow()
        assert.equals("ui", repaint())
        viewer.panel_refresh_settings.panel_refresh_on_page_change = true
        viewer:onShow()
        assert.equals("full", repaint())
        UIManager.setDirty = original_dirty
    end)

    it("suppresses the outgoing flash only when replacing a page with page refresh disabled", function()
        local viewer = setmetatable({
            main_frame = { dimen = {} },
            panel_refresh_settings = { panel_refresh_on_page_change = false },
            _panels_plus_replacing = true,
        }, { __index = PanelViewer })
        local repaint = viewer:guardRefreshFunc(nil, function()
            return "flashui"
        end)
        assert.equals("ui", repaint())
        viewer._panels_plus_replacing = nil
        assert.equals("flashui", repaint())
        viewer._panels_plus_replacing = true
        viewer.panel_refresh_settings.panel_refresh_on_page_change = true
        assert.equals("flashui", repaint())
    end)

    it("defers the interval picker and updates the current interval label", function()
        local old_tick, old_spin = UIManager.nextTick, package.loaded["ui/widget/spinwidget"]
        local pending
        UIManager.nextTick = function(_, callback)
            pending = callback
        end
        package.loaded["ui/widget/spinwidget"] = {
            new = function(_, options)
                return options
            end,
        }
        local controller = setmetatable({
            settings = Settings.withDefaults({}),
            saveSettings = function() end,
        }, { __index = ViewerController })
        controller:showPanelRefreshSettings({})
        local menu = UIManager._last_shown
        assert.is_true(menu.item_table[1].text:find("Every N panels (current: 6) | Tap here to config", 1, true) ~= nil)
        menu.item_table[1].callback()
        assert.is_nil(menu.close_callback)
        assert.is_not_nil(pending)
        pending()
        local picker = UIManager._last_shown
        assert.equals(6, picker.value)
        picker.callback({ value = 12 })
        assert.equals(12, controller.settings.panel_refresh_interval)
        assert.is_true(UIManager._last_shown.item_table[1].text:find("current: 12", 1, true) ~= nil)
        UIManager.nextTick, package.loaded["ui/widget/spinwidget"] = old_tick, old_spin
    end)

    it("refreshes at the configured interval and follows the active KOReader rate", function()
        local original_dirty, original_rate = UIManager.setDirty, UIManager.FULL_REFRESH_COUNT
        local refreshes = 0
        UIManager.setDirty = function(_, _, mode, region, dither)
            assert.equals("full", mode)
            assert.is_nil(region)
            assert.is_true(dither)
            refreshes = refreshes + 1
        end
        local viewer = setmetatable({
            panel_refresh_settings = { panel_refresh_mode = "interval", panel_refresh_interval = 2 },
        }, { __index = PanelViewer })
        viewer:refreshAfterPanelChange()
        assert.equals(0, refreshes)
        viewer:refreshAfterPanelChange()
        assert.equals(1, refreshes)
        viewer.panel_refresh_settings.panel_refresh_mode = "every"
        viewer:refreshAfterPanelChange()
        assert.equals(2, refreshes)
        viewer.panel_refresh_settings.panel_refresh_mode = "never"
        viewer:refreshAfterPanelChange()
        assert.equals(2, refreshes)
        viewer.panel_refresh_settings.panel_refresh_mode = "koreader"
        UIManager.FULL_REFRESH_COUNT = 1
        viewer:refreshAfterPanelChange()
        assert.equals(3, refreshes)
        UIManager.FULL_REFRESH_COUNT = 0
        viewer:refreshAfterPanelChange()
        assert.equals(3, refreshes)
        UIManager.setDirty, UIManager.FULL_REFRESH_COUNT = original_dirty, original_rate
    end)
end)
