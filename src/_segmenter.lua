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

--- Slopes tried when no straight gutter exists, as dx per unit y.
---
--- Panels are rarely drawn perfectly square, and a gutter tilted by even two
--- degrees leaves no column empty from top to bottom, which is enough to stop
--- the straight cut entirely. The ladder covers 2 to 8 degrees either way; the
--- spacing matters, since a coarser ladder straddles 5 degrees and misses the
--- most common case.
Segmenter.SHEAR_SLOPES = {
    0.035, -0.035,   -- 2.0 degrees
    0.061, -0.061,   -- 3.5
    0.087, -0.087,   -- 5.0
    0.115, -0.115,   -- 6.5
    0.141, -0.141,   -- 8.0
}

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

--- Collect every interior gutter run in a projection, widest first.
---
--- Unlike the straight cut, the sheared search cannot just take the widest run:
--- projecting a slanted band back onto the axis widens it by `drift`, which
--- often makes the widest candidate unusable while a narrower one is fine. It
--- also keeps re-finding the gutter it just split on, now sitting against the
--- region border, so it has to be able to look past it.
---
--- @param projection table Row or column accumulator.
--- @param from integer Inclusive start index.
--- @param to integer Inclusive end index.
--- @param span number Perpendicular extent, used to scale the ink tolerance.
--- @param ink_ratio number Fraction of `span` still counted as empty.
--- @param min_length integer Shortest run accepted as a gutter.
--- @return {from:integer, to:integer, length:integer}[] gutters Sorted widest first.
local function collectGutters(projection, from, to, span, ink_ratio, min_length)
    local max_ink = span * ink_ratio
    local gutters = {}
    local run_start = nil

    for index = from, to do
        if projection[index] <= max_ink then
            if not run_start then
                run_start = index
            end
        else
            if run_start and run_start > from then
                local length = index - run_start
                if length >= min_length then
                    table.insert(gutters, {
                        from = run_start,
                        to = index - 1,
                        length = length,
                    })
                end
            end
            run_start = nil
        end
    end

    table.sort(gutters, function(a, b)
        return a.length > b.length
    end)
    return gutters
end

--- Accumulate column ink counts along lines sheared by `slope`.
---
--- Only the y loop may be stepped. Every x must still be visited, or the
--- columns that were skipped read as empty and become phantom gutters.
---
--- @param map PPPageMap Page ink map.
--- @param x0 integer Inclusive left cell.
--- @param y0 integer Inclusive top cell.
--- @param x1 integer Inclusive right cell.
--- @param y1 integer Inclusive bottom cell.
--- @param slope number Shear, as dx per unit y.
--- @param cols ffi.cdata* Column accumulator.
--- @param step integer Sample every `step`-th row.
local function projectColumnsSheared(map, x0, y0, x1, y1, slope, cols, step)
    for x = x0, x1 do
        cols[x] = 0
    end

    local data, map_w = map.data, map.w
    local ymid = math.floor((y0 + y1) / 2)
    for y = y0, y1, step do
        local shift = math.floor(slope * (y - ymid) + 0.5)
        local base = y * map_w
        local lo = x0 + shift
        if lo < x0 then
            lo = x0
        end
        local hi = x1 + shift
        if hi > x1 then
            hi = x1
        end
        for x = lo, hi do
            if data[base + x] == 1 then
                local target = x - shift
                cols[target] = cols[target] + 1
            end
        end
    end
end

--- Accumulate row ink counts along lines sheared by `slope`.
---
--- Mirror of the column pass: here only the x loop may be stepped.
---
--- @param map PPPageMap Page ink map.
--- @param x0 integer Inclusive left cell.
--- @param y0 integer Inclusive top cell.
--- @param x1 integer Inclusive right cell.
--- @param y1 integer Inclusive bottom cell.
--- @param slope number Shear, as dy per unit x.
--- @param rows ffi.cdata* Row accumulator.
--- @param step integer Sample every `step`-th column.
local function projectRowsSheared(map, x0, y0, x1, y1, slope, rows, step)
    for y = y0, y1 do
        rows[y] = 0
    end

    local data, map_w = map.data, map.w
    local xmid = math.floor((x0 + x1) / 2)
    for y = y0, y1 do
        local base = y * map_w
        for x = x0, x1, step do
            if data[base + x] == 1 then
                local target = y - math.floor(slope * (x - xmid) + 0.5)
                if target >= y0 and target <= y1 then
                    rows[target] = rows[target] + 1
                end
            end
        end
    end
end

