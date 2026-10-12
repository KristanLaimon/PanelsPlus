local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local Toolbar = require("src._quicktoolbar")
local ImageViewer = require("ui/widget/imageviewer")
local Screen = require("device").screen

-- Model KOReader's child-first event propagation, including the second dispatch
-- of named events after GestureRange matching (generic Tap skips that matching).
local function withRail(width, height, callback, horizontal)
    local saved = {}
    local Widget = {}
    function Widget:extend(value)
        return setmetatable(value, { __index = self })
    end
    function Widget:new(value)
        value = self:extend(value)
        value.ges_events = {}
        if value.init then
            value:init()
        end
        return value
    end
    function Widget:getSize()
        return { w = self.width or 40, h = self.height or 12 }
    end
    function Widget:handleEvent(name, gesture)
        for _, child in ipairs(self) do
            if child:handleEvent(name, gesture) then
                return true
            end
        end
        local handler = self["on" .. name]
        if handler then
            return handler(self, nil, gesture)
        end
    end
    function Widget:onGesture(_, gesture)
        for name, ranges in pairs(self.ges_events) do
            local range = ranges[1]
            local rect, pos = range.range, gesture.pos
            if
                range.ges == gesture.ges
                and pos.x >= rect.x
                and pos.x < rect.x + rect.w
                and pos.y >= rect.y
                and pos.y < rect.y + rect.h
            then
                return self:handleEvent(name, gesture)
            end
        end
    end
    local modules = {
        ["ui/widget/container/inputcontainer"] = Widget,
        ["ui/widget/container/centercontainer"] = Widget,
        ["ui/widget/verticalgroup"] = Widget,
        ["ui/widget/horizontalgroup"] = Widget,
        ["ui/widget/iconwidget"] = Widget,
        ["ui/widget/textwidget"] = Widget,
        ["ui/gesturerange"] = Widget,
        ["ui/font"] = { getFace = function() end },
    }
    for name, value in pairs(modules) do
        saved[name] = { package.loaded[name] }
        package.loaded[name] = value
    end
    local old_scale = Screen.scaleBySize
    Screen.scaleBySize = function(_, value)
        return value
    end
    local ok, err = pcall(function()
        local calls, actions = {}, {}
        for _, id in ipairs(Toolbar.order) do
            actions[id] = {
                text = id,
                callback = function()
                    calls[id] = (calls[id] or 0) + 1
                end,
            }
        end
        local rail = Toolbar.build(Toolbar.controls(actions), width, height, horizontal)
        for index, tile in ipairs(rail) do
            tile.dimen.x = 600 - width
            tile.dimen.y = (index - 1) * tile.height
        end
        callback(rail, calls)
    end)
    Screen.scaleBySize = old_scale
    for name, value in pairs(saved) do
        package.loaded[name] = value[1]
    end
    if not ok then
        error(err)
    end
end

