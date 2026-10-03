--[[
Panels+
File: src/_componentdetector.lua
Name: ComponentDetector
Description: Implements Deep mode with 8-connected components, frame evidence, candidate filtering, and validation.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local ffi = require("ffi")
local Geometry = require("src._geometry")
local Segmenter = require("src._segmenter")
local Settings = require("src._settings")

--- Deep mode's production detector over a bounded background-relative ink map.
--- Connected frames survive tilted gutters and white space inside artwork;
--- page-level acceptance rejects implausible candidate sets.
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

--- Release scratch buffers to free memory when closing widgets or low memory.
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

--- Fraction of a component boundary supported by a straight (possibly tilted)
--- line. Several well-separated sample pairs make this insensitive to a
--- balloon protruding through one corner; curved face/balloon outlines do not
--- support a straight line over most of their extent.
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

local INF = 100000000

local function frameSides(queue, count, map_width, box, tolerance)
    for y = box.y, box.y + box.h - 1 do
        scratch_left[y], scratch_right[y] = INF, -1
    end
    for x = box.x, box.x + box.w - 1 do
        scratch_top[x], scratch_bottom[x] = INF, -1
    end
    for index = 0, count - 1 do
        local p = queue[index]
        local y = math.floor(p / map_width)
        local x = p - y * map_width
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
    if lineSupport(scratch_left, box.y, box.y + box.h - 1, tolerance) >= 0.80 then
        sides = sides + 1
    end
    if lineSupport(scratch_right, box.y, box.y + box.h - 1, tolerance) >= 0.80 then
        sides = sides + 1
    end
    if lineSupport(scratch_top, box.x, box.x + box.w - 1, tolerance) >= 0.80 then
        sides = sides + 1
    end
    if lineSupport(scratch_bottom, box.x, box.x + box.w - 1, tolerance) >= 0.80 then
        sides = sides + 1
    end
    return sides
end

--- Extract substantial 8-connected components without modifying the input.
--- Reuses persistent scratch arrays across page turns to eliminate GC churn
--- on low-memory e-ink devices. Tiny components are discarded before allocating boxes.
local function collectComponents(map, min_side, min_area)
    local width, height, data = map.w, map.h, map.data
    ensureScratch(width * height, math.max(width, height))
    ffi.fill(scratch_seen, width * height, 0)
    local queue = scratch_queue
    local seen = scratch_seen
    local components = {}

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
                -- Clip columns once per pixel, then walk contiguous offsets.
                -- Keep the same 8-connected traversal order without repeating
                -- column bounds and row-offset arithmetic for every neighbor.
                local first_x, last_x = math.max(0, x - 1), math.min(width - 1, x + 1)
                for ny = math.max(0, y - 1), math.min(height - 1, y + 1) do
                    local row = ny * width
                    for neighbor = row + first_x, row + last_x do
                        if seen[neighbor] == 0 and data[neighbor] == 1 then
                            seen[neighbor] = 1
                            queue[tail] = neighbor
                            tail = tail + 1
                        end
                    end
                end
            end
            local w, h = right - left + 1, bottom - top + 1
            if w >= width * min_side and h >= height * min_side and w * h >= min_area then
                local box = { x = left, y = top, w = w, h = h }
                box.frame_sides = frameSides(queue, tail, width, box, math.max(1, math.min(width, height) * 0.003))
                components[#components + 1] = box
            end
        end
    end
    return components
end

--- Small panels need evidence of a frame so large letters and isolated faces
--- do not qualify on size alone. Sample a narrow band along all four edges.
local function hasFrame(map, box)
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
    return top > box.w * 0.8 and bottom > box.w * 0.8 and left > box.h * 0.8 and right > box.h * 0.8
end

--- Separate frames joined by artwork crossing a gutter. Projection cuts are
--- confined to an existing component, so unrelated page furniture stays out.
--- Uses both white-gutter and dark shared-border detection to find split points.
local function splitJoinedFrames(map, box, settings, depth, shared_borders)
    depth = depth or 0
    if depth == 0 then
        -- A closed frame is stronger evidence than straight lines in its art.
        if (box.frame_sides or 0) >= 3 then
            return { box }
        end
        shared_borders = settings.mode ~= "comic" and map.dark ~= nil
    end
    if depth >= 5 then
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
            local white = projection[i] <= span * 0.025
            local black = shared_borders and border[i] >= span * 0.90
            if white or black then
                local start = i
                repeat
                    i = i + 1
                until i > last
                    or (white and projection[i] > span * 0.025)
                    or (black and border[i] < span * 0.90)
                local stop = i - 1
                local width = stop - start + 1
                local valid = stop <= last - minimum
                if white then
                    local before, after = 0, 0
                    for offset = 1, 4 do
                        before = math.max(before, projection[start - offset] or 0)
                        after = math.max(after, projection[stop + offset] or 0)
                    end
                    valid = valid and width >= 2 and before >= span * 0.85 and after >= span * 0.85
                else
                    valid = valid
                        and width <= 4
                        and (border[start - 2] or span) < span * 0.90
                        and (border[stop + 2] or span) < span * 0.90
                end
                if valid then
                    local score = white and 2 + width / length or 1
                    score = score + math.min(start - first, last - stop) / length
                    if not best or score > best.score then
                        best = { axis = axis, start = start, stop = stop, white = white, score = score }
                    end
                end
            else
                i = i + 1
            end
        end
    end
    search(rows, brows, box.y, box.w, box.h, math.max(12, math.floor(map.h * 0.10)), "y")
    search(cols, bcols, box.x, box.h, box.w, math.max(12, math.floor(map.w * 0.12)), "x")
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
    local parts = splitJoinedFrames(map, a, settings, depth + 1, shared_borders)
    for _, part in ipairs(splitJoinedFrames(map, b, settings, depth + 1, shared_borders)) do
        parts[#parts + 1] = part
    end
    if depth == 0 and #parts == 2 then
        local framed_count = 0
        for _, p in ipairs(parts) do
            if (p.frame_sides or 0) >= 3 or hasFrame(map, p) then
                framed_count = framed_count + 1
            end
        end
        if framed_count == 0 then
            return { box }
        end
    end
    return parts
end

--- Return native-coordinate candidate boxes, with contained regions removed.
--- Containment is a candidate policy: it removes speech balloons inside frames
--- but can also remove an intentional inset. It does not merge partial overlaps.
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
        -- Attempt to split large single-component pages that lack framed sub-regions.
        for _, box in ipairs(cells) do
            if box.w * box.h >= map.w * map.h * 0.5 then
                local parts = splitJoinedFrames(map, box, settings)
                if #parts > 1 then
                    framed = { box }
                    floating = {}
                    break
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
            if overlap >= box.h * 0.7 and gap <= map.w * 0.08 and (not distance or gap < distance) then
                target, distance = other, gap
            end
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
    --- Apply splitJoinedFrames to each framed component to separate panels
    --- that are joined by artwork crossing gutters or shared drawn borders.
    local refined = {}
    for _, box in ipairs(framed) do
        for _, part in ipairs(splitJoinedFrames(map, box, settings)) do
            refined[#refined + 1] = part
        end
    end
    local panels = {}
    for _, box in ipairs(refined) do
        local x = math.max(0, (box.x - 1) * map.scale_x)
        local y = math.max(0, (box.y - 1) * map.scale_y)
        local right = math.min(map.native_w, (box.x + box.w + 1) * map.scale_x)
        local bottom = math.min(map.native_h, (box.y + box.h + 1) * map.scale_y)
        panels[#panels + 1] = { x = x, y = y, w = right - x, h = bottom - y, frame_sides = box.frame_sides }
    end
    if #panels > (settings.segment_max_panels or Settings.defaults.segment_max_panels) then
        return {} -- Let the caller fall back instead of returning a partial page.
    end
    return panels
end

--- Check whether a speech balloon spans multiple proposed sub-panels,
--- indicating those panels should remain grouped.
local function sharedBalloon(map, parts)
    local size = map.w * map.h
    ensureWhiteScratch(size)
    local white = scratch_white
    for k = 0, size - 1 do
        white[k] = 1 - map.data[k]
    end
    local holes = collectComponents({ w = map.w, h = map.h, data = white }, 0.015, size * 0.001)
    for _, h in ipairs(holes) do
        if h.frame_sides < 3 and h.w * h.h < size * 0.15 and h.w / h.h < 4 and h.h / h.w < 4 then
            local hole = {
                x = h.x * map.scale_x,
                y = h.y * map.scale_y,
                w = h.w * map.scale_x,
                h = h.h * map.scale_y,
            }
            local hits = 0
            for _, q in ipairs(parts) do
                local inter = math.max(0, math.min(hole.x + hole.w, q.x + q.w) - math.max(hole.x, q.x))
                    * math.max(0, math.min(hole.y + hole.h, q.y + q.h) - math.max(hole.y, q.y))
                if inter > hole.w * hole.h * 0.15 then
                    hits = hits + 1
                end
            end
            if hits >= 2 then
                return true
            end
        end
    end
    return false
end

--- Apply the existing coverage guards and reading order to component boxes.
--- When the map provides a structural ink layer, runs a secondary detection pass
--- to split merged regions into sub-panels visible only in the structural map.
function ComponentDetector.detectPage(map, settings)
    settings = settings or Settings.defaults
    local panels = ComponentDetector.segment(map, settings)

    -- Evidence-based sub-splitting: if the map provides a structural ink layer
    -- (high-contrast-only pixels, ignoring gray shading), re-run detection on
    -- that layer and use its candidates to refine oversized merged regions.
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
                if inter >= q.w * q.h * 0.95 and q.w * q.h < p.w * p.h * 0.85 and (q.frame_sides or 0) >= 2 then
                    parts[#parts + 1] = q
                    area = area + q.w * q.h
                end
            end
            -- Replacing a parent must account for almost all of it, with
            -- independently framed, non-overlapping children. Otherwise keep
            -- the wider crop instead of zooming into fragments of artwork.
            local reliable = #parts >= 2 and area >= p.w * p.h * 0.85
            for i, q in ipairs(parts) do
                if (q.frame_sides or 0) < 3 then
                    reliable = false
                end
                for j = i + 1, #parts do
                    local r = parts[j]
                    local overlap = math.max(0, math.min(q.x + q.w, r.x + r.w) - math.max(q.x, r.x))
                        * math.max(0, math.min(q.y + q.h, r.y + r.h) - math.max(q.y, r.y))
                    if overlap > math.min(q.w * q.h, r.w * r.h) * 0.02 then
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

    -- Comic mode fallback: if multiple panels were found but they lack 3-sided frames,
    -- this is a splash/full-page art layout without real panel boxes.
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

    -- Remove nested "zoom panels": extra sub-boxes found inside a bigger panel
    -- (e.g. an unframed speech bubble, character inset, or decoration inside a large or page-sized panel).
    if #panels > 1 then
        local filtered = {}
        for i = 1, #panels do
            local a = panels[i]
            local is_zoom_fp = false
            for j = 1, #panels do
                if i ~= j then
                    local b_box = panels[j]
                    local inter_w = math.max(0, math.min(a.x + a.w, b_box.x + b_box.w) - math.max(a.x, b_box.x))
                    local inter_h = math.max(0, math.min(a.y + a.h, b_box.y + b_box.h) - math.max(a.y, b_box.y))
                    local inter = inter_w * inter_h
                    local a_area = a.w * a.h
                    local b_area = b_box.w * b_box.h
                    if
                        (b_area > a_area or (b_area == a_area and j < i))
                        and inter >= a_area * 0.85
                        and (b_area >= map.native_w * map.native_h * 0.55 or (a.frame_sides or 0) < 3)
                    then
                        is_zoom_fp = true
                        break
                    end
                end
            end
            if not is_zoom_fp then
                filtered[#filtered + 1] = a
            end
        end
        panels = filtered
    end

    -- Keep caller settings (including the shared defaults table) immutable.
    local acceptance = {}
    for key, value in pairs(settings) do
        acceptance[key] = value
    end
    acceptance.segment_page_coverage_min = settings.segment_page_coverage_min or 0.5
    local accepted, reason = Segmenter.accept(panels, map, acceptance)
    if not accepted then
        return { { x = 0, y = 0, w = map.native_w, h = map.native_h } }, false, reason
    end
    return Geometry.sortReadingOrder(panels, settings.mode or "manga"), true
end

return ComponentDetector