--- Return the smallest value in a projection range.
---
--- @param projection ffi.cdata* Row or column accumulator.
--- @param from integer Inclusive start index.
--- @param to integer Inclusive end index.
--- @return number smallest Lowest ink count in the range.
local function minInRange(projection, from, to)
    local smallest = math.huge
    for index = from, to do
        if projection[index] < smallest then
            smallest = projection[index]
        end
    end
    return smallest
end

--- Look for a split along slanted lines, for panels that are not square.
---
--- Returns the axis to split on plus the band's full extent once projected back
--- to the axis. Both children are given the whole band, so each panel keeps all
--- of its own artwork and gains a thin wedge of its neighbour rather than losing
--- a corner.
---
--- @param map PPPageMap Page ink map.
--- @param left integer Inclusive left cell.
--- @param top integer Inclusive top cell.
--- @param right integer Inclusive right cell.
--- @param bottom integer Inclusive bottom cell.
--- @param ctx table Segmentation limits and shared scratch buffers.
--- @return '"cols"'|'"rows"'|nil axis Axis to split on, or nil when none works.
--- @return integer|nil lo Lower edge of the band.
--- @return integer|nil hi Upper edge of the band.
local function findShearedSplit(map, left, top, right, bottom, ctx)
    local width = right - left + 1
    local height = bottom - top + 1
    local step = ctx.shear_step

    -- Whichever slope worked last is overwhelmingly likely to work again on the
    -- same page, so it is worth trying before the rest of the ladder.
    local order = {}
    if ctx.slope_hint then
        table.insert(order, ctx.slope_hint)
    end
    for _, slope in ipairs(ctx.slopes) do
        if slope ~= ctx.slope_hint then
            table.insert(order, slope)
        end
    end

    for _, slope in ipairs(order) do
        projectColumnsSheared(map, left, top, right, bottom, slope, ctx.cols, step)
        local drift = math.floor(math.abs(slope) * height / 2) + 1
        for _, gutter in ipairs(collectGutters(ctx.cols, left, right, height / step,
                ctx.ink_ratio, ctx.min_gutter)) do
            local lo, hi = gutter.from - drift, gutter.to + drift
            if lo > left and hi < right then
                ctx.slope_hint = slope
                return "cols", lo, hi
            end
        end

        projectRowsSheared(map, left, top, right, bottom, slope, ctx.rows, step)
        drift = math.floor(math.abs(slope) * width / 2) + 1
        for _, gutter in ipairs(collectGutters(ctx.rows, top, bottom, width / step,
                ctx.ink_ratio, ctx.min_gutter)) do
            local lo, hi = gutter.from - drift, gutter.to + drift
            if lo > top and hi < bottom then
                ctx.slope_hint = slope
                return "rows", lo, hi
            end
        end
    end

    return nil
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

        -- Nothing straight. The panels may simply not be square, so look along
        -- slanted lines -- but only when something already looks part-empty. A
        -- splash page has no such line and skips a search that cannot succeed.
        if ctx.slopes and depth <= ctx.shear_max_depth
                and (minInRange(ctx.cols, left, right) <= height * ctx.shear_trigger
                    or minInRange(ctx.rows, top, bottom) <= width * ctx.shear_trigger) then
            local axis, lo, hi = findShearedSplit(map, left, top, right, bottom, ctx)
            ctx.shear_searches = ctx.shear_searches + 1
            if axis == "cols" then
                ctx.shear_splits = ctx.shear_splits + 1
                cut(map, left, top, hi, bottom, depth + 1, ctx, out)
                cut(map, lo, top, right, bottom, depth + 1, ctx, out)
                return
            elseif axis == "rows" then
                ctx.shear_splits = ctx.shear_splits + 1
                cut(map, left, top, right, hi, depth + 1, ctx, out)
                cut(map, left, lo, right, bottom, depth + 1, ctx, out)
                return
            end
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
        slopes = settings.segment_shear ~= false and Segmenter.SHEAR_SLOPES or nil,
        shear_max_depth = settings.segment_shear_max_depth or defaults.segment_shear_max_depth,
        shear_trigger = settings.segment_shear_trigger or defaults.segment_shear_trigger,
        shear_step = settings.segment_shear_step or defaults.segment_shear_step,
        slope_hint = nil,
        shear_searches = 0,
        shear_splits = 0,
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

    if ctx.shear_searches > 0 then
        stop(string.format("%d panels, %d of %d slanted searches split",
            #panels, ctx.shear_splits, ctx.shear_searches))
    else
        stop(#panels .. " panels")
    end
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