describe("Panel viewer compact controls", function()
    it("lets center taps hide controls without closing the viewer or opening rotation", function()
        withRail(72, 420, function(rail, calls)
            local viewer = PanelViewer:new({
                buttons_visible = true,
                update = function() end,
                onClose = function()
                    error("Center tap must not close Panels+")
                end,
            })
            local center = { ges = "tap", pos = { x = 300, y = 200 } }
            assert.is_nil(rail:handleEvent("Gesture", center))
            assert.is_nil(rail:handleEvent("Tap", center))
            assert.is_true(viewer:onTap(nil, center))
            assert.is_false(viewer.buttons_visible)
            assert.is_nil(calls.rotate)
            assert.is_true(viewer:onTap(nil, center))
            assert.is_true(viewer.buttons_visible)
            for index, id in ipairs(Toolbar.order) do
                local tile = rail[index]
                assert.is_true(rail:handleEvent("Gesture", {
                    ges = "tap",
                    pos = { x = tile.dimen.x + 10, y = tile.dimen.y + 10 },
                }))
                assert.equals(1, calls[id])
            end
            assert.is_nil(rail:handleEvent("Hold", center))
            assert.is_nil(rail:handleEvent("HoldRelease", center))
        end)
    end)

    it("uses larger icons while fitting captions inside compact tiles", function()
        withRail(72, 420, function(rail)
            assert.equals(40, rail[1][1][1][1].width)
        end)
        withRail(52, 160, function(rail)
            for _, tile in ipairs(rail) do
                local content = tile[1][1]
                assert.is_true(content[1].height + content[2]:getSize().h <= tile.height)
            end
        end)
    end)

    it("fits five borderless actions in one compact portrait row", function()
        for _, width in ipairs({ 600, 240 }) do
            withRail(width, 64, function(rail)
                local row_width = 0
                for index, tile in ipairs(rail) do
                    assert.equals(Toolbar.order[index], tile.control.id)
                    assert.equals(64, tile.height)
                    row_width = row_width + tile.width
                end
                assert.is_true(row_width <= width)
            end, true)
        end
    end)

    it("places settings in two rows of three and Close across the bottom", function()
        local viewer = PanelViewer:new({ width = 600 })
        viewer:replaceButtonTable()
        local rows = viewer.button_table.buttons
        assert.equals(3, #rows)
        assert.equals(3, #rows[1])
        assert.equals("mode", rows[1][1].id)
        assert.equals("nav_transition", rows[1][2].id)
        assert.equals("crop", rows[1][3].id)
        assert.equals(3, #rows[2])
        assert.equals("more_config", rows[2][1].id)
        assert.equals("settings_profile", rows[2][2].id)
        assert.equals("panel_finding", rows[2][3].id)
        assert.equals(1, #rows[3])
        assert.equals("close", rows[3][1].id)
        for _, id in ipairs(Toolbar.order) do
            assert.is_not_nil(viewer.quick_controls[id])
            assert.is_true(viewer.quick_controls[id].icon_file:match("%.svg$") ~= nil)
        end
    end)

    it("keeps base scale/rotation relabeling compatible with icon controls", function()
        local viewer = PanelViewer:new({ width = 600, _scale_to_fit = true, progress_bar_visible = false })
        viewer:replaceButtonTable()
        local scale = viewer.button_table:getButtonById("scale")
        assert.equals("1:1", scale.text)
        scale:setText("Scale")
        assert.equals("Fit", scale.text)
        local rotate = viewer.button_table:getButtonById("rotate")
        rotate:setText("No rotation")
        assert.equals("Rotate", rotate.text)
        assert.equals("Show", viewer.quick_controls.progress_bar.text)
    end)

    it("dispatches rail actions and retains long-press settings on navigation and crop", function()
        local selected = {}
        local viewer = PanelViewer:new({
            width = 600,
            nav_transition_mode = "smooth",
            crop_mode = "margin",
            ocr_language_callback = function()
                selected.ocr = true
            end,
            progress_bar_toggle_callback = function()
                selected.progress = true
            end,
            nav_transition_options_callback = function()
                selected.nav = true
            end,
            onOpenRotationPicker = function()
                selected.rotate = true
            end,
            onSaveImageView = function()
                selected.screenshot = true
            end,
            onAdjustMarginRatio = function()
                selected.crop = true
            end,
        })
        viewer:replaceButtonTable()
        for _, id in ipairs({ "rotate", "ocr_language", "screenshot", "progress_bar" }) do
            viewer.quick_controls[id].callback()
        end
        viewer.button_table.buttons[1][2].hold_callback()
        viewer.button_table.buttons[1][3].hold_callback()
        for _, name in ipairs({ "rotate", "ocr", "screenshot", "progress", "nav", "crop" }) do
            assert.is_true(selected[name])
        end
    end)

    it("reserves rail width only while controls are visible, preserving margin and rotation", function()
        local old_new, old_build, old_scale = ImageViewer._new_image_wg, Toolbar.build, Screen.scaleBySize
        local old_group = package.loaded["ui/widget/horizontalgroup"]
        Screen.scaleBySize = function(_, value)
            return value
        end
        package.loaded["ui/widget/horizontalgroup"] = {
            new = function(_, value)
                return value
            end,
        }
        Toolbar.build = function(_, width, height)
            return { width = width, height = height }
        end
        ImageViewer._new_image_wg = function(self)
            self._image_wg = { width = self.width, height = self.img_container_h }
            self.image_container = { dimen = { w = self.width, h = self.img_container_h } }
        end
        local viewer = PanelViewer:new({
            width = 600,
            height = 400,
            img_container_h = 420,
            buttons_visible = true,
            crop_mode = "margin",
            margin_ratio = 0.2,
            panel_is_full_page = { false },
            _images_list_cur = 1,
            rotated = 180,
        })
        viewer:replaceButtonTable()
        viewer:_new_image_wg()
        local visible_container, visible_image = viewer.image_container, viewer._image_wg
        viewer.buttons_visible = false
        viewer:_new_image_wg()
        local hidden_container, hidden_image = viewer.image_container, viewer._image_wg
        ImageViewer._new_image_wg, Toolbar.build, Screen.scaleBySize = old_new, old_build, old_scale
        package.loaded["ui/widget/horizontalgroup"] = old_group
        assert.equals(600, viewer.width)
        assert.equals(528, visible_container[1].dimen.w)
        assert.equals(72, visible_container[2].width)
        assert.equals(420, visible_container[2].height)
        assert.near(528 * 0.8, visible_image.width, 0.001)
        assert.equals(180, visible_image.rotation_angle)
        assert.equals(600, hidden_container.dimen.w)
        assert.near(600 * 0.8, hidden_image.width, 0.001)
        assert.is_nil(viewer.quick_rail)
    end)

    it("places the portrait icon row below the full-width panel and removes it when hidden", function()
        local old_new, old_build, old_scale = ImageViewer._new_image_wg, Toolbar.build, Screen.scaleBySize
        local old_group = package.loaded["ui/widget/verticalgroup"]
        package.loaded["ui/widget/verticalgroup"] = {
            new = function(_, value)
                return value
            end,
        }
        Screen.scaleBySize = function(_, value)
            return value
        end
        Toolbar.build = function(_, width, height, horizontal)
            return { width = width, height = height, horizontal = horizontal }
        end
        ImageViewer._new_image_wg = function(self)
            self._image_wg = { width = self.width, height = self.img_container_h }
            self.image_container = { dimen = { w = self.width, h = self.img_container_h } }
        end
        local viewer = PanelViewer:new({ width = 600, height = 800, img_container_h = 500, buttons_visible = true })
        viewer:replaceButtonTable()
        viewer:_new_image_wg()
        local visible, rail = viewer.image_container, viewer.quick_rail
        viewer.buttons_visible = false
        viewer:_new_image_wg()
        ImageViewer._new_image_wg, Toolbar.build, Screen.scaleBySize = old_new, old_build, old_scale
        package.loaded["ui/widget/verticalgroup"] = old_group
        assert.equals(600, visible[1].dimen.w)
        assert.equals(436, visible[1].dimen.h)
        assert.equals(600, visible[2].dimen.w)
        assert.equals(64, visible[2].dimen.h)
        assert.is_true(rail.horizontal)
        assert.equals(rail, visible[2][1])
        assert.equals(600, viewer.image_container.dimen.w)
        assert.equals(500, viewer.image_container.dimen.h)
        assert.equals(500, viewer.img_container_h)
        assert.is_nil(viewer.quick_rail)
    end)
end)
