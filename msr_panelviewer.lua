local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local ImageViewer = require("ui/widget/imageviewer")
local _ = require("gettext")

local PanelViewer = ImageViewer:extend{
    name = "mangacomicsmoother_panel_viewer",
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

function PanelViewer:onTap(_, ges)
    if ges.pos:notIntersectWith(self.main_frame.dimen) then
        self:onClose()
        return true
    end

    self.buttons_visible = not self.buttons_visible
    self:update()
    return true
end

function PanelViewer:init()
    ImageViewer.init(self)
    self:replaceButtonTable()
    self:update()
end

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
