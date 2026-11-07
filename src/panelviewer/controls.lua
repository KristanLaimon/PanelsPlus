--[[
Panels+
File: src/panelviewer/controls.lua
Name: PanelViewer
Description: Focused viewer controls methods.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local NavEasing = require("src._naveasing")
local NavCapabilities = require("src._navcapabilities")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local QuickToolbar = require("src._quicktoolbar")
local _ = require("gettext")

local Constants = require("src.panelviewer.constants")
local NAV_TRANSITION_STEPS_DEFAULT = Constants.NAV_TRANSITION_STEPS_DEFAULT
local FLOW_WARNING_TIMEOUT = Constants.FLOW_WARNING_TIMEOUT

return function(PanelViewer)
    --- Show a slider dialog to adjust how much "margin" crop mode zooms out.
    ---
    --- Applying a value also switches crop mode to "margin" so the change is
    --- visible immediately, since tuning a value you can't see would be useless.
    ---
    --- @return boolean handled Always true for button hold-callback dispatch.
    function PanelViewer:onAdjustMarginRatio()
        local SpinWidget = require("ui/widget/spinwidget")
        local viewer = self
        UIManager:show(SpinWidget:new({
            title_text = _("Panel margin"),
            info_text = _(
                "Zooms panels out a little to leave breathing room around them. Has no effect on full-page panels."
            ),
            value = math.floor((self.margin_ratio or 0.12) * 100 + 0.5),
            value_min = 0,
            value_max = 40,
            value_step = 1,
            value_hold_step = 5,
            unit = "%",
            default_value = 12,
            callback = function(spin)
                local ratio = spin.value / 100
                if viewer.margin_ratio_callback then
                    viewer.margin_ratio_callback(viewer, ratio, true)
                else
                    viewer.margin_ratio = ratio
                    viewer.crop_mode = "margin"
                    viewer:replaceButtonTable()
                    viewer:update()
                end
            end,
        }))
        return true
    end

    --- Show a slider dialog to adjust how much extra page area "loose" crop reveals.
    ---
    --- Applying a value also switches crop mode to "loose" so the change is
    --- visible immediately, since tuning a value you can't see would be useless.
    ---
    --- @return boolean handled Always true for button hold-callback dispatch.
    function PanelViewer:onAdjustBleedRatio()
        local SpinWidget = require("ui/widget/spinwidget")
        local viewer = self
        UIManager:show(SpinWidget:new({
            title_text = _("Loose crop bleed"),
            info_text = _("How much page area outside each panel's edges to reveal."),
            value = math.floor((self.bleed_ratio or 0.08) * 100 + 0.5),
            value_min = 0,
            value_max = 100,
            value_step = 1,
            value_hold_step = 5,
            unit = "%",
            default_value = 8,
            callback = function(spin)
                local ratio = spin.value / 100
                if viewer.bleed_ratio_callback then
                    viewer.bleed_ratio_callback(viewer, ratio, true)
                else
                    viewer.bleed_ratio = ratio
                    viewer.crop_mode = "loose"
                    viewer:replaceButtonTable()
                    viewer:update()
                end
            end,
        }))
        return true
    end

    --- Show a slider dialog to adjust how long the smooth-navigation camera pan takes.
    ---
    --- @return boolean handled Always true for button hold-callback dispatch.
    function PanelViewer:onAdjustNavTransitionDuration()
        local SpinWidget = require("ui/widget/spinwidget")
        local viewer = self
        UIManager:show(SpinWidget:new({
            title_text = _("Smooth navigation duration"),
            info_text = _("How long the camera pan between panels takes."),
            value = math.floor((self.nav_transition_duration or 0.4) * 1000 + 0.5),
            value_min = 150,
            value_max = 900,
            value_step = 50,
            value_hold_step = 100,
            unit = "ms",
            default_value = 400,
            callback = function(spin)
                local seconds = spin.value / 1000
                if viewer.nav_transition_duration_callback then
                    viewer.nav_transition_duration_callback(viewer, seconds)
                else
                    viewer.nav_transition_duration = seconds
                end
            end,
        }))
        return true
    end

    --- Show a slider dialog to adjust how many steps the smooth-navigation camera
    --- pan is split into.
    ---
    --- @param on_committed fun()|nil Called after a new value is applied, so a
    ---   caller showing this from a settings menu can refresh a label reflecting
    ---   the current value.
    --- @return boolean handled Always true for button hold-callback dispatch.
    function PanelViewer:onAdjustNavTransitionFrames(on_committed)
        local SpinWidget = require("ui/widget/spinwidget")
        local viewer = self
        UIManager:show(SpinWidget:new({
            title_text = _("Smooth navigation frames"),
            info_text = _(
                "How many steps the camera pan between panels is split into. More frames look smoother but schedule more work per transition."
            ),
            value = self.nav_transition_frames or NAV_TRANSITION_STEPS_DEFAULT,
            value_min = 1,
            value_max = 60,
            value_step = 1,
            value_hold_step = 4,
            unit = _("frames"),
            default_value = NAV_TRANSITION_STEPS_DEFAULT,
            callback = function(spin)
                local frames = spin.value
                if viewer.nav_transition_frames_callback then
                    viewer.nav_transition_frames_callback(viewer, frames)
                else
                    viewer.nav_transition_frames = frames
                end
                if on_committed then
                    on_committed()
                end
            end,
        }))
        return true
    end

    --- Show a multi-options menu popup for navigation transition configuration.
    ---
    --- @return boolean handled Always true for button hold-callback dispatch.
    function PanelViewer:onShowNavTransitionOptionsMenu()
        local Menu = require("ui/widget/menu")
        local viewer = self
        local menu

        local menu_items
        if viewer.nav_transition_mode == "animated" then
            menu_items = {
                {
                    text = _("Animate between panels (Actual: ")
                        .. (viewer.nav_animated_panels ~= false and _("true") or _("false"))
                        .. ")",
                    checked_func = function()
                        return viewer.nav_animated_panels ~= false
                    end,
                    callback = function()
                        viewer.nav_animated_panels = viewer.nav_animated_panels == false
                        UIManager:close(menu)
                        viewer:onShowNavTransitionOptionsMenu()
                    end,
                },
                {
                    text = _("Animate between pages (Actual: ")
                        .. (viewer.nav_animated_pages ~= false and _("true") or _("false"))
                        .. ")",
                    checked_func = function()
                        return viewer.nav_animated_pages ~= false
                    end,
                    callback = function()
                        viewer.nav_animated_pages = viewer.nav_animated_pages == false
                        UIManager:close(menu)
                        viewer:onShowNavTransitionOptionsMenu()
                    end,
                },
            }
        else
            menu_items = {
                {
                    text = _("Pan animation duration..."),
                    callback = function()
                        viewer:onAdjustNavTransitionDuration()
                    end,
                    help_text = _("Adjust how long the camera pan between panels takes in milliseconds."),
                },
                {
                    text = _("Animate page-to-page transitions (Actual: ")
                        .. (viewer.nav_transition_cross_page == true and _("true") or _("false"))
                        .. ")",
                    checked_func = function()
                        return viewer.nav_transition_cross_page == true
                    end,
                    callback = function()
                        local new_val = not viewer.nav_transition_cross_page
                        viewer.nav_transition_cross_page = new_val
                        if viewer.nav_transition_cross_page_callback then
                            viewer.nav_transition_cross_page_callback(viewer, new_val)
                        end
                        UIManager:close(menu)
                        viewer:onShowNavTransitionOptionsMenu()
                    end,
                    help_text = _(
                        "Also pan across the boundary between the last panel of a page and the first panel of the next, instead of cutting instantly. Only animates when the adjacent page has already been detected in the background; otherwise the crossing stays an instant cut."
                    ),
                },
                {
                    text = _("Transition frames (Actual: ")
                        .. tostring(viewer.nav_transition_frames or NAV_TRANSITION_STEPS_DEFAULT)
                        .. _(" fps)"),
                    callback = function()
                        viewer:onAdjustNavTransitionFrames(function()
                            UIManager:close(menu)
                            viewer:onShowNavTransitionOptionsMenu()
                        end)
                    end,
                    help_text = _(
                        "How many discrete steps the smooth camera pan between panels is split into. More frames look smoother but schedule more work per transition."
                    ),
                },
            }
        end

        if viewer.nav_transition_mode == "smooth" then
            menu_items[#menu_items + 1] = {
                text = _("Smooth style") .. ": " .. NavEasing.label(viewer.nav_smooth_style),
                callback = function()
                    local style = NavEasing.next(viewer.nav_smooth_style)
                    if viewer.nav_smooth_style_callback then
                        viewer.nav_smooth_style_callback(viewer, style)
                    else
                        viewer.nav_smooth_style = style
                    end
                    UIManager:close(menu)
                    viewer:onShowNavTransitionOptionsMenu()
                end,
            }
        end

        menu = Menu:new({
            title = _("Navigation Transition Settings"),
            item_table = menu_items,
        })
        UIManager:show(menu)
        return true
    end

    --- Open the rotation picker: one 4-way control for KOReader's real screen
    --- rotation, one for this plugin's own zoomed-view rotation.
    ---
    --- Passes an explicit "full" refresh type: `Button:onTapSelectButton()`
    --- (the tap that got us here) queues its own highlight/unhighlight refresh
    --- scoped to just the button's small rectangle, and without an explicit
    --- type here, this dialog's *content* still paints correctly but the
    --- physical screen refresh stays clipped to that button-sized region --
    --- same fix `ui/screensaver.lua` and `readerstatus.lua` use for the same
    --- button-triggered full-screen-dialog situation.
    ---
    --- @return boolean handled Always true for button callback dispatch.
    function PanelViewer:onOpenRotationPicker()
        local RotationPickerDialog = require("src._rotationpicker")
        local viewer = self
        UIManager:show(
            RotationPickerDialog:new({
                on_device_rotate = function(direction)
                    viewer:onSetDeviceRotation(direction)
                end,
                on_image_rotate = function(direction)
                    viewer:onSetImageRotation(direction)
                end,
            }),
            "full"
        )
        return true
    end

    --- Rotate the whole device/screen via KOReader's own rotation, exactly like
    --- the built-in rotate control -- this moves menus, status bar, and
    --- everything else, not just this viewer.
    ---
    --- Mirrors `ui/elements/screen_rotation_menu_table.lua`'s own rotation menu
    --- items, which broadcast this same event for the same reason: several
    --- modules (e.g. `ReaderView:onSetRotationMode`) listen for it to update
    --- their own layout alongside the screen itself.
    ---
    --- Base `ImageViewer` has no `onScreenResize`/`onSetDimensions` handler of
    --- its own (it's built for short-lived overlays, not ones that outlive a
    --- screen rotation): its outer region gets sized once at construction from
    --- `Screen:getWidth/getHeight()` and never revisited, so simply leaving it
    --- open across a rotation leaves stale strips uncovered by the reader's own
    --- full repaint. `device_rotate_callback` (wired up by `ViewerController`)
    --- closes this viewer, performs the rotation, and reopens an equivalent one
    --- for the same page/panel/index -- the same close-and-rebuild idiom
    --- `setViewerBleedRatio` already uses for a crop-rectangle change -- so the
    --- reader stays in zoom mode instead of dropping back to the plain page
    --- view. Without a controller wired up (e.g. standalone use), falls back to
    --- closing outright: `UIManager:onRotation()` (setDirty "all"/"full" +
    --- forceRePaint) is the same belt-and-suspenders flash every built-in
    --- rotation control in KOReader chains after broadcasting the event.
    ---
    --- Each direction is a *relative* turn from wherever the screen currently
    --- is, not a fixed absolute target -- pressing "right" while already
    --- rotated clockwise turns another quarter further, like holding a D-pad,
    --- rather than jumping back to a fixed clockwise orientation. KOReader's
    --- rotation-mode integers are themselves sequential quarter-turn steps
    --- (0=upright, 1=clockwise, 2=upside-down, 3=counter-clockwise), so adding
    --- a quarter-turn count and wrapping mod 4 is exact.
    ---
    --- @param direction "up"|"down"|"left"|"right"
    function PanelViewer:onSetDeviceRotation(direction)
        local quarter_turns_by_direction = { up = 2, right = 1, down = 0, left = 3 }
        local turns = quarter_turns_by_direction[direction]
        if turns == nil then
            return
        end
        local mode = (Screen:getRotationMode() + turns) % 4
        if self.device_rotate_callback then
            self.device_rotate_callback(self, mode)
        else
            self:onClose()
            UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
            UIManager:onRotation()
        end
    end

    --- Rotate only this zoomed panel view, leaving KOReader's own screen
    --- rotation untouched.
    ---
    --- Reuses `self.rotated`, the same state ImageViewer already applies for
    --- document-driven landscape auto-rotation (see `screenToPageTransform`/
    --- `pageToScreenTransform` above) -- setting it here to a real 4-way angle
    --- rotates the displayed image exactly like that existing mechanism, with
    --- no separate pixel-rotation code needed.
    ---
    --- Unlike `onSetDeviceRotation`, each direction here is an *absolute*
    --- target angle, not a relative turn -- pressing "right" always means
    --- "rotate this view to 90 degrees", regardless of its current angle.
    ---
    --- Stored in `self.image_rotation` (distinct from `self.rotated`, which also
    --- carries the document's own auto-rotation and gets reset to that on every
    --- panel switch -- see `init`/`switchToImageNum`) so this choice survives
    --- switching panels, and reported through `image_rotation_callback` so
    --- `ViewerController` can persist it, surviving closing and reopening the
    --- viewer too.
    ---
    --- @param direction "up"|"down"|"left"|"right"|"auto"
    function PanelViewer:onSetImageRotation(direction)
        local angle_by_direction = { up = 180, right = 90, down = false, left = 270 }
        self.image_rotation = direction == "auto" and nil or angle_by_direction[direction]
        self:applyImageRotation(self._images_list_cur or 1)
        if self.image_rotation_callback and self.image_rotation_callback(self, self.image_rotation) == "reopened" then
            return
        end
        self:replaceButtonTable()
        self:update()
    end

    --- Return the label for the detector currently in use.
    ---
    --- @return string text Localized detector label.
    function PanelViewer:getDetectorText()
        return _("Deep mode")
    end

    --- Rebuild the ImageViewer button table from current mode/crop state.
    function PanelViewer:replaceButtonTable()
        -- The base constructor and every settings change create a new container.
        -- Free the detached text/button widgets before losing their only owner.
        if self.button_container then
            self.button_container:free()
        end
        local buttons = {
            {
                {
                    id = "scale",
                    text = self._scale_to_fit and _("Original size") or _("Scale"),
                    callback = function()
                        self.scale_factor = self._scale_to_fit and 1 or 0
                        self._scale_to_fit = not self._scale_to_fit
                        self._center_x_ratio = 0.5
                        self._center_y_ratio = 0.5
                        self:update()
                    end,
                },
                {
                    id = "rotate",
                    text = _("Rotate"),
                    callback = function()
                        self:onOpenRotationPicker()
                    end,
                },
                {
                    id = "mode",
                    text = self.reading_mode == "comic" and _("Comic mode") or _("Manga mode"),
                    callback = function()
                        if self.mode_toggle_callback then
                            self.mode_toggle_callback(self)
                        else
                            self.reading_mode = self.reading_mode == "comic" and "manga" or "comic"
                            self:replaceButtonTable()
                            self:update()
                        end
                    end,
                },
                {
                    id = "close",
                    text = _("Close"),
                    callback = function()
                        self:onClose()
                    end,
                },
            },
            {
                {
                    id = "screenshot",
                    text = _("Screenshot"),
                    callback = function()
                        self:onSaveImageView()
                    end,
                },
                {
                    id = "progress_bar",
                    text = self.progress_bar_visible == false and _("Show progress") or _("Hide progress"),
                    callback = function()
                        if self.progress_bar_toggle_callback then
                            self.progress_bar_toggle_callback(self)
                        else
                            self.progress_bar_visible = not self.progress_bar_visible
                            self:replaceButtonTable()
                            self:update()
                        end
                    end,
                },
                {
                    id = "ocr_language",
                    text = _("OCR Language"),
                    dim = self.hold_text_selection == false,
                    callback = function()
                        if self.hold_text_selection == false then
                            return self:showTextSelectionDisabledWarning()
                        end
                        if self.ocr_language_callback then
                            self.ocr_language_callback(self)
                        end
                    end,
                },
                {
                    id = "nav_transition",
                    text = self:getNavTransitionText(),
                    callback = function()
                        if self.nav_transition_toggle_callback then
                            self.nav_transition_toggle_callback(self)
                        else
                            local mode = NavCapabilities.nextMode(self.nav_transition_mode)
                            self.nav_transition_mode = mode
                            self:replaceButtonTable()
                            self:update()
                            if mode == "smooth" then
                                NavCapabilities.warnSmooth()
                            end
                        end
                    end,
                    hold_callback = function()
                        if self.nav_transition_mode == "smooth" or self.nav_transition_mode == "animated" then
                            if self.nav_transition_options_callback then
                                self.nav_transition_options_callback(self)
                            else
                                self:onShowNavTransitionOptionsMenu()
                            end
                        end
                    end,
                },
            },
            {
                {
                    id = "more_config",
                    text = _("More config..."),
                    callback = function()
                        if self.more_config_callback then
                            self.more_config_callback(self)
                        end
                    end,
                },
                {
                    id = "settings_profile",
                    text = _("Settings Profile:")
                        .. " "
                        .. (self.profile_name_callback and self.profile_name_callback() or _("None")),
                    callback = function()
                        if self.settings_profile_callback then
                            self.settings_profile_callback(self)
                        end
                    end,
                },
                {
                    id = "panel_finding",
                    text = self:getPanelFindingModeText(),
                    callback = function()
                        if self.panel_finding_toggle_callback then
                            self.panel_finding_toggle_callback(self)
                        else
                            self.panel_finding_mode = self.panel_finding_mode == "smart" and "safe" or "smart"
                            self:replaceButtonTable()
                            self:update()
                        end
                    end,
                },
                {
                    id = "crop",
                    text = self:getCropModeText(),
                    callback = function()
                        if self.crop_toggle_callback then
                            self.crop_toggle_callback(self)
                        else
                            local next_mode = { strict = "loose", loose = "margin", margin = "none", none = "strict" }
                            self.crop_mode = next_mode[self.crop_mode] or "strict"
                            self:replaceButtonTable()
                            self:update()
                        end
                    end,
                    hold_callback = function()
                        if self.crop_mode == "loose" then
                            self:onAdjustBleedRatio()
                        elseif self.crop_mode == "margin" then
                            self:onAdjustMarginRatio()
                        end
                    end,
                },
            },
        }

        local actions = {}
        for _, row in ipairs(buttons) do
            for _, action in ipairs(row) do
                actions[action.id] = action
            end
        end
        local reader_ui = self.reader_ui
        local configurable = reader_ui and reader_ui.document and reader_ui.document.configurable
        actions.night_mode = {
            text = Screen.night_mode and _("Night Mode") or _("Light Mode"),
            icon = Screen.night_mode and "moon" or "sun",
            dim = not reader_ui,
            callback = function()
                if not reader_ui then
                    return
                end
                reader_ui:handleEvent(Event:new("ToggleNightMode"))
                self:refreshPanelColors()
            end,
        }
        actions.invert_document = {
            text = configurable and configurable.nightmode_document == 1 and _("Inverted") or _("Invert"),
            dim = not Screen.night_mode or not configurable,
            callback = function()
                if not Screen.night_mode then
                    UIManager:show(require("ui/widget/infomessage"):new({
                        text = _("This option inverts panel colors in night mode. Turn on Night Mode first to use it."),
                        timeout = FLOW_WARNING_TIMEOUT,
                    }))
                    return
                end
                if not configurable then
                    return
                end
                local value = configurable.nightmode_document == 1 and 0 or 1
                reader_ui:handleEvent(Event:new("ConfigChange", "nightmode_document", value))
                if reader_ui.doc_settings then
                    reader_ui.doc_settings:saveSetting("kopt_nightmode_document", value)
                    reader_ui.doc_settings:flush()
                end
                reader_ui:handleEvent(Event:new("RedrawCurrentPage"))
                self:refreshPanelColors()
            end,
        }
        QuickToolbar.free(self.quick_controls)
        self.quick_controls = QuickToolbar.controls(actions)
        buttons = {
            { actions.mode, actions.nav_transition, actions.crop },
            { actions.more_config, actions.settings_profile, actions.panel_finding },
            { actions.close },
        }

        local width = (self.width or 600) - 2 * (self.button_padding or 0)
        self.button_table = ButtonTable:new({
            width = width,
            buttons = buttons,
            zero_sep = true,
            show_parent = self,
        })
        -- ImageViewer:update() still relabels scale/rotate through this lookup.
        -- Keep those controls available without putting them in the bottom rows.
        local get_button = self.button_table.getButtonById
        local quick_controls = self.quick_controls
        self.button_table.getButtonById = function(table_widget, id)
            return quick_controls[id] or (get_button and get_button(table_widget, id))
        end
        self.button_container = CenterContainer:new({
            dimen = Geom:new({
                w = self.width or (self.button_table and self.button_table:getSize().w) or 600,
                h = self.button_table:getSize().h,
            }),
            self.button_table,
        })
    end
end
