--[[
Panels+
File: src/_componentscan.lua
Name: Shared component scan
Description: Reuses one run-based traversal workspace for Safe and Smart.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
-- Shared, reusable component workspace for Safe and Smart.
-- No page data or output boxes are retained between calls.
local ffi = require("ffi")
local Scanner = {}

local scratch_capacity = 0
local scratch_seen = nil
local scratch_queue = nil

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

function Scanner.clearScratch()
    scratch_capacity = 0
    scratch_seen = nil
    scratch_queue = nil
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

-- `safe` applies bounding-box floors; `artwork` prefilters Smart's compact
-- candidates. Visitors receive every component pixel, without frame fitting;
-- returning true stops the scan. The map must contain binary (0/1) cells.
function Scanner.collect(map, min_side, min_area, visit, policy)
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
            local start_y = math.floor(start_index / width)
            local start_x = start_index - start_y * width
            local left = start_x
            local top, bottom = start_y, start_y
            local head, tail = 0, 0
            local finish = start_index
            local row_end = (start_y + 1) * width - 1
            while finish < row_end and data[finish + 1] == 1 and seen[finish + 1] == 0 do
                finish = finish + 1
            end
            for pixel = start_index, finish do
                seen[pixel] = 1
                queue[tail] = pixel
                tail = tail + 1
            end
            local right = finish - start_y * width

            -- Queue complete horizontal runs. Each pixel is still recorded once
            -- for boundary fitting and visitors, but neighboring rows are scanned
            -- once per run rather than checking eight neighbors per pixel.
            while head < tail do
                local first = queue[head]
                local y = math.floor(first / width)
                local row = y * width
                local last = first
                head = head + 1
                while head < tail and queue[head] == last + 1 and queue[head] < row + width do
                    last = queue[head]
                    head = head + 1
                end
                local first_x = math.max(0, first - row - 1)
                local last_x = math.min(width - 1, last - row + 1)
                for ny = y - 1, y + 1, 2 do
                    if ny >= 0 and ny < height then
                        local offset = ny * width
                        local cursor, stop = offset + first_x, offset + last_x
                        while cursor <= stop do
                            if seen[cursor] == 0 and data[cursor] == 1 then
                                local lo, hi = cursor, cursor
                                while lo > offset and seen[lo - 1] == 0 and data[lo - 1] == 1 do
                                    lo = lo - 1
                                end
                                while hi < offset + width - 1 and seen[hi + 1] == 0 and data[hi + 1] == 1 do
                                    hi = hi + 1
                                end
                                for pixel = lo, hi do
                                    seen[pixel] = 1
                                    queue[tail] = pixel
                                    tail = tail + 1
                                end
                                left, right = math.min(left, lo - offset), math.max(right, hi - offset)
                                top, bottom = math.min(top, ny), math.max(bottom, ny)
                                cursor = hi + 1
                            else
                                cursor = cursor + 1
                            end
                        end
                    end
                end
            end

            local w = right - left + 1
            local h = bottom - top + 1
            local ordinary = tail >= min_pixels and w >= min_w and h >= min_h
            if policy == "safe" then
                ordinary = w >= width * min_side and h >= height * min_side and w * h >= min_area
            end
            if policy == "artwork" and tail < math.max(1, math.floor(width * height * 0.002)) then
                -- Below the ordinary ink floor only compact frames can survive.
                -- Reject impossible geometry before fitting four boundary lines.
                local area = w * h
                ordinary = ordinary
                    and area >= width * height * 0.0015
                    and area < width * height * 0.008
                    and w >= width * 0.05
                    and h >= height * 0.03
            end
            if ordinary then
                local box = { x = left, y = top, w = w, h = h, ink_count = tail }
                -- Balloon visitors only need pixels and bounds, never frame sides.
                if not visit then
                    box.frame_sides = frameSides(queue, tail, width, box, math.max(1, math.min(width, height) * 0.003))
                end
                if visit then
                    if visit(box, queue, tail) then
                        return components
                    end
                else
                    components[#components + 1] = box
                end
            end
        end
    end
    return components
end

return Scanner
