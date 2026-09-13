--[[
Panels+
File: tests/spec/panelviewer_margin_spec.lua
Name: PanelViewer margin specs
Description: Verifies margin factors during local and cross-page smooth transitions.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Margin framing is normally based on the displayed panel. Smooth navigation
--- temporarily displays a transition canvas while the current index still
--- names the source panel, so its target lookup must be index-specific.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local PanelViewer = require("src._panelviewer")

describe("PanelViewer margin factors", function()
    it("uses the landing panel's margin factor during a smooth transition", function()
        local viewer = PanelViewer:new({
            crop_mode = "margin",
            margin_ratio = 0.2,
            _images_list_cur = 1,
            panel_is_full_page = { true, false },
        })

        assert.is_nil(viewer:getMarginShrinkFactor(), "the current splash panel must not be shrunk")
        assert.near(0.8, viewer:getMarginShrinkFactorForPanel(2), 0.0001)

        viewer._panels_plus_transition_margin_factor = viewer:getMarginShrinkFactorForPanel(2)
        assert.near(0.8, viewer:getMarginShrinkFactor(), 0.0001)
    end)

    it("does not shrink a full-page landing panel", function()
        local viewer = PanelViewer:new({
            crop_mode = "margin",
            margin_ratio = 0.2,
            _images_list_cur = 1,
            panel_is_full_page = { false, true },
        })

        assert.near(0.8, viewer:getMarginShrinkFactor(), 0.0001)
        assert.is_nil(viewer:getMarginShrinkFactorForPanel(2))
    end)

    it("accepts an adjacent page's explicit full-page flag", function()
        local viewer = PanelViewer:new({
            crop_mode = "margin",
            margin_ratio = 0.2,
            panel_is_full_page = { false },
        })

        assert.is_nil(viewer:getMarginShrinkFactorForPanel(nil, true))
        assert.near(0.8, viewer:getMarginShrinkFactorForPanel(nil, false), 0.0001)
    end)
end)
