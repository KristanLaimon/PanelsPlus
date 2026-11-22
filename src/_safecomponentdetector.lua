local ffi = require("ffi")
-- Safe: preserve real ink connections; gray shading alone is not a panel bridge.
local Geometry = require("src._safegeometry")
local Settings = require("src._settings")

--- Safe keeps real strokes connected and conservatively resolves gray-only joins.
local ComponentDetector = {}
local Segmenter = require("src._segmenter")

local Scanner = require("src._componentscan")
local scratch_white_capacity = 0
local scratch_white
local function ensureWhiteScratch(size)
    if scratch_white_capacity < size then
        scratch_white = ffi.new("uint8_t[?]", size)
        scratch_white_capacity = size
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
    local padding = map.embedded_image and 1 or 0
    for _, box in ipairs(framed) do
        local x = math.max(0, (box.x - padding) * map.scale_x)
        local y = math.max(0, (box.y - padding) * map.scale_y)
        local right = math.min(map.native_w, (box.x + box.w + padding) * map.scale_x)
        local bottom = math.min(map.native_h, (box.y + box.h + padding) * map.scale_y)
        panels[#panels + 1] = { x = x, y = y, w = right - x, h = bottom - y, frame_sides = box.frame_sides }
    end
    if #panels > (settings.segment_max_panels or Settings.defaults.segment_max_panels) then
        return {} -- Let the caller fall back instead of returning a partial page.
    end
    return panels
end

local function intersectionArea(a, b)
    return math.max(0, math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x))
        * math.max(0, math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y))
end

--- A gray wash may connect frames, but a dark stroke must keep them together.
local function hasDarkBridge(map, panels)
    local joined = false
    Scanner.collect({ w = map.w, h = map.h, data = map.dark }, 0, 1, function(box, pixels, count)
        local bounds =
            { x = box.x * map.scale_x, y = box.y * map.scale_y, w = box.w * map.scale_x, h = box.h * map.scale_y }
        local possible = 0
        for _, panel in ipairs(panels) do
            if intersectionArea(bounds, panel) > 0 then
                possible = possible + 1
            end
        end
        if possible < 2 then
            return
        end
        local touched = {}
        for i = 0, count - 1 do
            local index = pixels[i]
            local y = math.floor(index / map.w) * map.scale_y
            local x = (index % map.w) * map.scale_x
            local owner, overlap
            for j, panel in ipairs(panels) do
                if x >= panel.x and y >= panel.y and x < panel.x + panel.w and y < panel.y + panel.h then
                    if owner then
                        overlap = true
                        break
                    end
                    owner = j
                end
            end
            if owner and not overlap then
                touched[owner] = (touched[owner] or 0) + 1
            end
        end
        local shared = 0
        for _, hits in pairs(touched) do
            -- Boundary rounding alone can place one or two cells in a neighbour.
            if hits >= 3 then
                shared = shared + 1
            end
        end
        if shared >= 2 then
            joined = true
            return true
        end
    end)
    return joined
end

local function hasConservativeLayout(parent, parts, map, parent_count)
    if parent_count <= 1 and parent.w * parent.h >= map.native_w * map.native_h * 0.90 then
        return true
    end
    if #parts == 2 then
        local a, b = parts[1], parts[2]
        return a.w >= parent.w * 0.80
            and b.w >= parent.w * 0.80
            and (a.y + a.h <= b.y + map.scale_y or b.y + b.h <= a.y + map.scale_y)
    end
    if #parts == 3 then
        for i, panel in ipairs(parts) do
            if panel.h >= parent.h * 0.90 and panel.w <= parent.w * 0.50 then
                return true
            end
            if
                parent_count >= 3
                and (panel.frame_sides or 0) >= 2
                and panel.h >= parent.h * 0.90
                and panel.y <= parent.y + map.scale_y * 2
            then
                local a, b = parts[i % 3 + 1], parts[(i + 1) % 3 + 1]
                local same_side = (a.x >= panel.x and b.x >= panel.x) or (a.x <= panel.x and b.x <= panel.x)
                local stacked = a.y + a.h <= b.y + map.scale_y or b.y + b.h <= a.y + map.scale_y
                if same_side and stacked and (a.frame_sides or 0) >= 2 and (b.frame_sides or 0) >= 2 then
                    return true
                end
            end
        end
    end
    return false
end

local function hasStackedFrames(parent, parts)
    local wide_frames = 0
    for _, part in ipairs(parts) do
        if part.frame_sides ~= 4 then
            return false
        end
        if part.w >= parent.w * 0.80 then
            wide_frames = wide_frames + 1
        end
    end
    return wide_frames >= 3
