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
        assert.equals(4, #menu.item_table)
        menu.item_table[2].callback()
        assert.equals("every", controller.settings.panel_refresh_mode)
        assert.equals(controller.settings, viewer.panel_refresh_settings)
        assert.equals(0, viewer._panel_refresh_count)
        assert.equals(1, saves)
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
