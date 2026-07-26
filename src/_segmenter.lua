local Settings = require("src._settings")
local Timing = require("src._timing")
local ffi = require("ffi")

--- Panel segmentation by recursive X-Y cut over a page ink map.
---
--- Comic and manga pages are laid out as nested bands: a page splits into tiers,
--- a tier splits into panels, and the separators are gutters of bare background.
--- Recursively slicing on the widest empty band reproduces that structure
--- directly, and because "empty" is defined against the page's own background
--- (see `src._pagebitmap`) it is indifferent to whether the page is printed dark
--- on light or light on dark.
---
--- The cut cannot separate interlocking or staircase layouts, where no straight
--- line runs cleanly between two panels. `Segmenter.accept()` exists to detect
--- that case so the caller can fall back to the native detector.
---
--- @class PPSegmenterModule
local Segmenter = {}

--- Accumulate ink counts per row and per column over a sub-rectangle.
---
--- @param map PPPageMap Page ink map.
--- @param x0 integer Inclusive left cell.
--- @param y0 integer Inclusive top cell.
--- @param x1 integer Inclusive right cell.
--- @param y1 integer Inclusive bottom cell.
--- @param rows ffi.cdata* `int32_t[map.h]` row accumulator.
--- @param cols ffi.cdata* `int32_t[map.w]` column accumulator.
local function project(map, x0, y0, x1, y1, rows, cols)
    local data, map_w = map.data, map.w

    for x = x0, x1 do
        cols[x] = 0
    end

    for y = y0, y1 do
        local base = y * map_w
        local count = 0
        for x = x0, x1 do
            if data[base + x] == 1 then
                count = count + 1
                cols[x] = cols[x] + 1
            end
        end
        rows[y] = count
    end
end

--- Shrink a range to the first and last line that carry ink.
---
--- @param projection ffi.cdata* Row or column accumulator.
--- @param from integer Inclusive start index.
--- @param to integer Inclusive end index.
--- @return integer from Trimmed start index.
--- @return integer to Trimmed end index.
local function trimRange(projection, from, to)
    while from <= to and projection[from] == 0 do
        from = from + 1
    end
    while to >= from and projection[to] == 0 do
        to = to - 1
    end
    return from, to
end

--- Find the widest interior run of near-empty lines.
---
--- Runs touching either end of the range are page or panel margins, not
--- separators between two siblings, so they are never split points.
---
--- @param projection ffi.cdata* Row or column accumulator.
--- @param from integer Inclusive start index.
--- @param to integer Inclusive end index.
--- @param span integer Perpendicular extent, used to scale the ink tolerance.
--- @param ink_ratio number Fraction of `span` still counted as empty.
--- @param min_length integer Shortest run accepted as a gutter.
--- @return integer|nil start First line of the widest gutter.
--- @return integer|nil stop Last line of the widest gutter.
--- @return integer length Width of the widest gutter, 0 when there is none.
local function findWidestGutter(projection, from, to, span, ink_ratio, min_length)
    local max_ink = span * ink_ratio
    local best_start, best_stop, best_length = nil, nil, 0
    local run_start = nil

    for index = from, to do
        if projection[index] <= max_ink then
            if not run_start then
                run_start = index
            end
        else
            if run_start and run_start > from then
                local length = index - run_start
                if length >= min_length and length > best_length then
                    best_start, best_stop, best_length = run_start, index - 1, length
                end
            end
            run_start = nil
        end
    end

    return best_start, best_stop, best_length
end

--- Record a terminal region as a panel candidate, in map cells.
---
--- @param x0 integer Inclusive left cell.
--- @param y0 integer Inclusive top cell.
--- @param x1 integer Inclusive right cell.
--- @param y1 integer Inclusive bottom cell.
--- @param ctx table Segmentation limits.
--- @param out table[] Mutable candidate list.
local function emitLeaf(x0, y0, x1, y1, ctx, out)
    local w = x1 - x0 + 1
    local h = y1 - y0 + 1
    if w < ctx.min_side or h < ctx.min_side or w * h < ctx.min_area then
        return
    end
    table.insert(out, { x = x0, y = y0, w = w, h = h })
end

--- Split a region on its widest gutter, recursing until none remains.
---
--- @param map PPPageMap Page ink map.
--- @param x0 integer Inclusive left cell.
--- @param y0 integer Inclusive top cell.
--- @param x1 integer Inclusive right cell.
--- @param y1 integer Inclusive bottom cell.
--- @param depth integer Current recursion depth.
--- @param ctx table Segmentation limits and shared scratch buffers.
--- @param out table[] Mutable candidate list.
local function cut(map, x0, y0, x1, y1, depth, ctx, out)
    if x1 < x0 or y1 < y0 or #out >= ctx.max_panels then
        return
    end

    project(map, x0, y0, x1, y1, ctx.rows, ctx.cols)
    local top, bottom = trimRange(ctx.rows, y0, y1)
    local left, right = trimRange(ctx.cols, x0, x1)
    if bottom < top or right < left then
        return -- region is entirely background
    end

    if depth < ctx.max_depth then
        local width = right - left + 1
        local height = bottom - top + 1
        local row_start, row_stop, row_length =
            findWidestGutter(ctx.rows, top, bottom, width, ctx.ink_ratio, ctx.min_gutter)
        local col_start, col_stop, col_length =
            findWidestGutter(ctx.cols, left, right, height, ctx.ink_ratio, ctx.min_gutter)

        -- Every value needed below is already a local, so the children are free
        -- to overwrite the shared projection buffers.
        if row_length > 0 and row_length >= col_length then
            cut(map, left, top, right, row_start - 1, depth + 1, ctx, out)
            cut(map, left, row_stop + 1, right, bottom, depth + 1, ctx, out)
            return
        elseif col_length > 0 then
            cut(map, left, top, col_start - 1, bottom, depth + 1, ctx, out)
            cut(map, col_stop + 1, top, right, bottom, depth + 1, ctx, out)
            return
        end
    end

    emitLeaf(left, top, right, bottom, ctx, out)