end

--- Recover a complete framed band while keeping the unframed remainder intact.
local function recoverFrameBand(parent, parts, map, mode)
    local tolerance = math.max(map.scale_x, map.scale_y) * 2
    local minimum = parent.w * parent.h * 0.10
    for i, a in ipairs(parts) do
        if (a.frame_sides or 0) >= 2 and a.w * a.h >= minimum then
            for j = i + 1, #parts do
                local b = parts[j]
                if (b.frame_sides or 0) >= 2 and b.w * b.h >= minimum then
                    local left, right = math.min(a.x, b.x), math.max(a.x + a.w, b.x + b.w)
                    local top, bottom = math.min(a.y, b.y), math.max(a.y + a.h, b.y + b.h)
                    if
                        math.abs(a.y - b.y) <= tolerance
                        and math.abs(a.h - b.h) <= tolerance
                        and top <= parent.y + tolerance
                        and right - left >= parent.w * 0.97
                        and bottom < parent.y + parent.h * 0.80
                    then
                        return {
                            a,
                            b,
                            {
                                x = parent.x,
                                y = bottom - map.scale_y,
                                w = parent.w,
                                h = parent.y + parent.h - bottom + map.scale_y,
                                frame_sides = 0,
                            },
                        }
                    end
                    local leading_edge = mode == "comic" and left <= parent.x + tolerance
                        or mode ~= "comic" and right >= parent.x + parent.w - tolerance
                    local remainder = mode == "comic" and parent.x + parent.w - right or left - parent.x
                    if
                        math.abs(a.x - b.x) <= tolerance
                        and math.abs(a.w - b.w) <= tolerance
                        and leading_edge
                        and bottom - top >= parent.h * 0.97
                        and remainder > parent.w * 0.15
                    then
                        -- Keep the shared edge in both crops so a floating figure is not clipped.
                        local x = mode == "comic" and right - map.scale_x or parent.x
                        return {
                            a,
                            b,
                            { x = x, y = parent.y, w = remainder + map.scale_x, h = parent.h, frame_sides = 0 },
                        }
                    end
                end
            end
        end
    end
end

