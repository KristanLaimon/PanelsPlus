-- Manhwa detection and rendering are isolated from the Manga/Comic policies.
-- Enable only after the separate Smart ground truth has been evaluated.
local ENABLE_MANHWA_SMART = false

local Manhwa = { smart_enabled = ENABLE_MANHWA_SMART }
local states = setmetatable({}, { __mode = "k" })

function Manhwa.clear(document)
    states[document] = nil
end

function Manhwa.layout(document)
    if states[document] then
        return states[document]
    end
    local Document = require("document/document")
    local layout = {
        pages = {},
        summaries = {},
        breaks = {},
        width = 0,
        height = 0,
        document_ref = setmetatable({ document }, { __mode = "v" }),
    }
    local page, seen = 1, {}
    while page and page ~= 0 and not seen[page] do
        seen[page] = true
        local size = Document.getNativePageDimensions(document, page)
        if not size and document.getPageDimensions then
            size = document:getPageDimensions(page, 1, 0)
        end
        if not size or not size.w or not size.h or size.w <= 0 or size.h <= 0 then
            break
        end
        layout.pages[#layout.pages + 1] = { page = page, y = layout.height, w = size.w, h = size.h }
        layout.width, layout.height = math.max(layout.width, size.w), layout.height + size.h
        if document.getNextPage then
            page = document:getNextPage(page)
        elseif document.getPageCount and page < document:getPageCount() then
            page = page + 1
        else
            page = nil
        end
    end
    function layout:indexForPage(number)
        for i, item in ipairs(self.pages) do
            if item.page == number then
                return i
            end
        end
    end
    function layout:owner(y)
        local lo, hi = 1, #self.pages
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if self.pages[mid].y <= y then
                lo = mid
            else
                hi = mid - 1
            end
        end
        return lo
    end
    states[document] = layout
    return layout
end

local function summary(layout, index, settings, build)
    local mode = Manhwa.smart_enabled and settings.panel_finding_mode == "smart" and "smart" or "safe"
    local key = mode
        .. ":"
        .. index
        .. ":"
        .. tostring(settings.segment_target_width)
        .. ":"
        .. tostring(settings.segment_ink_delta)
    if layout.summaries[key] then
        return layout.summaries[key]
    end
    local item = layout.pages[index]
    local detector = mode == "smart" and require("src._manhwasmart") or require("src._manhwasafe")
    local map = build(layout.document_ref[1], item.page, settings)
    local result = { panels = {}, tolerance = 2 }
    if map then
        result.panels = detector.detectPage(map, settings)
        result.tolerance = math.max(map.scale_y * 5, 2)
    else
        -- Unavailable bitmaps remain readable rather than silently disappearing.
        result.panels = { { x = 0, y = 0, w = item.w, h = item.h } }
        result.unavailable = true
    end
    layout.summaries[key] = result -- geometry only: no chapter-sized bitmap retained
    return result
end

local function union(a, b)
    local x, y = math.min(a.x, b.x), math.min(a.y, b.y)
    return {
        x = x,
        y = y,
        w = math.max(a.x + a.w, b.x + b.w) - x,
        h = math.max(a.y + a.h, b.y + b.h) - y,
        manhwa = true,
    }
end

local function globalRect(item, panel)
    return { x = panel.x, y = item.y + panel.y, w = panel.w, h = panel.h, manhwa = true }
end

local function continuous(a, b)
    local overlap = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
    return overlap >= math.min(a.w, b.w) * 0.5
end

--- Detect complete illustrations across seams, independently of viewer subdivision.
function Manhwa.detect(document, settings, page, build)
    if not document then
        return {}
    end
    local layout = Manhwa.layout(document)
    local index = layout:indexForPage(page)
    if not index then
        return {}
    end
    build = build or require("src._manhwabitmap").build
    local here = summary(layout, index, settings, build)
    local result, seen = {}, {}
    local limit = math.max(1, math.floor(tonumber(settings.manhwa_max_join_pages) or 12))
    for _, panel in ipairs(here.panels) do
        local rect = globalRect(layout.pages[index], panel)
        local first, last = index, index
        if not here.unavailable and panel.y <= here.tolerance then
            while first > 1 and index - first < limit - 1 and not layout.breaks[first] do
                local previous = summary(layout, first - 1, settings, build)
                if previous.unavailable then
                    break
                end
                local candidate = previous.panels[#previous.panels]
                local item = layout.pages[first - 1]
                if not candidate or item.h - candidate.y - candidate.h > previous.tolerance then
                    break
                end
                local global = globalRect(item, candidate)
                if not continuous(global, rect) then
                    break
                end
                rect, first = union(global, rect), first - 1
                if candidate.y > previous.tolerance then
                    break
                end
            end
        end
        if index - first >= limit - 1 then
            layout.breaks[first] = true
        end
        if not here.unavailable and layout.pages[index].h - panel.y - panel.h <= here.tolerance then
            while last < #layout.pages and last - first < limit - 1 and not layout.breaks[last + 1] do
                local following = summary(layout, last + 1, settings, build)
                if following.unavailable then
                    break
                end
                local candidate = following.panels[1]
                if not candidate or candidate.y > following.tolerance then
                    break
                end
                local item = layout.pages[last + 1]
                local global = globalRect(item, candidate)
                if not continuous(rect, global) then
                    break
                end
                rect, last = union(rect, global), last + 1
                if item.h - candidate.y - candidate.h > following.tolerance then
                    break
                end
            end
        end
        if last - first >= limit - 1 then
            layout.breaks[last + 1] = true
        end
        local key = string.format("%.3f:%.3f:%.3f:%.3f", rect.x, rect.y, rect.w, rect.h)
        if not seen[key] then
            seen[key] = true
            result[#result + 1] = rect
        end
    end
    table.sort(result, function(a, b)
        return a.y == b.y and a.x < b.x or a.y < b.y
    end)
    return result
end

--- Balanced reading sections retain an illustration's true beginning and ending.
function Manhwa.sections(panels, settings)
    local Screen = require("device").screen
    local result = {}
    for _, panel in ipairs(panels) do
        local ratio = math.max(0.25, tonumber(settings.manhwa_section_height_ratio) or 1.6)
        local max_height = math.max(1, panel.w * Screen:getHeight() / Screen:getWidth() * ratio)
        local count = math.max(1, math.ceil(panel.h / max_height))
        for i = 1, count do
            local y = panel.y + math.floor(panel.h * (i - 1) / count)
            local bottom = panel.y + math.floor(panel.h * i / count)
            result[#result + 1] = {
                x = panel.x,
                y = y,
                w = panel.w,
                h = bottom - y,
                manhwa = true,
                illustration_y = panel.y,
                illustration_h = panel.h,
            }
        end
    end
    return result
end

function Manhwa.collect(ui, settings, page)
    return Manhwa.sections(Manhwa.detect(ui.document, settings, page), settings)
end

--- Return an adjacent, nonduplicate section, even when it starts in the same file.
function Manhwa.adjacent(ui, settings, viewer, direction)
    if not ui or not ui.document then
        return
    end
    local layout = Manhwa.layout(ui.document)
    local current = viewer.panels and viewer.panels[viewer._images_list_cur or 1]
    if not current then
        return
    end
    local forward = direction == "next"
    local edge = forward and current.y + current.h or current.y
    local index = layout:owner(forward and edge + 0.01 or edge - 0.01)
    while index >= 1 and index <= #layout.pages do
        local page = layout.pages[index].page
        local panels = Manhwa.collect(ui, settings, page)
        if forward then
            for i, panel in ipairs(panels) do
                if panel.y >= edge - 0.01 then
                    return page, panels, i
                end
            end
        else
            for i = #panels, 1, -1 do
                if panels[i].y + panels[i].h <= edge + 0.01 then
                    return page, panels, i
                end
            end
        end
        index = index + (forward and 1 or -1)
    end
end

--- Composite only intersecting source crops at a screen-bounded render size.
--- Returned buffers belong to the caller, unlike ordinary DocCache tiles.
function Manhwa.render(ui, rect, zoom)
    if not ui or not ui.document or not rect or (rect.w or 0) <= 0 or (rect.h or 0) <= 0 then
        return nil, false
    end
    if zoom and zoom <= 0 then
        return nil, false
    end
    local Screen = require("device").screen
    local Blitbuffer = require("ffi/blitbuffer")
    local PageRender = require("src._pagerender")
    local layout = Manhwa.layout(ui.document)
    zoom = zoom or math.min(Screen:getWidth() / rect.w, Screen:getHeight() / rect.h)
    local w, h = math.max(1, math.floor(rect.w * zoom + 0.5)), math.max(1, math.floor(rect.h * zoom + 0.5))
    if
        w * h > Screen:getWidth() * Screen:getHeight() * 16
        or not require("src._memory").hasAllocationHeadroom(8 * 1024 * 1024, w * h * 8)
    then
        return nil, false
    end
    local canvas, scaled
    local ok, err = pcall(function()
        for i = layout:owner(rect.y), #layout.pages do
            local item = layout.pages[i]
            if item.y >= rect.y + rect.h then
                break
            end
            local top, bottom = math.max(rect.y, item.y), math.min(rect.y + rect.h, item.y + item.h)
            local left, right = math.max(0, rect.x), math.min(item.w, rect.x + rect.w)
            if bottom > top and right > left then
                local x = math.max(0, math.floor((left - rect.x) * zoom + 0.5))
                local y = math.max(0, math.floor((top - rect.y) * zoom + 0.5))
                local right_pixel = math.min(w, math.floor((right - rect.x) * zoom + 0.5))
                local bottom_pixel = math.min(h, math.floor((bottom - rect.y) * zoom + 0.5))
                local pw, ph = right_pixel - x, bottom_pixel - y
                if pw > 0 and ph > 0 then
                    local part = { x = left, y = top - item.y, w = right - left, h = bottom - top }
                    local tile = PageRender.drawPagePart(ui, item.page, part, 0, zoom)
                    if not tile then
                        error("manhwa source crop render failed")
                    end
                    if not canvas then
                        canvas = Blitbuffer.new(w, h, tile:getType())
                        canvas:fill(Blitbuffer.COLOR_WHITE)
                    end
                    if tile:getWidth() ~= pw or tile:getHeight() ~= ph then
                        local resized = require("ui/renderimage"):scaleBlitBuffer(tile, pw, ph, false)
                        if not resized then
                            error("manhwa source crop resize failed")
                        end
                        if resized ~= tile then
                            scaled = resized
                        end
                    end
                    canvas:blitFrom(scaled or tile, x, y, 0, 0, pw, ph)
                    if scaled and scaled ~= tile then
                        scaled:free()
                    end
                    scaled = nil
                end
            end
        end
    end)
    if not ok then
        if scaled then
            scaled:free()
        end
        if canvas then
            canvas:free()
        end
        require("logger").warn("[Panels+] manhwa render failed", err)
        return nil, false
    end
    return canvas, false
end

return Manhwa
