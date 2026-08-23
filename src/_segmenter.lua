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
--- Comic mode can add a second kind of separator search, off by default behind
--- `segment_border_split`. Western comics routinely bleed differently-coloured,
--- dark, or grey panels edge to edge with no blank gutter between them at all
--- -- only the artist's drawn black border stroke. That stroke is invisible to
--- the background-relative gutter search (there is no empty band to find) but
--- stands out as a thin, densely dark run against whatever fills the panels
--- either side of it, so it gets its own pass over `map.border` (see
--- `src._pagebitmap`). Manga mode never builds `map.border`, so neither the
--- pass nor its cost apply there.
---
--- It is opt-in because at ink-map resolution the pattern it keys on is not
--- unique to a panel border. A shared border between two bled panels and a
--- black line drawn *through* one panel -- a horizon, a caption rule, a pole,
--- a letterbox band -- produce byte-identical maps: a thin, full-width, densely
--- dark run flanked by artwork. Nothing left in the map distinguishes them, so
--- no amount of tuning separates the two and the pass splits real panels in
--- half on any page carrying such a line. Off, those pages read correctly and
--- genuinely bled layouts fall back to the documented "panels with no gutter"
--- limitation -- one panel instead of two, which costs the reader far less than
--- a panel cut in half. On, bled layouts split at the price of that
--- false-positive rate.
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
    0.035,
    -0.035, -- 2.0 degrees
    0.061,
    -0.061, -- 3.5
    0.087,
    -0.087, -- 5.0
    0.115,
    -0.115, -- 6.5
    0.141,
    -0.141, -- 8.0
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

--- Accumulate ink and border-stroke-candidate counts per row and column
--- together, over a sub-rectangle.
---
--- Comic mode only. Folds the border pass into the same traversal as the ink
--- pass so a region costs one scan instead of two; `project()` above is used
--- everywhere `map.border` is nil, so manga mode never runs this.
---
--- @param map PPPageMap Page ink map, with `border` populated.
--- @param x0 integer Inclusive left cell.
--- @param y0 integer Inclusive top cell.
--- @param x1 integer Inclusive right cell.
--- @param y1 integer Inclusive bottom cell.
--- @param rows ffi.cdata* `int32_t[map.h]` ink row accumulator.
--- @param cols ffi.cdata* `int32_t[map.w]` ink column accumulator.
--- @param brows ffi.cdata* `int32_t[map.h]` border row accumulator.
--- @param bcols ffi.cdata* `int32_t[map.w]` border column accumulator.
local function projectWithBorder(map, x0, y0, x1, y1, rows, cols, brows, bcols)
    local data, border, map_w = map.data, map.border, map.w

    for x = x0, x1 do
        cols[x] = 0
        bcols[x] = 0
    end

    for y = y0, y1 do
        local base = y * map_w
        local count, bcount = 0, 0
        for x = x0, x1 do
            local idx = base + x
            if data[idx] == 1 then
                count = count + 1
                cols[x] = cols[x] + 1
            end
            if border[idx] == 1 then
                bcount = bcount + 1
                bcols[x] = bcols[x] + 1
            end
        end
        rows[y] = count
        brows[y] = bcount
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

