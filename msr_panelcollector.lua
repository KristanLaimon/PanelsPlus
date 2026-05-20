local Geometry = require("msr_geometry")
local Settings = require("msr_settings")

local PanelCollector = {}

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
            if not panels_by_key[key] then
                panels_by_key[key] = true
                table.insert(panels, rect)
            end
        end
    end

    addPanel(hold_pos)
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

function PanelCollector.buildImages(ui, page, panels)
    local document = ui.document
    local images = {
        image_disposable = false,
    }

    for _, rect in ipairs(panels) do
        table.insert(images, function()
            local image, rotate = document:drawPagePart(page, rect, 0)
            images.rotated = rotate
            return image
        end)
    end

    return images
end

return PanelCollector
