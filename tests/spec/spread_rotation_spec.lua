--[[
Panels+
File: tests/spec/spread_rotation_spec.lua
Name: Spread screen rotation specs
Description: Verifies screen rotation for double-page spreads on the reading page and the hand-over to the panel viewer.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Specs for `src/spread_rotation.lua`.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local DoubleSpread = require("src._doublespread")
local MainMenu = require("src.menu")
local PanelCollector = require("src._panelcollector")
local PanelViewer = require("src._panelviewer")
local Screen = require("device").screen
local Settings = require("src._settings")
local SpreadRotation = require("src.spread_rotation")
local UIManager = require("ui/uimanager")
local ViewerController = require("src.viewer_controller")
local time = require("ui/time")

-- The shared `ui/time` mock stands still. Here every reading of the clock is ten seconds after the
-- one before, so page turns count as separate unless a spec sets the clock itself.
local clock_ms = 0
time.to_ms = function(value)
    return value
end
local function useSteppingClock()
    time.now = function()
        clock_ms = clock_ms + 10000
        return clock_ms
    end
end
local function useFixedClock(ms)
    clock_ms = ms
    time.now = function()
        return clock_ms
    end
end

local PORTRAIT_PAGE = { w = 1050, h = 1522 }
local SPREAD_PAGE = { w = 1692, h = 1200 }
local PAGES = { [1] = PORTRAIT_PAGE, [2] = SPREAD_PAGE, [3] = SPREAD_PAGE, [4] = PORTRAIT_PAGE }
local WHOLE_SPREAD = { x = 0, y = 0, w = SPREAD_PAGE.w, h = SPREAD_PAGE.h }
local INNER_PANEL = { x = 40, y = 40, w = 600, h = 500 }

--- Run `callback` with KOReader's "invert default rotation in portrait mode" set to `inverted`.
local function withPortraitInvert(inverted, callback)
    local old = _G.G_reader_settings
    _G.G_reader_settings = {
        isTrue = function(_, key)
            return inverted and key == "imageviewer_rotation_portrait_invert"
        end,
    }
    local ok, err = pcall(callback)
    _G.G_reader_settings = old
    if not ok then
        error(err, 0)
    end
end

--- Plugin stub whose `SetRotationMode` broadcasts rotate the mock screen.
---
--- @param settings table|nil Partial settings, merged over the defaults.
--- @param start_mode integer|nil Screen rotation mode to start in.
--- @return table reader Plugin stub with the spread-rotation methods mixed in.
--- @return integer[] turns Every rotation mode that was requested, in order.
local function readerFor(settings, start_mode)
    useSteppingClock()
    Screen:setRotationMode(start_mode or 0)
    local merged = Settings.withDefaults({})
    for key, value in pairs(settings or { rotate_screen_for_double_pages = true }) do
        merged[key] = value
    end
    local turns, saved = {}, {}
    local reader
    reader = setmetatable({
        settings = merged,
        saved = saved,
        spread_rotation_ready = true,
        ui = {
            paging = { current_page = 1 },
            document = {
                getNativePageDimensions = function(_, page)
                    return PAGES[page]
                end,
                getPageDimensions = function(_, page)
                    return PAGES[page]
                end,
            },
            doc_settings = {
                saveSetting = function(_, key, value)
                    saved[key] = value
                end,
            },
        },
        isEnabled = function()
            return true
        end,
    }, {
        __index = function(_, key)
            return SpreadRotation[key] or ViewerController[key]
        end,
    })
    UIManager.broadcastEvent = function(_, event)
        if event.name == "SetRotationMode" then
            table.insert(turns, event.args[1])
            Screen:setRotationMode(event.args[1])
            -- ReaderUI passes the event on to the plugin as well.
            reader:onSetRotationMode(event.args[1])
        end
    end
    return reader, turns
end

--- Simulate the user picking a rotation in KOReader's menu.
local function userTurnsScreen(reader, mode)
    Screen:setRotationMode(mode)
    reader:onSetRotationMode(mode)
end

describe("DoubleSpread.screenRotationFor", function()
    it("matches the direction the viewer rotates a spread image in", function()
        -- The viewer uses 90 (page top on the left), or 270 with the invert
        -- setting. Screen mode 1 puts the page top on the device's left edge.
        withPortraitInvert(false, function()
            assert.equals(1, DoubleSpread.screenRotationFor(0, SPREAD_PAGE.w, SPREAD_PAGE.h))
            assert.equals(3, DoubleSpread.screenRotationFor(2, SPREAD_PAGE.w, SPREAD_PAGE.h))
        end)
        withPortraitInvert(true, function()
            assert.equals(3, DoubleSpread.screenRotationFor(0, SPREAD_PAGE.w, SPREAD_PAGE.h))
        end)
    end)

    it("returns nothing for a normal page, a landscape base or a missing size", function()
        assert.is_nil(DoubleSpread.screenRotationFor(0, PORTRAIT_PAGE.w, PORTRAIT_PAGE.h))
        assert.is_nil(DoubleSpread.screenRotationFor(1, SPREAD_PAGE.w, SPREAD_PAGE.h))
        assert.is_nil(DoubleSpread.screenRotationFor(0, nil, nil))
    end)
end)

describe("Spread rotation direction", function()
    it("follows KOReader's image viewer setting unless a direction is chosen", function()
        withPortraitInvert(false, function()
            assert.equals(90, DoubleSpread.imageAngle("auto"))
            assert.equals(90, DoubleSpread.imageAngle(nil))
            assert.equals(270, DoubleSpread.imageAngle("cw"))
        end)
        withPortraitInvert(true, function()
            assert.equals(270, DoubleSpread.imageAngle("auto"))
            assert.equals(90, DoubleSpread.imageAngle("ccw"))
        end)
    end)

    it("turns the screen the same way as the image", function()
        withPortraitInvert(false, function()
            assert.equals(3, DoubleSpread.screenRotationFor(0, SPREAD_PAGE.w, SPREAD_PAGE.h, "cw"))
            assert.equals(1, DoubleSpread.screenRotationFor(0, SPREAD_PAGE.w, SPREAD_PAGE.h, "ccw"))
            assert.equals(1, DoubleSpread.screenRotationFor(2, SPREAD_PAGE.w, SPREAD_PAGE.h, "cw"))
        end)
    end)

    it("rotates the reading page in the chosen direction", function()
        local reader = readerFor({ rotate_screen_for_double_pages = true, spread_rotation_direction = "cw" })

        reader:onPageUpdate(2)

        assert.equals(3, Screen:getRotationMode())
    end)

    it("turns a rotated spread the other way when the direction changes", function()
        local reader, turns = readerFor({ rotate_screen_for_double_pages = true, spread_rotation_direction = "cw" })
        reader.ui.paging.current_page = 2
        reader:onPageUpdate(2)

        reader.settings.spread_rotation_direction = "ccw"
        reader:applySpreadRotationSetting()
        reader:onPageUpdate(4)

        assert.equals("3,1,0", table.concat(turns, ","))
    end)

    it("rotates the viewer's spread image in the chosen direction", function()
        withPortraitInvert(true, function()
            local viewer = PanelViewer:new({
                auto_rotate_double_pages = true,
                spread_rotation_direction = "ccw",
                panels = { WHOLE_SPREAD },
                panel_is_full_page = { true },
            })

            viewer:applyImageRotation(1)

            assert.equals(90, viewer.rotated)
        end)
    end)
end)

describe("SpreadRotation while pages are turned in quick succession", function()
    it("waits until the turning stops, then rotates for the page the reader stopped on", function()
        local old_schedule = UIManager.scheduleIn
        local settle
        UIManager.scheduleIn = function(_, _, action)
            settle = action
        end
        local reader, turns = readerFor()
        reader:onPageUpdate(1)
        useFixedClock(clock_ms + 200)

        reader:onPageUpdate(2)
        useFixedClock(clock_ms + 200)
        reader:onPageUpdate(3)
        assert.equals(0, #turns)
        reader.ui.paging.current_page = 3
        settle()

        UIManager.scheduleIn = old_schedule
        assert.equals("1", table.concat(turns, ","))
    end)

    it("does not rotate at all when the reader flips past a spread", function()
        local old_schedule = UIManager.scheduleIn
        local settle
        UIManager.scheduleIn = function(_, _, action)
            settle = action
        end
        local reader, turns = readerFor()
        reader:onPageUpdate(1)
        useFixedClock(clock_ms + 200)

        reader:onPageUpdate(2)
        useFixedClock(clock_ms + 200)
        reader:onPageUpdate(4)
        reader.ui.paging.current_page = 4
        settle()

        UIManager.scheduleIn = old_schedule
        assert.equals(0, #turns)
    end)

    it("rotates at once again after a pause", function()
        local reader, turns = readerFor()
        reader:onPageUpdate(1)
        useFixedClock(clock_ms + 5000)

        reader:onPageUpdate(2)

        assert.equals(1, #turns)
    end)

    it("drops a pending rotation when the document closes", function()
        local old_schedule, old_unschedule = UIManager.scheduleIn, UIManager.unschedule
        local settle, unscheduled
        UIManager.scheduleIn = function(_, _, action)
            settle = action
        end
        UIManager.unschedule = function(_, action)
            unscheduled = action
        end
        local reader = readerFor()
        reader:onPageUpdate(1)
        useFixedClock(clock_ms + 200)
        reader:onPageUpdate(2)

        reader:onCloseDocument()

        UIManager.scheduleIn, UIManager.unschedule = old_schedule, old_unschedule
        assert.equals(settle, unscheduled)
    end)
end)

describe("SpreadRotation on the reading page", function()
    it("rotates the screen on a spread and restores it on the next normal page", function()
        local reader, turns = readerFor()

        reader:onPageUpdate(3)
        assert.equals(1, Screen:getRotationMode())
        reader:onPageUpdate(4)

        assert.equals("1,0", table.concat(turns, ","))
    end)

    it("stays rotated from one spread to the next", function()
        local reader, turns = readerFor()

        reader:onPageUpdate(2)
        reader:onPageUpdate(3)

        assert.equals(1, #turns)
    end)

    it("restores the rotation the reader was in", function()
        local reader = readerFor(nil, 2)

        reader:onPageUpdate(2)
        assert.equals(3, Screen:getRotationMode())
        reader:onPageUpdate(4)

        assert.equals(2, Screen:getRotationMode())
    end)

    it("leaves a landscape screen alone", function()
        local reader, turns = readerFor(nil, 1)

        reader:onPageUpdate(2)
        reader:onPageUpdate(4)

        assert.equals(0, #turns)
    end)

    it("is off by default", function()
        local reader, turns = readerFor({})

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
    end)

    it("still rotates while panel focusing is disabled", function()
        -- "Disable plugin panel focusing" hands panel zoom back to KOReader. The reading page has
        -- nothing to do with panel zoom.
        local reader, turns = readerFor()
        reader.isEnabled = function()
            return false
        end

        reader:onPageUpdate(2)

        assert.equals(1, #turns)
    end)

    it("does nothing in continuous view, where several pages share the screen", function()
        local reader, turns = readerFor()
        reader.ui.view = { page_scroll = true }

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
    end)

    it("restores the rotation when continuous view is switched on over a rotated spread", function()
        local reader, turns = readerFor()
        reader:onPageUpdate(2)
        reader.ui.view = { page_scroll = true }

        reader:onPageUpdate(2)

        assert.equals("1,0", table.concat(turns, ","))
        assert.is_nil(reader.spread_rotation)
    end)

    it("does nothing in a reflowable document", function()
        local reader, turns = readerFor()
        reader.ui.paging = nil

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
    end)

    it("applies a changed setting to the current page", function()
        local reader, turns = readerFor({})
        reader.ui.paging.current_page = 2

        reader.settings.rotate_screen_for_double_pages = true
        reader:applySpreadRotationSetting()
        reader.settings.rotate_screen_for_double_pages = false
        reader:applySpreadRotationSetting()

        assert.equals("1,0", table.concat(turns, ","))
    end)
end)

describe("SpreadRotation while a book is opening", function()
    it("does not rotate before the reader is ready", function()
        -- KOReader sends the first PageUpdate while ReaderUI is still being built.
        local reader, turns = readerFor()
        reader.spread_rotation_ready = nil

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
        assert.is_nil(reader.spread_rotation)
    end)

    it("rotates the opening page once the reader is ready", function()
        local old_next_tick = UIManager.nextTick
        UIManager.nextTick = function(_, action)
            action()
        end
        local reader = readerFor()
        reader.spread_rotation_ready = nil
        reader.ui.paging.current_page = 2

        reader:startSpreadRotation()

        UIManager.nextTick = old_next_tick
        assert.equals(1, Screen:getRotationMode())
    end)

    it("clears its busy flag and passes the error on unchanged when the rotation request raises", function()
        local reader = readerFor()
        UIManager.broadcastEvent = function()
            error("rotation failed", 0)
        end

        local ok, err = pcall(reader.setSpreadScreenRotation, reader, 1)

        assert.is_false(ok)
        assert.equals("rotation failed", err)
        assert.is_nil(reader._spread_rotation_busy)
    end)

    it("drops the hold when the rotation request had no effect", function()
        local reader = readerFor()
        UIManager.broadcastEvent = function() end

        reader:onPageUpdate(2)

        assert.is_nil(reader.spread_rotation)
    end)

    it("restores the rotation and stops when the document closes", function()
        local reader, turns = readerFor()
        reader:onPageUpdate(2)

        reader:onCloseDocument()
        reader:onPageUpdate(3)

        assert.equals("1,0", table.concat(turns, ","))
    end)
end)

describe("SpreadRotation when the user rotates the screen", function()
    it("keeps the user's rotation on that spread", function()
        local reader, turns = readerFor()
        reader:onPageUpdate(2)

        userTurnsScreen(reader, 0)
        reader:onPageUpdate(2)

        assert.equals(0, Screen:getRotationMode())
        assert.equals(1, #turns)
    end)

    it("does not restore a rotation after the user changed it", function()
        local reader, turns = readerFor()
        reader:onPageUpdate(2)
        userTurnsScreen(reader, 3)

        reader:onPageUpdate(4)

        assert.equals(3, Screen:getRotationMode())
        assert.equals(1, #turns)
    end)

    it("rotates the next spread again", function()
        local reader = readerFor()
        reader:onPageUpdate(2)
        userTurnsScreen(reader, 0)
        reader:onPageUpdate(4)

        reader:onPageUpdate(3)

        assert.equals(1, Screen:getRotationMode())
    end)
end)

describe("SpreadRotation and the saved document rotation", function()
    it("saves the rotation the book had before the spread", function()
        local reader = readerFor()
        reader:onPageUpdate(2)

        reader:keepSpreadRotationOutOfDocSettings()

        assert.equals(0, reader.saved.kopt_rotation_mode)
    end)

    it("leaves the document settings alone when nothing is rotated", function()
        local reader = readerFor()
        reader:onPageUpdate(1)

        reader:keepSpreadRotationOutOfDocSettings()

        assert.is_nil(reader.saved.kopt_rotation_mode)
    end)
end)

describe("SpreadRotation and the panel viewer", function()
    it("does nothing while a viewer is open", function()
        local reader, turns = readerFor()
        reader.active_panel_viewer = {}

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
    end)

    it("keeps the rotated screen for a viewer that only shows the whole spread", function()
        local reader, turns = readerFor()
        reader:onPageUpdate(2)

        reader:prepareSpreadRotationForViewer(2, { WHOLE_SPREAD })

        assert.equals(1, #turns)
    end)

    it("restores the rotation for a viewer that shows panels of the spread", function()
        local reader = readerFor()
        reader:onPageUpdate(2)

        reader:prepareSpreadRotationForViewer(2, { INNER_PANEL, WHOLE_SPREAD })

        assert.equals(0, Screen:getRotationMode())
        assert.is_nil(reader.spread_rotation)
    end)

    it("restores the rotation before a viewer opens on a normal page", function()
        local reader = readerFor()
        reader:onPageUpdate(3)

        reader:prepareSpreadRotationForViewer(4, { INNER_PANEL })

        assert.equals(0, Screen:getRotationMode())
    end)

    it("handles the current page after the viewer has closed", function()
        local old_next_tick = UIManager.nextTick
        UIManager.nextTick = function(_, action)
            action()
        end
        local reader = readerFor()
        local viewer = { _panels_plus_closed = true }
        reader.active_panel_viewer = viewer
        reader.ui.paging.current_page = 2

        reader:onPanelViewerClosed(viewer)

        UIManager.nextTick = old_next_tick
        assert.is_nil(reader.active_panel_viewer)
        assert.equals(1, Screen:getRotationMode())
    end)

    it("ignores the close of a viewer that was replaced", function()
        local reader, turns = readerFor()
        local new_viewer = {}
        reader.active_panel_viewer = new_viewer
        reader.ui.paging.current_page = 2

        reader:onPanelViewerClosed({ _panels_plus_closed = true })

        assert.equals(new_viewer, reader.active_panel_viewer)
        assert.equals(0, #turns)
    end)
end)

describe("SpreadRotation wiring", function()
    it("restores the rotation before the controller builds a viewer for a normal page", function()
        local old_build, old_new, old_show = PanelCollector.buildImages, PanelViewer.new, UIManager.show
        local rotation_when_built, options_seen, viewer = nil, nil, {}
        PanelCollector.buildImages = function(_, _, panels)
            rotation_when_built = Screen:getRotationMode()
            return { {} }, panels, { true }
        end
        PanelViewer.new = function(_, options)
            options_seen = options
            return viewer
        end
        UIManager.show = function() end
        local reader = readerFor()
        reader:onPageUpdate(3)

        local ok, err = pcall(reader.showPanelViewerForPage, reader, 4, { INNER_PANEL }, 1, { defer_preload = true })

        PanelCollector.buildImages, PanelViewer.new, UIManager.show = old_build, old_new, old_show
        assert.is_true(ok, tostring(err))
        assert.equals(0, rotation_when_built)
        assert.equals(viewer, reader.active_panel_viewer)
        viewer._panels_plus_closed = true
        options_seen.closed_callback(viewer)
        assert.is_nil(reader.active_panel_viewer)
    end)

    it("tells the viewer's owner when it has closed", function()
        local closed_viewer
        local viewer = PanelViewer:new({
            closed_callback = function(v)
                closed_viewer = v
            end,
        })

        viewer:onCloseWidget()

        assert.equals(viewer, closed_viewer)
    end)

    it("applies the setting from the plugin's setter, reader-ready and save hooks", function()
        local PanelsPlus = require("main")
        local old_next_tick = UIManager.nextTick
        UIManager.nextTick = function(_, action)
            action()
        end
        local reader = readerFor({})
        local plugin = setmetatable({
            settings = reader.settings,
            ui = reader.ui,
            saveSettings = function() end,
            saveDocSettings = function() end,
            loadDocSettings = function() end,
            applyPanelGesture = function() end,
        }, { __index = PanelsPlus })
        plugin.ui.paging.current_page = 2

        plugin:onReaderReady()
        assert.equals(0, Screen:getRotationMode())
        plugin:setSpreadRotationMode("both")
        assert.equals(1, Screen:getRotationMode())
        assert.is_true(plugin.settings.auto_rotate_double_pages)
        plugin:onSaveSettings()

        UIManager.nextTick = old_next_tick
        assert.equals(0, reader.saved.kopt_rotation_mode)
    end)
end)

describe("Double-page spread settings in the menus", function()
    local function findItem(items, text)
        for _, item in ipairs(items) do
            if item.text and item.text:find(text, 1, true) then
                return item
            end
        end
    end

    it("offers one main-menu entry with four choices", function()
        local chosen
        local menu_items = {}
        local plugin = {
            settings = Settings.withDefaults({}),
            getModeText = function()
                return "Panels+"
            end,
            setSpreadRotationMode = function(_, mode)
                chosen = mode
            end,
        }
        plugin.getSpreadRotationMode = MainMenu.getSpreadRotationMode
        MainMenu.addToMainMenu(plugin, menu_items)
        local entry = findItem(menu_items.panels_plus.sub_item_table, "Auto-rotate double-page spreads")
        local choices = entry.sub_item_table

        assert.equals(4, #choices)
        assert.equals("Off", choices[1].text)
        assert.equals("In the panel viewer", choices[2].text)
        assert.equals("While reading", choices[3].text)
        assert.equals("In the panel viewer and while reading", choices[4].text)
        assert.is_true(choices[2].checked_func())
        assert.is_false(choices[1].checked_func())
        choices[3].callback()

        assert.equals("reading", chosen)
    end)

    it("offers the direction in the main menu and in the viewer's settings", function()
        local chosen
        local menu_items = {}
        MainMenu.addToMainMenu({
            settings = Settings.withDefaults({}),
            getModeText = function()
                return "Panels+"
            end,
            getSpreadRotationMode = MainMenu.getSpreadRotationMode,
            setSpreadRotationDirection = function(_, direction)
                chosen = direction
            end,
        }, menu_items)
        local entry = findItem(menu_items.panels_plus.sub_item_table, "Spread rotation direction")
        local choices = entry.sub_item_table

        assert.equals("Same as KOReader's image viewer", choices[1].text)
        assert.equals("Clockwise", choices[2].text)
        assert.equals("Counter-clockwise", choices[3].text)
        assert.is_true(choices[1].checked_func())
        choices[2].callback()
        assert.equals("cw", chosen)

        local reader = readerFor({})
        reader.setSpreadRotationDirection = function(self, direction)
            self.settings.spread_rotation_direction = direction
        end
        reader:showMoreConfigMenu({ page = 1 })
        local item = findItem(UIManager._last_shown.item_table, "[Rotation]: Spread direction")
        assert.equals("[Rotation]: Spread direction (Actual: KOReader)", item.text)
        item.callback()
        assert.equals("cw", reader.settings.spread_rotation_direction)
    end)

    it("reads the mode from the two settings", function()
        local function mode(viewer, screen)
            return MainMenu.getSpreadRotationMode({
                settings = { auto_rotate_double_pages = viewer, rotate_screen_for_double_pages = screen },
            })
        end

        assert.equals("viewer", mode(nil, nil))
        assert.equals("off", mode(false, false))
        assert.equals("both", mode(true, true))
        assert.equals("reading", mode(false, true))
    end)

    it("steps through the four choices from the viewer's settings", function()
        local reader = readerFor({})
        reader.getSpreadRotationMode = MainMenu.getSpreadRotationMode
        reader.setSpreadRotationMode = function(self, mode)
            self.settings.auto_rotate_double_pages = mode == "viewer" or mode == "both"
            self.settings.rotate_screen_for_double_pages = mode == "reading" or mode == "both"
        end
        local seen = {}
        for _ = 1, 4 do
            reader:showMoreConfigMenu({ page = 1 })
            local item = findItem(UIManager._last_shown.item_table, "[Rotation]: Rotate spreads")
            table.insert(seen, item.text)
            item.callback()
        end

        assert.equals("[Rotation]: Rotate spreads (Actual: Viewer)", seen[1])
        assert.equals("[Rotation]: Rotate spreads (Actual: Reading)", seen[2])
        assert.equals("[Rotation]: Rotate spreads (Actual: Viewer + reading)", seen[3])
        assert.equals("[Rotation]: Rotate spreads (Actual: Off)", seen[4])
    end)

    it("rebuilds the viewer when the viewer setting changes on a spread", function()
        local reader = readerFor({})
        local rebuilt
        reader.setAutoRotateDoublePages = function(self, enabled)
            self.settings.auto_rotate_double_pages = enabled
        end
        reader.showPanelViewerForPage = function(_, page, _, index, options)
            rebuilt = { page = page, index = index, options = options }
            return { page = page }
        end
        local viewer = { page = 2, panels = { WHOLE_SPREAD }, panel_is_full_page = { true }, _images_list_cur = 1 }

        reader.getSpreadRotationMode = MainMenu.getSpreadRotationMode
        reader.setSpreadRotationMode = function(self, mode)
            self.settings.auto_rotate_double_pages = mode == "viewer" or mode == "both"
            self.settings.rotate_screen_for_double_pages = mode == "reading" or mode == "both"
        end
        reader.settings.rotate_screen_for_double_pages = true
        local shown = reader:cycleViewerSpreadRotationMode(viewer)

        assert.is_false(reader.settings.auto_rotate_double_pages)
        assert.equals(2, rebuilt.page)
        assert.is_true(rebuilt.options.return_viewer)
        assert.equals(2, shown.page)
    end)

    it("rebuilds the viewer on an ordinary panel too, so a change always shows at once", function()
        local reader = readerFor({})
        reader.setAutoRotateDoublePages = function(self, enabled)
            self.settings.auto_rotate_double_pages = enabled
        end
        local rebuilt_index
        reader.showPanelViewerForPage = function(_, page, _, index)
            rebuilt_index = index
            return { page = page }
        end
        local viewer = {
            page = 1,
            panels = { INNER_PANEL, INNER_PANEL },
            panel_is_full_page = { false, false },
            _images_list_cur = 2,
        }

        reader.getSpreadRotationMode = MainMenu.getSpreadRotationMode
        reader.setSpreadRotationMode = function(self, mode)
            self.settings.auto_rotate_double_pages = mode == "viewer" or mode == "both"
            self.settings.rotate_screen_for_double_pages = mode == "reading" or mode == "both"
        end
        reader.settings.rotate_screen_for_double_pages = true
        local shown = reader:cycleViewerSpreadRotationMode(viewer)

        assert.equals(2, rebuilt_index)
        assert.equals(1, shown.page)
    end)
end)

describe("Spread rotation switched off from an open viewer", function()
    it("restores a screen that was rotated for the spread, before the viewer is rebuilt", function()
        local old_build, old_new, old_show, old_close =
            PanelCollector.buildImages, PanelViewer.new, UIManager.show, UIManager.close
        local rotation_when_built
        PanelCollector.buildImages = function(_, _, panels)
            rotation_when_built = Screen:getRotationMode()
            return { {} }, panels, { true }
        end
        PanelViewer.new = function(_, options)
            return { closed_callback = options.closed_callback }
        end
        UIManager.show = function() end
        UIManager.close = function(_, widget)
            if widget.closed_callback then
                widget._panels_plus_closed = true
                widget.closed_callback(widget)
            end
        end
        local reader = readerFor({ rotate_screen_for_double_pages = true })
        reader.preloadNextPanels = function() end
        reader.setSpreadRotationMode = function(self, mode)
            self.settings.auto_rotate_double_pages = mode == "viewer" or mode == "both"
            self.settings.rotate_screen_for_double_pages = mode == "reading" or mode == "both"
            self:applySpreadRotationSetting()
        end
        reader.ui.paging.current_page = 2
        reader:onPageUpdate(2)
        local ok, err = pcall(function()
            local viewer = reader:showPanelViewerForPage(
                2,
                { WHOLE_SPREAD },
                1,
                { defer_preload = true, return_viewer = true }
            )
            assert.equals(1, Screen:getRotationMode())
            viewer.page, viewer.panels, viewer.panel_is_full_page = 2, { WHOLE_SPREAD }, { true }

            -- "both" steps to "off"
            reader:cycleViewerSpreadRotationMode(viewer)
        end)

        PanelCollector.buildImages, PanelViewer.new, UIManager.show, UIManager.close =
            old_build, old_new, old_show, old_close
        assert.is_true(ok, tostring(err))
        assert.equals("off", DoubleSpread.rotationMode(reader.settings))
        assert.equals(0, rotation_when_built)
        assert.equals(0, Screen:getRotationMode())
    end)
end)
