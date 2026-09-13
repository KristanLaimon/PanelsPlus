--[[
Panels+
File: tests/spec/viewer_controller_rotation_spec.lua
Name: ViewerController rotation specs
Description: Verifies device orientation preservation across page boundaries.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Regression coverage for preserving a chosen device orientation while
--- Panels+ crosses from the last panel of one page to the first of another.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local ViewerController = require("src.viewer_controller")

describe("ViewerController device rotation across page boundaries", function()
    local original_broadcast_event
    local original_on_rotation

    local function resetScreen()
        Screen:setRotationMode(0)
        original_broadcast_event = UIManager.broadcastEvent
        original_on_rotation = UIManager.onRotation
    end

    local function restoreUIManager()
        UIManager.broadcastEvent = original_broadcast_event
        UIManager.onRotation = original_on_rotation
    end

    it("restores the selected rotation when GotoPage resets it", function()
        resetScreen()
        Screen:setRotationMode(2)
        local broadcast_spy, rotation_spy = spy(), spy()
        UIManager.broadcastEvent = function(_, event)
            broadcast_spy(event)
            if event.name == "SetRotationMode" then
                Screen:setRotationMode(event.args[1])
            end
        end
        UIManager.onRotation = function()
            rotation_spy()
        end

        local shown_spy = spy()
        local current_viewer = {}
        local controller = setmetatable({
            ui = {
                handleEvent = function(_, event)
                    assert.equals("GotoPage", event.name)
                    -- Simulate a document/plugin rotation applied while the
                    -- normal KOReader page-change event is handled.
                    Screen:setRotationMode(0)
                end,
            },
            showPanelViewerForPage = function(_, page, panels, start_idx, options)
                shown_spy(page, panels, start_idx, options)
                return true
            end,
        }, { __index = ViewerController })

        local result = controller:commitBoundaryTransition("next", current_viewer, {
            next_page = 2,
            panels = { { x = 0, y = 0, w = 1, h = 1 } },
            start_idx = 1,
        })

        assert.is_true(result)
        assert.equals(2, Screen:getRotationMode())
        assert.equals(1, broadcast_spy:callCount())
        assert.equals("SetRotationMode", broadcast_spy:lastCall()[1].name)
        assert.equals(2, broadcast_spy:lastCall()[1].args[1])
        assert.equals(1, rotation_spy:callCount())
        assert.is_true(shown_spy:called())
        assert.equals(current_viewer, shown_spy:lastCall()[4].replace_viewer)
        assert.equals("next", shown_spy:lastCall()[4].boundary_direction)
        restoreUIManager()
    end)

    it("does not redraw when the page handoff leaves rotation unchanged", function()
        resetScreen()
        Screen:setRotationMode(3)
        local broadcast_spy, rotation_spy = spy(), spy()
        UIManager.broadcastEvent = function(_, event)
            broadcast_spy(event)
        end
        UIManager.onRotation = function()
            rotation_spy()
        end

        ViewerController.restoreDeviceRotation({}, 3)

        assert.is_false(broadcast_spy:called())
        assert.is_false(rotation_spy:called())
        restoreUIManager()
    end)
end)