local function refineGrayConnections(map, panels, settings)
    if not map.structural or not map.dark then
        return panels
    end
    local alternate = {}
    for key, value in pairs(map) do
        alternate[key] = value
    end
    alternate.data = map.structural
    local candidates = ComponentDetector.segment(alternate, settings)
    if #candidates == 0 then
        -- On dark pages with no high-contrast frames, isolated bright objects
        -- are poor evidence for panels.
        if map.inverted and #panels > 1 then
            return {}
        end
        return panels
    end
    local parents = panels
    if #parents == 0 then
        parents = { { x = 0, y = 0, w = map.native_w, h = map.native_h } }
    end
    local refined = {}
    for _, parent in ipairs(parents) do
        local parent_area = parent.w * parent.h
        local parts, area, strong, enclosing = {}, 0, 0, false
        for _, child in ipairs(candidates) do
            local size = child.w * child.h
            local overlap = intersectionArea(parent, child)
            if overlap >= size * 0.95 and size < parent_area * 0.85 then
                parts[#parts + 1] = child
                area = area + size
                if (child.frame_sides or 0) >= 2 then
                    strong = strong + 1
                end
            elseif overlap >= parent_area * 0.85 then
                enclosing = true
            end
        end
        local separated_frames = #parts >= 2
            and strong == #parts
            and not enclosing
            and #panels > 0
            and area >= parent_area * 0.93
        -- Parallel frames must span nearly all of the parent to distinguish a
        -- gray gutter from inset artwork or a staggered crop.
        if separated_frames then
            local top_tolerance = map.scale_y * 3
            local bottom_tolerance = math.max(top_tolerance, parent.h * 0.035)
            local bottom = parent.y + parent.h
            if bottom >= map.native_h - map.scale_y then
                top_tolerance = bottom_tolerance
            end
            for _, part in ipairs(parts) do
                if
                    math.abs(part.y - parent.y) > top_tolerance
                    or math.abs(part.y + part.h - bottom) > bottom_tolerance
                then
                    separated_frames = false
                    break
                end
            end
        end
        local stacked_frames = #panels == 1 and hasStackedFrames(parent, parts)
        local reliable = #parts >= 2
            and area >= parent_area * (stacked_frames and 0.75 or 0.80)
            and strong >= math.ceil(#parts * 0.40)
            and (#panels > 0 or strong >= 2)
            and (separated_frames or stacked_frames or hasConservativeLayout(parent, parts, map, #panels))
        for i, a in ipairs(parts) do
            for j = i + 1, #parts do
                local b = parts[j]
                -- The bounds of side-by-side frames can overlap when one
                -- leans into the gutter. The pixel bridge check still applies.
                local overlap_limit = separated_frames and 0.20 or 0.10
                if intersectionArea(a, b) > math.min(a.w * a.h, b.w * b.h) * overlap_limit then
                    reliable = false
                end
            end
        end
        local replacement
        -- Keep enclosing frames unless structural ink resolves them into separate aligned frames.
        if (parent.frame_sides or 0) < 4 or separated_frames or stacked_frames then
            if reliable then
                replacement = parts
            elseif (parent.frame_sides or 0) < 4 then
                replacement = recoverFrameBand(parent, parts, map, settings.mode)
            end
        end
        if replacement and hasDarkBridge(map, replacement) then
            replacement = nil
        end
        if replacement then
            for _, panel in ipairs(replacement) do
                refined[#refined + 1] = panel
            end
        elseif #panels > 0 then
            refined[#refined + 1] = parent
        end
    end
    if #refined > (settings.segment_max_panels or Settings.defaults.segment_max_panels) then
        return panels
    end
    return refined
end

--- Window frames and caption boxes must not divide an otherwise floating illustration.
local function groupSparseIllustration(map, panels)
    local first
    for _, panel in ipairs(panels) do
        if
            panel.w >= map.native_w * 0.70
            and panel.h >= map.native_h * 0.10
            and (panel.frame_sides or 0) >= 3
            and panel.y >= map.native_h * 0.35
        then
            if not first or panel.y < first.y then
                first = panel
            end
        end
    end
    if not first then
        return panels
    end
    local upper, tiny, rest = {}, true, {}
    for _, panel in ipairs(panels) do
        if panel.y + panel.h <= first.y + map.scale_y then
            upper[#upper + 1] = panel
            tiny = tiny and panel.w * panel.h <= map.native_w * map.native_h * 0.06 and panel.w <= map.native_w * 0.40
        else
            rest[#rest + 1] = panel
        end
    end
    if #upper < 3 or not tiny then
        return panels
    end
    local inside, outside = 0, 0
    for y = 0, math.min(map.h, math.floor(first.y / map.scale_y)) - 1 do
        for x = 0, map.w - 1 do
            if map.data[y * map.w + x] == 1 then
                local contained = false
                for _, panel in ipairs(upper) do
                    if
                        x * map.scale_x >= panel.x
                        and x * map.scale_x < panel.x + panel.w
                        and y * map.scale_y >= panel.y
                        and y * map.scale_y < panel.y + panel.h
                    then
                        contained = true
                        break
                    end
                end
                if contained then
                    inside = inside + 1
                else
                    outside = outside + 1
                end
            end
        end
    end
    -- Real compact panels contain their artwork; an illustration extends beyond its windows/captions.
    if outside <= inside then
        return panels
    end
    rest[#rest + 1] = { x = 0, y = 0, w = map.native_w, h = first.y }
    return rest
end

-- Stop at a gap wider than a word space to exclude the running page number.
local function footerBox(map, left, right, top, bottom)
    local h = bottom - top + 1
    local last_ink, count = left, 0
    for x = left, right do
        local ink = 0
        for y = top, bottom do
            ink = ink + map.dark[y * map.w + x]
        end
        if ink > 0 then
            last_ink = x
            count = count + ink
        elseif x - last_ink > h * 1.5 then
            break
        end
    end
    local w = last_ink - left + 1
    if w >= map.w * 0.10 and w >= h * 3 and count >= w * h * 0.08 and count <= w * h * 0.70 then
        return { x = left * map.scale_x, y = top * map.scale_y, w = w * map.scale_x, h = h * map.scale_y }
    end
end

-- A short line of detached ink below the frames is readable on its own.
-- Scan within the artwork margins so a scan mark in the corner stays out.
local function recoverDetachedFooter(map, panels)
    if not map.dark or map.inverted then
        return panels
    end
    local left, right, bottom = map.native_w, 0, 0
    local framed_count = 0
    for _, panel in ipairs(panels) do
        if (panel.frame_sides or 0) >= 2 and panel.h >= map.native_h * 0.08 then
            framed_count = framed_count + 1
            left = math.min(left, panel.x)
            right = math.max(right, panel.x + panel.w)
            bottom = math.max(bottom, panel.y + panel.h)
        end
    end
    if
        framed_count < 2
        or right - left < map.native_w * 0.60
        or bottom < map.native_h * 0.75
        or bottom >= map.native_h
    then
        return panels
    end
    for i = #panels, 1, -1 do
        local panel = panels[i]
        if
            ((panel.frame_sides or 0) <= 1 or panel.x >= right and (panel.frame_sides or 0) <= 2)
            and panel.y >= bottom
            and panel.y >= map.native_h * 0.94
            and panel.h <= map.native_h * 0.05
            and panel.w <= map.native_w * 0.12
            and panel.x + panel.w > right
            and panel.x >= right - map.native_w * 0.09
        then
            table.remove(panels, i)
        end
    end
    local first_x = math.ceil(left / map.scale_x)
    local last_x = math.floor((right - (right - left) * 0.17) / map.scale_x) - 1
    local first_y = math.ceil(bottom / map.scale_y)
    local last_y = math.min(map.h - 1, first_y + math.floor(map.h * 0.10))
    local run_left, run_top, run_bottom = last_x, nil, nil
    for y = first_y, last_y + 1 do
        if run_bottom and (y - run_bottom > 2 or y > last_y) then
            local h = run_bottom - run_top + 1
            if run_top >= first_y + 2 and h >= map.h * 0.009 and h <= map.h * 0.04 then
                local footer = footerBox(map, run_left, math.floor(right / map.scale_x) - 1, run_top, run_bottom)
                local left_aligned = run_left <= first_x + map.w * 0.07
                local centered = footer
                    and math.abs(footer.x + footer.w / 2 - (left + right) / 2) <= map.native_w * 0.07
                if footer and (left_aligned or centered) then
                    local fragments = {}
                    for i, panel in ipairs(panels) do
                        local overlap = intersectionArea(footer, panel)
                        if overlap > 0 then
                            if
                                panel.y < bottom
                                or panel.h > map.native_h * 0.04
                                or overlap < panel.w * panel.h * 0.80
                            then
                                return panels
                            end
                            fragments[#fragments + 1] = i
                        end
                    end
                    for i = #fragments, 1, -1 do
                        table.remove(panels, fragments[i])
                    end
                    panels[#panels + 1] = footer
                    return panels
                end
            end
            run_left, run_top, run_bottom = last_x, nil, nil
        end
        if y <= last_y then
            local row_left, count = last_x, 0
            for x = first_x, last_x do
                if map.dark[y * map.w + x] == 1 then
                    row_left = math.min(row_left, x)
                    count = count + 1
                end
            end
            -- A rule under the caption is often continuous across the page.
            if count > 0 and count < (last_x - first_x + 1) * 0.75 then
                run_left = math.min(run_left, row_left)
                run_top, run_bottom = run_top or y, y
            end
        end
    end
    return panels
end

local function isTitleIllustration(map, panels)
    if #panels < 3 then
        return false
    end
    local illustration_count = 0
    for _, panel in ipairs(panels) do
        if panel.w >= map.native_w * 0.85 and panel.h >= map.native_h * 0.75 and (panel.frame_sides or 0) < 2 then
            illustration_count = illustration_count + 1
        elseif panel.y + panel.h > map.native_h * 0.10 or panel.h > map.native_h * 0.05 then
            return false
        end
    end
    return illustration_count == 1
end

function ComponentDetector.detectPage(map, settings)
    settings = settings or Settings.defaults
    local panels = ComponentDetector.segment(map, settings)
    local strong, maximum_sides = 0, 0
    for _, panel in ipairs(panels) do
        local sides = panel.frame_sides or 0
        maximum_sides = math.max(maximum_sides, sides)
        if sides >= 2 then
            strong = strong + 1
        end
    end
    if #panels >= 2 and (strong == 0 or (#panels >= 3 and strong == 1 and maximum_sides < 3)) then
        return { { x = 0, y = 0, w = map.native_w, h = map.native_h } }, false, "insufficient frame evidence"
    end
    panels = groupSparseIllustration(map, refineGrayConnections(map, panels, settings))
    if isTitleIllustration(map, panels) then
        return { { x = 0, y = 0, w = map.native_w, h = map.native_h } }, false, "title illustration"
    end
    if settings.mode ~= "comic" and #panels < (settings.segment_max_panels or Settings.defaults.segment_max_panels) then
        panels = recoverDetachedFooter(map, panels)
    end
    local accepted, reason = Segmenter.accept(panels, map, settings)
    if not accepted then
        return { { x = 0, y = 0, w = map.native_w, h = map.native_h } }, false, reason
    end
    return Geometry.sortReadingOrder(panels, settings.mode or "manga"), true
end

return ComponentDetector
