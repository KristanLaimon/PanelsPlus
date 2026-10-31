--[[
Panels+
File: src/_componentpipeline.lua
Name: Component frame pipeline
Description: Creates independent frame extraction and refinement pipelines.
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
-- Keep method overrides, white bitmaps, and projection tables per instance.
-- The run-based traversal workspace is shared and retains no page data.
return function()
    local ffi = require("ffi")
    local Geometry = require("src._smartgeometry")
    local Segmenter = require("src._segmenter")
    local Settings = require("src._settings")

    local ComponentDetector = {}

    local Scanner = require("src._componentscan")
    local collectComponents = Scanner.collect
    local scratch_white_capacity = 0
    local scratch_white
    local split_rows, split_cols, split_brows, split_bcols = {}, {}, {}, {}
    local function ensureWhiteScratch(size)
        if scratch_white_capacity < size then
            scratch_white_capacity = size
            scratch_white = ffi.new("uint8_t[?]", size)
        end
    end

    function ComponentDetector.clearScratch()
        Scanner.clearScratch()
        scratch_white_capacity = 0
        scratch_white = nil
        split_rows, split_cols, split_brows, split_bcols = {}, {}, {}, {}
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

    -- A split consumes its projections before descending into either child.
    -- Clear keys rather than allocating four Lua tables per recursive rectangle.
    local function clearProjection(projection)
        for key in pairs(projection) do
            projection[key] = nil
        end
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
        local rows, cols, brows, bcols = split_rows, split_cols, split_brows, split_bcols
        clearProjection(rows)
        clearProjection(cols)
        clearProjection(brows)
        clearProjection(bcols)
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

    -- At this scale a lone outlined mark can be typography. Adjacent closed
    -- frames on the same tier establish an intentional compact panel strip.
    local function compactEligible(map, b)
        local area = b.w * b.h
        return b.frame_sides == 4
            and area >= map.w * map.h * 0.0015
            and area < map.w * map.h * 0.008
            and b.w >= map.w * 0.05
            and b.h >= map.h * 0.03
    end

    local function hasCompactPeer(map, box, components)
        if not compactEligible(map, box) then
            return false
        end
        for _, other in ipairs(components) do
            local overlap = math.min(box.y + box.h, other.y + other.h) - math.max(box.y, other.y)
            local gap = math.max(0, other.x - box.x - box.w, box.x - other.x - other.w)
            if
                other ~= box
                and compactEligible(map, other)
                and overlap >= math.max(box.h, other.h) * 0.8
                and gap <= map.w * 0.05
            then
                return true
            end
        end
        return false
    end

    function ComponentDetector.segment(map, settings)
        settings = settings or Settings.defaults
        local min_side = 0.02
        -- Thin closed frames have little ink even when their crop is substantial.
        -- Collect them first; the geometry and edge checks below reject lettering.
        local min_area = map.w * map.h * 0.0002
        local extracted = collectComponents(map, min_side, min_area, nil, "artwork")
        local components, compact = {}, {}
        local ordinary_ink_min = math.max(1, math.floor(map.w * map.h * 0.002))
        for _, box in ipairs(extracted) do
            compact[box] = hasCompactPeer(map, box, extracted)
            if (box.ink_count or 0) >= ordinary_ink_min or compact[box] then
                components[#components + 1] = box
            end
        end
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
            local compact_frame = compact[box]
            if
                keep
                and not compact_frame
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
                -- An isolated illustration need not have straight frame edges.
                -- Keep its crop when one substantial component accounts for most
                -- of the page's ink; sparse lettering still uses the full page.
                for _, box in ipairs(cells) do
                    if
                        box.w * box.h >= map.w * map.h * 0.15
                        and (box.ink_count or 0) >= (map.ink or math.huge) * 0.70
                    then
                        framed[#framed + 1] = box
                        break
                    end
                end
                if #framed == 0 then
                    return {}
                end
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
                        not has_border
                        and (gap <= map.w * 0.25 or (overlap >= box.h * 0.75 and overlap >= other.h * 0.75))
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
        local padding = map.embedded_image and 1 or 0
        for _, box in ipairs(refined) do
            local sides = box.frame_sides
            if sides == nil then
                sides = countEdges(map, box)
            end
            local is_sliver = (box.h < map.h * 0.08 or box.w < map.w * 0.08 or box.w * box.h < map.w * map.h * 0.015)
                and sides < 2
            if not is_sliver and not emptySplitMargin(map, box) then
                -- Fixed-page bounds describe the ink; viewer margins are separate.
                -- Embedded rasters retain their original one-cell crop padding.
                local x = math.max(0, (box.x - padding) * map.scale_x)
                local y = math.max(0, (box.y - padding) * map.scale_y)
                local right = math.min(map.native_w, (box.x + box.w + padding) * map.scale_x)
                local bottom = math.min(map.native_h, (box.y + box.h + padding) * map.scale_y)
                panels[#panels + 1] = { x = x, y = y, w = right - x, h = bottom - y, frame_sides = sides }
            end
        end
        if #panels > (settings.segment_max_panels or Settings.defaults.segment_max_panels) then
            return {}
        end
        return panels
    end

    local function sharedBalloon(map, parts, merge)
        local size = map.w * map.h
        ensureWhiteScratch(size)
        local white = scratch_white
        for k = 0, size - 1 do
            white[k] = 1 - map.data[k]
        end
        local shared = false
        local owners = {}
        for i = 1, #parts do
            owners[i] = i
        end
        local function root(i)
            while owners[i] ~= i do
                i = owners[i]
            end
            return i
        end
        collectComponents({ w = map.w, h = map.h, data = white }, 0.015, size * 0.001, function(h, pixels, count)
            if
                (shared and not merge)
                or count < h.w * h.h * 0.25
                or h.x == 0
                or h.y == 0
                or h.x + h.w == map.w
                or h.y + h.h == map.h
                or h.w * h.h >= size * 0.30
                or h.w / h.h >= 4
                or h.h / h.w >= 4
            then
                return
            end
            -- Most white regions belong to one panel, including ordinary gutters
            -- and blank artwork. A region confined to one panel cannot join two:
            -- reject it by bounds before walking every white pixel against the
            -- full panel list.
            -- Keep all intersecting panels, including overlaps, so ambiguous pixels
            -- are still excluded exactly as in the original ownership test.
            local relevant = {}
            local left, top = (h.x + 0.5) * map.scale_x, (h.y + 0.5) * map.scale_y
            local right = (h.x + h.w - 0.5) * map.scale_x
            local bottom = (h.y + h.h - 0.5) * map.scale_y
            for j, q in ipairs(parts) do
                if left < q.x + q.w and right >= q.x and top < q.y + q.h and bottom >= q.y then
                    relevant[#relevant + 1] = j
                end
            end
            if #relevant < 2 then
                return
            end
            local counts = {}
            for i = 0, count - 1 do
                local row = math.floor(pixels[i] / map.w)
                local x, y = (pixels[i] - row * map.w + 0.5) * map.scale_x, (row + 0.5) * map.scale_y
                local owner
                for _, j in ipairs(relevant) do
                    local q = parts[j]
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
            local first
            for i, n in pairs(counts) do
                if n > count * 0.05 then
                    hits = hits + 1
                    if merge then
                        if first then
                            owners[root(i)] = root(first)
                        else
                            first = i
                        end
                    end
                end
            end
            if hits >= 2 then
                shared = true
            end
            return shared and not merge
        end)
        if merge then
            local groups, result = {}, {}
            for i, p in ipairs(parts) do
                local owner = root(i)
                if groups[owner] then
                    local union = Geometry.rectUnion(groups[owner], p)
                    union.frame_sides = math.max(groups[owner].frame_sides or 0, p.frame_sides or 0)
                    groups[owner] = union
                else
                    groups[owner] = p
                end
            end
            for i = 1, #parts do
                if groups[i] then
                    result[#result + 1] = groups[i]
                end
            end
            return result
        end
        return shared
    end

    -- Detached notes below the artwork are readable content too. Individual
    -- letters are below the component size floor; combine their horizontal band.
    local function addFootnotes(map, panels, settings)
        if settings.mode == "comic" or not map.data or #panels == 0 then
            return
        end
        local bands, band = {}, nil
        for y = math.floor(map.h * 0.85), map.h - 1 do
            local left, right, count = map.w, -1, 0
            for x = 0, map.w - 1 do
                if map.data[y * map.w + x] == 1 then
                    local covered = false
                    local nx, ny = (x + 0.5) * map.scale_x, (y + 0.5) * map.scale_y
                    for _, p in ipairs(panels) do
                        if nx >= p.x and nx <= p.x + p.w and ny >= p.y and ny <= p.y + p.h then
                            covered = true
                            break
                        end
                    end
                    if not covered then
                        left, right, count = math.min(left, x), math.max(right, x), count + 1
                    end
                end
            end
            if count > 0 then
                if not band or y - band.bottom > 3 then
                    band = { x = left, right = right, y = y, bottom = y, count = 0 }
                    bands[#bands + 1] = band
                end
                band.x, band.right = math.min(band.x, left), math.max(band.right, right)
                band.bottom, band.count = y, band.count + count
            end
        end
        for _, b in ipairs(bands) do
            local width, height = b.right - b.x + 1, b.bottom - b.y + 1
            if
                width >= map.w * 0.18
                and height >= 3
                and height <= map.h * 0.04
                and b.count >= width * height * 0.10
            then
                local note = {
                    x = b.x * map.scale_x,
                    y = b.y * map.scale_y,
                    w = width * map.scale_x,
                    h = height * map.scale_y,
                    frame_sides = 0,
                }
                local overlaps = false
                for _, p in ipairs(panels) do
                    if
                        note.x < p.x + p.w
                        and note.x + note.w > p.x
                        and note.y < p.y + p.h
                        and note.y + note.h > p.y
                    then
                        overlaps = true
                        break
                    end
                end
                if not overlaps then
                    panels[#panels + 1] = note
                end
            end
        end
    end

    -- Resolve overlaps in ranked order so two candidates cannot discard each
    -- other. Stronger frame evidence wins; ties retain the wider artwork.
    local function removeOverlaps(panels)
        local ranked, kept = {}, {}
        for _, panel in ipairs(panels) do
            ranked[#ranked + 1] = panel
        end
        table.sort(ranked, function(a, b)
            if (a.frame_sides or 0) ~= (b.frame_sides or 0) then
                return (a.frame_sides or 0) > (b.frame_sides or 0)
            end
            local aa, ba = a.w * a.h, b.w * b.h
            if aa ~= ba then
                return aa > ba
            end
            if a.y ~= b.y then
                return a.y < b.y
            end
            if a.x ~= b.x then
                return a.x < b.x
            end
            return a.w > b.w
        end)
        for _, a in ipairs(ranked) do
            local drop = false
            for _, b in ipairs(kept) do
                local inter = math.max(0, math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x))
                    * math.max(0, math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y))
                local union = a.w * a.h + b.w * b.h - inter
                if inter >= math.min(a.w * a.h, b.w * b.h) * 0.30 or inter >= union * 0.50 then
                    drop = true
                    break
                end
            end
            if not drop then
                kept[#kept + 1] = a
            end
        end
        return kept
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
            local candidates = removeOverlaps(ComponentDetector.segment(alternate, settings))

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

        panels = removeOverlaps(panels)

        if #panels > 1 and map.data then
            panels = sharedBalloon(map, panels, true)
        end
        addFootnotes(map, panels, settings)

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
end
