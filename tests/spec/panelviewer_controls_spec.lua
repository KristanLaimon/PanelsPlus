local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local Toolbar = require("src._quicktoolbar")
local ImageViewer = require("ui/widget/imageviewer")
local Screen = require("device").screen

-- Model KOReader's child-first event propagation, including the second dispatch
-- of named events after GestureRange matching (generic Tap skips that matching).
local function withRail(width, height, callback, horizontal, dim_ocr, captions)
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
    function Widget:free() end
    local TextBox = Widget:extend({})
    function TextBox:init()
        self.height = math.max(1, math.ceil(#self.text * 6 / self.width)) * 12
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
        ["ui/widget/textboxwidget"] = TextBox,
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
                dim = id == "ocr_language" and dim_ocr or false,
                callback = function()
                    calls[id] = (calls[id] or 0) + 1
                end,
            }
        end
        local controls = Toolbar.controls(actions)
        for id, text in pairs(captions or {}) do
            controls[id].text = text
        end
        local rail = Toolbar.build(controls, width, height, horizontal)
        local y = 0
        for _, tile in ipairs(rail) do
            tile.dimen.x = 600 - width
            tile.dimen.y = y
            y = y + tile.height
        end
        callback(rail, calls, controls)
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
    it("renders the disabled OCR icon faded while keeping its explanation tappable", function()
        withRail(72, 420, function(rail, calls)
            local tile = rail[2]
            assert.is_true(tile[1][1][1].dim)
            assert.is_false(rail[1][1][1][1].dim)
            rail:handleEvent("Gesture", {
                ges = "tap",
                pos = { x = tile.dimen.x + 10, y = tile.dimen.y + 10 },
            })
            assert.equals(1, calls.ocr_language)
        end, false, true)
    end)

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

    it("fits seven borderless actions in one compact portrait row", function()
        for _, width in ipairs({ 600, 240 }) do
            withRail(width, 64, function(rail)
                local row_width = 0
                for index, tile in ipairs(rail) do
                    assert.equals(Toolbar.order[index], tile.control.id)
                    assert.is_true(tile.height >= 64)
                    row_width = row_width + tile.width
                end
                assert.is_true(row_width <= width)
            end, true)
        end
    end)

    it("keeps seven landscape actions within the panel height, including wrapped captions", function()
        local captions = {
            rotate = "Girar",
            ocr_language = "Modelo OCR",
            screenshot = "Captura",
            progress_bar = "Mostrar barra",
            scale = "Tamanho real",
            night_mode = "Modo noturno",
            invert_document = "Invertido",
        }
        for _, width in ipairs({ 52, 72 }) do
            for _, height in ipairs({ 280, 350, 420 }) do
                withRail(width, height, function(rail, calls)
                    local rail_height = 0
                    for _, tile in ipairs(rail) do
                        local content = tile[1][1]
                        assert.is_true(content[1].height + content[2]:getSize().h <= tile.height)
                        rail_height = rail_height + tile.height
                    end
                    assert.is_true(rail_height <= height, "the icon rail must not push Close below the viewport")
                    local last = rail[#rail]
                    rail:handleEvent("Gesture", {
                        ges = "tap",
                        pos = { x = last.dimen.x + 10, y = last.dimen.y + last.height - 1 },
                    })
                    assert.equals(1, calls.invert_document)
                end, false, false, captions)
            end
        end
    end)

    it("wraps long translated captions and moves the following rail actions down", function()
        local label = "Mostrar a barra de progresso"
        withRail(52, 420, function(rail, calls)
            local tile = rail[4]
            local caption = tile[1][1][2]
            assert.equals(label, caption.text)
            assert.equals("center", caption.alignment)
            assert.is_true(caption:getSize().h > 12)
            assert.is_true(tile.height >= tile[1][1][1].height + caption:getSize().h)
            assert.equals(tile.dimen.y + tile.height, rail[5].dimen.y)
            rail:handleEvent("Gesture", {
                ges = "tap",
                pos = { x = tile.dimen.x + 10, y = tile.dimen.y + tile.height - 1 },
            })
            assert.equals(1, calls.progress_bar)
        end, false, false, { progress_bar = label })
    end)

    it("reserves a taller portrait row for wrapped captions in the panel viewport", function()
        withRail(240, 64, function(rail, _, controls)
            local viewer = PanelViewer:new({
                width = 240,
                height = 800,
                img_container_h = 500,
                buttons_visible = true,
                quick_controls = controls,
            })
            local width, height, row_height = viewer:getPanelViewportSize()
            assert.equals(240, width)
            assert.is_true(row_height > 64)
            assert.equals(500 - row_height, height)
            for _, tile in ipairs(rail) do
                assert.is_true(tile.height <= row_height)
            end
        end, true, false, { progress_bar = "Mostrar a barra de progresso" })
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
        assert.equals("Actual Size", scale.text)
        scale:setText("Scale")
        assert.equals("Fit", scale.text)
        local rotate = viewer.button_table:getButtonById("rotate")
        rotate:setText("No rotation")
        assert.equals("Rotate", rotate.text)
        assert.equals("Show Bar", viewer.quick_controls.progress_bar.text)
    end)

    it("toggles KOReader night mode and changes the moon/sun state icon", function()
        local old_night_mode = Screen.night_mode
        Screen.night_mode = false
        local events = {}
        local viewer = PanelViewer:new({
            width = 600,
            reader_ui = {
                document = { configurable = {} },
                handleEvent = function(_, event)
                    events[#events + 1] = event
                    Screen.night_mode = not Screen.night_mode
                end,
            },
            update = function() end,
        })
        viewer:replaceButtonTable()
        local light_icon, light_text = viewer.quick_controls.night_mode.icon_file, viewer.quick_controls.night_mode.text
        viewer.quick_controls.night_mode.callback()
        local night_icon, night_text = viewer.quick_controls.night_mode.icon_file, viewer.quick_controls.night_mode.text
        viewer.quick_controls.night_mode.callback()
        local restored_icon = viewer.quick_controls.night_mode.icon_file
        Screen.night_mode = old_night_mode
        assert.equals("ToggleNightMode", events[1].name)
        assert.is_true(light_icon:match("/sun%.svg$") ~= nil)
        assert.equals("Light Mode", light_text)
        assert.is_true(night_icon:match("/moon%.svg$") ~= nil)
        assert.equals("Night Mode", night_text)
        assert.equals(light_icon, restored_icon)
    end)

    it("persists document inversion in KOReader and explains its requirement in light mode", function()
        local old_night_mode = Screen.night_mode
        Screen.night_mode = true
        local configurable, events = { nightmode_document = 0 }, {}
        local saved, flushes = {}, 0
        local viewer = PanelViewer:new({
            width = 600,
            reader_ui = {
                document = { configurable = configurable },
                doc_settings = {
                    saveSetting = function(_, key, value)
                        saved[key] = value
                    end,
                    flush = function()
                        flushes = flushes + 1
                    end,
                },
                handleEvent = function(_, event)
                    events[#events + 1] = event
                    if event.name == "ConfigChange" then
                        configurable[event.args[1]] = event.args[2]
                    end
                end,
            },
            update = function() end,
        })
        viewer:replaceButtonTable()
        viewer.quick_controls.invert_document.callback()
        local inverted_text = viewer.quick_controls.invert_document.text
        local saved_inverted = saved.kopt_nightmode_document
        viewer.quick_controls.invert_document.callback()
        local normal_text = viewer.quick_controls.invert_document.text
        Screen.night_mode = false
        viewer:replaceButtonTable()
        local dim = viewer.quick_controls.invert_document.dim
        local UIManager = require("ui/uimanager")
        local previous_dialog = UIManager._last_shown
        UIManager._last_shown = nil
        viewer.quick_controls.invert_document.callback()
        local dialog = UIManager._last_shown
        UIManager._last_shown = previous_dialog
        Screen.night_mode = old_night_mode
        assert.equals("ConfigChange", events[1].name)
        assert.equals("nightmode_document", events[1].args[1])
        assert.equals(1, events[1].args[2])
        assert.equals(1, saved_inverted)
        assert.equals(0, saved.kopt_nightmode_document)
        assert.equals(2, flushes)
        assert.equals("RedrawCurrentPage", events[2].name)
        assert.equals("ConfigChange", events[3].name)
        assert.equals(0, events[3].args[2])
        assert.equals("RedrawCurrentPage", events[4].name)
        assert.equals(4, #events)
        assert.equals("Inverted", inverted_text)
        assert.equals("Invert", normal_text)
        assert.is_true(dim)
        assert.is_not_nil(dialog)
        assert.equals(
            "This option inverts panel colors in night mode. Turn on Night Mode first to use it.",
            dialog.text
        )
        assert.equals(7, dialog.timeout)
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
