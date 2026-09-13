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
        if keep and (box.w < map.w * 0.10 or box.h < map.h * 0.10 or box.w * box.h < map.w * map.h * 0.01) then
            keep = box.frame_sides == 4 or hasFrame(map, box)
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
        return {}
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
    local panels = {}
    for _, box in ipairs(framed) do
        local x = math.max(0, (box.x - 1) * map.scale_x)
        local y = math.max(0, (box.y - 1) * map.scale_y)
        local right = math.min(map.native_w, (box.x + box.w + 1) * map.scale_x)
        local bottom = math.min(map.native_h, (box.y + box.h + 1) * map.scale_y)
        panels[#panels + 1] = { x = x, y = y, w = right - x, h = bottom - y }
    end
    if #panels > (settings.segment_max_panels or Settings.defaults.segment_max_panels) then
        return {} -- Let the caller fall back instead of returning a partial page.
    end
    return panels
end

--- Apply the existing coverage guards and reading order to component boxes.
function ComponentDetector.detectPage(map, settings)
    settings = settings or Settings.defaults
    local panels = ComponentDetector.segment(map, settings)
    local accepted, reason = Segmenter.accept(panels, map, settings)
    if not accepted then
        return { { x = 0, y = 0, w = map.native_w, h = map.native_h } }, false, reason
    end
    return Geometry.sortReadingOrder(panels, settings.mode or "manga"), true
end

return ComponentDetector
