--[[
Panels+
File: src/_imagedocument.lua
Name: ImageDocument
Description: Provides bounded bitmap crops and native OCR contexts for extracted images.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
-- Bitmap-backed OCR source. Borrows the viewer's image; only small crops are owned here.
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local RenderImage = require("ui/renderimage")
local Memory = require("src._memory")
local ffi = require("ffi")
local ImageDocument = {}

local function raster(image, box, zoom)
    local x, y = math.max(0, math.floor(box.x)), math.max(0, math.floor(box.y))
    local w = math.min(image:getWidth() - x, math.ceil(box.x + box.w) - x)
    local h = math.min(image:getHeight() - y, math.ceil(box.y + box.h) - y)
    assert(w > 0 and h > 0, "empty OCR crop")
    local sw, sh = math.max(1, math.ceil(w * zoom)), math.max(1, math.ceil(h * zoom))
    assert(Memory.hasAllocationHeadroom(40 * 1024 * 1024, w * h + sw * sh * 4), "low OCR memory")
    local crop = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local ok, result = pcall(function()
        crop:blitFrom(image, 0, 0, x, y, w, h)
        return RenderImage:scaleBlitBuffer(crop, sw, sh, true)
    end)
    if not ok then
        crop:free()
        error(result)
    end
    return result, x, y
end

local function fillContext(context, image)
    local x0, y0, x1, y1 = context:getBBox()
    local bb = raster(image, { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }, context:getZoom())
    local ok, err = pcall(function()
        local k2 = require("ffi/koptcontext").k2pdfopt
        local bmp = context.src
        bmp.width, bmp.height, bmp.bpp, bmp.type = bb.w, bb.h, 8, 0
        assert(k2.bmp_alloc(bmp) ~= 0, "OCR bitmap allocation failed")
        for i = 0, 255 do
            bmp.red[i], bmp.green[i], bmp.blue[i] = i, i, i
        end
        local stride = k2.bmp_bytewidth(bmp)
        for y = 0, bb.h - 1 do
            ffi.copy(bmp.data + y * stride, bb.data + y * bb.stride, bb.w)
        end
        context.page_width, context.page_height = bb.w, bb.h
    end)
    bb:free()
    if not ok then
        error(err)
    end
end

function ImageDocument.new(image)
    local source = { is_bitmap_source = true, configurable = { doc_language = "eng" }, render_mode = 0 }
    function source:getNativePageDimensions()
        return Geom:new({ w = image:getWidth(), h = image:getHeight() })
    end
    function source:transformRect(rect, zoom)
        local scaled = rect:copy()
        scaled:transformByScale(zoom)
        return scaled
    end
    function source:renderPage(_, rect, zoom)
        -- Match the integer origin used by WordFinder's page renderer.
        local scaled = rect.scaled_rect
        local bb, x, y =
            raster(image, { x = scaled.x / zoom, y = scaled.y / zoom, w = scaled.w / zoom, h = scaled.h / zoom }, zoom)
        return { bb = bb, disposable = true, origin_x = x * zoom, origin_y = y * zoom }
    end
    source.koptinterface = {
        tessocr_data = require("src._wordfinder").userModelDirectory(),
        createContext = function(_, _, _, bbox)
            local context = require("ffi/koptcontext").new()
            context:setBBox(bbox.x0, bbox.y0, bbox.x1, bbox.y1)
            return context
        end,
    }
    source._document = {
        openPage = function()
            return {
                getSize = function()
                    return image:getWidth(), image:getHeight()
                end,
                getPagePix = function(_, context)
                    fillContext(context, image)
                end,
                close = function() end,
            }
        end,
    }
    function source:getTextBoxes(_, seed)
        -- Bound the dialogue search around the held word rather than copying a whole scan.
        local margin = math.max(seed.h * 12, 120)
        local x, y = math.max(0, seed.x - margin), math.max(0, seed.y - margin)
        local right = math.min(image:getWidth(), seed.x + seed.w + margin)
        local bottom = math.min(image:getHeight(), seed.y + seed.h + margin)
        local context = self.koptinterface:createContext(self, 1, { x0 = x, y0 = y, x1 = right, y1 = bottom })
        local ok, boxes = pcall(function()
            context:setZoom(1)
            fillContext(context, image)
            return context:getNativeWordBoxes("src", 0, 0, context.page_width, context.page_height)
        end)
        context:free()
        if not ok then
            error(boxes)
        end
        for _, line in ipairs(boxes or {}) do
            line.x0, line.x1, line.y0, line.y1 =
                line.x0 + math.floor(x), line.x1 + math.floor(x), line.y0 + math.floor(y), line.y1 + math.floor(y)
            for _, word in ipairs(line) do
                word.x0, word.x1 = word.x0 + math.floor(x), word.x1 + math.floor(x)
                word.y0, word.y1 = word.y0 + math.floor(y), word.y1 + math.floor(y)
            end
        end
        return boxes
    end
    return source
end

return ImageDocument
