--[[
Panels+
File: src/embedded_image.lua
Name: EmbeddedImage
Description: Extracts, detects, displays, and navigates panel sequences in reflow-document images.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Blitbuffer = require("ffi/blitbuffer")
local Event = require("ui/event")
local Geometry = require("src._geometry")
local PanelViewport = require("src._panelviewport")
local PanelViewer = require("src._panelviewer")
local RenderImage = require("ui/renderimage")
local NativeDetector = require("src._nativedetector")
local ComponentDetector = require("src._componentdetector")
local PageBitmap = require("src._pagebitmap")
local Settings = require("src._settings")
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen

--- Embedded-image support for reflowable EPUB, KEPUB, and MOBI documents.
---
--- KOReader's fixed-page panel API deliberately does not run in ReaderRolling.
--- Its document API can still extract the image under a hold, so we segment
--- that bitmap itself and feed its crops to the normal Panels+ viewer.
local EmbeddedImage = {}

-- Reused probe ratios: page-to-page image search must not create two small
-- tables for every reflow page it crosses.
local IMAGE_SEARCH_XS = { 0.1, 0.25, 0.4, 0.6, 0.75, 0.9 }
local IMAGE_SEARCH_YS = { 0.08, 0.2, 0.35, 0.5, 0.65, 0.8, 0.92 }

local function isSupportedDocument(document)
    local file = document and document.file
    if type(file) ~= "string" then
        return false
    end
    file = file:lower()
    -- Kobo's usual sync name is `book.kepub.epub`, which the EPUB suffix
    -- already accepts. Some import and cloud workflows keep the direct
    -- `.kepub` suffix instead, so accept that spelling as well when KOReader
    -- has opened it in ReaderRolling.
    return file:match("%.epub$") ~= nil or file:match("%.kepub$") ~= nil or file:match("%.mobi$") ~= nil
end

local function freeImage(image)
    if image and image.free then
        image:free()
    end
end

local function dimensions(bb)
    if not bb then
        return nil, nil
    end
    local w = bb.getWidth and bb:getWidth() or bb.w
    local h = bb.getHeight and bb:getHeight() or bb.h
    return w, h
end

local function expandRect(rect, width, height, settings)
    if settings.crop_mode ~= "loose" then
        return rect
    end
    local bleed = math.max(
        settings.panel_bleed_min or Settings.defaults.panel_bleed_min,
        math.max(rect.w, rect.h) * (settings.panel_bleed_ratio or Settings.defaults.panel_bleed_ratio)
    )
    local x = math.max(0, rect.x - bleed)
    local y = math.max(0, rect.y - bleed)
    local right = math.min(width, rect.x + rect.w + bleed)
    local bottom = math.min(height, rect.y + rect.h + bleed)
    return { x = x, y = y, w = math.max(1, right - x), h = math.max(1, bottom - y) }
end

local function cropImage(source, rect)
    local source_w, source_h = dimensions(source)
    if not source_w or not source_h or not source.getType then
        return nil
    end
    local x = math.max(0, math.floor(rect.x + 0.5))
    local y = math.max(0, math.floor(rect.y + 0.5))
    local w = math.min(source_w - x, math.max(1, math.floor(rect.w + 0.5)))
    local h = math.min(source_h - y, math.max(1, math.floor(rect.h + 0.5)))
    if w <= 0 or h <= 0 then
        return nil
    end
    local crop = Blitbuffer.new(w, h, source:getType())
    crop:blitFrom(source, 0, 0, x, y, w, h)
    return crop
end

--- Render an extracted image using the shared no-crop panel viewport. This
--- matches the fixed-layout behavior: the selected panel is centred in a
--- screen-aspect canvas, with white padding only where that viewport reaches
--- beyond the image edge.
local function buildNoCropImage(source, rect, source_size)
    local viewport = PanelViewport.noCrop(rect, source_size)
    if not viewport then
        return function()
            return cropImage(source, rect)
        end, rect
    end

    local image_rect = {
        x = viewport.union_x,
        y = viewport.union_y,
        w = math.max(1, viewport.union_w),
        h = math.max(1, viewport.union_h),
    }
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    return function()
        if viewport.union_w <= 0 or viewport.union_h <= 0 then
            local canvas = Blitbuffer.new(screen_w, screen_h, source:getType())
            canvas:fill(Blitbuffer.COLOR_WHITE)
            return canvas
        end

        local content = cropImage(source, image_rect)
        if not content then
            return nil
        end
        local canvas
        local ok = pcall(function()
            local scaled_w = math.max(1, math.floor(viewport.union_w * viewport.scale + 0.5))
            local scaled_h = math.max(1, math.floor(viewport.union_h * viewport.scale + 0.5))
            content = RenderImage:scaleBlitBuffer(content, scaled_w, scaled_h, true)
            canvas = Blitbuffer.new(screen_w, screen_h, content:getType())
            canvas:fill(Blitbuffer.COLOR_WHITE)
            local paste_x = math.max(0, math.floor((viewport.union_x - viewport.box_x) * viewport.scale + 0.5))
            local paste_y = math.max(0, math.floor((viewport.union_y - viewport.box_y) * viewport.scale + 0.5))
            local blit_w = math.min(content:getWidth(), screen_w - paste_x)
            local blit_h = math.min(content:getHeight(), screen_h - paste_y)
            if blit_w > 0 and blit_h > 0 then
                canvas:blitFrom(content, paste_x, paste_y, 0, 0, blit_w, blit_h)
            end
        end)
        if content and content.free then
            content:free()
        end
        if ok then
            return canvas
        end
        if canvas and canvas.free then
            canvas:free()
        end
        return nil
    end,
        image_rect
end

--- Render two embedded-image panels' source union at the exact scale the
--- fixed-layout smooth transition expects. The generic camera code owns the
--- returned buffer and frees it after copying it into its transition canvas.
--- A raw union is capped before copying: unlike document pages, EPUB/KEPUB/MOBI
--- images can be very large decoded bitmaps.
local function renderImageUnion(source, union, zoom)
    local screen_area = Screen:getWidth() * Screen:getHeight()
    if (union.w or 0) * (union.h or 0) > screen_area * 4 then
        Timing.log("embedded smooth transition skipped: source union is too large")
        return nil
    end

    local content = cropImage(source, union)
    if not content then
        return nil
    end
    local scaled
    local ok = pcall(function()
        scaled = RenderImage:scaleBlitBuffer(
            content,
            math.max(1, math.ceil((union.w or 1) * zoom)),
            math.max(1, math.ceil((union.h or 1) * zoom)),
            true
        )
        content = nil
    end)
    if not ok then
        freeImage(scaled)
        freeImage(content)
        return nil
    end
    return scaled
end

local function extractImage(document, pos)
    local ok, image = pcall(document.getImageFromPosition, document, pos, false, false)
    if ok and image and type(image.getType) == "function" then
        return image
    end
    freeImage(image)
    return nil
end

--- Move ReaderRolling while an embedded-image boundary search is hidden by
--- the still-open panel viewer. ReaderRolling emits `PageChangeAnimation` for
--- every `GotoPage`; on supported e-ink devices that arms a one-shot hardware
--- swipe for the next refresh. Cancel that one-shot after the synchronous
--- event dispatch so intervening text pages do not each animate underneath
--- the overlay. The successful replacement explicitly arms one final swipe.
local function gotoSearchPage(ui, page)
    ui:handleEvent(Event:new("GotoPage", page))
    if type(Screen.setSwipeAnimations) == "function" then
        Screen:setSwipeAnimations(false)
    end
end

local function startIndex(panels, point)
    if not point then
        return 1
    end
    local best_idx, best_distance = 1, math.huge
    for index, panel in ipairs(panels) do
        local cx, cy = Geometry.rectCenter(panel)
        local distance = (cx - point.x) ^ 2 + (cy - point.y) ^ 2
        if distance < best_distance then
            best_idx, best_distance = index, distance
        end
    end
    return best_idx
end

--- Match fixed-layout detection and retain sparse images in the sequence.
local function detectPanels(image, settings)
    local map = PageBitmap.buildFromBlitbuffer(image, settings)
    if map then
        local panels = ComponentDetector.detectPage(map, settings)
        return panels, "components"
    end
    local native = NativeDetector.collectFromBlitbuffer(image, settings)
    if #native > 0 then
        return native, "exact"
    end
    local width, height = dimensions(image)
    if width and height and width > 0 and height > 0 then
        return { { x = 0, y = 0, w = width, h = height } }, "full page"
    end
    return nil, "invalid image dimensions"
end

--- Open an already-extracted image. This takes ownership of `image` on
--- success and frees it when detection rejects the bitmap.
function EmbeddedImage:showEmbeddedImagePanelsForImage(image, options)
    options = options or {}
    local width, height = dimensions(image)
    if not width or not height then
        freeImage(image)
        return false
    end

    local panels, detector_or_reason = detectPanels(image, self.settings)
    if not panels then
        Timing.log("embedded image detector rejected: " .. tostring(detector_or_reason))
        freeImage(image)
        return false
    end
    panels = Geometry.sortReadingOrder(panels, self.settings.mode)

    local images = { image_disposable = true }
    local image_rects, full_page_flags = {}, {}
    for _, panel in ipairs(panels) do
        local image_rect = expandRect(panel, width, height, self.settings)
        table.insert(image_rects, image_rect)
        table.insert(
            full_page_flags,
            panel.w * panel.h >= (self.settings.full_page_panel_ratio or 0.92) * width * height
        )
        if self.settings.crop_mode == "none" then
            local image_func, viewport_rect = buildNoCropImage(image, panel, { w = width, h = height })
            image_rects[#image_rects] = viewport_rect
            table.insert(images, image_func)
        else
            table.insert(images, function()
                return cropImage(image, image_rect)
            end)
        end
    end

    local viewer = PanelViewer:new({
        image = images,
        image_disposable = true,
        images_list_nb = #images,
        panels = panels,
        image_rects = image_rects,
        panel_is_full_page = full_page_flags,
        reader_ui = self.ui,
        embedded_source_image = image,
        reading_mode = self.settings.mode,
        crop_mode = self.settings.crop_mode,
        margin_ratio = self.settings.panel_margin_ratio,
        bleed_ratio = self.settings.panel_bleed_ratio,
        detector = "exact",
        invert_swipe = self.settings.invert_swipe == true,
        invert_taps = self.settings.invert_taps == true,
        tap_navigation = self.settings.tap_navigation == true,
        swipe_navigation = self.settings.swipe_navigation ~= false,
        kobo_vertical_gesture = self.settings.kobo_vertical_gesture ~= false,
        progress_bar_visible = self.settings.progress_bar_visible ~= false,
        hold_text_selection = false,
        image_rotation = self.settings.image_rotation,
        -- Smooth movement is rendered only from the extracted bitmap. This
        -- leaves the normal document-page renderer untouched.
        nav_transition_mode = self.settings.embedded_nav_transition_mode or "classic",
        nav_animated_panels = self.settings.nav_animated_panels ~= false,
        nav_animated_pages = self.settings.nav_animated_pages ~= false,
        nav_transition_duration = self.settings.nav_transition_duration or Settings.defaults.nav_transition_duration,
        nav_transition_cross_page = false,
        nav_transition_frames = self.settings.nav_transition_frames or Settings.defaults.nav_transition_frames,
        image_union_renderer = function(union, zoom)
            return renderImageUnion(image, union, zoom)
        end,
        buttons_visible = options.buttons_visible == true,
        boundary_callback = function(direction, current_viewer)
            return self:onEmbeddedImageBoundary(direction, current_viewer)
        end,
        embedded_cleanup_callback = function(current_viewer)
            self:cancelEmbeddedImageSearch(current_viewer)
        end,
        mode_toggle_callback = function(current_viewer)
            local next_mode = (current_viewer.reading_mode or self.settings.mode) == "manga" and "comic" or "manga"
            self:setMode(next_mode)
            return self:reopenEmbeddedImagePanels(current_viewer)
        end,
        crop_toggle_callback = function(current_viewer)
            local next_mode = { strict = "loose", loose = "margin", margin = "none", none = "strict" }
            self:setCropMode(next_mode[self.settings.crop_mode] or "strict")
            return self:reopenEmbeddedImagePanels(current_viewer)
        end,
        margin_ratio_callback = function(current_viewer, ratio, activate_margin_mode)
            self:setMarginRatio(ratio)
            if activate_margin_mode then
                self:setCropMode("margin")
            end
            current_viewer.margin_ratio = self.settings.panel_margin_ratio
            current_viewer.crop_mode = self.settings.crop_mode
            current_viewer:replaceButtonTable()
            current_viewer:update()
            return true
        end,
        bleed_ratio_callback = function(current_viewer, ratio, activate_loose_mode)
            self:setBleedRatio(ratio)
            if activate_loose_mode then
                self:setCropMode("loose")
            end
            return self:reopenEmbeddedImagePanels(current_viewer)
        end,
        progress_bar_toggle_callback = function(current_viewer)
            self:setProgressBarVisible(current_viewer.progress_bar_visible == false)
            current_viewer.progress_bar_visible = self.settings.progress_bar_visible ~= false
            current_viewer:replaceButtonTable()
            current_viewer:update()
            return true
        end,
        nav_transition_toggle_callback = function(current_viewer)
            local next_mode = { classic = "smooth", smooth = "animated", animated = "classic" }
            next_mode = next_mode[self.settings.embedded_nav_transition_mode] or "classic"
            self:setEmbeddedNavTransitionMode(next_mode)
            current_viewer.nav_transition_mode = self.settings.embedded_nav_transition_mode
            current_viewer:replaceButtonTable()
            current_viewer:update()
            if self.settings.embedded_nav_transition_mode == "animated" then
                self:notifyAnimatedModeUnsupported()
            end
            return true
        end,
        nav_transition_duration_callback = function(current_viewer, seconds)
            self:setNavTransitionDuration(seconds)
            current_viewer.nav_transition_duration = self.settings.nav_transition_duration
            return true
        end,
        nav_transition_frames_callback = function(current_viewer, frames)
            self:setNavTransitionFrames(frames)
            current_viewer.nav_transition_frames = self.settings.nav_transition_frames
            return true
        end,
        nav_transition_cross_page_callback = function(current_viewer, enabled)
            self:setNavTransitionCrossPage(enabled)
            current_viewer.nav_transition_cross_page = self.settings.nav_transition_cross_page == true
            return true
        end,
        nav_transition_options_callback = function(current_viewer)
            return self:showNavTransitionOptionsMenu(current_viewer)
        end,
        panel_animation_callback = function(direction, current_viewer)
            return self:armPanelTransitionAnimation(direction, current_viewer)
        end,
        image_rotation_callback = function(_, value)
            self:setImageRotation(value)
            return true
        end,
        device_rotate_callback = function(current_viewer, mode)
            return self:setDeviceRotation(current_viewer, mode)
        end,
        screen_resize_callback = function(current_viewer)
            return self:reopenEmbeddedImagePanels(current_viewer, {
                buttons_visible = current_viewer.buttons_visible,
            })
        end,
        more_config_callback = function(current_viewer)
            return self:showMoreConfigMenu(current_viewer)
        end,
    })
    if options.replace_viewer then
        -- All search-page turns were deliberately silent. Arm one animation
        -- only now, immediately before the old crop is replaced by the
        -- destination crop. The shared controller applies the Panels+/KOReader
        -- sync preference and suppresses this while Smooth mode is selected.
        if options.boundary_direction then
            self:armPageTurnAnimation(options.boundary_direction, options.replace_viewer)
        end
        UIManager:close(options.replace_viewer)
    end
    UIManager:show(viewer)
    -- A forward boundary lands at the first panel of the next image, while a
    -- backward boundary must land at the last panel of the previous image.
    -- Starting at panel 1 in both directions made backward page crossings
    -- look like a broken smooth transition and skipped the expected endpoint.
    local index = options.boundary_direction == "previous" and #panels or startIndex(panels, options.start_point)
    if index > 1 then
        viewer:switchToImageNum(index)
    end
    return true
end

--- Rebuild an embedded image viewer after changing its reading order or crop.
function EmbeddedImage:reopenEmbeddedImagePanels(viewer, options)
    -- A boundary search intentionally releases the source before it crosses
    -- reflow pages. Ignore a late menu/button action rather than closing the
    -- still-visible current crop and attempting to rebuild from nil.
    if viewer._panels_plus_boundary_pending or not viewer.embedded_source_image then
        return true
    end
    local panel = viewer.panels and viewer.panels[viewer._images_list_cur or 1]
    local start_point = panel
        and {
            x = (panel.x or 0) + (panel.w or 0) / 2,
            y = (panel.y or 0) + (panel.h or 0) / 2,
        }
    local image = viewer.embedded_source_image
    local buttons_visible = options and options.buttons_visible
    if buttons_visible == nil then
        buttons_visible = true
    end
    viewer.embedded_source_image = nil -- transfer ownership to the replacement viewer
    UIManager:close(viewer)
    return self:showEmbeddedImagePanelsForImage(image, { start_point = start_point, buttons_visible = buttons_visible })
end

--- Rotate the device/screen and reopen the embedded image viewer at the current panel.
function EmbeddedImage:setDeviceRotation(viewer, mode)
    if viewer._panels_plus_boundary_pending or not viewer.embedded_source_image then
        return true
    end
    local panel = viewer.panels and viewer.panels[viewer._images_list_cur or 1]
    local start_point = panel
        and {
            x = (panel.x or 0) + (panel.w or 0) / 2,
            y = (panel.y or 0) + (panel.h or 0) / 2,
        }
    local image = viewer.embedded_source_image
    local buttons_visible = viewer.buttons_visible
    viewer.embedded_source_image = nil -- transfer ownership to the replacement viewer
    UIManager:close(viewer)
    UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
    UIManager:onRotation()
    return self:showEmbeddedImagePanelsForImage(image, {
        start_point = start_point,
        buttons_visible = buttons_visible,
    })
end

--- Probe a reader page for an image. ReaderRolling positions use screen
--- coordinates directly, so a modest grid finds an image even when it is not
--- centred on its text page.
function EmbeddedImage:findEmbeddedImageOnCurrentPage()
    local ui = self.ui
    local document, view = ui and ui.document, ui and ui.view
    if not document or not view or type(document.getImageFromPosition) ~= "function" then
        return nil
    end
    for _, y_ratio in ipairs(IMAGE_SEARCH_YS) do
        for _, x_ratio in ipairs(IMAGE_SEARCH_XS) do
            local pos = view:screenToPageTransform({
                x = math.floor(Screen:getWidth() * x_ratio),
                y = math.floor(Screen:getHeight() * y_ratio),
            })
            if pos then
                local image = extractImage(document, pos)
                if image then
                    return image
                end
            end
        end
    end
    return nil
end

--- Invalidate queued reflow-page searches. `tickAfterNext()` has no public
--- cancellation handle, so a generation token makes stale callbacks harmless
--- as soon as a viewer or document closes.
--- @param viewer PanelViewer|nil Viewer whose search should be cancelled.
function EmbeddedImage:cancelEmbeddedImageSearch(viewer)
    self._embedded_search_generation = (self._embedded_search_generation or 0) + 1
    if not viewer or self._embedded_search_viewer == viewer then
        self._embedded_search_viewer = nil
    end
end

--- Queue one search step only while its embedded viewer remains current.
local function scheduleEmbeddedImageSearch(plugin, page, direction, viewer, generation)
    UIManager:tickAfterNext(function()
        if
            plugin._embedded_search_generation ~= generation
            or plugin._embedded_search_viewer ~= viewer
            or (viewer and viewer._panels_plus_closed)
        then
            return
        end
        plugin:openNextEmbeddedImagePage(page, direction, viewer, generation)
    end)
end

--- Turn through reflow pages until another image with a panel layout appears.
function EmbeddedImage:openNextEmbeddedImagePage(page, direction, viewer, generation)
    local ui, document = self.ui, self.ui and self.ui.document
    if
        not document
        or (generation and generation ~= self._embedded_search_generation)
        or (viewer and viewer._panels_plus_closed)
    then
        return false
    end
    local image = self:findEmbeddedImageOnCurrentPage()
    if
        image
        and self:showEmbeddedImagePanelsForImage(image, {
            replace_viewer = viewer,
            boundary_direction = direction,
        })
    then
        return true
    end

    local next_page = direction == "next" and document:getNextPage(page) or document:getPrevPage(page)
    if not next_page or next_page == 0 then
        if viewer then
            UIManager:close(viewer)
        end
        return false
    end
    gotoSearchPage(ui, next_page)
    scheduleEmbeddedImageSearch(self, next_page, direction, viewer, generation)
    return true
end

--- Continue past the first/last panel by seeking the next/previous image.
function EmbeddedImage:onEmbeddedImageBoundary(direction, viewer)
    if viewer._panels_plus_boundary_pending then
        return true
    end
    viewer._panels_plus_boundary_pending = true
    local document = self.ui and self.ui.document
    local page = document and document:getCurrentPage()
    local next_page = page and (direction == "next" and document:getNextPage(page) or document:getPrevPage(page))
    if not next_page or next_page == 0 then
        viewer._panels_plus_boundary_pending = nil
        return true
    end

    if self.cancelEmbeddedImageSearch then
        self:cancelEmbeddedImageSearch()
    else
        self._embedded_search_generation = (self._embedded_search_generation or 0) + 1
    end
    local generation = self._embedded_search_generation
    self._embedded_search_viewer = viewer
    -- Keep the active, already-rendered crop visible, but discard the full
    -- source image and lazy crop closures before scanning subsequent pages.
    if viewer.releaseEmbeddedSource then
        viewer:releaseEmbeddedSource(true)
    end

    gotoSearchPage(self.ui, next_page)
    scheduleEmbeddedImageSearch(self, next_page, direction, viewer, generation)
    return true
end

--- Open Panels+ on an image embedded in a supported reflowable document.
---
--- This includes Kobo-synced `.kepub.epub` books and directly named `.kepub`
--- files when a KOReader provider has opened them in ReaderRolling.
--- Returning false deliberately lets ReaderHighlight resume its native image
--- viewer or text-selection path when the hold was not on a usable bitmap.
function EmbeddedImage:showEmbeddedImagePanels(reader_highlight, ges)
    local ui = self.ui
    local document = ui and ui.document
    if not (ui and ui.rolling and isSupportedDocument(document)) then
        return false
    end
    local view = reader_highlight and reader_highlight.view
    local pos = view and view.screenToPageTransform and view:screenToPageTransform(ges and ges.pos)
    if not pos or type(document.getImageFromPosition) ~= "function" then
        return false
    end

    local image = extractImage(document, pos)
    if not image then
        return false
    end
    local shown = self:showEmbeddedImagePanelsForImage(image)
    if shown then
        reader_highlight:clear()
    end
    return shown
end

--- Show a centered info message if Animated mode is selected on a device that doesn't support hardware swipe animations.
function EmbeddedImage:notifyAnimatedModeUnsupported()
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.canDoSwipeAnimation and Device:canDoSwipeAnimation() then
        return
    end
    local _ = require("gettext")
    local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok_info and InfoMessage and InfoMessage.new then
        pcall(function()
            UIManager:show(InfoMessage:new({
                text = _(
                    "Requires special e-ink devices swipe hardware support (Kindles, Kobos, etc..) not compatible with Android and Desktop (Linux)"
                ),
                timeout = 3,
            }))
        end)
    end
end

return EmbeddedImage
