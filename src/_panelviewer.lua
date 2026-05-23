local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local ImageViewer = require("ui/widget/imageviewer")
local Screenshoter = require("ui/widget/screenshoter")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

--- ImageViewer subclass for navigating one page's ordered panel sequence.
---
--- @class PanelViewer : ImageViewer
--- @field reading_mode PPReadingMode Current left/right panel order.
--- @field crop_mode PPCropMode Current crop rendering mode.
--- @field invert_swipe boolean Whether horizontal swipe direction is inverted.
--- @field page number|nil Document page number represented by `panels`.
--- @field panels PPPanel[]|nil Ordered panel rectangles.
--- @field boundary_callback fun(direction:PPBoundaryDirection, viewer:PanelViewer):boolean|nil
--- @field mode_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field crop_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field buttons_visible boolean Whether controls are currently shown.
--- @field with_title_bar boolean Whether ImageViewer title bar is shown.
--- @field fullscreen boolean Whether the viewer is fullscreen.
--- @field images_keep_pan_and_zoom boolean Whether ImageViewer preserves pan/zoom.
local PanelViewer = ImageViewer:extend{
    name = "panels_plus_panel_viewer",
    reading_mode = "manga",
    crop_mode = "strict",
    invert_swipe = false,
    page = nil,
    panels = nil,
    boundary_callback = nil,
    mode_toggle_callback = nil,
    crop_toggle_callback = nil,
    buttons_visible = false,
    with_title_bar = false,
    fullscreen = true,
    images_keep_pan_and_zoom = false,
}

--- Return which horizontal swipe direction advances to the next panel.
---
--- @return '"west"'|'"east"' direction Swipe direction treated as next.
function PanelViewer:getNextSwipeDirection()
    local direction
    if self.reading_mode == "comic" then
        direction = "east"
    else
        direction = "west"
    end
    if self.invert_swipe then
        return direction == "west" and "east" or "west"
    end
    return direction
end

--- Handle horizontal panel navigation before falling back to ImageViewer.
---
--- @param arg any KOReader gesture argument.
--- @param ges table Gesture event with `direction`.
--- @return boolean|nil handled Whether the gesture was consumed.
function PanelViewer:onSwipe(arg, ges)
    if self._images_list and (ges.direction == "west" or ges.direction == "east") then
        if ges.direction == self:getNextSwipeDirection() then
            if self._images_list_cur < self._images_list_nb then
                self:onShowNextImage()
            elseif self.boundary_callback then
                return self.boundary_callback("next", self)
            end
        else
            if self._images_list_cur > 1 then
                self:onShowPrevImage()
            elseif self.boundary_callback then
                return self.boundary_callback("previous", self)
            end
        end
        return true
    end
    return ImageViewer.onSwipe(self, arg, ges)
end

--- Toggle controls on inside taps and close on taps outside the frame.
---
--- @param _ any Unused KOReader tap argument.
--- @param ges table Gesture event with a `pos` geometry object.
--- @return boolean handled Always true after processing a tap.
function PanelViewer:onTap(_, ges)
    if ges.pos:notIntersectWith(self.main_frame.dimen) then
        self:onClose()
        return true
    end

    self.buttons_visible = not self.buttons_visible
    self:update()
    return true
end

--- Redraw the viewer, hiding the progress count during screenshot capture.
function PanelViewer:update()
    if not self._hide_progress_for_screenshot then
        return ImageViewer.update(self)
    end

    local images_list_nb = self._images_list_nb
    self._images_list_nb = 1
    local ok, err = pcall(ImageViewer.update, self)
    self._images_list_nb = images_list_nb
    if not ok then
        error(err)
    end
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

--- Initialize ImageViewer state, controls, and first render.
function PanelViewer:init()
    ImageViewer.init(self)
    self:replaceButtonTable()
    self:update()
end

--- Free a superseded panel image after ImageViewer has rebuilt its widget tree.
---
--- @param image any Owned panel blitbuffer.
function PanelViewer:releasePreviousPanelImage(image)
    if not image or not image.free then
        return
    end

    UIManager:tickAfterNext(function()
        if image ~= self.image then
            image:free()
            collectgarbage()
        end
    end)
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
end

--- Rebuild the ImageViewer button table from current mode/crop state.
function PanelViewer:replaceButtonTable()
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
                text = self.rotated and _("No rotation") or _("Rotate"),
                callback = function()
                    self.rotated = not self.rotated and true or false
                    self:update()
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
                id = "crop",
                text = self.crop_mode == "loose" and _("Loose crop") or _("Strict crop"),
                callback = function()
                    if self.crop_toggle_callback then
                        self.crop_toggle_callback(self)
                    else
                        self.crop_mode = self.crop_mode == "loose" and "strict" or "loose"
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
        },
    }

    self.button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = buttons,
        zero_sep = true,
        show_parent = self,
    }
    self.button_container = CenterContainer:new{
        dimen = Geom:new{
            w = self.width,
            h = self.button_table:getSize().h,
        },
        self.button_table,
    }
end

return PanelViewer
