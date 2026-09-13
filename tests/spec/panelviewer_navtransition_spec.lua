--[[
Panels+
File: tests/spec/panelviewer_navtransition_spec.lua
Name: PanelViewer transition specs
Description: Verifies Classic, Smooth, and Animated transition selection and options.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local PanelViewer = require("src._panelviewer")
local UIManager = require("ui/uimanager")

describe("PanelViewer nav transition hold options", function()
    local function findNavButton(viewer)
        for _, row in ipairs(viewer.button_table.buttons or {}) do
            for _, button in ipairs(row) do
                if button.id == "nav_transition" then
                    return button
                end
            end
        end
    end

    it("labels Animated mode as long-press configurable", function()
        local viewer = PanelViewer:new({ nav_transition_mode = "animated" })
        assert.equals("Nav. Animated (Long Press)", viewer:getNavTransitionText())
    end)

    it("cycles Classic, Smooth, and Animated in order", function()
        local viewer = PanelViewer:new({ nav_transition_mode = "classic" })
        viewer:replaceButtonTable()

        findNavButton(viewer).callback()
        assert.equals("smooth", viewer.nav_transition_mode)
        findNavButton(viewer).callback()
        assert.equals("animated", viewer.nav_transition_mode)
        findNavButton(viewer).callback()
        assert.equals("classic", viewer.nav_transition_mode)
    end)

    it("delegates hold to nav_transition_options_callback when provided", function()
        local options_spy = spy()
        local viewer = PanelViewer:new({
            nav_transition_mode = "smooth",
            nav_transition_options_callback = options_spy,
        })
        viewer:replaceButtonTable()

        local nav_btn = findNavButton(viewer)

        assert.is_not_nil(nav_btn)
        assert.is_not_nil(nav_btn.hold_callback)
        nav_btn.hold_callback()
        assert.is_true(options_spy:called())
    end)

    it("falls back to onShowNavTransitionOptionsMenu when options callback is nil", function()
        local viewer = PanelViewer:new({
            nav_transition_mode = "smooth",
            nav_transition_options_callback = nil,
        })
        local menu_spy = spy()
        viewer.onShowNavTransitionOptionsMenu = menu_spy
        viewer:replaceButtonTable()

        local nav_btn = findNavButton(viewer)

        assert.is_not_nil(nav_btn)
        nav_btn.hold_callback()
        assert.is_true(menu_spy:called())
    end)

    it("displays the menu with options when onShowNavTransitionOptionsMenu is invoked", function()
        local cross_page_spy = spy()
        local viewer = PanelViewer:new({
            nav_transition_mode = "smooth",
            nav_transition_cross_page = false,
            nav_transition_cross_page_callback = cross_page_spy,
        })

        assert.is_true(viewer:onShowNavTransitionOptionsMenu())
        local shown_menu = UIManager._last_shown
        assert.is_not_nil(shown_menu)
        assert.is_not_nil(shown_menu.item_table)
        assert.equals(3, #shown_menu.item_table)
    end)

    it("arms Animated mode for panel switches only when its panel option is enabled", function()
        local animation_spy = spy()
        local viewer = PanelViewer:new({
            _images_list_cur = 1,
            _images_list_nb = 2,
            nav_transition_mode = "animated",
            nav_animated_panels = true,
            panel_animation_callback = animation_spy,
        })

        viewer:onShowNextImage()
        assert.equals(1, animation_spy:callCount())
        assert.equals("next", animation_spy:lastCall()[1])

        viewer.nav_animated_panels = false
        viewer:onShowNextImage()
        assert.equals(1, animation_spy:callCount())
    end)
end)
