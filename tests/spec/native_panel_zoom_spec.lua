--[[
Panels+
File: tests/spec/native_panel_zoom_spec.lua
Name: Native panel zoom specs
Description: Verifies the patched reflow-image hold hook and KOReader fallback behavior.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Regression coverage for the reflow-document hold hook.
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local NativePanelZoom = require("src.native_panel_zoom")

describe("NativePanelZoom embedded-image hold hook", function()
    it("opens Panels+ first and preserves KOReader's image/text fallback", function()
        local native_hold = spy()
        native_hold.return_value = "native"
        local native_zoom = spy()
        local highlight = {
            onHold = native_hold,
            onPanelZoom = native_zoom,
        }
        local plugin = {
            ui = { highlight = highlight },
            enabled = true,
            embedded_result = true,
            settings = { panel_gesture = "hold" },
        }
        setmetatable(plugin, { __index = NativePanelZoom })
        function plugin:isEnabled()
            return self.enabled
        end
        function plugin:showEmbeddedImagePanels()
            return self.embedded_result
        end

        NativePanelZoom.patchNativePanelZoom(plugin)
        assert.is_true(highlight:onHold(nil, { pos = {} }))
        assert.equals(0, native_hold:callCount(), "Panels+ should consume a detected embedded image")

        plugin.embedded_result = false
        assert.equals("native", highlight:onHold(nil, { pos = {} }))
        assert.equals(1, native_hold:callCount(), "text and unsupported images must fall back to KOReader")

        NativePanelZoom.restoreNativePanelZoom(plugin)
        assert.equals(native_hold, highlight.onHold)
        assert.equals(native_zoom, highlight.onPanelZoom)
    end)

    it("restores KOReader panel-zoom settings when switching to two-finger tap", function()
        local highlight = {
            panel_zoom_enabled = false,
            panel_zoom_fallback_to_text_selection = true,
        }
        local plugin = {
            ui = { highlight = highlight, paging = true },
            settings = { panel_gesture = "hold" },
        }
        setmetatable(plugin, { __index = NativePanelZoom })

        plugin:onReadSettings()
        assert.is_true(highlight.panel_zoom_enabled)
        assert.is_false(highlight.panel_zoom_fallback_to_text_selection)

        plugin.settings.panel_gesture = "two_finger_tap"
        plugin:applyPanelGesture()
        assert.is_false(highlight.panel_zoom_enabled)
        assert.is_true(highlight.panel_zoom_fallback_to_text_selection)
    end)
end)
