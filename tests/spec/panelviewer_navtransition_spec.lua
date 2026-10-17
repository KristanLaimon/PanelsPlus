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

describe("PanelViewer panel finding button", function()
    local function button(viewer)
        for _, row in ipairs(viewer.button_table.buttons or {}) do
            for _, item in ipairs(row) do
                if item.id == "panel_finding" then
                    return item
                end
            end
        end
    end

    it("shows the selected mode in the middle of the bottom row and cycles on tap", function()
        local viewer = PanelViewer:new({})
        viewer:replaceButtonTable()
        assert.equals("settings_profile", viewer.button_table.buttons[2][2].id)
        assert.equals("panel_finding", viewer.button_table.buttons[2][3].id)
        assert.equals("Panels Finding: Safe", button(viewer).text)
        button(viewer).callback()
        assert.equals("smart", viewer.panel_finding_mode)
        assert.equals("Panels Finding: Smart", button(viewer).text)
        button(viewer).callback()
        assert.equals("safe", viewer.panel_finding_mode)
    end)
end)

-- Exercise the real transition dispatch with bounded fake bitmap allocations.
describe("PanelViewer large-to-small smooth navigation", function()
    local Blitbuffer = require("ffi/blitbuffer")
    local RenderImage = require("ui/renderimage")
    local Memory = require("src._memory")
    local PageRender = require("src._pagerender")

    local function withTransition(options, check)
        local old_draw = PageRender.drawPagePart
        local old_new = Blitbuffer.new
        local old_scale = RenderImage.scaleBlitBuffer
        local old_headroom = Memory.hasHeadroom
        local old_allocation = Memory.hasAllocationHeadroom
        local buffers, frames, blits = {}, {}, {}
        local source
        Blitbuffer.new = function(w, h, kind)
            local bb = old_new(w, h, kind)
            bb.getWidth = function()
                return w
            end
            bb.getHeight = function()
                return h
            end
            bb.free = function(self)
                self.frees = (self.frees or 0) + 1
            end
            bb.blitFrom = function(_, _, _, _, sx, sy, bw, bh)
                blits[#blits + 1] = { sx = sx, sy = sy, w = bw, h = bh }
            end
            bb.copy = function()
                return Blitbuffer.new(w, h, kind)
            end
            buffers[#buffers + 1] = bb
            return bb
        end
        RenderImage.scaleBlitBuffer = function(_, _, w, h)
            if options.fail_scale then
                error("scale failed")
            end
            return Blitbuffer.new(w, h, 0)
        end
        Memory.hasHeadroom = function()
            return not options.low_memory
        end
        Memory.hasAllocationHeadroom = function()
            return not options.low_memory
        end
        local viewer = PanelViewer:new({
            _images_list_cur = 1,
            image_rects = options.rects or {
                { x = 0, y = 0, w = 600, h = 800 },
                { x = 650, y = 300, w = 60, h = 80 },
            },
            nav_transition_frames = 4,
            nav_transition_duration = 0.4,
            image_disposable = true,
            crop_mode = options.margin and "margin" or "tight",
            margin_ratio = 0.2,
            image_union_renderer = function(union, zoom)
                source = Blitbuffer.new(math.ceil(union.w * zoom), math.ceil(union.h * zoom), 0)
                return source
            end,
        })
        if options.cached_source then
            local render = viewer.image_union_renderer
            viewer.image_union_renderer = nil
            PageRender.drawPagePart = function(_, _, union)
                return render(union, math.min(600 / union.w, 800 / union.h))
            end
        end
        viewer.shouldAutoRotateDoublePage = function()
            return false
        end
        viewer.isOpen = function()
            return not options.closed
        end
        viewer.releasePreviousPanelImage = function(_, image)
            if image then
                image:free()
            end
        end
        viewer.update = function(self)
            frames[#frames + 1] = { image = self.image, margin = self:getMarginShrinkFactor() }
        end
        viewer.switchToImageNum = function(self, target)
            self.switched_to = target
            self._images_list_cur = target
        end
        viewer.runNavPanAnimation = function(self)
            self.used_canvas_pan = true
        end
        local ok, err = pcall(function()
            check(viewer, buffers, frames, blits, function()
                return source
            end)
        end)
        PageRender.drawPagePart = old_draw
        Blitbuffer.new = old_new
        RenderImage.scaleBlitBuffer = old_scale
        Memory.hasHeadroom = old_headroom
        Memory.hasAllocationHeadroom = old_allocation
        if not ok then
            error(err)
        end
    end

    it("animates a tiny destination with screen-sized frames and releases its source", function()
        withTransition({}, function(viewer, buffers, frames, blits, source)
            viewer:animateSwitchToImageNum(2)
            assert.is_true(viewer._panels_plus_transition_active)
            assert.is_nil(viewer.switched_to)
            for _ = 1, 4 do
                UIManager._last_scheduled()
            end
            assert.equals(2, viewer.switched_to)
            assert.equals(5, #frames)
            assert.equals(1, source().frees)
            assert.is_nil(viewer._panels_plus_transition_cleanup)
            for _, bb in ipairs(buffers) do
                assert.is_true(bb.w <= 600 and bb.h <= 800, "all allocations stay within screen dimensions")
                assert.is_true((bb.frees or 0) <= 1)
            end
            assert.is_true(blits[1].sx ~= blits[#blits].sx, "the camera moves toward the destination")
            assert.is_true(blits[1].w > blits[#blits].w, "the camera zooms toward the small panel")
        end)
    end)

    it("copies cache-owned document pixels before scheduling frames", function()
        withTransition({ cached_source = true }, function(viewer, buffers, _, _, source)
            viewer:animateSwitchToImageNum(2)
            assert.is_true(viewer._panels_plus_transition_active)
            for _ = 1, 4 do
                UIManager._last_scheduled()
            end
            assert.equals(2, viewer.switched_to)
            assert.is_nil(source().frees, "DocCache retains ownership of the source")
            assert.equals(1, buffers[2].frees, "the private animation copy is released")
        end)
    end)

    it("preserves margin framing on every bounded frame", function()
        withTransition({ margin = true }, function(viewer, _, frames)
            viewer:animateSwitchToImageNum(2)
            for _ = 1, 4 do
                UIManager._last_scheduled()
            end
            for _, frame in ipairs(frames) do
                assert.equals(480, frame.image.w)
                assert.equals(640, frame.image.h)
                assert.near(0.8, frame.margin, 0.0001)
            end
            assert.is_nil(viewer._panels_plus_transition_margin_factor)
        end)
    end)

    it("keeps the shared-canvas pan for similar-sized and small-to-large moves", function()
        for _, rects in ipairs({
            { { x = 0, y = 0, w = 300, h = 400 }, { x = 320, y = 0, w = 300, h = 400 } },
            { { x = 650, y = 300, w = 60, h = 80 }, { x = 0, y = 0, w = 600, h = 800 } },
        }) do
            withTransition({ rects = rects }, function(viewer)
                viewer:animateSwitchToImageNum(2)
                assert.is_true(viewer.used_canvas_pan)
            end)
        end
    end)

    it("still switches instantly when memory is low", function()
        withTransition({ low_memory = true }, function(viewer, buffers)
            viewer:animateSwitchToImageNum(2)
            assert.equals(2, viewer.switched_to)
            assert.equals(0, #buffers)
        end)
    end)

    it("releases temporary crops and the source if scaling fails", function()
        withTransition({ fail_scale = true }, function(viewer, buffers)
            viewer:animateSwitchToImageNum(2)
            assert.equals(2, viewer.switched_to)
            assert.is_nil(viewer._panels_plus_transition_active)
            for _, bb in ipairs(buffers) do
                assert.equals(1, bb.frees)
            end
        end)
    end)

    it("releases the retained source when the viewer closes during a pan", function()
        withTransition({ closed = true }, function(viewer, _, _, _, source)
            viewer:animateSwitchToImageNum(2)
            UIManager._last_scheduled()
            assert.equals(1, source().frees)
            assert.is_nil(viewer._panels_plus_transition_active)
            assert.is_nil(viewer.switched_to)
        end)
    end)
end)
