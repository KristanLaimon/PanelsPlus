local ffi = require("ffi")
-- Safe: v1.4.0 panel grouping and reading order.
-- Forked from _safecomponentdetector.lua; manhwa policy evolves independently.
local Geometry = require("src._manhwasafegeometry")
local Settings = require("src._settings")

--- Stable Safe grouping from 6a82bc8, independent of Smart's refinements.
--- The traversal workspace is shared; acceptance and grouping stay conservative.
local ComponentDetector = {}

local Scanner = require("src._componentscan")
local scratch_white_capacity = 0
local scratch_white
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
end

local function collectComponents(map, min_side, min_area)
    return Scanner.collect(map, min_side, min_area, nil, "safe")
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
        panels[#panels + 1] = { x = x, y = y, w = right - x, h = bottom - y, framed = (box.frame_sides or 0) >= 3 }
    end
    if #panels > (settings.segment_max_panels or Settings.defaults.segment_max_panels) then
        return {} -- Let the caller fall back instead of returning a partial page.
    end
    return panels
end

--- Find vertical content bands, retaining floating text and borderless artwork.
--- Framed manga-style boxes still use the forked component segmentation above.
function ComponentDetector.detectPage(map, settings)
    settings = settings or Settings.defaults
    local framed = ComponentDetector.segment(map, settings)
    local gap = math.max(3, math.floor(map.w * 0.045))
    local bands, first, last, left, right = {}, nil, nil, map.w, -1
    local function finish()
        if not first then
            return
        end
        if last - first < 2 and (first <= 2 or last >= map.h - 3) then
            first, last, left, right = nil, nil, map.w, -1
            return
        end
        local rect = {
            x = left * map.scale_x,
            y = first * map.scale_y,
            w = (right - left + 1) * map.scale_x,
            h = (last - first + 1) * map.scale_y,
        }
        -- Retain ordinary framed panels inside a band when there is clear
        -- side-by-side structure. Never reject floating narration on page coverage.
        local candidates = {}
        for _, panel in ipairs(framed) do
            if panel.y >= rect.y - map.scale_y and panel.y + panel.h <= rect.y + rect.h + map.scale_y then
                candidates[#candidates + 1] = panel
            end
        end
        local candidate_area = 0
        for _, candidate in ipairs(candidates) do
            candidate_area = candidate_area + candidate.w * candidate.h
        end
        local side_by_side = #candidates > 1
        for i = 2, #candidates do
            local a, b = candidates[i - 1], candidates[i]
            local overlap = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
            if overlap < math.min(a.h, b.h) * 0.8 or math.min(a.x + a.w, b.x + b.w) > math.max(a.x, b.x) then
                side_by_side = false
            end
        end
        local framed_grid = #candidates >= 4
        for i, a in ipairs(candidates) do
            if not a.framed then
                framed_grid = false
            end
            for j = i + 1, #candidates do
                local b = candidates[j]
                local overlap_w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
                local overlap_h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
                if overlap_w > map.scale_x * 2 and overlap_h > map.scale_y * 2 then
                    framed_grid = false
                end
            end
        end
        if (side_by_side or framed_grid) and candidate_area >= rect.w * rect.h * 0.8 then
            for _, panel in ipairs(candidates) do
                bands[#bands + 1] = panel
            end
        else
            bands[#bands + 1] = rect
        end
        first, last, left, right = nil, nil, map.w, -1
    end
    for y = 0, map.h - 1 do
        local lo, hi, count = map.w, -1, 0
        local background
        if map.paper then
            local black, white = 0, 0
            for x = 0, map.w - 1 do
                local shade = map.paper[y * map.w + x]
                if shade == 1 then
                    black = black + 1
                elseif shade == 2 then
                    white = white + 1
                end
            end
            background = black >= white and 1 or 2
        end
        for x = 1, map.w - 2 do
            local active = map.paper and map.paper[y * map.w + x] ~= background
                or (not map.paper and map.data[y * map.w + x] ~= 0)
            if active then
                lo, hi, count = math.min(lo, x), x, count + 1
            end
        end
        if count >= 2 then
            if first and y - last > gap then
                finish()
            end
            first, last = first or y, y
            left, right = math.min(left, lo), math.max(right, hi)
        end
    end
    finish()
    table.sort(bands, function(a, b)
        return a.y == b.y and a.x < b.x or a.y < b.y
    end)
    return bands, true
end

return ComponentDetector
