--[[
Panels+
File: src/reading_page_fold.lua
Name: ReadingPageFold
Description: Removes the fold strip of a double-page spread while drawing the reading page.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local DoubleSpread = require("src._doublespread")
local FoldJoin = require("src._foldjoin")
local Timing = require("src._timing")
local logger = require("logger")

--- Fold strip removal on the reading page.
---
--- KOReader draws a page from a cached tile (`document:renderPage`, then a blit in
--- `document:drawPage`). This module keeps that tile's pixels unchanged. A joined bitmap is
--- cached separately and stands in for the tile's bitmap while KOReader's own `drawPage` runs.
---
--- Only a tile that covers the whole page is processed. When the page is zoomed in
--- far enough that KOReader renders it in parts, the original drawing path is used.
--- Renders for the panel viewer are handled in `PanelCollector.buildImages`.
---
--- Mixed into the plugin through `include()` in `main.lua`, which calls
--- `installReadingPageFold` from `onReaderReady` and `removeReadingPageFold` from
--- `onCloseWidget`.
---
--- @class PPReadingPageFoldMixin
local ReadingPageFold = {}

--- Native size of `pageno` when it has the shape of a double-page spread, else `nil`.
local function spreadPageSize(document, pageno)
    if not document.getNativePageDimensions then
        return nil
    end
    local ok, size = pcall(document.getNativePageDimensions, document, pageno)
    if ok and DoubleSpread.isSpreadRect(size) then
        return size
    end
    return nil
end

-- Tiles remembered per document, newest first. A joined bitmap is as large as a page tile, and
-- LuaJIT's collector does not see that memory, so the oldest is freed here. Three covers the page
-- being read, and the pages that share the screen in continuous view.
local MAX_REMEMBERED = 3

--- Free the joined bitmaps owned by a document.
local function clearJoinedTiles(document)
    if not document then
        return
    end
    for _, entry in ipairs(document.pp_fold_joined_tiles or {}) do
        if entry.bb and entry.bb.free then
            entry.bb:free()
        end
    end
    document.pp_fold_joined_tiles = {}
end

--- Remember the result for `tile` (`false` when it has no strip) and drop the oldest.
local function remember(remembered, tile, joined)
    table.insert(remembered, 1, { tile = tile, bb = joined })
    while #remembered > MAX_REMEMBERED do
        local dropped = table.remove(remembered)
        if dropped.bb and dropped.bb.free then
            dropped.bb:free()
        end
    end
end

--- Return a plugin-owned joined bitmap for a whole-page tile.
---
--- A remembered `false` means that the tile was checked and has no fold strip. The original
--- tile is never changed.
---
--- @param document table KOReader document instance.
--- @param page_size table Native page size.
--- @param pageno integer Page number.
--- @param rect table Region of the zoomed page being drawn.
--- @param zoom number Zoom factor.
--- @param rotation number Document rotation.
--- @param gamma number Gamma.
--- @param saturation number|nil Saturation.
--- @return table|nil joined Joined bitmap, or nil when the original drawing path should be used.
--- @return table|nil tile Original rendered tile.
local function joinedTile(document, page_size, pageno, rect, zoom, rotation, gamma, saturation)
    local tile = document:renderPage(pageno, rect, zoom, rotation, gamma, saturation)
    if type(tile) ~= "table" or not tile.bb then
        return nil, tile
    end

    local excerpt = tile.excerpt
    if excerpt and ((excerpt.x or 0) ~= 0 or (excerpt.y or 0) ~= 0) then
        return nil, tile
    end

    local bb = tile.bb
    local page_w = page_size.w * zoom
    if math.abs(bb:getWidth() - page_w) > 0.01 * page_w then
        return nil, tile
    end

    local remembered = document.pp_fold_joined_tiles
    if not remembered then
        remembered = {}
        document.pp_fold_joined_tiles = remembered
    end
    for _, entry in ipairs(remembered) do
        if entry.tile == tile then
            return entry.bb or nil, tile
        end
    end

    local joined = FoldJoin.joinBitmap(bb) or false
    remember(remembered, tile, joined)
    if joined then
        Timing.log("reading page fold: strip removed from page %d", pageno)
    end
    return joined or nil, tile
end

--- Drop joined reading-page bitmaps without touching KOReader's document cache.
function ReadingPageFold:clearReadingPageFoldCache()
    local document = self.ui and self.ui.document
    clearJoinedTiles(document)
end

--- Wrap the open document's `drawPage`. Safe to call more than once.
function ReadingPageFold:installReadingPageFold()
    local document = self.ui and self.ui.document
    if not document or not self.ui.paging or document.pp_fold_original_draw_page then
        return
    end
    if type(document.drawPage) ~= "function" or type(document.renderPage) ~= "function" then
        return
    end

    local plugin = self
    local original = document.drawPage
    document.pp_fold_original_draw_page = original
    document.pp_fold_had_own_draw_page = rawget(document, "drawPage") ~= nil
    document.pp_fold_joined_tiles = {}

    document.drawPage = function(doc, target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
        local page_size = plugin.settings.join_spread_fold ~= false
            and (rotation or 0) == 0
            and not (rect and rect.scaled_rect)
            and spreadPageSize(doc, pageno)

        if page_size then
            local ok, joined, tile = pcall(joinedTile, doc, page_size, pageno, rect, zoom, rotation, gamma, saturation)
            if ok and joined and tile then
                -- KOReader's own draw fetches this cached tile again and blits from its bitmap. It
                -- also inverts for night mode and dithers, so it stays in charge of the drawing. The
                -- tile's own bitmap is put back straight after.
                local tile_bb = tile.bb
                tile.bb = joined
                local draw_ok, draw_err =
                    pcall(original, doc, target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
                tile.bb = tile_bb
                if not draw_ok then
                    error(draw_err, 0)
                end
                return
            elseif not ok then
                logger.warn("[Panels+] reading page fold:", tostring(joined))
            end
        end

        return original(doc, target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    end
end

--- Put the document's own `drawPage` back.
function ReadingPageFold:removeReadingPageFold()
    local document = self.ui and self.ui.document
    if not document or not document.pp_fold_original_draw_page then
        return
    end

    clearJoinedTiles(document)

    if document.pp_fold_had_own_draw_page then
        document.drawPage = document.pp_fold_original_draw_page
    else
        document.drawPage = nil
    end

    document.pp_fold_original_draw_page = nil
    document.pp_fold_had_own_draw_page = nil
    document.pp_fold_joined_tiles = nil
end

return ReadingPageFold
