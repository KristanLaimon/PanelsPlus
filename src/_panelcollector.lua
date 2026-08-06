local Blitbuffer = require("ffi/blitbuffer")
local Geometry = require("src._geometry")
local NativeDetector = require("src._nativedetector")
local PageBitmap = require("src._pagebitmap")
local Segmenter = require("src._segmenter")
local Settings = require("src._settings")
local Timing = require("src._timing")
local Screen = require("device").screen

--- Panel detection dispatch and lazy image-list construction.
---
--- Two detectors are available and they fail in different places, so the
--- default is to run the cheap one and fall back:
---
--- * `src._segmenter` slices a low-resolution ink map. One page render, works on
---   any background colour, but cannot separate interlocking layouts.
--- * `src._nativedetector` drives KOReader's k2pdfopt detector. Handles awkward
---   layouts, but only recognizes white gutters and costs a full-resolution
---   page rasterization.
---
--- @class PPPanelCollectorModule
local PanelCollector = {}

--- Expand a panel crop by the configured bleed while staying inside the page.
---
--- @param rect PPPanel Native panel rectangle.
--- @param page_size PPPageSize Page dimensions.
--- @param settings PPSettings Plugin settings.
--- @return PPPanel rect Expanded rectangle.
local function expandRect(rect, page_size, settings)
    local ratio = settings.panel_bleed_ratio or Settings.defaults.panel_bleed_ratio
    local min_bleed = settings.panel_bleed_min or Settings.defaults.panel_bleed_min

    local rx = rect.x or 0
    local ry = rect.y or 0
    local rw = rect.w or 0
    local rh = rect.h or 0
    local pw = page_size.w or 0
    local ph = page_size.h or 0

    local panel_dim = math.max(rw, rh)
    local bleed = math.max(min_bleed, panel_dim * ratio)

    local x = math.max(0, rx - bleed)
    local y = math.max(0, ry - bleed)
    local right = math.min(pw, rx + rw + bleed)
    local bottom = math.min(ph, ry + rh + bleed)

    return {
        x = x,
        y = y,
        w = math.max(1, right - x),
        h = math.max(1, bottom - y),
    }
end

--- Expand or keep a panel rectangle for rendering.
---
--- @param rect PPPanel Native panel rectangle.
--- @param page_size PPPageSize|nil Page dimensions.
--- @param settings PPSettings Plugin settings.
--- @return PPPanel rect Rectangle passed to drawPagePart().
local function getImageRect(rect, page_size, settings)
    if settings.crop_mode == "loose" and page_size then
        return expandRect(rect, page_size, settings)
    end
    return rect
end

--- Build a centered canvas image for "No crop" mode.
---
--- Centers the panel's width (`rect.w`) to fill the screen width (`Screen:getWidth()`),
--- and centers its height vertically in the screen. Any region outside the document
--- page boundaries is filled with a white background.
---
--- @param document table KOReader document instance.
--- @param page number Document page number.
--- @param rect PPPanel Native panel rectangle.
--- @param page_size PPPageSize Page dimensions.
--- @return function image_func Lazy function returning the composite Blitbuffer image.
--- @return PPPanel image_rect Bounding rectangle used for transition math.
local function buildNoCropImage(document, page, rect, page_size)
    local rx = rect.x or 0
    local ry = rect.y or 0
    local rw = math.max(1, rect.w or 0)
    local rh = math.max(1, rect.h or 0)
    local pw = page_size and page_size.w or 0
    local ph = page_size and page_size.h or 0

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    if screen_w <= 0 or screen_h <= 0 or pw <= 0 or ph <= 0 then
        local image_rect = rect
        return function()
            local img, rotate = document:drawPagePart(page, image_rect, 0)
            if img and img.copy then return img:copy() end
            return img
        end, image_rect
    end

    local scale = math.min(screen_w / rw, screen_h / rh)
    local box_w = screen_w / scale
    local box_h = screen_h / scale
    local cx = rx + rw / 2
    local cy = ry + rh / 2

    local box_x = cx - box_w / 2
    local box_y = cy - box_h / 2

    local union_x = math.max(0, box_x)
    local union_y = math.max(0, box_y)
    local union_right = math.min(pw, box_x + box_w)
    local union_bottom = math.min(ph, box_y + box_h)
    local union_w = math.max(0, union_right - union_x)
    local union_h = math.max(0, union_bottom - union_y)

    local image_rect = {
        x = union_x,
        y = union_y,
        w = math.max(1, union_w),
        h = math.max(1, union_h),
    }

    local image_func = function()
        if union_w <= 0 or union_h <= 0 then
            local canvas = Blitbuffer.new(screen_w, screen_h, Blitbuffer.TYPE_BWRGB_8888)
            canvas:fill(Blitbuffer.COLOR_WHITE)
            return canvas
        end

        local content_image, rotate = document:drawPagePart(page, image_rect, 0)
        if not content_image then
            local canvas = Blitbuffer.new(screen_w, screen_h, Blitbuffer.TYPE_BWRGB_8888)
            canvas:fill(Blitbuffer.COLOR_WHITE)
            return canvas
        end

        local canvas_w = screen_w
        local canvas_h = screen_h
        local canvas
        local ok = pcall(function()
            canvas = Blitbuffer.new(canvas_w, canvas_h, content_image:getType())
            canvas:fill(Blitbuffer.COLOR_WHITE)

            local paste_x = math.max(0, math.floor((union_x - box_x) * scale + 0.5))
            local paste_y = math.max(0, math.floor((union_y - box_y) * scale + 0.5))
            local blit_w = math.min(content_image:getWidth(), canvas_w - paste_x)
            local blit_h = math.min(content_image:getHeight(), canvas_h - paste_y)

            if blit_w > 0 and blit_h > 0 then
                canvas:blitFrom(content_image, paste_x, paste_y, 0, 0, blit_w, blit_h)
            end
        end)

        if ok then
            return canvas
        end

        -- The allocation above can succeed and then fail during fill/blit
        -- (e.g. a type mismatch on an unusual page render); free it rather
        -- than losing the only reference to an already-allocated buffer.
        if canvas and canvas.free then
            canvas:free()
        end

        if content_image and content_image.copy then
            return content_image:copy()
        end
        return content_image
    end

    return image_func, image_rect
