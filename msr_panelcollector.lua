local Geometry = require("msr_geometry")
local Settings = require("msr_settings")

local PanelCollector = {}

local function isFullPagePanel(rect, page_size, settings)
    if not rect or not page_size or not page_size.w or not page_size.h then
        return false
    end
    local page_area = page_size.w * page_size.h
    if page_area <= 0 then
        return false
    end
    local ratio = settings.full_page_panel_ratio or Settings.defaults.full_page_panel_ratio
    local area_ratio = ((rect.w or 0) * (rect.h or 0)) / page_area
    local edge_slop = math.max(4, math.min(page_size.w, page_size.h) * 0.03)
    return area_ratio >= ratio
        and (rect.x or 0) <= edge_slop
        and (rect.y or 0) <= edge_slop
        and ((rect.x or 0) + (rect.w or 0)) >= page_size.w - edge_slop
        and ((rect.y or 0) + (rect.h or 0)) >= page_size.h - edge_slop
end

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

function PanelCollector.collect(ui, settings, page, hold_pos)
    local document = ui.document
    local page_size = document:getPageDimensions(page, 1, 0)
    if not page_size then
        return {}
    end

    local cols = settings.panel_grid_cols or Settings.defaults.panel_grid_cols
    local rows = settings.panel_grid_rows or Settings.defaults.panel_grid_rows
    local panels_by_key = {}
    local panels = {}

    local function addPanel(pos)
        local ok, rect = pcall(document.getPanelFromPage, document, page, pos)
        if ok and rect and rect.w and rect.h and rect.w > 0 and rect.h > 0 then
            local key = Geometry.rectKey(rect)
            if not isFullPagePanel(rect, page_size, settings) and not panels_by_key[key] then
                panels_by_key[key] = true
                table.insert(panels, rect)
            end
        end
    end

    if hold_pos then
        addPanel(hold_pos)
    end
    for row = 1, rows do
        for col = 1, cols do
            addPanel({
                page = page,
                x = page_size.w * (col - 0.5) / cols,
                y = page_size.h * (row - 0.5) / rows,
            })
        end
    end

    table.sort(panels, function(a, b)
        if Geometry.sameRow(a, b) then
            if settings.mode == "comic" then
                return a.x < b.x
            end
            return a.x > b.x
        end
        return a.y < b.y
    end)

    return panels
end

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

function PanelCollector.buildImages(ui, page, panels, settings)
    local document = ui.document
    local page_size = document:getPageDimensions(page, 1, 0)
    settings = settings or Settings.defaults
    local images = {
        image_disposable = false,
    }

    for _, rect in ipairs(panels) do
        local image_rect = rect
        if settings.crop_mode == "loose" and page_size then
            image_rect = expandRect(rect, page_size, settings)
        end
        table.insert(images, function()
            local image, rotate = document:drawPagePart(page, image_rect, 0)
            images.rotated = rotate
            return image
        end)
    end

    return images
end

return PanelCollector
