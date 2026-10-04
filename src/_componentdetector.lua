local ffi = require("ffi")
local Geometry = require("src._geometry")
local Segmenter = require("src._segmenter")
local Settings = require("src._settings")

local ComponentDetector = {}

local scratch_capacity = 0
local scratch_seen = nil
local scratch_queue = nil

local scratch_white_capacity = 0
local scratch_white = nil

local scratch_dim_capacity = 0
local scratch_left = nil
local scratch_right = nil
local scratch_top = nil
local scratch_bottom = nil

local function ensureScratch(size, max_dim)
    if scratch_capacity < size then
        scratch_capacity = size
        scratch_seen = ffi.new("uint8_t[?]", size)
        scratch_queue = ffi.new("int32_t[?]", size)
    end
    if scratch_dim_capacity < max_dim then
        scratch_dim_capacity = max_dim
        scratch_left = ffi.new("int32_t[?]", max_dim)
        scratch_right = ffi.new("int32_t[?]", max_dim)
        scratch_top = ffi.new("int32_t[?]", max_dim)
        scratch_bottom = ffi.new("int32_t[?]", max_dim)
    end
end

local function ensureWhiteScratch(size)
    if scratch_white_capacity < size then
        scratch_white_capacity = size
        scratch_white = ffi.new("uint8_t[?]", size)
    end
end

function ComponentDetector.clearScratch()
    scratch_capacity = 0
    scratch_seen = nil
    scratch_queue = nil
    scratch_white_capacity = 0
    scratch_white = nil
    scratch_dim_capacity = 0
    scratch_left = nil
    scratch_right = nil
    scratch_top = nil
    scratch_bottom = nil
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
                    if best >= 0.80 then
                        return best
                    end
                end
            end
        end
    end
    return best
end

local function frameSides(pixels, count, width, box, tolerance)
    local top, bottom = box.y, box.y + box.h - 1
    local left, right = box.x, box.x + box.w - 1

    for y = top, bottom do
        scratch_left[y] = right + 1
        scratch_right[y] = left - 1
    end
    for x = left, right do
        scratch_top[x] = bottom + 1
        scratch_bottom[x] = top - 1
    end

    for i = 0, count - 1 do
        local index = pixels[i]
        local y = math.floor(index / width)
        local x = index - y * width
        if x < scratch_left[y] then
            scratch_left[y] = x
        end
        if x > scratch_right[y] then
            scratch_right[y] = x
        end
        if y < scratch_top[x] then
            scratch_top[x] = y
        end
        if y > scratch_bottom[x] then
            scratch_bottom[x] = y
        end
    end

    local sides = 0
    if lineSupport(scratch_left, top, bottom, tolerance) >= 0.80 then
        sides = sides + 1
    end
    if lineSupport(scratch_right, top, bottom, tolerance) >= 0.80 then
        sides = sides + 1
    end
    if lineSupport(scratch_top, left, right, tolerance) >= 0.80 then
        sides = sides + 1
    end
    if lineSupport(scratch_bottom, left, right, tolerance) >= 0.80 then
        sides = sides + 1
    end
    return sides
end