end

--- Segment a page ink map into panel rectangles in native page coordinates.
---
--- @param map PPPageMap Page ink map.
--- @param settings PPSettings Plugin settings.
--- @return PPPanel[] panels Unordered panel rectangles.
function Segmenter.segment(map, settings)
    settings = settings or Settings.defaults
    local defaults = Settings.defaults
    local stop = Timing.span("segment")

    -- Note that min_gutter is a fraction of the *map*, so it stays a fixed
    -- fraction of the page whatever the map resolution is. Raising the
    -- resolution alone therefore does not make narrow gutters detectable; the
    -- ratio has to come down with it. The two are reset together on migration.
    local min_dimension = math.min(map.w, map.h)
    local ctx = {
        rows = ffi.new("int32_t[?]", map.h),
        cols = ffi.new("int32_t[?]", map.w),
        ink_ratio = settings.segment_gutter_ink_ratio or defaults.segment_gutter_ink_ratio,
        min_gutter = math.max(2, math.floor(min_dimension
            * (settings.segment_gutter_ratio or defaults.segment_gutter_ratio))),
        min_side = math.max(4, math.floor(min_dimension
            * (settings.segment_min_panel_side or defaults.segment_min_panel_side))),
        min_area = math.floor(map.w * map.h
            * (settings.segment_min_panel_area or defaults.segment_min_panel_area)),
        max_depth = settings.segment_max_depth or defaults.segment_max_depth,
        max_panels = settings.segment_max_panels or defaults.segment_max_panels,
    }

    local cells = {}
    cut(map, 0, 0, map.w - 1, map.h - 1, 0, ctx, cells)

    -- One map cell is several native pixels, so grow every rectangle by a cell
    -- to keep quantization from shaving the outermost artwork off the crop.
    local panels = {}
    for _, cell in ipairs(cells) do
        local x = math.max(0, cell.x * map.scale_x - map.scale_x)
        local y = math.max(0, cell.y * map.scale_y - map.scale_y)
        local right = math.min(map.native_w, (cell.x + cell.w) * map.scale_x + map.scale_x)
        local bottom = math.min(map.native_h, (cell.y + cell.h) * map.scale_y + map.scale_y)
        table.insert(panels, {
            x = x,
            y = y,
            w = math.max(1, right - x),
            h = math.max(1, bottom - y),
        })
    end

    stop(#panels .. " panels")
    return panels
end

--- Decide whether a segmentation result is trustworthy.
---
--- @param panels PPPanel[] Segmented panel rectangles.
--- @param map PPPageMap Page ink map.
--- @param settings PPSettings Plugin settings.
--- @return boolean accepted Whether the caller should use these panels.
--- @return string|nil reason Rejection reason when not accepted.
function Segmenter.accept(panels, map, settings)
    settings = settings or Settings.defaults
    local count = #panels
    if count == 0 then
        return false, "no panels"
    end

    local page_area = map.native_w * map.native_h
    local full_ratio = settings.full_page_panel_ratio or Settings.defaults.full_page_panel_ratio

    local total_area, largest_area = 0, 0
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = 0, 0
    for _, panel in ipairs(panels) do
        local area = panel.w * panel.h
        total_area = total_area + area
        if area > largest_area then
            largest_area = area
        end
        min_x = math.min(min_x, panel.x)
        min_y = math.min(min_y, panel.y)
        max_x = math.max(max_x, panel.x + panel.w)
        max_y = math.max(max_y, panel.y + panel.h)
    end

    if count == 1 then
        -- One rectangle spanning most of the page is the right answer twice
        -- over: it is what a splash page actually is, and it is also the best
        -- either detector can do on a layout with no straight gutters (a
        -- diagonal split, say), so falling back would only cost a
        -- full-resolution render to reach the same rectangle. A lone *small*
        -- rectangle is different: the cut latched onto one blob and missed the
        -- rest of the page, which is worth a second opinion.
        local single_ratio = settings.segment_single_panel_ratio
            or Settings.defaults.segment_single_panel_ratio
        if largest_area >= page_area * single_ratio then
            return true
        end
        return false, "single partial panel"
    end

    local covered_area = (max_x - min_x) * (max_y - min_y)
    if covered_area < page_area * (settings.segment_page_coverage_min
            or Settings.defaults.segment_page_coverage_min) then
        return false, "panels cover too little of the page"
    end

    local coverage_min = settings.segment_coverage_min or Settings.defaults.segment_coverage_min
    if total_area < covered_area * coverage_min then
        return false, string.format("only %d%% of the covered area kept",
            math.floor(total_area * 100 / covered_area))
    end

    return true
end

return Segmenter