end

--- Run the fast segmenter, returning nil when its result cannot be trusted.
---
--- @param ui table KOReader reader UI object.
--- @param settings PPSettings Plugin settings.
--- @param page number Document page number.
--- @return PPPanel[]|nil panels Ordered panel rectangles, or nil to fall back.
local function segment(ui, settings, page)
    local map, reason = PageBitmap.build(ui.document, page, settings)
    if not map then
        Timing.log("segmenter skipped: " .. tostring(reason))
        return nil
    end

    local panels = Segmenter.segment(map, settings)
    local accepted, rejection = Segmenter.accept(panels, map, settings)
    if not accepted then
        Timing.log("segmenter rejected: " .. tostring(rejection))
        return nil
    end

    return Geometry.sortReadingOrder(panels, settings.mode)
end

--- Collect a page's ordered panel rectangles.
---
--- @param ui table KOReader reader UI object.
--- @param settings PPSettings Plugin settings.
--- @param page number Document page number.
--- @param hold_pos PPPagePosition|nil Optional page-space position from the user's hold.
--- @return PPPanel[] panels Ordered panel rectangles.
function PanelCollector.collect(ui, settings, page, hold_pos)
    local detector = settings.detector or Settings.defaults.detector

    if detector ~= "exact" then
        local panels = segment(ui, settings, page)
        if panels then
            return panels
        end
        if detector == "fast" then
            return {}
        end
    end

    return NativeDetector.collect(ui, settings, page, hold_pos)
end

--- Find the panel index that should open for a hold position.
---
--- @param panels PPPanel[] Ordered panel rectangles.
--- @param hold_pos PPPagePosition|{x:number,y:number} Page-space position.
--- @return integer index 1-based index of containing or nearest panel.
function PanelCollector.startIndex(panels, hold_pos)
    local best_idx, best_dist = 1, math.huge
    for idx, rect in ipairs(panels) do
        if Geometry.rectContains(rect, hold_pos) then
            return idx
        end
        local cx, cy = Geometry.rectCenter(rect)
        local dist = (cx - hold_pos.x) ^ 2 + (cy - hold_pos.y) ^ 2
        if dist < best_dist then
            best_idx, best_dist = idx, dist
        end
    end
    return best_idx
end

--- Return whether a native panel rectangle spans nearly the whole page.
---
--- Reuses `full_page_panel_ratio`, the same threshold the segmenter uses to
--- recognize a splash page, so "full page" means the same thing everywhere
--- in the plugin.
---
--- @param rect PPPanel Native panel rectangle (pre-crop-mode expansion).
--- @param page_size PPPageSize|nil Page dimensions.
--- @param settings PPSettings Plugin settings.
--- @return boolean is_full_page `true` when the panel covers most of the page.
local function isFullPagePanel(rect, page_size, settings)
    if not page_size or (page_size.w or 0) <= 0 or (page_size.h or 0) <= 0 then
        return false
    end
    local full_ratio = settings.full_page_panel_ratio or Settings.defaults.full_page_panel_ratio
    local page_area = page_size.w * page_size.h
    local rect_area = (rect.w or 0) * (rect.h or 0)
    return rect_area >= full_ratio * page_area
end

--- Build KOReader ImageViewer lazy image functions for a panel sequence.
---
--- This intentionally stores functions, not rendered blitbuffers. Each visit
--- gets a fresh private copy because drawPagePart() returns a renderPage tile
--- buffer owned by KOReader's document/cache layer.
---
--- @param ui table KOReader reader UI object.
--- @param page number Document page number.
--- @param panels PPPanel[] Ordered panel rectangles.
--- @param settings PPSettings Plugin settings.
--- @return PPImageList images Lazy image list for ImageViewer.
--- @return PPPanel[] image_rects Crop rectangles matching `images`, for prerendering.
--- @return boolean[] full_page_flags Per-panel flag matching `images`, for margin-mode gating.
function PanelCollector.buildImages(ui, page, panels, settings)
    local document = ui.document
    local page_size = document:getPageDimensions(page, 1, 0)
    settings = settings or Settings.defaults
    local images = {
        image_disposable = true,
    }
    local image_rects = {}
    local full_page_flags = {}

    for _, rect in ipairs(panels) do
        table.insert(full_page_flags, isFullPagePanel(rect, page_size, settings))
        if settings.crop_mode == "none" then
            local image_func, image_rect = buildNoCropImage(document, page, rect, page_size)
            table.insert(image_rects, image_rect)
            table.insert(images, image_func)
        else
            local image_rect = getImageRect(rect, page_size, settings)
            table.insert(image_rects, image_rect)
            table.insert(images, function()
                local image, rotate = document:drawPagePart(page, image_rect, 0)
                images.rotated = rotate
                if image and image.copy then
                    return image:copy()
                end
                return image
            end)
        end
    end

    return images, image_rects, full_page_flags
end

PanelCollector._getImageRect = getImageRect

return PanelCollector
