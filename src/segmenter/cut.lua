--[[
Panels+
File: src/segmenter/cut.lua
Name: Segmenter
Description: Recursive gutter, slanted separator and border segmentation.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Settings = require("src._settings")
local Timing = require("src._timing")
local ffi = require("ffi")

return function(Segmenter)
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
    --- @param avg_ink number|nil Average ink in region for adaptive valley detection.
    --- @param is_column boolean|nil Whether this is a column projection.
    --- @return integer|nil start First line of the widest gutter.
    --- @return integer|nil stop Last line of the widest gutter.
    --- @return integer length Width of the widest gutter, 0 when there is none.
    local function findWidestGutter(projection, from, to, span, ink_ratio, min_length, avg_ink, is_column)
        local max_ink = span * ink_ratio
        local valley_cap = is_column and 0.03 or 0.05
        local valley_ratio = is_column and 0.10 or 0.15
        if avg_ink and avg_ink > 0 then
            local valley_max = math.min(span * valley_cap, avg_ink * valley_ratio)
            if valley_max > max_ink then
                max_ink = valley_max
            end
        end
        local best_start, best_stop, best_length = nil, nil, 0
        local best_score = 0
        local run_start = nil

        for index = from, to do
            if projection[index] <= max_ink then
                if not run_start then
                    run_start = index
                end
            else
                if run_start and run_start > from then
                    local length = index - run_start
                    -- Noisy gutters (with screentones) should not exceed realistic gutter width (30 cells).
                    -- Truly clean gutters (near-zero ink) can span any width (e.g. wide margins).
                    local is_clean = projection[run_start] <= span * 0.015
                    local max_allowed_len = is_clean and math.huge or 30
                    -- A one-cell cut is only safe when it is truly blank. The
                    -- usual proportional tolerance is useful for multi-cell
                    -- gutters (which can pick up a halftone speck), but would let
                    -- a one-cell artwork gap split a Comic panel in two.
                    local score = length + (is_clean and 100 or 0)
                    if
                        length >= min_length
                        and length <= max_allowed_len
                        and (length > 1 or projection[run_start] == 0)
                        and score > best_score
                    then
                        best_start, best_stop, best_length, best_score = run_start, index - 1, length, score
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
                    if length >= min_length and (length > 1 or projection[run_start] == 0) then
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

    --- Measure the longest contiguous vertical run of ink cells in a column.
    ---
    --- @param map PPPageMap Page ink map.
    --- @param x integer Column index.
    --- @param y0 integer Inclusive top row.
    --- @param y1 integer Inclusive bottom row.
    --- @return integer max_run Length of the longest continuous ink stroke.
    local function maxContinuousRun(map, x, y0, y1)
        local max_run, cur_run = 0, 0
        local data = map.data
        local map_w = map.w
        for y = y0, y1 do
            if data[y * map_w + x] == 1 then
                cur_run = cur_run + 1
                if cur_run > max_run then
                    max_run = cur_run
                end
            else
                cur_run = 0
            end
        end
        return max_run
    end

    --- Find a vertical dividing gutter between side-by-side panels in 4-koma manga tiers.
    ---
    --- In 4-koma manga, side-by-side vertical panel strips share a very narrow gutter
    --- (often only 2-3 native pixels wide) flanked by dark border strokes. Downsampled
    --- to 480px, the seam carries 15-30% ink, exceeding the standard column valley cap
    --- (3%), which causes findWidestGutter to merge the two panels into a single wide tier.
    ---
    --- When standard gutters fail and the region spans the page width with a double-panel
    --- aspect ratio (>= 1.25), this searches the central corridor (35% to 65% of page width)
    --- for an ink valley flanked by dense continuous vertical border lines. Both resulting
    --- child panels must have valid 4-koma aspect ratios (<= 1.55).
    ---
    --- @param map PPPageMap Page ink map.
    --- @param left integer Inclusive left column.
    --- @param top integer Inclusive top row.
    --- @param right integer Inclusive right column.
    --- @param bottom integer Inclusive bottom row.
    --- @param cols ffi.cdata* Column ink projection.
    --- @return integer|nil split_x Split column index, or nil if no 4-koma seam is found.
    local function find4KomaCenterlineSplit(map, left, top, right, bottom, cols)
        local width = right - left + 1
        local height = bottom - top + 1

        -- Region must be wide enough, span across the page, and have a wide aspect ratio
        if width < map.w * 0.65 or (width / height) < 1.25 then
            return nil
        end
        if left > map.w * 0.18 or right < map.w * 0.82 then
            return nil
        end

        -- Corridor in center of page (35% to 65% of page width)
        local min_x = math.max(left + 15, math.floor(map.w * 0.35))
        local max_x = math.min(right - 15, math.ceil(map.w * 0.65))
        if min_x > max_x then
            return nil
        end

        local best_split = nil
        local best_score = -1

        for x = min_x, max_x do
            local val_r = cols[x] / height
            if val_r <= 0.35 then
                local left_w = x - left + 1
                local right_w = right - x + 1
                local left_aspect = left_w / height
                local right_aspect = right_w / height

                -- Both children must have plausible 4-koma panel aspect ratios
                if left_aspect <= 1.55 and right_aspect <= 1.55 then
                    local left_run = 0
                    for dx = 1, 6 do
                        local bx = x - dx
                        if bx >= left and (cols[bx] / height) >= 0.45 then
                            local run = maxContinuousRun(map, bx, top, bottom) / height
                            if run > left_run then
                                left_run = run
                            end
                        end
                    end

                    local right_run = 0
                    for dx = 1, 6 do
                        local bx = x + dx
                        if bx <= right and (cols[bx] / height) >= 0.45 then
                            local run = maxContinuousRun(map, bx, top, bottom) / height
                            if run > right_run then
                                right_run = run
                            end
                        end
                    end

                    if
                        (left_run >= 0.50 and right_run >= 0.50)
                        or (left_run >= 0.65 and right_run >= 0.35)
                        or (right_run >= 0.65 and left_run >= 0.35)
                    then
                        local score = (left_run + right_run) - val_r
                        if score > best_score then
                            best_score = score
                            best_split = x
                        end
                    end
                end
            end
        end

        return best_split
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
            local avg_row = height > 0 and (region_ink / height) or 0
            local avg_col = width > 0 and (region_ink / width) or 0
            local row_start, row_stop, row_length =
                findWidestGutter(ctx.rows, top, bottom, width, ctx.ink_ratio, ctx.min_gutter, avg_row, false)
            local col_start, col_stop, col_length =
                findWidestGutter(ctx.cols, left, right, height, ctx.ink_ratio, ctx.min_gutter, avg_col, true)

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

            -- 4-koma / double-panel centerline split.
            -- In manga mode, when a tier spanning the page width has no clear blank gutter
            -- (due to downsampled narrow vertical seams flanked by dark borders),
            -- search the central corridor for a vertical separator flanked by panel borders.
            if ctx.mode == "manga" then
                local k_split = find4KomaCenterlineSplit(map, left, top, right, bottom, ctx.cols)
                if k_split then
                    ctx.koma_splits = ctx.koma_splits + 1
                    cut(map, left, top, k_split - 1, bottom, depth + 1, ctx, out)
                    cut(map, k_split + 1, top, right, bottom, depth + 1, ctx, out)
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
        --
        -- Comic pages can have an intentional one-cell white seam between panels
        -- after downsampling. That seam is still a complete, edge-to-edge strip of
        -- page background, while a panel's own frame keeps ordinary artwork from
        -- producing the same projection. Keep manga's two-cell floor (where tone
        -- screens make one-cell gaps especially noisy), but let Comic mode retain
        -- the single-cell seam rather than merging every panel in that row. The
        -- generic ratio still controls Manga; Comic mode intentionally accepts the
        -- smallest possible complete background seam.
        local min_dimension = math.min(map.w, map.h)
        local default_ink_ratio = settings.mode == "manga" and 0.04 or defaults.segment_gutter_ink_ratio
        local ink_ratio = settings.segment_gutter_ink_ratio or default_ink_ratio

        local ctx = {
            rows = ffi.new("int32_t[?]", map.h),
            cols = ffi.new("int32_t[?]", map.w),
            ink_ratio = ink_ratio,
            min_gutter = settings.mode == "comic" and 1 or math.max(
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
            slopes = (settings.segment_shear == true) and Segmenter.SHEAR_SLOPES or nil,
            shear_max_depth = settings.segment_shear_max_depth or defaults.segment_shear_max_depth,
            shear_trigger = settings.segment_shear_trigger or defaults.segment_shear_trigger,
            shear_step = settings.segment_shear_step or defaults.segment_shear_step,
            slope_hint = nil,
            shear_searches = 0,
            shear_splits = 0,
            border_splits = 0,
            mode = settings.mode or "manga",
            koma_splits = 0,
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

        if ctx.shear_searches > 0 or ctx.border_splits > 0 or ctx.koma_splits > 0 then
            stop(
                string.format(
                    "%d panels, %d of %d slanted searches split, %d border-line splits, %d 4-koma splits",
                    #panels,
                    ctx.shear_splits,
                    ctx.shear_searches,
                    ctx.border_splits,
                    ctx.koma_splits
                )
            )
        else
            stop(#panels .. " panels")
        end
        return panels
    end
end
