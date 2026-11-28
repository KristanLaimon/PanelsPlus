--[[
Panels+
File: src/segmenter/acceptance.lua
Name: Segmenter
Description: Validates panel coverage and rejects page furniture.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Settings = require("src._settings")

return function(Segmenter)
    --- Detect a contents/credits layout that the gutter cutter can mistake for a
    --- tall panel beside a stack of panels. In this layout the tall illustration
    --- owns nearly all of the page ink while the "stack" consists of sparse text
    --- fragments. Real side-stack panel layouts distribute substantially more ink
    --- through the smaller panels.
    ---
    --- This is deliberately narrow: it requires at least six candidates, one
    --- near-full-height strip, every other candidate on the opposite side, and a
    --- strong density/ink-share contrast. Keeping the gate here (after ordinary
    --- segmentation) avoids changing any panel boundary produced for normal pages.
    local function looksLikePageFurnitureLayout(panels, map)
        if #panels < 6 or not map.data or not map.ink or map.ink <= 0 then
            return false
        end

        local page_w, page_h = map.native_w, map.native_h
        local dominant_index, dominant = nil, nil
        for index, panel in ipairs(panels) do
            if
                panel.h >= page_h * 0.90
                and panel.w >= page_w * 0.20
                and panel.w <= page_w * 0.50
                and (not dominant or panel.w * panel.h > dominant.w * dominant.h)
            then
                dominant_index, dominant = index, panel
            end
        end
        if not dominant then
            return false
        end

        local strip_mid = dominant.x + dominant.w / 2
        local strip_on_left = strip_mid < page_w / 2
        for index, panel in ipairs(panels) do
            if index ~= dominant_index then
                if strip_on_left then
                    if panel.x < dominant.x + dominant.w * 0.90 then
                        return false
                    end
                elseif panel.x + panel.w > dominant.x + dominant.w * 0.10 then
                    return false
                end
            end
        end

        local function panelInk(panel)
            local x0 = math.max(0, math.floor(panel.x / map.scale_x))
            local y0 = math.max(0, math.floor(panel.y / map.scale_y))
            local x1 = math.min(map.w - 1, math.floor((panel.x + panel.w) / map.scale_x))
            local y1 = math.min(map.h - 1, math.floor((panel.y + panel.h) / map.scale_y))
            local ink = 0
            for y = y0, y1 do
                local base = y * map.w
                for x = x0, x1 do
                    if map.data[base + x] == 1 then
                        ink = ink + 1
                    end
                end
            end
            return ink, math.max(1, (x1 - x0 + 1) * (y1 - y0 + 1))
        end

        local dominant_ink, dominant_cells = panelInk(dominant)
        if dominant_ink / map.ink < 0.75 or dominant_ink / dominant_cells < 0.60 then
            return false
        end

        local minor_ink, minor_cells = 0, 0
        for index, panel in ipairs(panels) do
            if index ~= dominant_index then
                local ink, cells = panelInk(panel)
                minor_ink = minor_ink + ink
                minor_cells = minor_cells + cells
            end
        end
        return minor_cells > 0 and minor_ink / minor_cells < 0.30
    end

    --- Decide whether a segmentation result is trustworthy.
    ---
    --- @param panels PPPanel[] Segmented panel rectangles.
    --- @param map PPPageMap Page ink map.
    --- @param settings PPSettings Plugin settings.
    --- @return boolean accepted Whether the caller should use these panels.
    --- @return string|nil reason Rejection reason when not accepted.
    function Segmenter.accept(panels, map, settings)
        settings = settings or Settings.defaults
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
            -- One rectangle spanning most of the page is the right answer twice
            -- over: it is what a splash page actually is, and it is also the best
            -- either detector can do on a layout with no straight gutters (a
            -- diagonal split, say), so falling back would only cost a
            -- full-resolution render to reach the same rectangle. A lone *small*
            -- rectangle is different: the cut latched onto one blob and missed the
            -- rest of the page, which is worth a second opinion.
            local single_ratio = settings.segment_single_panel_ratio or Settings.defaults.segment_single_panel_ratio
            if largest_area >= page_area * single_ratio then
                return true
            end
            -- If the lone panel captures almost all the page's ink, the rest of the
            -- page is blank margin (e.g. an omake, bonus strip, or chapter end illustration)
            -- rather than an unsegmented multi-panel layout.
            if map.ink and map.ink > 0 and map.data then
                local mx0 = math.max(0, math.floor(panels[1].x / map.scale_x))
                local my0 = math.max(0, math.floor(panels[1].y / map.scale_y))
                local mx1 = math.min(map.w - 1, math.floor((panels[1].x + panels[1].w) / map.scale_x))
                local my1 = math.min(map.h - 1, math.floor((panels[1].y + panels[1].h) / map.scale_y))
                local p_ink = 0
                for y = my0, my1 do
                    local base = y * map.w
                    for x = mx0, mx1 do
                        if map.data[base + x] == 1 then
                            p_ink = p_ink + 1
                        end
                    end
                end
                if p_ink >= map.ink * 0.70 then
                    return true
                end
            end
            return false, "single partial panel"
        end

        if looksLikePageFurnitureLayout(panels, map) then
            return false, "page furniture mistaken for panels"
        end

        local covered_area = (max_x - min_x) * (max_y - min_y)
        if
            covered_area
            < page_area * (settings.segment_page_coverage_min or Settings.defaults.segment_page_coverage_min)
        then
            return false, "panels cover too little of the page"
        end

        local coverage_min = settings.segment_coverage_min or Settings.defaults.segment_coverage_min
        if total_area < covered_area * coverage_min then
            return false,
                string.format("only %d%% of the covered area kept", math.floor(total_area * 100 / covered_area))
        end

        return true
    end
end
