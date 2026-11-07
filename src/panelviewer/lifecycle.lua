--[[
Panels+
File: src/panelviewer/lifecycle.lua
Name: PanelViewer
Description: Focused viewer lifecycle methods.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local DoubleSpread = require("src._doublespread")
local Event = require("ui/event")
local ImageViewer = require("ui/widget/imageviewer")
local Memory = require("src._memory")
local Screenshoter = require("ui/widget/screenshoter")
local UIManager = require("ui/uimanager")
local QuickToolbar = require("src._quicktoolbar")
local WordFinder = require("src._wordfinder")
local _ = require("gettext")

local Constants = require("src.panelviewer.constants")
local NAV_TRANSITION_MIN_FREE_BYTES = Constants.NAV_TRANSITION_MIN_FREE_BYTES

return function(PanelViewer)
    --- Schedule the initial full repaint without assuming layout already happened.
    function PanelViewer:onShow()
        self._panels_plus_closed = nil
        self.dithered = true
        UIManager:setDirty(self, function()
            if not self:isOpen() or not self.main_frame or not self.main_frame.dimen then
                return nil
            end
            return "full", self.main_frame.dimen, true
        end)
        self:requestPanelPrerender()
        return true
    end

    --- Redraw the viewer, optionally suppressing the progress bar.
    function PanelViewer:update()
        local result
        if not self._hide_progress_for_screenshot and self.progress_bar_visible ~= false then
            result = self:withGuardedImageViewerRefresh(function()
                return ImageViewer.update(self)
            end)
        else
            local images_list_nb = self._images_list_nb
            self._images_list_nb = 1
            local ok, err = pcall(function()
                result = self:withGuardedImageViewerRefresh(function()
                    return ImageViewer.update(self)
                end)
            end)
            self._images_list_nb = images_list_nb
            if not ok then
                error(err)
            end
        end

        -- Base ImageViewer:update() always relabels the "rotate" button itself
        -- (self.rotated and _("No rotation") or _("Rotate")), overwriting the
        -- static text replaceButtonTable() gave it -- that toggle-style label
        -- made sense for the base class's tap-to-toggle button, but ours opens
        -- the rotation picker instead, so its label should never change.
        if self.buttons_visible and self.button_table then
            local rotate_btn = self.button_table:getButtonById("rotate")
            if rotate_btn then
                rotate_btn:setText(_("Rotate"), rotate_btn.width)
            end
        end

        return result
    end

    --- Save a screenshot of the current panel view.
    ---
    --- Temporarily hides controls and title chrome so screenshots contain only the
    --- rendered panel, then restores the previous viewer state through KOReader's
    --- screenshot callback.
    ---
    --- @return boolean handled Always true for button callback dispatch.
    function PanelViewer:onSaveImageView()
        self._hide_progress_for_screenshot = true

        local restore_settings_func
        if self.with_title_bar or self.buttons_visible or not self.fullscreen then
            local with_title_bar = self.with_title_bar
            local buttons_visible = self.buttons_visible
            local fullscreen = self.fullscreen
            restore_settings_func = function()
                self.with_title_bar = with_title_bar
                self.buttons_visible = buttons_visible
                self.fullscreen = fullscreen
                self._hide_progress_for_screenshot = false
                self:update()
            end
            self.with_title_bar = false
            self.buttons_visible = false
            self.fullscreen = true
            self:update()
            UIManager:forceRePaint()
        else
            restore_settings_func = function()
                self._hide_progress_for_screenshot = false
                self:update()
            end
            self:update()
            UIManager:forceRePaint()
        end

        local screenshot_dir = Screenshoter:getScreenshotDir()
        local screenshot_name = os.date(screenshot_dir .. "/ImageViewer_%Y-%m-%d_%H%M%S.png")
        UIManager:sendEvent(Event:new("Screenshot", screenshot_name, restore_settings_func))
        return true
    end

    --- Return whether this panel's source geometry looks like a double-page spread.
    --- @param index integer 1-based panel index.
    --- @return boolean
    function PanelViewer:shouldAutoRotateDoublePage(index)
        if self.auto_rotate_double_pages == false or self.image_rotation ~= nil then
            return false
        end
        local panels = self.panels
        local flags = self.panel_is_full_page
        return DoubleSpread.shouldRotate(panels and panels[index], flags and flags[index], panels and #panels == 1)
    end

    --- Apply the document's rotation, a manual choice, or spread auto-rotation.
    --- @param index integer 1-based panel index.
    function PanelViewer:applyImageRotation(index)
        self.rotated = self._images_list and self._images_list.rotated
        if self.image_rotation ~= nil then
            self.rotated = self.image_rotation
        elseif self:shouldAutoRotateDoublePage(index) then
            -- An explicit angle, for the page/screen coordinate transforms. Without a chosen
            -- direction it matches KOReader's portrait ImageViewer.
            self.rotated = DoubleSpread.imageAngle(self.spread_rotation_direction)
        end
    end

    --- Initialize ImageViewer state, controls, and first render.
    function PanelViewer:init()
        -- Base ImageViewer always materializes list entry 1 during init. When a
        -- rebuilt viewer needs to reopen on a later panel, give it a one-entry
        -- initialization view so it renders the destination directly instead of
        -- rendering panel 1 and immediately throwing that bitmap away.
        local images = type(self.image) == "table" and self.image or nil
        local image_count = images and (self.images_list_nb or #images) or 0
        local initial_image_num = math.floor(tonumber(self.initial_image_num) or 1)
        if initial_image_num < 1 or initial_image_num > image_count then
            initial_image_num = 1
        end
        local initial_image
        local images_list_disposable = self.image_disposable
        if images and initial_image_num > 1 then
            initial_image = images[initial_image_num]
            if type(initial_image) == "function" then
                initial_image = initial_image()
            end
            self.images_list_nb = image_count
            self.image = {
                initial_image,
                image_disposable = images.image_disposable,
            }
        end

        ImageViewer.init(self)
        if images and initial_image_num > 1 then
            self.image = initial_image
            self._images_list = images
            self._images_list_cur = initial_image_num
            self._images_list_nb = image_count
            self._images_list_disposable = images_list_disposable
            self.image_disposable = images.image_disposable
        end
        self.initial_image_num = nil
        self:applyImageRotation(initial_image_num)
        self:replaceButtonTable()
        self:update()

        self.key_events = self.key_events or {}
        local ok_dev, Device = pcall(require, "device")
        local pg_back = { "LPgBack", "RPgBack" }
        local pg_fwd = { "LPgFwd", "RPgFwd" }
        local back = { "Back" }
        if ok_dev and Device and Device.input and Device.input.group then
            pg_back = Device.input.group.PgBack or pg_back
            pg_fwd = Device.input.group.PgFwd or pg_fwd
            back = Device.input.group.Back or back
        end

        self.key_events.Close = self.key_events.Close or { { back } }
        self.key_events.ShowPrevImage = { { pg_back }, { "PageUp" } }
        self.key_events.ShowNextImage = { { pg_fwd }, { "PageDown" }, { " " } }
        self.key_events.Home = self.key_events.Home or { { "Home" } }
        self.key_events.PanLeft = nil
        self.key_events.PanRight = nil
        self.key_events.ZoomIn = nil
        self.key_events.ZoomOut = nil
        self.key_events.PanelNavLeft = { { "Left" }, { "a" }, { "A" } }
        self.key_events.PanelNavRight = { { "Right" }, { "d" }, { "D" } }
    end

    --- Android can rotate the screen while this viewer is open. The image list's
    --- current bitmap was rendered for the previous canvas dimensions, and the
    --- base ImageViewer also keeps its outer region and touch ranges from init.
    --- Reopen at the same panel so drawPagePart uses the new canvas size.
    function PanelViewer:onScreenResize(dimen)
        if self._panels_plus_closed or not dimen or not self.region then
            return
        end
        if self.region.w == dimen.w and self.region.h == dimen.h then
            return
        end
        if self.screen_resize_callback then
            return self.screen_resize_callback(self)
        end
    end

    --- Close ImageViewer resources while guarding its final dirty-region callback.
    function PanelViewer:onCloseWidget()
        self:_cancelPhraseHold()
        self._phrase_selected = nil
        self._panels_plus_closed = true
        self._panels_plus_smooth_preview = nil
        if self._document_boundary_dialog then
            UIManager:close(self._document_boundary_dialog)
        end
        self._panels_plus_closing = true
        self._panels_plus_transition_active = nil
        if self._panels_plus_transition_action then
            UIManager:unschedule(self._panels_plus_transition_action)
            self._panels_plus_transition_action = nil
        end
        if self._panels_plus_transition_cleanup then
            self._panels_plus_transition_cleanup()
            self._panels_plus_transition_cleanup = nil
        end
        if self.embedded_cleanup_callback then
            pcall(self.embedded_cleanup_callback, self)
        end
        local active_image = self.image
        local ok, err = pcall(function()
            return self:withGuardedImageViewerRefresh(function()
                return ImageViewer.onCloseWidget(self)
            end)
        end)
        self._panels_plus_closing = nil
        -- The base viewer frees and clears self.image on successful disposal.
        if self.image == active_image and self.image_disposable and active_image and active_image.free then
            active_image:free()
        end
        self.image = nil
        self._images_list = nil
        self.image_rects = nil
        self:releaseEmbeddedSource()
        -- Old crops wait two UI ticks so ImageViewer can replace its child widget.
        -- A reader can close before those ticks run; release them now that the
        -- widget tree is gone instead of retaining several screen-sized buffers.
        for _, pending in ipairs(self._pending_panel_images or {}) do
            if pending.image and pending.image.free then
                pending.image:free()
                pending.image = nil
            end
        end
        self._pending_panel_images = nil
        self.panels = nil
        self.panel_is_full_page = nil
        self.boundary_callback = nil
        self.detector_cycle_callback = nil
        self.mode_toggle_callback = nil
        self.crop_toggle_callback = nil
        self.panel_finding_toggle_callback = nil
        self.margin_ratio_callback = nil
        self.bleed_ratio_callback = nil
        self.nav_smooth_style_callback = nil
        self.panel_prerender_callback = nil
        self.embedded_cleanup_callback = nil
        self.screen_resize_callback = nil
        QuickToolbar.free(self.quick_controls)
        self.quick_controls = nil
        self.quick_rail = nil
        local closed_callback = self.closed_callback
        self.closed_callback = nil
        if closed_callback then
            pcall(closed_callback, self)
        end
        pcall(WordFinder.cleanup)
        if not Memory.hasHeadroom(NAV_TRANSITION_MIN_FREE_BYTES) then
            collectgarbage("collect")
        end
        if not ok then
            error(err)
        end
    end

    --- Release the decoded EPUB/KEPUB/MOBI source and the renderer closure that captures
    --- it. The current displayed crop remains owned by `self.image`, so this is
    --- safe while a boundary search keeps the viewer visible.
    function PanelViewer:releaseEmbeddedSource(discard_navigation)
        if self.embedded_source_image then
            self:_cancelPhraseHold()
            self._panels_plus_text_holding = nil
            self._phrase_selected = nil
        end
        local source = self.embedded_source_image
        self.embedded_source_image = nil
        self._embedded_ocr_document = nil
        self._embedded_selection = nil
        self.image_union_renderer = nil
        if discard_navigation then
            self._images_list = nil
            self.image_rects = nil
            self.panels = nil
            self.panel_is_full_page = nil
        end
        if source and source.free then
            source:free()
        end
    end

    --- Free a superseded panel image after ImageViewer has rebuilt its widget tree.
    ---
    --- `image:free()` releases the blitbuffer's C memory immediately, so there is
    --- deliberately no `collectgarbage()` here: a full collection on every panel
    --- switch stalls the UI for far longer than it reclaims.
    ---
    --- @param image any Owned panel blitbuffer.
    function PanelViewer:releasePreviousPanelImage(image)
        if not image or not image.free then
            return
        end

        local pending = { image = image }
        self._pending_panel_images = self._pending_panel_images or {}
        table.insert(self._pending_panel_images, pending)
        UIManager:tickAfterNext(function()
            local previous = pending.image
            if previous and previous ~= self.image then
                previous:free()
            end
            pending.image = nil
            local images = self._pending_panel_images
            if images then
                for i = #images, 1, -1 do
                    if images[i] == pending then
                        table.remove(images, i)
                        break
                    end
                end
            end
        end)
    end

    --- Ask the owner to warm the following panel's render while the device is idle.
    function PanelViewer:requestPanelPrerender()
        if self.panel_prerender_callback then
            self.panel_prerender_callback(self, self._images_list_cur or 1)
        end
    end

    --- Rebuild baked-in padding after a color change, retaining the current pan and zoom.
    function PanelViewer:refreshPanelColors()
        local old_image = self.image
        local render = self._images_list and self._images_list[self._images_list_cur or 1]
        if type(render) == "function" then
            self.image = render()
        end
        self:replaceButtonTable()
        self:update()
        if self.image_disposable and old_image ~= self.image then
            self:releasePreviousPanelImage(old_image)
        end
    end

    --- Switch panel images after rendering the destination panel.
    ---
    --- KOReader's base ImageViewer frees the current image before `update()`
    --- removes the old ImageWidget. That can segfault with drawPagePart() buffers
    --- on Kindle/SDL. This keeps the old buffer alive until the new widget is in
    --- place, then releases it on the next UI tick.
    ---
    --- @param image_num integer 1-based image index.
    function PanelViewer:switchToImageNum(image_num)
        if image_num == self._images_list_cur then
            return
        end

        local old_image = self.image
        self.image = self._images_list[image_num]
        if type(self.image) == "function" then
            self.image = self.image()
        end
        self:applyImageRotation(image_num)
        self._images_list_cur = image_num
        if not self.images_keep_pan_and_zoom then
            self._center_x_ratio = 0.5
            self._center_y_ratio = 0.5
            self.scale_factor = self._images_orig_scale_factor
        end
        self:update()
        if self.image_disposable then
            self:releasePreviousPanelImage(old_image)
        end
        self:requestPanelPrerender()
    end
end