--- Find the narrowest interior run of densely bordered lines.
---
--- The comic-mode counterpart to `findWidestGutter`: instead of a blank gap,
--- this looks for a thin drawn separator stroke. A real border line is dense
--- (mostly border cells) *and* narrow; a wide dense run is a filled panel
--- interior (a black or near-black background), not a separator, so
--- `max_length` rejects it. The narrowest qualifying run is preferred over the
--- widest, since thinness is exactly what tells the two cases apart.
---
--- Runs touching either end of the range are excluded for the same reason as
--- in `findWidestGutter`: they are the region's own edge, not a separator
--- between two siblings inside it. `min_child` goes further and rejects a run
--- sitting *close* to either end too: a thin off-cut sliver (a page-footer
--- rule, a caption strip) would otherwise pass every other check and still
--- get emitted as its own spurious "panel", the same size floor
--- `emitLeaf` would reject it by, applied before the split happens instead of
--- after.
---
--- @param projection ffi.cdata* Row or column border-cell accumulator.
--- @param from integer Inclusive start index.
--- @param to integer Inclusive end index.
--- @param span integer Perpendicular extent, used to scale the density floor.
--- @param ratio number Fraction of `span` that must be border cells.
--- @param max_length integer Widest run still accepted as a separator line.
--- @param min_child integer Smallest cell count either resulting side may have.
--- @return integer|nil start First line of the border run.
--- @return integer|nil stop Last line of the border run.
--- @return integer length Width of the run, 0 when there is none.
local function findBorderLine(projection, from, to, span, ratio, max_length, min_child)
    local min_count = span * ratio
    local best_start, best_stop, best_length = nil, nil, 0
    local run_start = nil

    for index = from, to do
        if projection[index] >= min_count then
            if not run_start then
                run_start = index
            end
        else
            if run_start and run_start > from then
                local length = index - run_start
                local left_child = run_start - from
                local right_child = to - (index - 1)
                if
                    length <= max_length
                    and left_child >= min_child
                    and right_child >= min_child
                    and (best_length == 0 or length < best_length)
                then
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
local function byLengthDesc(a, b)
    return a.length > b.length
end

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

    table.sort(gutters, byLengthDesc)
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

--- Try one shear slope, returning the axis/band it splits on, if any.
---
--- @param map PPPageMap Page ink map.
--- @param left integer Inclusive left cell.
--- @param top integer Inclusive top cell.
--- @param right integer Inclusive right cell.
--- @param bottom integer Inclusive bottom cell.
--- @param ctx table Segmentation limits and shared scratch buffers.
--- @param slope number Shear to try, as dx per unit y (or dy per unit x).
--- @return '"cols"'|'"rows"'|nil axis Axis to split on, or nil when this slope finds nothing.
--- @return integer|nil lo Lower edge of the band.
--- @return integer|nil hi Upper edge of the band.
local function trySlope(map, left, top, right, bottom, ctx, slope)
    local width = right - left + 1
    local height = bottom - top + 1
    local step = ctx.shear_step

    projectColumnsSheared(map, left, top, right, bottom, slope, ctx.cols, step)
    local drift = math.floor(math.abs(slope) * height / 2) + 1
    for _, gutter in ipairs(collectGutters(ctx.cols, left, right, height / step, ctx.ink_ratio, ctx.min_gutter)) do
        local lo, hi = gutter.from - drift, gutter.to + drift
        if lo > left and hi < right then
            return "cols", lo, hi
        end
    end

    projectRowsSheared(map, left, top, right, bottom, slope, ctx.rows, step)
    drift = math.floor(math.abs(slope) * width / 2) + 1
    for _, gutter in ipairs(collectGutters(ctx.rows, top, bottom, width / step, ctx.ink_ratio, ctx.min_gutter)) do
        local lo, hi = gutter.from - drift, gutter.to + drift
        if lo > top and hi < bottom then
            return "rows", lo, hi
        end
    end

    return nil
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
    -- Whichever slope worked last is overwhelmingly likely to work again on the
    -- same page, so it is worth trying before the rest of the ladder.
    if ctx.slope_hint then
        local axis, lo, hi = trySlope(map, left, top, right, bottom, ctx, ctx.slope_hint)
        if axis then
            return axis, lo, hi
        end
    end

    for _, slope in ipairs(ctx.slopes) do
        if slope ~= ctx.slope_hint then
            local axis, lo, hi = trySlope(map, left, top, right, bottom, ctx, slope)
            if axis then
                ctx.slope_hint = slope
                return axis, lo, hi
            end
        end
    end

    return nil
end

