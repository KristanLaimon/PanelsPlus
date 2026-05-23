local Geometry = require("src._geometry")
local Settings = require("src._settings")

--- Panel detection, sorting, and lazy image-list construction.
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

--- Add a detector probe point if its floored coordinate has not been used.
---
--- @param probes PPPagePosition[] Mutable probe list.
--- @param seen table<string, boolean> Coordinate-key set.
--- @param page number Document page number.
--- @param x number Page-space x coordinate.
--- @param y number Page-space y coordinate.
local function addProbe(probes, seen, page, x, y)
    local key = math.floor(x) .. ":" .. math.floor(y)
    if seen[key] then
        return
    end
    seen[key] = true
    table.insert(probes, {
        page = page,
        x = x,
        y = y,
    })
end

--- Add the center point of one probe-grid cell.
---
--- @param probes PPPagePosition[] Mutable probe list.
--- @param seen table<string, boolean> Coordinate-key set.
--- @param page number Document page number.
--- @param page_size PPPageSize Page dimensions.
--- @param col integer 1-based grid column.
--- @param row integer 1-based grid row.
--- @param cols integer Total grid columns.
--- @param rows integer Total grid rows.
local function addGridProbe(probes, seen, page, page_size, col, row, cols, rows)
    addProbe(
        probes,
        seen,
        page,
        page_size.w * (col - 0.5) / cols,
        page_size.h * (row - 0.5) / rows
    )
end

--- Build an ordered list of points to pass to KOReader's native detector.
---
--- The order favors the user's hold position, then the center, then likely
--- reading-path cells before falling back to the complete grid.
---
--- @param page number Document page number.
--- @param page_size PPPageSize Page dimensions.
--- @param settings PPSettings Plugin settings.
--- @param hold_pos PPPagePosition|nil Optional hold position.
--- @return PPPagePosition[] probes Ordered detector probe points.
local function buildProbePlan(page, page_size, settings, hold_pos)
    local cols = settings.panel_grid_cols or Settings.defaults.panel_grid_cols
    local rows = settings.panel_grid_rows or Settings.defaults.panel_grid_rows
    local probes, seen = {}, {}
    local center_col = math.ceil(cols / 2)
    local center_row = math.ceil(rows / 2)
    local x_order = {}

    if settings.mode == "comic" then
        for col = 1, cols do
            table.insert(x_order, col)
        end
    else
        for col = cols, 1, -1 do
            table.insert(x_order, col)
        end
    end

    if hold_pos then
        addProbe(probes, seen, page, hold_pos.x, hold_pos.y)
    end

    addGridProbe(probes, seen, page, page_size, center_col, center_row, cols, rows)

    for row = 1, rows do
        addGridProbe(probes, seen, page, page_size, x_order[1], row, cols, rows)
    end

    for _, col in ipairs(x_order) do
        addGridProbe(probes, seen, page, page_size, col, center_row, cols, rows)
    end

    for row = 1, rows do
        for _, col in ipairs(x_order) do
            addGridProbe(probes, seen, page, page_size, col, row, cols, rows)
        end
    end

    return probes
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

--- Collect page panels by probing KOReader's native panel detector.
---
--- The detector call is relatively expensive on low-memory e-readers. The
--- probe plan checks the hold position, likely reading-path points, and finally
--- the full grid. Every point already covered by a discovered panel is skipped,
--- so large panels suppress many redundant probes while the full grid remains a
--- safety net for pages with many small panels.
---
--- @param ui table KOReader reader UI object.
--- @param settings PPSettings Plugin settings.
--- @param page number Document page number.
--- @param hold_pos PPPagePosition|nil Optional page-space position from the user's hold.
--- @return PPPanel[] panels Ordered panel rectangles.
function PanelCollector.collect(ui, settings, page, hold_pos)
    local document = ui.document
    local page_size = document:getPageDimensions(page, 1, 0)
    if not page_size then
        return {}
    end

    local panels_by_key = {}
    local panels = {}
    local probes = buildProbePlan(page, page_size, settings, hold_pos)

    --- Return whether a probe point is already covered by a found panel.
    ---
    --- @param pos PPPagePosition Probe point.
    --- @return boolean known Whether the point can be skipped.
    local function isKnownPanelPoint(pos)
        for _, rect in ipairs(panels) do
            if Geometry.rectContains(rect, pos) then
                return true
            end
        end
        return false
    end

    --- Probe the native detector and add a newly discovered panel.
    ---
    --- @param pos PPPagePosition Probe point.
    --- @param force boolean Whether to probe even when already inside a panel.
    local function addPanel(pos, force)
        if not force and isKnownPanelPoint(pos) then
            return
        end
        local ok, rect = pcall(document.getPanelFromPage, document, page, pos)
        if ok and rect and rect.w and rect.h and rect.w > 0 and rect.h > 0 then
            local key = Geometry.rectKey(rect)
            if not panels_by_key[key] then
                panels_by_key[key] = true
                table.insert(panels, rect)
            end
        end
    end

    for idx, pos in ipairs(probes) do
        addPanel(pos, hold_pos and idx == 1)
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
--- This intentionally stores functions, not rendered blitbuffers. The current
--- panel is decoded by ImageViewer, and later panels are decoded only when the
--- user navigates to them.
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
        image_disposable = false,
    }

    for _, rect in ipairs(panels) do
        local image_rect = getImageRect(rect, page_size, settings)
        table.insert(images, function()
            local image, rotate = document:drawPagePart(page, image_rect, 0)
            images.rotated = rotate
            return image
        end)
    end

    return images
end

return PanelCollector
