-- Panel detection: a decoded page in, ordered panel rectangles out.

local ffi = require("ffi")
local RenderImage = require("ui/renderimage")

local Image = require("meguru/doc/image")

local Panel = {}

local PANEL_SCAN_WIDTH = 480

local PANEL_SCAN_MAX_CELLS = 1200000

local PANEL_INK_DELTA = 40

local PANEL_BG_RING_FRAC = 0.01
local PANEL_BG_MID_LO = 32
local PANEL_BG_MID_HI = 224
local PANEL_DARK_BG_LUMA = 128
local PANEL_DARK_FRAME_CELLS = 1
local PANEL_SEPARATOR_MIN_LUMA = 245
local PANEL_SEPARATOR_FRAC = 0.80
local PANEL_SEPARATOR_EDGE_FRAC = 0.03

-- One drawn side is enough to call a body framed (the reference's own rule).
local PANEL_BODY_MIN_SIDE_FRAC = 0.02
local PANEL_BODY_MIN_AREA_FRAC = 0.002
local PANEL_BODY_FRAME_SUPPORT = 0.80
local PANEL_BODY_FRAME_TOL_FRAC = 0.003
local PANEL_BODY_FRAME_MIN = 1

local PANEL_GUTTER_INK_RATIO = 0.005
local PANEL_GUTTER_RATIO = 0.004

local PANEL_MIN_SIDE_FRAC = 0.03
local PANEL_MIN_AREA_FRAC = 0.005
local PANEL_SLIVER_ASPECT = 4
local PANEL_SLIVER_INK_FRAC = 0.02

local PANEL_MAX_DEPTH = 6
local PANEL_MAX_PANELS = 40

local PANEL_SINGLE_PANEL_RATIO = 0.6
local PANEL_PAGE_COVERAGE_MIN = 0.4
local PANEL_COVERAGE_MIN = 0.5

local PANEL_SHEAR_SLOPES = {
    0.015, -0.015,   -- 0.86 degrees
    0.030, -0.030,   -- 1.7
    0.045, -0.045,   -- 2.6
    0.060, -0.060,   -- 3.4
    0.075, -0.075,   -- 4.3
    0.090, -0.090,   -- 5.1
    0.105, -0.105,   -- 6.0
    0.120, -0.120,   -- 6.8
    0.135, -0.135,   -- 7.7
    0.150, -0.150,   -- 8.5
}
local PANEL_SHEAR_MAX_DEPTH = 4
local PANEL_SHEAR_TRIGGER = 0.35
-- Only the slope's own axis may be stepped, or skipped lines read as gutters.
local PANEL_SHEAR_STEP = 2

local PANEL_SHEAR_INK_RATIO = 0

local PANEL_SHEAR_FIT_MIN_SAMPLES = 8
local PANEL_SHEAR_FIT_MIN_FRAC = 0.25
local PANEL_SHEAR_FIT_MAX_RESIDUAL = 2.5
local PANEL_SHEAR_FIT_SLOPE_MAX = 0.165
local PANEL_SHEAR_REFINE_EPS = 0.010

-- Both early exits use `>=` on a growing count, so neither can skip a line.
local function hasWhiteSeparator(raster)
    local w, h = raster.w, raster.h
    local luma = raster.luma
    local x_margin = math.max(1, math.floor(w * PANEL_SEPARATOR_EDGE_FRAC))
    local y_margin = math.max(1, math.floor(h * PANEL_SEPARATOR_EDGE_FRAC))
    local row_required = math.ceil(w * PANEL_SEPARATOR_FRAC)
    local col_required = math.ceil(h * PANEL_SEPARATOR_FRAC)
    for y = y_margin, h - 1 - y_margin do
        local bright = 0
        for x = 0, w - 1 do
            if luma(y, x) >= PANEL_SEPARATOR_MIN_LUMA then
                bright = bright + 1
            end
            if bright >= row_required then
                return true
            end
            if bright + w - 1 - x < row_required then
                break
            end
        end
    end
    for x = x_margin, w - 1 - x_margin do
        local bright = 0
        for y = 0, h - 1 do
            if luma(y, x) >= PANEL_SEPARATOR_MIN_LUMA then
                bright = bright + 1
            end
            if bright >= col_required then
                return true
            end
            if bright + h - 1 - y < col_required then
                break
            end
        end
    end
    return false
end

local function backgroundFor(raster)
    local w, h = raster.w, raster.h
    local ring = math.max(1, math.floor(math.min(w, h) * PANEL_BG_RING_FRAC))
    local bins = {}
    local total = 0
    local luma = raster.luma
    local function sample(x, y)
        local v = math.floor(luma(y, x))
        if v < 0 then v = 0 elseif v > 255 then v = 255 end
        bins[v] = (bins[v] or 0) + 1
        total = total + 1
    end
    for y = 0, h - 1 do
        if y < ring or y >= h - ring then
            for x = 0, w - 1 do
                sample(x, y)
            end
        else
            for x = 0, ring - 1 do
                sample(x, y)
            end
            for x = w - ring, w - 1 do
                sample(x, y)
            end
        end
    end
    if total == 0 then
        return 255
    end
    local half = total / 2
    local seen = 0
    for v = 0, 255 do
        seen = seen + (bins[v] or 0)
        if seen >= half then
            if v >= PANEL_BG_MID_LO and v < PANEL_BG_MID_HI
                and hasWhiteSeparator(raster) then
                return 255
            end
            return v
        end
    end
    return 255
end

-- `#map.data` is not a length: cdata has no `#`, so `map.w`/`map.h` are the sizes.
local function buildInkMap(raster, bg, native_w, native_h)
    local w, h = raster.w, raster.h
    local data = ffi.new("uint8_t[?]", w * h)
    local luma = raster.luma
    local ink = 0
    for y = 0, h - 1 do
        local base = y * w
        for x = 0, w - 1 do
            local d = luma(y, x) - bg
            if d < 0 then d = -d end
            if d > PANEL_INK_DELTA then
                data[base + x] = 1
                ink = ink + 1
            end
        end
    end
    return {
        w = w,
        h = h,
        data = data,
        ink = ink,
        bg = bg,
        native_w = native_w,
        native_h = native_h,
        scale_x = native_w / w,
        scale_y = native_h / h,
    }
end

local function lineSupport(values, first, last, tolerance)
    local span = last - first
    if span <= 0 then
        return 0
    end
    local best = 0
    for a = 0, 4 do
        for b = a + 3, 8 do
            local i = first + math.floor(span * a / 8)
            local j = first + math.floor(span * b / 8)
            local slope = (values[j] - values[i]) / (j - i)
            if math.abs(slope) <= 0.35 then
                local count = 0
                for k = first, last do
                    if math.abs(values[k] - values[i] - (k - i) * slope) <= tolerance then
                        count = count + 1
                    end
                end
                local ratio = count / (span + 1)
                if ratio > best then
                    best = ratio
                    if best >= PANEL_BODY_FRAME_SUPPORT then
                        return best
                    end
                end
            end
        end
    end
    return best
end

local INF = 100000000

local function frameSides(scratch, queue, count, map_width, box, tolerance)
    for y = box.y, box.y + box.h - 1 do
        scratch.left[y], scratch.right[y] = INF, -1
    end
    for x = box.x, box.x + box.w - 1 do
        scratch.top[x], scratch.bottom[x] = INF, -1
    end
    for index = 0, count - 1 do
        local p = queue[index]
        local y = math.floor(p / map_width)
        local x = p - y * map_width
        if x < scratch.left[y] then
            scratch.left[y] = x
        end
        if x > scratch.right[y] then
            scratch.right[y] = x
        end
        if y < scratch.top[x] then
            scratch.top[x] = y
        end
        if y > scratch.bottom[x] then
            scratch.bottom[x] = y
        end
    end
    local sides = 0
    if lineSupport(scratch.left, box.y, box.y + box.h - 1, tolerance)
        >= PANEL_BODY_FRAME_SUPPORT then
        sides = sides + 1
    end
    if lineSupport(scratch.right, box.y, box.y + box.h - 1, tolerance)
        >= PANEL_BODY_FRAME_SUPPORT then
        sides = sides + 1
    end
    if lineSupport(scratch.top, box.x, box.x + box.w - 1, tolerance)
        >= PANEL_BODY_FRAME_SUPPORT then
        sides = sides + 1
    end
    if lineSupport(scratch.bottom, box.x, box.x + box.w - 1, tolerance)
        >= PANEL_BODY_FRAME_SUPPORT then
        sides = sides + 1
    end
    return sides
end

local function collectBodies(map)
    local width, height, data = map.w, map.h, map.data
    local tolerance = math.max(1, math.min(width, height) * PANEL_BODY_FRAME_TOL_FRAC)
    -- Sized to the ink count, never lower: LuaJIT bounds-checks cdata only in debug.
    local queue_size = width * height
    if map.ink then
        queue_size = math.max(1, map.ink)
    end
    local seen = ffi.new("uint8_t[?]", width * height)
    local queue = ffi.new("int32_t[?]", queue_size)
    local scratch = {
        left = ffi.new("int32_t[?]", height),
        right = ffi.new("int32_t[?]", height),
        top = ffi.new("int32_t[?]", width),
        bottom = ffi.new("int32_t[?]", width),
    }

    local bodies = {}
    for index = 0, width * height - 1 do
        if data[index] == 1 and seen[index] == 0 then
            local head, tail = 0, 1
            queue[0], seen[index] = index, 1
            local left, right, top, bottom = width, 0, height, 0
            while head < tail do
                local position = queue[head]
                head = head + 1
                local y = math.floor(position / width)
                local x = position - y * width
                if x < left then
                    left = x
                end
                if x > right then
                    right = x
                end
                if y < top then
                    top = y
                end
                if y > bottom then
                    bottom = y
                end
                local first_x, last_x = math.max(0, x - 1), math.min(width - 1, x + 1)
                for ny = math.max(0, y - 1), math.min(height - 1, y + 1) do
                    local row = ny * width
                    for neighbour = row + first_x, row + last_x do
                        if seen[neighbour] == 0 and data[neighbour] == 1 then
                            seen[neighbour] = 1
                            queue[tail] = neighbour
                            tail = tail + 1
                        end
                    end
                end
            end
            local w, h = right - left + 1, bottom - top + 1
            if w >= width * PANEL_BODY_MIN_SIDE_FRAC
                and h >= height * PANEL_BODY_MIN_SIDE_FRAC
                and w * h >= width * height * PANEL_BODY_MIN_AREA_FRAC then
                local box = { x = left, y = top, w = w, h = h }
                box.frame_sides = frameSides(scratch, queue, tail, width, box, tolerance)
                if box.frame_sides >= PANEL_BODY_FRAME_MIN then
                    bodies[#bodies + 1] = box
                end
            end
        end
    end
    return bodies
end

local function blocked(ctx, x0, x1, y0, y1, axis)
    local bodies = ctx.bodies
    if not bodies then
        return nil
    end
    for i = 1, #bodies do
        local b = bodies[i]
        if axis == "rows" then
            if b.y < y0 and b.y + b.h - 1 > y1
                and b.x <= x0 and b.x + b.w - 1 >= x1 then
                return b
            end
        elseif b.x < x0 and b.x + b.w - 1 > x1
            and b.y <= y0 and b.y + b.h - 1 >= y1 then
            return b
        end
    end
    return nil
end

-- Inclusive bounds, absolute indices -- trimRange and findWidestGutter agree.
-- The accumulator is reused by every node, so a node zeroes only its own span.
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

local function trimRange(projection, from, to)
    while from <= to and projection[from] == 0 do
        from = from + 1
    end
    while to >= from and projection[to] == 0 do
        to = to - 1
    end
    return from, to
end

-- max_ink is deliberately unfloored: one inked cell has to keep a line out.
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

local function minInRange(projection, from, to)
    local smallest = math.huge
    for index = from, to do
        if projection[index] < smallest then
            smallest = projection[index]
        end
    end
    return smallest
end

local function trySlope(map, left, top, right, bottom, ctx, slope)
    local width = right - left + 1
    local height = bottom - top + 1
    local step = ctx.shear_step

    projectColumnsSheared(map, left, top, right, bottom, slope, ctx.cols, step)
    for _, gutter in ipairs(collectGutters(ctx.cols, left, right, height / step,
            PANEL_SHEAR_INK_RATIO, ctx.min_gutter)) do
        local split = math.floor((gutter.from + gutter.to) / 2)
        if split > left and split < right then
            return "cols", split
        end
    end

    projectRowsSheared(map, left, top, right, bottom, slope, ctx.rows, step)
    for _, gutter in ipairs(collectGutters(ctx.rows, top, bottom, width / step,
            PANEL_SHEAR_INK_RATIO, ctx.min_gutter)) do
        local split = math.floor((gutter.from + gutter.to) / 2)
        if split > top and split < bottom then
            return "rows", split
        end
    end

    return nil
end

local function refineShearedSplit(map, left, top, right, bottom, axis, split, slope)
    local data, width = map.data, map.w
    local rows = axis == "rows"
    local from, to, lo_bound, hi_bound, mid
    if rows then
        from, to, lo_bound, hi_bound = left, right, top, bottom
        mid = math.floor((left + right) / 2)
    else
        from, to, lo_bound, hi_bound = top, bottom, left, right
        mid = math.floor((top + bottom) / 2)
    end
    local function inked(along, across)
        if rows then
            return data[across * width + along] == 1
        end
        return data[along * width + across] == 1
    end

    local xs, ys, count = {}, {}, 0
    for along = from, to do
        local across = math.floor(split + slope * (along - mid) + 0.5)
        if across >= lo_bound and across <= hi_bound and not inked(along, across) then
            local lo, hi = across, across
            while lo - 1 >= lo_bound and not inked(along, lo - 1) do
                lo = lo - 1
            end
            while hi + 1 <= hi_bound and not inked(along, hi + 1) do
                hi = hi + 1
            end
            if lo > lo_bound and hi < hi_bound then
                count = count + 1
                xs[count], ys[count] = along, (lo + hi) / 2
            end
        end
    end

    local need = math.max(PANEL_SHEAR_FIT_MIN_SAMPLES,
        math.floor((to - from + 1) * PANEL_SHEAR_FIT_MIN_FRAC))
    if count < need then
        return nil
    end
    local mx, my = 0, 0
    for i = 1, count do
        mx, my = mx + xs[i], my + ys[i]
    end
    mx, my = mx / count, my / count
    local num, den = 0, 0
    for i = 1, count do
        local dx = xs[i] - mx
        num = num + dx * (ys[i] - my)
        den = den + dx * dx
    end
    if den == 0 then
        return nil
    end
    local b = num / den
    local a = my - b * mx
    if math.abs(b) > PANEL_SHEAR_FIT_SLOPE_MAX then
        return nil
    end
    local residual = 0
    for i = 1, count do
        local d = ys[i] - (a + b * xs[i])
        residual = residual + d * d
    end
    if math.sqrt(residual / count) > PANEL_SHEAR_FIT_MAX_RESIDUAL then
        return nil
    end
    if math.abs(b - slope) <= PANEL_SHEAR_REFINE_EPS then
        return nil -- the ladder was already right, and the cut keeps its own arithmetic
    end
    local refined = math.floor(a + b * mid + 0.5)
    if refined <= lo_bound or refined >= hi_bound then
        return false
    end
    return refined, b
end

-- The last slope that worked is tried first: one page, one skew angle.
local function findShearedSplit(map, left, top, right, bottom, ctx)
    local function attempt(slope)
        local axis, split = trySlope(map, left, top, right, bottom, ctx, slope)
        if not axis then
            return nil
        end
        local refined, fitted = refineShearedSplit(map, left, top, right, bottom,
            axis, split, slope)
        if refined == false then
            return "reject"
        end
        ctx.slope_hint = fitted or slope
        return axis, refined or split
    end
    if ctx.slope_hint then
        local axis, split = attempt(ctx.slope_hint)
        if axis == "reject" then
            return nil
        end
        if axis then
            return axis, split
        end
    end
    for _, slope in ipairs(PANEL_SHEAR_SLOPES) do
        if slope ~= ctx.slope_hint then
            local axis, split = attempt(slope)
            if axis == "reject" then
                return nil
            end
            if axis then
                return axis, split
            end
        end
    end
    return nil
end

local function emitLeaf(x0, y0, x1, y1, ink, ctx, out, edges)
    local w = x1 - x0 + 1
    local h = y1 - y0 + 1
    if w < ctx.min_side or h < ctx.min_side or w * h < ctx.min_area then
        return
    end
    local long_side, short_side = w, h
    if h > w then
        long_side, short_side = h, w
    end
    if long_side >= short_side * PANEL_SLIVER_ASPECT and ink < ctx.sliver_ink then
        return
    end
    table.insert(out, { x = x0, y = y0, w = w, h = h, edges = edges })
end

local function cut(map, x0, y0, x1, y1, edges, depth, ctx, out)
    if x1 < x0 or y1 < y0 or #out >= PANEL_MAX_PANELS then
        return
    end

    project(map, x0, y0, x1, y1, ctx.rows, ctx.cols)
    local top, bottom = trimRange(ctx.rows, y0, y1)
    local left, right = trimRange(ctx.cols, x0, x1)
    if bottom < top or right < left then
        return -- region is entirely background
    end

    local el = left == x0 and edges.l or { a = left, b = 0 }
    local er = right == x1 and edges.r or { a = right, b = 0 }
    local et = top == y0 and edges.t or { a = top, b = 0 }
    local ebo = bottom == y1 and edges.bo or { a = bottom, b = 0 }

    -- Summed before the sheared search and recursion overwrite the shared buffers.
    local region_ink = 0
    for y = top, bottom do
        region_ink = region_ink + ctx.rows[y]
    end

    if depth < PANEL_MAX_DEPTH then
        local width = right - left + 1
        local height = bottom - top + 1
        local row_start, row_stop, row_length =
            findWidestGutter(ctx.rows, top, bottom, width, ctx.ink_ratio, ctx.min_gutter)
        local col_start, col_stop, col_length =
            findWidestGutter(ctx.cols, left, right, height, ctx.ink_ratio, ctx.min_gutter)

        local row_hit = row_length > 0
            and blocked(ctx, left, right, row_start, row_stop, "rows")
        local col_hit = col_length > 0
            and blocked(ctx, col_start, col_stop, top, bottom, "cols")
        local row_ok = row_length > 0 and not row_hit
        local col_ok = col_length > 0 and not col_hit
        if row_ok and (not col_ok or row_length >= col_length) then
            cut(map, left, top, right, row_start - 1,
                { l = el, r = er, t = et, bo = { a = row_start - 1, b = 0 } },
                depth + 1, ctx, out)
            cut(map, left, row_stop + 1, right, bottom,
                { l = el, r = er, t = { a = row_stop + 1, b = 0 }, bo = ebo },
                depth + 1, ctx, out)
            return
        elseif col_ok then
            cut(map, left, top, col_start - 1, bottom,
                { l = el, r = { a = col_start - 1, b = 0 }, t = et, bo = ebo },
                depth + 1, ctx, out)
            cut(map, col_stop + 1, top, right, bottom,
                { l = { a = col_stop + 1, b = 0 }, r = er, t = et, bo = ebo },
                depth + 1, ctx, out)
            return
        end

        if row_length == 0 and col_length == 0
            and depth <= PANEL_SHEAR_MAX_DEPTH
            and (minInRange(ctx.cols, left, right) <= height * PANEL_SHEAR_TRIGGER
                or minInRange(ctx.rows, top, bottom) <= width * PANEL_SHEAR_TRIGGER) then
            local axis, split = findShearedSplit(map, left, top, right, bottom, ctx)
            if axis then
                local slope = ctx.slope_hint
                local bx0, bx1, by0, by1, mid, line
                if axis == "cols" then
                    mid = math.floor((top + bottom) / 2)
                    local a = split + slope * (top - mid)
                    local b = split + slope * (bottom - mid)
                    bx0, bx1 = math.floor(math.min(a, b)), math.ceil(math.max(a, b))
                    by0, by1 = top, bottom
                    line = { a = split - slope * mid, b = slope }
                else
                    mid = math.floor((left + right) / 2)
                    local a = split + slope * (left - mid)
                    local b = split + slope * (right - mid)
                    by0, by1 = math.floor(math.min(a, b)), math.ceil(math.max(a, b))
                    bx0, bx1 = left, right
                    line = { a = split - slope * mid, b = slope }
                end
                if not blocked(ctx, bx0, bx1, by0, by1, axis) then
                    if axis == "cols" then
                        cut(map, left, top, split, bottom,
                            { l = el, r = line, t = et, bo = ebo }, depth + 1, ctx, out)
                        cut(map, split + 1, top, right, bottom,
                            { l = line, r = er, t = et, bo = ebo }, depth + 1, ctx, out)
                    else
                        cut(map, left, top, right, split,
                            { l = el, r = er, t = et, bo = line }, depth + 1, ctx, out)
                        cut(map, left, split + 1, right, bottom,
                            { l = el, r = er, t = line, bo = ebo }, depth + 1, ctx, out)
                    end
                    return
                end
            end
        end
    end

    emitLeaf(left, top, right, bottom, region_ink, ctx, out,
        { l = el, r = er, t = et, bo = ebo })
end

local function frameCells(map, x0, y0, x1, y1)
    if x0 < 0 or y0 < 0 or x1 > map.w - 1 or y1 > map.h - 1 then
        return 0
    end
    local data, width = map.data, map.w
    for y = y0, y1 do
        local base = y * width
        for x = x0, x1 do
            if data[base + x] == 1 then
                return 0
            end
        end
    end
    return PANEL_DARK_FRAME_CELLS
end

local function segment(map)
    local min_dimension = math.min(map.w, map.h)
    local ctx = {
        rows = ffi.new("int32_t[?]", map.h),
        cols = ffi.new("int32_t[?]", map.w),
        ink_ratio = PANEL_GUTTER_INK_RATIO,
        min_gutter = math.max(1, math.floor(min_dimension * PANEL_GUTTER_RATIO)),
        min_side = math.max(4, math.floor(min_dimension * PANEL_MIN_SIDE_FRAC)),
        min_area = math.floor(map.w * map.h * PANEL_MIN_AREA_FRAC),
        -- A zero ink total disables the sliver floor instead of rejecting every leaf.
        sliver_ink = math.floor((map.ink or 0) * PANEL_SLIVER_INK_FRAC),
        shear_step = PANEL_SHEAR_STEP,
        slope_hint = nil,
        bodies = collectBodies(map),
    }

    local cells = {}
    cut(map, 0, 0, map.w - 1, map.h - 1,
        { l = { a = 0, b = 0 }, r = { a = map.w - 1, b = 0 },
          t = { a = 0, b = 0 }, bo = { a = map.h - 1, b = 0 } },
        0, ctx, cells)

    local kept = {}
    for i, cell in ipairs(cells) do
        local contained = false
        for j, other in ipairs(cells) do
            if j ~= i
                and other.w * other.h > cell.w * cell.h -- strict: a tie keeps both
                and cell.x >= other.x and cell.y >= other.y
                and cell.x + cell.w <= other.x + other.w
                and cell.y + cell.h <= other.y + other.h
            then
                contained = true
                break
            end
        end
        if not contained then
            kept[#kept + 1] = cell
        end
    end
    cells = kept

    -- Deliberately floats: `panelTileKey` is where they become integers.
    local panels = {}
    local dark = (map.bg or 255) < PANEL_DARK_BG_LUMA
    for _, cell in ipairs(cells) do
        local e = cell.edges
        local x0n, x1n = cell.x * map.scale_x, (cell.x + cell.w - 1) * map.scale_x
        local y0n, y1n = cell.y * map.scale_y, (cell.y + cell.h - 1) * map.scale_y
        local fl, fr, ft, fb = 0, 0, 0, 0
        if dark then
            local n, w, h = PANEL_DARK_FRAME_CELLS, cell.w, cell.h
            fl = frameCells(map, cell.x - n, cell.y, cell.x - 1, cell.y + h - 1)
            fr = frameCells(map, cell.x + w, cell.y, cell.x + w + n - 1, cell.y + h - 1)
            ft = frameCells(map, cell.x, cell.y - n, cell.x + w - 1, cell.y - 1)
            fb = frameCells(map, cell.x, cell.y + h, cell.x + w - 1, cell.y + h + n - 1)
        end
        -- Converting a line converts its coefficients, not two points.
        local l = { a = (e.l.a - fl) * map.scale_x,
                    b = e.l.b * map.scale_x / map.scale_y }
        local r = { a = (e.r.a + 1 + fr) * map.scale_x,
                    b = e.r.b * map.scale_x / map.scale_y }
        local t = { a = (e.t.a - ft) * map.scale_y,
                    b = e.t.b * map.scale_y / map.scale_x }
        local bo = { a = (e.bo.a + 1 + fb) * map.scale_y,
                     b = e.bo.b * map.scale_y / map.scale_x }

        local left = math.max(0, math.min(l.a + l.b * y0n, l.a + l.b * y1n))
        local right = math.min(map.native_w, math.max(r.a + r.b * y0n, r.a + r.b * y1n))
        local top = math.max(0, math.min(t.a + t.b * x0n, t.a + t.b * x1n))
        local bottom = math.min(map.native_h, math.max(bo.a + bo.b * x0n, bo.a + bo.b * x1n))
        if right - left >= 1 and bottom - top >= 1 then
            table.insert(panels, {
                x = left,
                y = top,
                w = right - left,
                h = bottom - top,
                planes = {
                    { A = -1, B = l.b, C = l.a },
                    { A = 1, B = -r.b, C = -r.a },
                    { A = t.b, B = -1, C = t.a },
                    { A = -bo.b, B = 1, C = -bo.a },
                },
            })
        end
    end

    return panels
end

local function accept(panels, map)
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
        if largest_area >= page_area * PANEL_SINGLE_PANEL_RATIO then
            return true
        end
        return false, "single partial panel"
    end

    local covered_area = (max_x - min_x) * (max_y - min_y)
    if covered_area < page_area * PANEL_PAGE_COVERAGE_MIN then
        return false, "panels cover too little of the page"
    end
    if total_area < covered_area * PANEL_COVERAGE_MIN then
        return false, string.format("only %d%% of the covered area kept",
            math.floor(total_area * 100 / covered_area))
    end

    return true
end

local function buildRows(panels)
    local sorted = {}
    for i, p in ipairs(panels) do
        sorted[i] = p
    end
    table.sort(sorted, function(a, b)
        if a.y ~= b.y then
            return a.y < b.y
        end
        return a.x < b.x
    end)

    local rows = {}
    for _, p in ipairs(sorted) do
        local height = math.max(1, p.h)
        local best_row, best_distance
        for _, row in ipairs(rows) do
            local distance = math.abs(p.y - row.top)
            local tolerance = math.min(height, row.min_h) * 0.35
            if distance <= tolerance and (not best_distance or distance < best_distance) then
                best_row, best_distance = row, distance
            end
        end
        if not best_row then
            best_row = { top = p.y, min_h = height, members = {} }
            rows[#rows + 1] = best_row
        else
            best_row.min_h = math.min(best_row.min_h, height)
        end
        best_row.members[#best_row.members + 1] = p
    end
    return rows
end

local function isLeadingOf(later, panel, manga)
    if manga then
        return later.x >= panel.x + panel.w
    end
    return later.x + later.w <= panel.x
end

local function sortReadingOrder(panels, manga)
    local rows = buildRows(panels)
    local sorted = {}
    local deferred = {}
    for row_index, row in ipairs(rows) do
        table.sort(row.members, function(a, b)
            if a.x == b.x then
                return a.y < b.y
            end
            if manga then
                return a.x > b.x
            end
            return a.x < b.x
        end)
        for item_index, panel in ipairs(row.members) do
            local defer_until = row_index
            if item_index > 1 then
                local bottom = panel.y + math.max(1, panel.h)
                for later_index = row_index + 1, #rows do
                    if rows[later_index].top >= bottom then
                        break -- later rows start below this panel: no overlap
                    end
                    for _, later in ipairs(rows[later_index].members) do
                        if isLeadingOf(later, panel, manga) then
                            defer_until = later_index
                            break
                        end
                    end
                end
            end
            if defer_until > row_index then
                deferred[defer_until] = deferred[defer_until] or {}
                table.insert(deferred[defer_until], panel)
            else
                sorted[#sorted + 1] = panel
            end
        end
        if deferred[row_index] then
            for _, panel in ipairs(deferred[row_index]) do
                sorted[#sorted + 1] = panel
            end
            deferred[row_index] = nil
        end
    end
    -- The loop above already flushes every hold; this guards a future change to it.
    for row_index = 1, #rows do
        if deferred[row_index] then
            for _, panel in ipairs(deferred[row_index]) do
                sorted[#sorted + 1] = panel
            end
            deferred[row_index] = nil
        end
    end
    for i, panel in ipairs(sorted) do
        panels[i] = panel
    end
    return panels
end

-- native_bb belongs to the document's native LRU and is not freed here.
function Panel.detect(native_bb, manga)
    if not native_bb then
        return nil, false, "no page buffer"
    end
    -- Sizes from the buffer itself; a raster copy would cost the whole page.
    if not (native_bb.getWidth and native_bb.getHeight) then
        return nil, false, "unreadable page buffer"
    end
    local native_w, native_h = native_bb:getWidth(), native_bb:getHeight()

    local scan = native_bb
    local sw, sh = native_w, native_h
    local scale = math.min(1,
        PANEL_SCAN_WIDTH / native_w,
        math.sqrt(PANEL_SCAN_MAX_CELLS / (native_w * native_h)))
    if scale < 1 then
        sw = math.max(2, math.floor(native_w * scale + 0.5))
        sh = math.max(2, math.floor(native_h * scale + 0.5))
        local ok_scale, scaled = pcall(RenderImage.scaleBlitBuffer,
            RenderImage, native_bb, sw, sh, false)
        if ok_scale and scaled then
            scan = scaled
        else
            sw, sh = native_w, native_h -- best effort: scan the page as it is
        end
    end

    local ok_raster, scan_raster = pcall(Image.rasterFor, scan)
    if scan ~= native_bb then
        -- The scan copy is C-side owned, so free it whatever the raster accessor did.
        scan:free()
    end
    if not ok_raster or not scan_raster then
        return nil, false, "unreadable page scan"
    end

    local bg = backgroundFor(scan_raster)
    local map = buildInkMap(scan_raster, bg, native_w, native_h)
    local panels = segment(map)
    local accepted, reason = accept(panels, map)
    if not accepted then
        -- The four edges are named rather than left nil, so consumers read one shape.
        return { { x = 0, y = 0, w = native_w, h = native_h,
                   planes = { { A = -1, B = 0, C = 0 },
                              { A = 1, B = 0, C = -native_w },
                              { A = 0, B = -1, C = 0 },
                              { A = 0, B = 1, C = -native_h } } } }, false, reason
    end
    return sortReadingOrder(panels, manga and true or false), true
end

function Panel.indexAt(panels, x, y)
    if not (panels and #panels > 0) then
        return nil
    end
    if not (x and y) then
        return nil
    end
    local inside, inside_area
    local nearest, nearest_d
    for i, p in ipairs(panels) do
        local hit = false
        if p.planes then
            hit = true
            for _, plane in ipairs(p.planes) do
                if plane.A * x + plane.B * y + plane.C > 0 then
                    hit = false
                    break
                end
            end
        else
            hit = x >= p.x and x <= p.x + p.w and y >= p.y and y <= p.y + p.h
        end
        if hit then
            local area = p.w * p.h
            if not inside_area or area < inside_area then
                inside, inside_area = i, area
            end
        end
        local dx = x - (p.x + p.w / 2)
        local dy = y - (p.y + p.h / 2)
        local d = dx * dx + dy * dy
        if not nearest_d or d < nearest_d then
            nearest, nearest_d = i, d
        end
    end
    return inside or nearest
end

return Panel