--- Record a terminal region as a panel candidate, in map cells.
---
--- The size floors alone do not describe a panel. A scanlation credit strip, a
--- footer rule or a row of page furniture clears both of them comfortably --
--- on a 480x720 map a 182x20 credit line is 3640 cells against a 1728-cell
--- area floor, and both its sides beat the 14-cell side floor -- and then gets
--- shown to the reader as a panel holding no artwork.
---
--- Neither half of what gives it away is sufficient alone. Measured against a
--- typical page:
---
--- | leaf | ink share | aspect | |
--- | --- | --- | --- | --- |
--- | credit strip 182x20 | 0.96% | 9.1:1 | furniture |
--- | inset panel 60x60 | 1.51% | 1:1 | panel |
--- | letterbox panel 458x60 | 7.95% | 7.6:1 | panel |
--- | strip panel 40x600 | 6.94% | 15:1 | panel |
---
--- An ink floor on its own would take the inset panel (1.51%) before it took
--- the credit strip (0.96%); an aspect limit on its own would take both
--- legitimately elongated panels. Only the *conjunction* isolates furniture:
--- a leaf has to be both stretched out and nearly empty to be rejected, which
--- is what a strip of page furniture is and what none of the real panels are.
---
--- The ink floor is deliberately a share of the page rather than an absolute
--- count, so a mostly-blank page with one small drawing still gives that
--- drawing ~100% of the page's ink and keeps it.
---
--- @param x0 integer Inclusive left cell.
--- @param y0 integer Inclusive top cell.
--- @param x1 integer Inclusive right cell.
--- @param y1 integer Inclusive bottom cell.
--- @param ink integer Ink cells inside the region.
--- @param ctx table Segmentation limits.
--- @param out table[] Mutable candidate list.
local function emitLeaf(x0, y0, x1, y1, ink, ctx, out)
    local w = x1 - x0 + 1
    local h = y1 - y0 + 1
    if w < ctx.min_side or h < ctx.min_side or w * h < ctx.min_area then
        return
    end

    local long_side, short_side = w, h
    if h > w then
        long_side, short_side = h, w
    end
    if long_side >= short_side * ctx.sliver_aspect and ink < ctx.sliver_ink then
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

    if ctx.border then
        projectWithBorder(map, x0, y0, x1, y1, ctx.rows, ctx.cols, ctx.brows, ctx.bcols)
    else
        project(map, x0, y0, x1, y1, ctx.rows, ctx.cols)
    end
    local top, bottom = trimRange(ctx.rows, y0, y1)
    local left, right = trimRange(ctx.cols, x0, x1)
    if bottom < top or right < left then
        return -- region is entirely background
    end

    -- Summed here, while the projections still describe *this* region: the
    -- sheared search below overwrites both buffers, and the recursive calls
    -- overwrite them again. Rows outside the trimmed range carry no ink by
    -- definition, so this is the region's exact ink count for O(height).
    local region_ink = 0
    for y = top, bottom do
        region_ink = region_ink + ctx.rows[y]
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

        -- No blank gutter. Comic panels are routinely bled edge to edge with
        -- only a drawn border stroke between them, which never shows up as an
        -- empty band -- but it stands out as a thin, densely dark run against
        -- whatever colour fills the panels either side of it. Prefer the
        -- thinner of the two axes: thinness is the signal that it is really a
        -- drawn line and not a wide, uniformly dark panel interior.
        if ctx.border then
            local brow_start, brow_stop, brow_length =
                findBorderLine(ctx.brows, top, bottom, width, ctx.border_ratio, ctx.border_max_width, ctx.min_side)
            local bcol_start, bcol_stop, bcol_length =
                findBorderLine(ctx.bcols, left, right, height, ctx.border_ratio, ctx.border_max_width, ctx.min_side)

            if brow_length > 0 and (bcol_length == 0 or brow_length <= bcol_length) then
                ctx.border_splits = ctx.border_splits + 1
                cut(map, left, top, right, brow_start - 1, depth + 1, ctx, out)
                cut(map, left, brow_stop + 1, right, bottom, depth + 1, ctx, out)
                return
            elseif bcol_length > 0 then
                ctx.border_splits = ctx.border_splits + 1
                cut(map, left, top, bcol_start - 1, bottom, depth + 1, ctx, out)
                cut(map, bcol_stop + 1, top, right, bottom, depth + 1, ctx, out)
                return
            end
        end

        -- Nothing straight. The panels may simply not be square, so look along
        -- slanted lines -- but only when something already looks part-empty. A
        -- splash page has no such line and skips a search that cannot succeed.
        if
            ctx.slopes
            and depth <= ctx.shear_max_depth
            and (
                minInRange(ctx.cols, left, right) <= height * ctx.shear_trigger
                or minInRange(ctx.rows, top, bottom) <= width * ctx.shear_trigger
            )
        then
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

    emitLeaf(left, top, right, bottom, region_ink, ctx, out)
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

    -- The drawn-border pass is opt-in, and gated here as well as in
    -- `src._pagebitmap` so a map carrying a border plane built for some other
    -- reason can never silently re-enable it.
    local border = settings.segment_border_split == true and map.border or nil

    -- Note that min_gutter is a fraction of the *map*, so it stays a fixed
    -- fraction of the page whatever the map resolution is. Raising the
    -- resolution alone therefore does not make narrow gutters detectable; the
    -- ratio has to come down with it. The two are reset together on migration.
    local min_dimension = math.min(map.w, map.h)
    local ctx = {
        rows = ffi.new("int32_t[?]", map.h),
        cols = ffi.new("int32_t[?]", map.w),
        ink_ratio = settings.segment_gutter_ink_ratio or defaults.segment_gutter_ink_ratio,
        min_gutter = math.max(
            2,
            math.floor(min_dimension * (settings.segment_gutter_ratio or defaults.segment_gutter_ratio))
        ),
        min_side = math.max(
            4,
            math.floor(min_dimension * (settings.segment_min_panel_side or defaults.segment_min_panel_side))
        ),
        min_area = math.floor(map.w * map.h * (settings.segment_min_panel_area or defaults.segment_min_panel_area)),
        sliver_aspect = settings.segment_sliver_aspect or defaults.segment_sliver_aspect,
        -- Zero when the map did not report its ink total, which disables the
        -- content floor rather than rejecting every sliver on the page.
        sliver_ink = math.floor((map.ink or 0) * (settings.segment_sliver_ink or defaults.segment_sliver_ink)),
        max_depth = settings.segment_max_depth or defaults.segment_max_depth,
        max_panels = settings.segment_max_panels or defaults.segment_max_panels,
        border = border,
        brows = border and ffi.new("int32_t[?]", map.h) or nil,
        bcols = border and ffi.new("int32_t[?]", map.w) or nil,
        border_ratio = settings.segment_border_line_ratio or defaults.segment_border_line_ratio,
        border_max_width = math.max(
            2,
            math.floor(min_dimension * (settings.segment_border_width_ratio or defaults.segment_border_width_ratio))
        ),
        slopes = settings.segment_shear ~= false and Segmenter.SHEAR_SLOPES or nil,
        shear_max_depth = settings.segment_shear_max_depth or defaults.segment_shear_max_depth,
        shear_trigger = settings.segment_shear_trigger or defaults.segment_shear_trigger,
        shear_step = settings.segment_shear_step or defaults.segment_shear_step,
        slope_hint = nil,
        shear_searches = 0,
        shear_splits = 0,
        border_splits = 0,
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

    if ctx.shear_searches > 0 or ctx.border_splits > 0 then
        stop(
            string.format(
                "%d panels, %d of %d slanted searches split, %d border-line splits",
                #panels,
                ctx.shear_splits,
                ctx.shear_searches,
                ctx.border_splits
            )
        )
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
        local single_ratio = settings.segment_single_panel_ratio or Settings.defaults.segment_single_panel_ratio
        if largest_area >= page_area * single_ratio then
            return true
        end
        return false, "single partial panel"
    end

    local covered_area = (max_x - min_x) * (max_y - min_y)
    if
        covered_area
        < page_area * (settings.segment_page_coverage_min or Settings.defaults.segment_page_coverage_min)
    then
        return false, "panels cover too little of the page"
    end

    local coverage_min = settings.segment_coverage_min or Settings.defaults.segment_coverage_min
    if total_area < covered_area * coverage_min then
        return false, string.format("only %d%% of the covered area kept", math.floor(total_area * 100 / covered_area))
    end

    return true
end

return Segmenter