local function collectComponents(map, min_side, min_area, visit)
    local width, height, data = map.w, map.h, map.data
    ensureScratch(width * height, math.max(width, height))
    ffi.fill(scratch_seen, width * height, 0)

    local seen = scratch_seen
    local queue = scratch_queue
    local components = {}
    local min_pixels = math.max(1, math.floor(min_area))
    local min_w = math.max(1, math.floor(width * min_side))
    local min_h = math.max(1, math.floor(height * min_side))

    for start_index = 0, width * height - 1 do
        if data[start_index] == 1 and seen[start_index] == 0 then
            seen[start_index] = 1
            queue[0] = start_index
            local head, tail = 0, 1

            local start_y = math.floor(start_index / width)
            local start_x = start_index - start_y * width
            local left, right = start_x, start_x
            local top, bottom = start_y, start_y

            while head < tail do
                local index = queue[head]
                head = head + 1

                local y = math.floor(index / width)
                local x = index - y * width

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

                for dy = -1, 1 do
                    local ny = y + dy
                    if ny >= 0 and ny < height then
                        local row_offset = ny * width
                        for dx = -1, 1 do
                            local nx = x + dx
                            if nx >= 0 and nx < width and (dx ~= 0 or dy ~= 0) then
                                local neighbor = row_offset + nx
                                if data[neighbor] == 1 and seen[neighbor] == 0 then
                                    seen[neighbor] = 1
                                    queue[tail] = neighbor
                                    tail = tail + 1
                                end
                            end
                        end
                    end
                end
            end

            local w = right - left + 1
            local h = bottom - top + 1
            if tail >= min_pixels and w >= min_w and h >= min_h then
                local box = { x = left, y = top, w = w, h = h }
                box.frame_sides = frameSides(queue, tail, width, box, math.max(1, math.min(width, height) * 0.003))
                components[#components + 1] = box
                if visit then
                    visit(box, queue, tail)
                end
            end
        end
    end
    return components
end

local function countEdges(map, box, include_page_edges)
    local top, bottom, left, right = 0, 0, 0, 0
    local band = math.min(3, box.w, box.h)
    for x = box.x, box.x + box.w - 1 do
        for offset = 0, band - 1 do
            if map.data[(box.y + offset) * map.w + x] == 1 then
                top = top + 1
                break
            end
        end
        for offset = 0, band - 1 do
            if map.data[(box.y + box.h - 1 - offset) * map.w + x] == 1 then
                bottom = bottom + 1
                break
            end
        end
    end
    for y = box.y, box.y + box.h - 1 do
        for offset = 0, band - 1 do
            if map.data[y * map.w + box.x + offset] == 1 then
                left = left + 1
                break
            end
        end
        for offset = 0, band - 1 do
            if map.data[y * map.w + box.x + box.w - 1 - offset] == 1 then
                right = right + 1
                break
            end
        end
    end
    local page_edges = include_page_edges ~= false
    local top_b = ((page_edges and box.y <= 3) or top > box.w * 0.75) and 1 or 0
    local bot_b = ((page_edges and box.y + box.h >= map.h - 4) or bottom > box.w * 0.75) and 1 or 0
    local left_b = ((page_edges and box.x <= 3) or left > box.h * 0.75) and 1 or 0
    local right_b = ((page_edges and box.x + box.w >= map.w - 4) or right > box.h * 0.75) and 1 or 0
    return top_b + bot_b + left_b + right_b
end

local function emptySplitMargin(map, box)
    if not box.split_child or countEdges(map, box, false) >= 3 then
        return false
    end
    local inset = math.max(4, math.floor(math.min(box.w, box.h) * 0.03))
    for y = box.y + inset, box.y + box.h - inset - 1 do
        for x = box.x + inset, box.x + box.w - inset - 1 do
            if map.data[y * map.w + x] == 1 then
                return false
            end
        end
    end
    return true
end

local function hasFrame(map, box)
    return countEdges(map, box) == 4
end

local function splitJoinedFrames(map, box, settings, depth, shared_borders)
    depth = depth or 0
    if depth == 0 then
        if (box.frame_sides or 0) >= 4 then
            return { box }
        end
        shared_borders = settings.mode ~= "comic" and map.dark ~= nil
    end
    if depth >= 4 then
        return { box }
    end
    local rows, cols, brows, bcols = {}, {}, {}, {}
    for x = box.x, box.x + box.w - 1 do
        cols[x] = 0
        bcols[x] = 0
    end
    for y = box.y, box.y + box.h - 1 do
        local count, bcount = 0, 0
        for x = box.x, box.x + box.w - 1 do
            local value = map.data[y * map.w + x]
            count = count + value
            cols[x] = cols[x] + value
            local dark = map.dark and map.dark[y * map.w + x] or 0
            bcols[x] = bcols[x] + dark
            bcount = bcount + dark
        end
        rows[y] = count
        brows[y] = bcount
    end
    local best
    local function search(projection, border, first, span, length, minimum, axis)
        local last = first + length - 1
        local i = first + minimum
        while i <= last - minimum do
            local white = projection[i] <= span * (depth == 0 and 0.035 or 0.025)
            local black = false
            if shared_borders and border and depth <= 3 then
                local b_val = border[i]
                local cutoff = depth == 0 and 0.88 or 0.90
                if b_val >= span * cutoff then
                    black = true
                elseif b_val >= span * (axis == "y" and 0.86 or 0.75) then
                    local b_prev = math.min(border[i - 2] or 0, border[i - 3] or 0)
                    local b_next = math.min(border[i + 2] or 0, border[i + 3] or 0)
                    local step = axis == "y" and 0.30 or 0.25
                    if (b_val - b_prev >= span * step) and (b_val - b_next >= span * step) then
                        black = true
                    end
                end
                if depth == 0 and box.frame_sides == 3 and b_val < span * 0.82 then
                    black = false
                end
            end
            if white or black then
                local start = i
                repeat
                    i = i + 1
                until i > last
                    or (white and projection[i] > span * (depth == 0 and 0.035 or 0.025))
                    or (black and (border[i] or 0) < span * 0.70)
                local stop = i - 1
                local width = stop - start + 1
                local valid = stop <= last - minimum
                if white then
                    local before, after = 0, 0
                    for offset = 1, 4 do
                        before = math.max(before, projection[start - offset] or 0)
                        after = math.max(after, projection[stop + offset] or 0)
                    end
                    valid = valid and width >= 1 and before >= span * 0.75 and after >= span * 0.75
                else
                    local b_prev = math.min(border[start - 2] or 0, border[start - 3] or 0)
                    local b_next = math.min(border[stop + 2] or 0, border[stop + 3] or 0)
                    valid = valid and width <= 4 and b_prev < span * 0.80 and b_next < span * 0.80
                    local peak = 0
                    for k = start, stop do
                        peak = math.max(peak, border[k] or 0)
                    end
                    local weak_unframed = depth == 0 and (box.frame_sides or 0) == 0 and peak < span * 0.88
                    if valid and (width >= 3 or weak_unframed) then
                        -- Dense text/hair can add up to a high projection without
                        -- forming a separator. Require a continuous half-span too.
                        local run, longest, gap = 0, 0, 0
                        local max_gap = math.ceil(span * 0.01)
                        local cross_first = axis == "y" and box.x or box.y
                        for cross = cross_first, cross_first + span - 1 do
                            local hit = false
                            for k = start, stop do
                                local index = axis == "y" and k * map.w + cross or cross * map.w + k
                                if map.dark[index] == 1 then
                                    hit = true
                                    break
                                end
                            end
                            gap = hit and 0 or gap + 1
                            run = gap <= max_gap and run + 1 or 0
                            if hit then
                                longest = math.max(longest, run)
                            end
                        end
                        valid = longest >= span * 0.50
                    end
                end
                if valid then
                    local score
                    if white then
                        score = 2.0 + width / length + math.min(start - first, last - stop) / length * 0.3
                    else
                        local b_max = 0
                        for k = start, stop do
                            if (border[k] or 0) > b_max then
                                b_max = border[k]
                            end
                        end
                        score = 1.0 + (b_max / span) * 2.0 + math.min(start - first, last - stop) / length * 0.3
                    end
                    if not best or score > best.score then
                        best = { axis = axis, start = start, stop = stop, white = white, score = score }
                    end
                end
            else
                i = i + 1
            end
        end
    end

    local min_y = math.max(14, math.floor(map.h * 0.08))
    local min_x = math.max(16, math.floor(map.w * 0.10))
    search(rows, brows, box.y, box.w, box.h, min_y, "y")
    search(cols, bcols, box.x, box.h, box.w, min_x, "x")

    if not best then
        return { box }
    end
    local lo = best.white and best.start - 1 or best.stop
    local hi = best.white and best.stop + 1 or best.start
    local a, b
    if best.axis == "y" then
        a = { x = box.x, y = box.y, w = box.w, h = lo - box.y + 1 }
        b = { x = box.x, y = hi, w = box.w, h = box.y + box.h - hi }
    else
        a = { x = box.x, y = box.y, w = lo - box.x + 1, h = box.h }
        b = { x = hi, y = box.y, w = box.x + box.w - hi, h = box.h }
    end
    a.split_child, b.split_child = true, true
    local parts = splitJoinedFrames(map, a, settings, depth + 1, shared_borders)
    for _, part in ipairs(splitJoinedFrames(map, b, settings, depth + 1, shared_borders)) do
        parts[#parts + 1] = part
    end
    if depth == 0 and box.frame_sides == 3 then
        for _, p in ipairs(parts) do
            if p.w < box.w * 0.18 or p.h < box.h * 0.12 or p.w * p.h < box.w * box.h * 0.04 then
                return { box }
            end
        end
    end
    if depth == 0 and #parts == 2 then
        local framed_count = 0
        for _, p in ipairs(parts) do
            if (p.frame_sides or 0) >= 2 or countEdges(map, p) >= 2 then
                framed_count = framed_count + 1
            end
        end
        if framed_count == 0 then
            return { box }
        end
    end
    if depth == 0 then
        for _, p in ipairs(parts) do
            if p.frame_sides == nil then
                p.frame_sides = countEdges(map, p)
            end
        end
    end
    return parts
end

function ComponentDetector.segment(map, settings)
    settings = settings or Settings.defaults
    local min_side = 0.02
    local min_area = map.w * map.h * 0.002
    local components = collectComponents(map, min_side, min_area)
    local cells = {}
    for _, box in ipairs(components) do
        local keep = true
        for _, other in ipairs(components) do
            if
                other ~= box
                and other.w * other.h > box.w * box.h
                and box.x >= other.x - 1
                and box.y >= other.y - 1
                and box.x + box.w <= other.x + other.w + 1
                and box.y + box.h <= other.y + other.h + 1
            then
                keep = false
                break
            end
        end
        if
            keep
            and (
                (box.w < map.w * 0.07 and box.h < map.h * 0.07)
                or (box.w * box.h < map.w * map.h * 0.008)
                or (box.h < map.h * 0.03)
                or (box.w < map.w * 0.03)
            )
        then
            keep = false
        elseif keep and (box.w < map.w * 0.10 or box.h < map.h * 0.10 or box.w * box.h < map.w * map.h * 0.01) then
            keep = ((box.frame_sides or 0) >= 3 or hasFrame(map, box))
                and (box.w >= map.w * 0.05 and box.h >= map.h * 0.03)
        end
        if keep then
            cells[#cells + 1] = box
        end
    end
    local framed, floating = {}, {}
    for _, box in ipairs(cells) do
        if box.frame_sides >= (settings.component_frame_min or 1) then
            framed[#framed + 1] = box
        else
            floating[#floating + 1] = box
        end
    end
    if #framed == 0 then
        for _, box in ipairs(cells) do
            if box.w * box.h >= map.w * map.h * 0.30 then
                local parts = splitJoinedFrames(map, box, settings)
                if #parts > 1 then
                    framed[#framed + 1] = box
                end
            end
        end
        if #framed == 0 then
            return {}
        end
    end
    local groups = {}
    for _, box in ipairs(floating) do
        local target, distance
        for _, other in ipairs(framed) do
            local overlap = math.max(0, math.min(box.y + box.h, other.y + other.h) - math.max(box.y, other.y))
            local gap = math.max(0, other.x - box.x - box.w, box.x - other.x - other.w)
            if overlap >= box.h * 0.6 and (not distance or gap < distance) then
                local has_border = false
                if map.dark and gap > 0 then
                    local min_x = math.min(box.x + box.w, other.x + other.w)
                    local max_x = math.max(box.x, other.x)
                    local y_start = math.max(box.y, other.y)
                    local y_end = math.min(box.y + box.h, other.y + other.h)
                    local h_span = y_end - y_start
                    if h_span > 10 then
                        for cx = min_x, max_x do
                            local dark_c = 0
                            for cy = y_start, y_end do
                                if map.dark[cy * map.w + cx] == 1 then
                                    dark_c = dark_c + 1
                                end
                            end
                            if dark_c >= h_span * 0.75 then
                                has_border = true
                                break
                            end
                        end
                    end
                end
                if
                    not has_border and (gap <= map.w * 0.25 or (overlap >= box.h * 0.75 and overlap >= other.h * 0.75))
                then
                    target, distance = other, gap
                end
            end
        end
        if
            target
            and #framed >= 2
            and box.w > map.w * 0.25
            and box.h > map.h * 0.25
            and box.w * box.h > map.w * map.h * 0.10
        then
            target = nil
        end
        if target then
            local union = Geometry.rectUnion(target, box)
            target.x, target.y, target.w, target.h = union.x, union.y, union.w, union.h
        else
            local above = 0
            for _, other in ipairs(framed) do
                if other.y + other.h <= box.y then
                    above = above + 1
                end
            end
            groups[above] = groups[above] and Geometry.rectUnion(groups[above], box) or box
        end
    end
    for _, box in pairs(groups) do
        framed[#framed + 1] = box
    end
    if settings.component_holes then
        local size = map.w * map.h
        ensureWhiteScratch(size)
        local white = scratch_white
        for index = 0, size - 1 do
            white[index] = map.data[index] == 0 and 1 or 0
        end
        local holes = collectComponents({ w = map.w, h = map.h, data = white }, 0.04, map.w * map.h * 0.005)
        local extras = {}
        local tolerance = math.min(map.w, map.h) * 0.008
        for _, hole in ipairs(holes) do
            if hole.frame_sides >= 3 then
                for _, parent in ipairs(framed) do
                    if
                        hole.w * hole.h < parent.w * parent.h * 0.85
                        and hole.x >= parent.x - tolerance
                        and hole.y >= parent.y - tolerance
                        and hole.x + hole.w <= parent.x + parent.w + tolerance
                        and hole.y + hole.h <= parent.y + parent.h + tolerance
                    then
                        local aligned = 0
                        if math.abs(hole.x - parent.x) <= tolerance then
                            aligned = aligned + 1
                        end
                        if math.abs(hole.y - parent.y) <= tolerance then
                            aligned = aligned + 1
                        end
                        if math.abs(hole.x + hole.w - parent.x - parent.w) <= tolerance then
                            aligned = aligned + 1
                        end
                        if math.abs(hole.y + hole.h - parent.y - parent.h) <= tolerance then
                            aligned = aligned + 1
                        end
                        if aligned >= 2 then
                            extras[#extras + 1] = hole
                            break
                        end
                    end
                end
            end
        end
        for _, extra in ipairs(extras) do
            framed[#framed + 1] = extra
        end
    end

    local refined = {}
    for _, box in ipairs(framed) do
        for _, part in ipairs(splitJoinedFrames(map, box, settings)) do
            refined[#refined + 1] = part
        end
    end
    local panels = {}
    for _, box in ipairs(refined) do
        local sides = box.frame_sides
        if sides == nil then
            sides = countEdges(map, box)
        end
        local is_sliver = (box.h < map.h * 0.08 or box.w < map.w * 0.08 or box.w * box.h < map.w * map.h * 0.015)
            and sides < 2
        if not is_sliver and not emptySplitMargin(map, box) then
            local x = math.max(0, (box.x - 1) * map.scale_x)
            local y = math.max(0, (box.y - 1) * map.scale_y)
            local right = math.min(map.native_w, (box.x + box.w + 1) * map.scale_x)
            local bottom = math.min(map.native_h, (box.y + box.h + 1) * map.scale_y)
            panels[#panels + 1] = { x = x, y = y, w = right - x, h = bottom - y, frame_sides = sides }
        end
    end
    if #panels > (settings.segment_max_panels or Settings.defaults.segment_max_panels) then
        return {}
    end
    return panels
end

local function sharedBalloon(map, parts)
    local size = map.w * map.h
    ensureWhiteScratch(size)
    local white = scratch_white
    for k = 0, size - 1 do
        white[k] = 1 - map.data[k]
    end
    local shared = false
    collectComponents({ w = map.w, h = map.h, data = white }, 0.015, size * 0.001, function(h, pixels, count)
        if
            shared
            or count < h.w * h.h * 0.4
            or h.frame_sides >= 3
            or h.w * h.h >= size * 0.15
            or h.w / h.h >= 4
            or h.h / h.w >= 4
        then
            return
        end
        local counts = {}
        for i = 0, count - 1 do
            local row = math.floor(pixels[i] / map.w)
            local x, y = (pixels[i] - row * map.w + 0.5) * map.scale_x, (row + 0.5) * map.scale_y
            local owner
            for j, q in ipairs(parts) do
                if x >= q.x and x < q.x + q.w and y >= q.y and y < q.y + q.h then
                    if owner then
                        owner = nil
                        break
                    end
                    owner = j
                end
            end
            if owner then
                counts[owner] = (counts[owner] or 0) + 1
            end
        end
        local hits = 0
        for _, n in pairs(counts) do
            if n > count * 0.15 then
                hits = hits + 1
            end
        end
        if hits >= 2 then
            shared = true
        end
    end)
    return shared
end

function ComponentDetector.detectPage(map, settings)
    settings = settings or Settings.defaults
    local panels = ComponentDetector.segment(map, settings)

    if map.structural then
        local alternate = {}
        for k, v in pairs(map) do
            alternate[k] = v
        end
        alternate.data = map.structural
        local candidates = ComponentDetector.segment(alternate, settings)

        local refined = {}
        if #panels == 0 then
            panels = { { x = 0, y = 0, w = map.native_w, h = map.native_h } }
        end
        for _, p in ipairs(panels) do
            local parts, area = {}, 0
            for _, q in ipairs(candidates) do
                local inter = math.max(0, math.min(p.x + p.w, q.x + q.w) - math.max(p.x, q.x))
                    * math.max(0, math.min(p.y + p.h, q.y + q.h) - math.max(p.y, q.y))
                if inter >= q.w * q.h * 0.95 and q.w * q.h < p.w * p.h * 0.85 then
                    parts[#parts + 1] = q
                    area = area + q.w * q.h
                end
            end
            local strong, sides = 0, 0
            for _, q in ipairs(parts) do
                sides = sides + (q.frame_sides or 0)
                if (q.frame_sides or 0) >= 3 then
                    strong = strong + 1
                end
            end
            local reliable = #parts >= 2
                and area >= p.w * p.h * 0.85
                and strong >= math.ceil(#parts * 0.6)
                and sides >= #parts * 2
            for i, q in ipairs(parts) do
                for j = i + 1, #parts do
                    local r = parts[j]
                    local overlap = math.max(0, math.min(q.x + q.w, r.x + r.w) - math.max(q.x, r.x))
                        * math.max(0, math.min(q.y + q.h, r.y + r.h) - math.max(q.y, r.y))
                    if overlap > math.min(q.w * q.h, r.w * r.h) * 0.25 then
                        reliable = false
                    end
                end
            end
            if reliable and not sharedBalloon(map, parts) then
                for _, q in ipairs(parts) do
                    refined[#refined + 1] = q
                end
            else
                refined[#refined + 1] = p
            end
        end
        if #refined <= (settings.segment_max_panels or Settings.defaults.segment_max_panels) then
            panels = refined
        end
    end

    if settings.mode == "comic" and #panels > 1 then
        local framed_area = 0
        for _, p in ipairs(panels) do
            if (p.frame_sides or 0) >= 3 then
                framed_area = framed_area + p.w * p.h
            end
        end
        if framed_area < map.native_w * map.native_h * 0.05 then
            panels = { { x = 0, y = 0, w = map.native_w, h = map.native_h } }
        end
    end

    if #panels > 1 then
        local filtered = {}
        for i = 1, #panels do
            local a = panels[i]
            local drop = false
            for j = 1, #panels do
                if i ~= j then
                    local b = panels[j]
                    local iw = math.max(0, math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x))
                    local ih = math.max(0, math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y))
                    local inter = iw * ih
                    local union = a.w * a.h + b.w * b.h - inter
                    local min_area = math.min(a.w * a.h, b.w * b.h)
                    if union > 0 and inter / union >= 0.50 then
                        if
                            (b.frame_sides or 0) > (a.frame_sides or 0)
                            or ((b.frame_sides or 0) == (a.frame_sides or 0) and j < i)
                        then
                            drop = true
                            break
                        end
                    elseif inter >= a.w * a.h * 0.60 and b.w * b.h >= a.w * a.h * 1.20 then
                        drop = true
                        break
                    elseif inter >= min_area * 0.30 then
                        local a_sides = a.frame_sides or 0
                        local b_sides = b.frame_sides or 0
                        if b_sides > a_sides then
                            drop = true
                            break
                        elseif a_sides == b_sides and (b.w * b.h > a.w * a.h or (b.w * b.h == a.w * a.h and j < i)) then
                            drop = true
                            break
                        end
                    end
                end
            end
            if not drop then
                filtered[#filtered + 1] = a
            end
        end
        panels = filtered
    end

    local acceptance = {}
    for key, value in pairs(settings) do
        acceptance[key] = value
    end
    local strong_count = 0
    for _, p in ipairs(panels) do
        if (p.frame_sides or 0) >= 3 then
            strong_count = strong_count + 1
        end
    end
    acceptance.segment_page_coverage_min = (strong_count >= 2 or (#panels >= 2 and strong_count >= 1)) and 0.20
        or (settings.segment_page_coverage_min or 0.5)
    local accepted, reason = Segmenter.accept(panels, map, acceptance)
    if not accepted then
        return { { x = 0, y = 0, w = map.native_w, h = map.native_h } }, false, reason
    end
    return Geometry.sortReadingOrder(panels, settings.mode or "manga"), true
end

return ComponentDetector
