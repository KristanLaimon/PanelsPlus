local Geometry = require("src._geometry")
local NativeDetector = require("src._nativedetector")
local PageBitmap = require("src._pagebitmap")
local Segmenter = require("src._segmenter")
local Settings = require("src._settings")
local Timing = require("src._timing")

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
    local bleed = math.max(min_bleed, math.min(rect.w or 0, rect.h or 0) * ratio)
    local x = math.max(0, (rect.x or 0) - bleed)
    local y = math.max(0, (rect.y or 0) - bleed)
    local right = math.min(page_size.w, (rect.x or 0) + (rect.w or 0) + bleed)
    local bottom = math.min(page_size.h, (rect.y or 0) + (rect.h or 0) + bleed)

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

    if detector ~= "native" then
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
function PanelCollector.buildImages(ui, page, panels, settings)
    local document = ui.document
    local page_size = document:getPageDimensions(page, 1, 0)
    settings = settings or Settings.defaults
    local images = {
        image_disposable = true,
    }

    for _, rect in ipairs(panels) do
        local image_rect = getImageRect(rect, page_size, settings)
        table.insert(images, function()
            local image, rotate = document:drawPagePart(page, image_rect, 0)
            images.rotated = rotate
            if image and image.copy then
                return image:copy()
            end
            return image
        end)
    end

    return images
end

return PanelCollector
