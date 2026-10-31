--[[
Panels+
File: src/_pagebitmap.lua
Name: PageBitmap
Description: Renders or resamples bounded source rasters and converts them into background-relative ink maps.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Blitbuffer = require("ffi/blitbuffer")
local Document = require("document/document")
local Geom = require("ui/geometry")
local RenderImage = require("ui/renderimage")
local Memory = require("src._memory")
local Settings = require("src._settings")
local Timing = require("src._timing")
local ffi = require("ffi")
local logger = require("logger")

--- Low-resolution binary ink map of a document page.
---
--- The map is the input to `src._segmenter`. Two properties matter:
---
--- 1. It costs a *single* page render, at roughly 1/5 linear scale, instead of
---    one full-resolution render per probe point.
--- 2. "Ink" is defined relative to the page's own border colour rather than
---    against white. A page printed white-on-black produces exactly the same
---    map as the equivalent black-on-white page, which is what lets panel
---    detection work on inverted artwork at all.
---
--- @class PPPageBitmapModule
local PageBitmap = {}

-- Resizing an extracted image needs a full private copy because the scaler
-- consumes its input. Keep this modest safety floor after that allocation;
-- the no-resize fallback below is deliberately available for older Kindles.
local EMBEDDED_RESIZE_MIN_FREE_BYTES = 15 * 1024 * 1024

--- @class PPPageMap
--- @field w integer Map width in cells.
--- @field h integer Map height in cells.
--- @field data ffi.cdata* `uint8_t[w*h]` of 0/1 ink flags.
--- @field ink integer Total ink cells.
--- @field native_w number Native page width.
--- @field native_h number Native page height.
--- @field scale_x number Native units per map cell, horizontally.
--- @field scale_y number Native units per map cell, vertically.
--- @field background integer Estimated page background luminance (0-255).
--- @field background_color table<{r:integer, g:integer, b:integer}> Estimated page background RGB colour.
--- @field inverted boolean Whether the page background is dark.
--- @field border ffi.cdata*|nil `uint8_t[w*h]` of 0/1 border-stroke candidate flags, comic mode only.

--- Return why the segmenter cannot run on this document, if it cannot.
---
--- `KoptInterface:renderPage()` only honors a caller-supplied zoom on its plain
--- path. Under reflow the rendered geometry does not correspond to native page
--- coordinates at all, and the page-optimization path runs an extra k2pdfopt
--- pass that defeats the point of a cheap render.
---
--- @param document table KOReader document object.
--- @return string|nil reason Blocking reason, or nil when usable.
function PageBitmap.getBlockReason(document)
    if not document then
        return "no document"
    end
    local configurable = document.configurable
    if configurable and configurable.text_wrap == 1 then
        return "reflow mode"
    end
    local koptinterface = document.koptinterface
    if koptinterface and koptinterface.is_optimizing_page and koptinterface:is_optimizing_page(document) then
        return "page optimization enabled"
    end
    return nil
end

--- Render one page at a fraction of its native size.
---
--- Uses the same `rect.scaled_rect` convention as `Document:drawPagePart()`,
--- which is what tells `renderPage()` that the caller has already handled
--- scaling and that it should not fall back to a full-size render.
---
--- @param document table KOReader document object.
--- @param page number Document page number.
--- @param target_width integer Desired render width in pixels.
--- @return table|nil bb Rendered blitbuffer.
--- @return PPPageSize|nil native Native page dimensions.
local function renderSmall(document, page, target_width)
    local native = Document.getNativePageDimensions(document, page)
    if not native or not native.w or not native.h or native.w <= 0 or native.h <= 0 then
        return nil
    end

    local zoom = math.min(1, target_width / native.w)
    local rect = Geom:new({ x = 0, y = 0, w = native.w, h = native.h })
    rect.scaled_rect = document:transformRect(rect, zoom, 0)
    if rect.scaled_rect.w < 32 or rect.scaled_rect.h < 32 then
        return nil
    end

    -- No hinting: this render is small and must not spin up extra CPU cores.
    local tile = document:renderPage(page, rect, zoom, 0, document.GAMMA_NO_GAMMA or 1.0, 1.0, false)
    if not tile or not tile.bb then
        return nil
    end
    return tile.bb, native
end

--- Return the pixel dimensions both detection backends should use for an
--- image. Fixed-layout documents already arrive from `renderSmall()` at this
--- size; extracted reflow images must be rescaled to it first. Never enlarge
--- a small source, matching `renderSmall()`'s `math.min(1, ...)` zoom.
---
--- @param width number Source image width.
--- @param height number Source image height.
--- @param target_width integer Maximum detector raster width.
--- @return integer|nil width
--- @return integer|nil height
local function detectionRasterSize(width, height, target_width)
    if not width or not height or width <= 0 or height <= 0 then
        return nil, nil
    end
    local target_height = target_width * 2
    if width <= target_width and height <= target_height then
        return width, height
    end
    local scale = math.min(1, target_width / width, target_height / height)
    return math.max(1, math.floor(width * scale + 0.5)), math.max(1, math.floor(height * scale + 0.5))
end

--- Conservative temporary memory required to rescale an extracted image.
--- Four bytes per pixel deliberately overestimates greyscale and RGB24
--- sources. The target buffer has a second allowance because normalizing an
--- unusual colour format can briefly make another target-sized copy.
local function embeddedResizeWorkingSetBytes(width, height, raster_w, raster_h)
    return math.floor(width * height * 4 + raster_w * raster_h * 8 + 4 * 1024 * 1024)
end

local function hasEmbeddedResizeHeadroom(width, height, raster_w, raster_h)
    return Memory.hasAllocationHeadroom(
        EMBEDDED_RESIZE_MIN_FREE_BYTES,
        embeddedResizeWorkingSetBytes(width, height, raster_w, raster_h)
    )
end

--- Return the old bounded sparse-sampling step for the low-memory fallback.
--- This avoids a new allocation entirely while retaining the historical cap
--- for unusually tall reflow images.
local function embeddedSparseStep(width, height, target_width)
    local step = math.max(1, math.floor(width / target_width))
    if math.floor(height / step) > target_width * 2 then
        step = math.max(step, math.ceil(height / (target_width * 2)))
    end
    return step
end

--- Make an extracted reflow image match the fixed-page detector raster.
---
--- `RenderImage:scaleBlitBuffer()` takes ownership of its input. Copying here
--- is essential: the original decoded image remains owned by the embedded
--- viewer and is later used to render full-quality panel crops.
---
--- @param bb table Decoded embedded-image BlitBuffer.
--- @param target_width integer Maximum detector raster width.
--- @return table|nil raster
--- @return table|nil owned Raster to free after detection, if newly allocated.
--- @return boolean|nil resampled `true` only when a new target raster was made.
local function makeEmbeddedDetectionRaster(bb, target_width)
    local width, height = bb and bb.w, bb and bb.h
    local raster_w, raster_h = detectionRasterSize(width, height, target_width)
    if not raster_w then
        return nil, nil, nil
    end
    if raster_w == width and raster_h == height then
        return bb, nil, false
    end
    if type(bb.copy) ~= "function" then
        Timing.memory("embedded resize skipped: image cannot be copied")
        return bb, nil, false
    end
    local working_set = embeddedResizeWorkingSetBytes(width, height, raster_w, raster_h)
    if not hasEmbeddedResizeHeadroom(width, height, raster_w, raster_h) then
        Timing.memory(
            "embedded resize skipped: low memory (%dx%d -> %dx%d, need %dMB + 15MB floor)",
            width,
            height,
            raster_w,
            raster_h,
            math.ceil(working_set / (1024 * 1024))
        )
        return bb, nil, false
    end

    local copy
    local ok, raster = pcall(function()
        copy = bb:copy()
        if not copy then
            error("image copy failed")
        end
        -- scaleBlitBuffer consumes this private copy, never the retained source.
        return RenderImage:scaleBlitBuffer(copy, raster_w, raster_h, true)
    end)
    if not ok or not raster then
        if not ok and copy and copy ~= raster then
            pcall(copy.free, copy)
        end
        Timing.log("embedded resize failed; using bounded sparse map")
        return bb, nil, false
    end
    return raster, raster, true
end

--- Return a buffer whose raw pixels can be sampled without applying a rotation
--- or inverse transform in Lua.
---
--- Keep colour buffers in colour. A solid coloured page background can share a
--- luminance with its panels, and reducing both to greyscale before comparing
--- them makes that gutter disappear. Rotated or inverted buffers are copied so
--- the raw fast paths below see their displayed pixels.
---
--- @param bb table Rendered blitbuffer.
--- @return table bb Buffer to sample.
--- @return table|nil owned Buffer the caller must free, if one was allocated.
--- @return boolean is_rgb Whether the sampled buffer is in an RGB colour space.
local function normalizeForSampling(bb)
    local is_rgb = bb:isRGB()
    if is_rgb then
        local btype = bb:getType()
        if
            (btype == Blitbuffer.TYPE_BBRGB32 or btype == Blitbuffer.TYPE_BBRGB24 or btype == Blitbuffer.TYPE_BBRGB16)
            and bb:getRotation() == 0
            and bb:getInverse() == 0
        then
            return bb, nil, true
        end

        local ok, normalized = pcall(function()
            local target = Blitbuffer.new(bb.w, bb.h, Blitbuffer.TYPE_BBRGB32)
            target:blitFrom(bb, 0, 0, 0, 0, bb.w, bb.h)
            return target
        end)
        if ok and normalized then
            return normalized, normalized, true
        end
        return bb, nil, true
    else
        -- Normalize all non-RGB formats (e.g. 4bpp e-ink BB4, monochrome, inverted,
        -- rotated) to standard 8bpp greyscale in C via blitFrom so pixel sampling
        -- never falls back to allocating Color objects in Lua.
        if bb:getType() == Blitbuffer.TYPE_BB8 and bb:getRotation() == 0 and bb:getInverse() == 0 then
            return bb, nil, false
        end

        local ok, normalized = pcall(function()
            local target = Blitbuffer.new(bb.w, bb.h, Blitbuffer.TYPE_BB8)
            target:blitFrom(bb, 0, 0, 0, 0, bb.w, bb.h)
            return target
        end)
        if ok and normalized then
            return normalized, normalized, false
        end
        return bb, nil, false
    end
end

--- Build the fastest available RGB accessor for a blitbuffer.
---
--- Reading raw pixels directly avoids a Lua colour object allocation per pixel,
--- which matters across ~150k of them.
---
--- @param bb table Buffer to sample.
--- @return fun(x:integer, y:integer):integer,integer,integer sample RGB accessor.
--- @return string kind Accessor name, for timing logs.
--- @return ffi.cdata*|nil raw_data Raw pointer if direct buffer access is possible.
--- @return integer|nil stride Stride or pixel_stride.
local function makeSampler(bb)
    local btype = bb:getType()
    if btype == Blitbuffer.TYPE_BB8 then
        local ok, data = pcall(ffi.cast, "uint8_t *", bb.data)
        if ok and data ~= nil then
            local stride = tonumber(bb.stride)
            return function(x, y)
                local value = data[y * stride + x]
                return value, value, value
            end,
                "bb8",
                data,
                stride
        end
    end

    local pixel_stride = tonumber(bb.pixel_stride)
    if btype == Blitbuffer.TYPE_BBRGB24 then
        local ok, data = pcall(ffi.cast, "ColorRGB24 *", bb.data)
        if ok and data ~= nil then
            return function(x, y)
                local pixel = data[y * pixel_stride + x]
                return pixel.r, pixel.g, pixel.b
            end,
                "rgb24",
                data,
                pixel_stride
        end
    elseif btype == Blitbuffer.TYPE_BBRGB32 then
        local ok, data = pcall(ffi.cast, "ColorRGB32 *", bb.data)
        if ok and data ~= nil then
            return function(x, y)
                local pixel = data[y * pixel_stride + x]
                return pixel.r, pixel.g, pixel.b
            end,
                "rgb32",
                data,
                pixel_stride
        end
    elseif btype == Blitbuffer.TYPE_BBRGB16 then
        local ok, data = pcall(ffi.cast, "ColorRGB16 *", bb.data)
        if ok and data ~= nil then
            return function(x, y)
                local value = tonumber(data[y * pixel_stride + x].v)
                local r = math.floor(value / 2048)
                local g = math.floor(value / 32) % 64
                local b = value % 32
                return r * 8 + math.floor(r / 4), g * 4 + math.floor(g / 16), b * 8 + math.floor(b / 4)
            end,
                "rgb16",
                data,
                pixel_stride
        end
    end

    return function(x, y)
        local color = bb:getPixel(x, y):getColorRGB24()
        return color.r, color.g, color.b
    end,
        "generic",
        nil,
        nil
end

--- Return an RGB colour's luminance using KOReader's own ColorRGB conversion.
---
--- @param r integer
--- @param g integer
--- @param b integer
--- @return integer luminance
local function luminance(r, g, b)
    return math.floor((4898 * r + 9618 * g + 1869 * b) / 16384)
end

--- Return the greatest per-channel difference between two RGB colours.
---
--- This is deliberately equivalent to the old absolute luminance difference
--- for greyscale pixels, while also seeing hues that have almost the same
--- luminance as the background.
local function colourDistance(r, g, b, background_r, background_g, background_b)
    local dr = math.abs(r - background_r)
    local dg = math.abs(g - background_g)
    local db = math.abs(b - background_b)
    return math.max(dr, dg, db)
end

--- Look for a white separator without allocating another page-sized buffer.
--- This also recovers paper colour after manga conversions trim the margins.
--- Preserve near-black backgrounds: white panel interiors can span most of a
--- page with black gutters, so a bright scanline alone cannot override them.
local function hasWhiteSeparatorGrey(data, stride, w, h, step)
    local grid_w = math.floor(w / step)
    local grid_h = math.floor(h / step)
    local x_margin = math.max(1, math.floor(grid_w * 0.03))
    local y_margin = math.max(1, math.floor(grid_h * 0.03))
    local row_required, col_required = math.ceil(grid_w * 0.80), math.ceil(grid_h * 0.80)
    for y = y_margin, grid_h - 1 - y_margin do
        local bright = 0
        local row = y * step * stride
        for x = 0, grid_w - 1 do
            if data[row + x * step] >= 245 then
                bright = bright + 1
            end
            if bright >= row_required then
                return true
            end
            if bright + grid_w - 1 - x < row_required then
                break
            end
        end
    end
    for x = x_margin, grid_w - 1 - x_margin do
        local bright = 0
        for y = 0, grid_h - 1 do
            if data[y * step * stride + x * step] >= 245 then
                bright = bright + 1
            end
            if bright >= col_required then
                return true
            end
            if bright + grid_h - 1 - y < col_required then
                break
            end
        end
    end
    return false
end

local function estimateBackgroundGrey(data, stride, w, h, step)
    step = step or 1
    local histogram = {}
    for value = 0, 255 do
        histogram[value] = 0
    end

    local grid_w = math.floor(w / step)
    local grid_h = math.floor(h / step)
    local ring = math.max(1, math.floor(math.min(grid_w, grid_h) * 0.01))
    local total = 0

    local function tally(grid_x, grid_y)
        local val = data[(grid_y * step) * stride + (grid_x * step)]
        histogram[val] = histogram[val] + 1
        total = total + 1
    end

    for offset = 0, ring - 1 do
        for x = 0, grid_w - 1 do
            tally(x, offset)
            tally(x, grid_h - 1 - offset)
        end
        for y = ring, grid_h - 1 - ring do
            tally(offset, y)
            tally(grid_w - 1 - offset, y)
        end
    end

    if total == 0 then
        return 255
    end

    local half, seen = total / 2, 0
    for value = 0, 255 do
        seen = seen + histogram[value]
        if seen >= half then
            if value >= 32 and value < 224 and hasWhiteSeparatorGrey(data, stride, w, h, step) then
                return 255
            end
            return value
        end
    end
    return 255
end

--- Estimate the page background colour from its outer border.
---
--- Use the border median unless a spanning white gutter contradicts it.
--- Converters can trim the paper margins right down to the artwork in both
--- manga and comics, so reading direction must not select the paper colour.
---
--- @param sample fun(x:integer, y:integer):integer,integer,integer RGB accessor.
--- @param w integer Source width.
--- @param h integer Source height.
--- @param step integer|nil Grid step (defaults to 1).
--- @return integer r Median border red channel (0-255).
--- @return integer g Median border green channel (0-255).
--- @return integer b Median border blue channel (0-255).
local function hasWhiteSeparator(sample, w, h, step)
    local grid_w = math.floor(w / step)
    local grid_h = math.floor(h / step)
    local x_margin = math.max(1, math.floor(grid_w * 0.03))
    local y_margin = math.max(1, math.floor(grid_h * 0.03))
    local row_required, col_required = math.ceil(grid_w * 0.80), math.ceil(grid_h * 0.80)
    local function isWhite(grid_x, grid_y)
        local r, g, b = sample(grid_x * step, grid_y * step)
        return r >= 245 and g >= 245 and b >= 245
    end
    for y = y_margin, grid_h - 1 - y_margin do
        local bright = 0
        for x = 0, grid_w - 1 do
            if isWhite(x, y) then
                bright = bright + 1
            end
            if bright >= row_required then
                return true
            end
            if bright + grid_w - 1 - x < row_required then
                break
            end
        end
    end
    for x = x_margin, grid_w - 1 - x_margin do
        local bright = 0
        for y = 0, grid_h - 1 do
            if isWhite(x, y) then
                bright = bright + 1
            end
            if bright >= col_required then
                return true
            end
            if bright + grid_h - 1 - y < col_required then
                break
            end
        end
    end
    return false
end

local function estimateBackground(sample, w, h, step)
    step = step or 1
    local red, green, blue = {}, {}, {}
    for value = 0, 255 do
        red[value], green[value], blue[value] = 0, 0, 0
    end

    local grid_w = math.floor(w / step)
    local grid_h = math.floor(h / step)
    local ring = math.max(1, math.floor(math.min(grid_w, grid_h) * 0.01))
    local total = 0

    local function tally(grid_x, grid_y)
        local r, g, b = sample(grid_x * step, grid_y * step)
        red[r] = red[r] + 1
        green[g] = green[g] + 1
        blue[b] = blue[b] + 1
        total = total + 1
    end

    for offset = 0, ring - 1 do
        for x = 0, grid_w - 1 do
            tally(x, offset)
            tally(x, grid_h - 1 - offset)
        end
        for y = ring, grid_h - 1 - ring do
            tally(offset, y)
            tally(grid_w - 1 - offset, y)
        end
    end

    if total == 0 then
        return 255, 255, 255
    end

    local function median(histogram)
        local half, seen = total / 2, 0
        for value = 0, 255 do
            seen = seen + histogram[value]
            if seen >= half then
                return value
            end
        end
        return 255
    end

    local r, g, b = median(red), median(green), median(blue)
    local brightest = math.max(r, g, b)
    if brightest >= 32 and brightest < 224 and hasWhiteSeparator(sample, w, h, step) then
        return 255, 255, 255
    end
    return r, g, b
end

--- Build an ink map from normalized buffer data.
--- Fast path for greyscale (BB8 raw pointer): zero closure calls, direct memory access,
--- single integer difference.
--- Colour path: inlined per-channel delta, no math.abs/max closure overhead.
local function buildMapFromBuffer(
    work,
    sample,
    kind,
    raw_data,
    stride,
    is_rgb,
    native_w,
    native_h,
    settings,
    step,
    w,
    h
)
    local ink_delta = settings.segment_ink_delta or Settings.defaults.segment_ink_delta
    local detect_borders = settings.mode == "comic" and settings.segment_border_split == true
    local border_luminance_max = settings.segment_border_luminance_max or Settings.defaults.segment_border_luminance_max

    local src_w, src_h = work.w, work.h
    local data = ffi.new("uint8_t[?]", w * h)
    local border = detect_borders and ffi.new("uint8_t[?]", w * h) or nil
    local ink = 0
    local border_cells = 0
    local background, background_r, background_g, background_b

    if not is_rgb and kind == "bb8" and raw_data ~= nil and stride ~= nil then
        -- Fast greyscale path (manga / e-ink / black-and-white artwork)
        local bg_val = estimateBackgroundGrey(raw_data, stride, src_w, src_h, step)
        background = bg_val
        background_r, background_g, background_b = bg_val, bg_val, bg_val

        if border then
            for y = 0, h - 1 do
                local src_y = y * step
                local row_offset = src_y * stride
                local map_row = y * w
                for x = 0, w - 1 do
                    local val = raw_data[row_offset + x * step]
                    local delta = val - bg_val
                    if delta < 0 then
                        delta = -delta
                    end
                    local idx = map_row + x
                    if delta > ink_delta then
                        data[idx] = 1
                        ink = ink + 1
                    end
                    if val <= border_luminance_max then
                        border[idx] = 1
                        border_cells = border_cells + 1
                    end
                end
            end
        else
            for y = 0, h - 1 do
                local src_y = y * step
                local row_offset = src_y * stride
                local map_row = y * w
                for x = 0, w - 1 do
                    local val = raw_data[row_offset + x * step]
                    local delta = val - bg_val
                    if delta < 0 then
                        delta = -delta
                    end
                    if delta > ink_delta then
                        data[map_row + x] = 1
                        ink = ink + 1
                    end
                end
            end
        end
    else
        -- Colour-aware path (Western colour comics / colour displays)
        background_r, background_g, background_b = estimateBackground(sample, src_w, src_h, step)
        background = luminance(background_r, background_g, background_b)

        if border then
            for y = 0, h - 1 do
                local src_y = y * step
                local row = y * w
                for x = 0, w - 1 do
                    local r, g, b = sample(x * step, src_y)
                    local dr = r - background_r
                    if dr < 0 then
                        dr = -dr
                    end
                    local dg = g - background_g
                    if dg < 0 then
                        dg = -dg
                    end
                    local db = b - background_b
                    if db < 0 then
                        db = -db
                    end
                    local delta = dr > dg and (dr > db and dr or db) or (dg > db and dg or db)
                    local idx = row + x
                    if delta > ink_delta then
                        data[idx] = 1
                        ink = ink + 1
                    end
                    if luminance(r, g, b) <= border_luminance_max then
                        border[idx] = 1
                        border_cells = border_cells + 1
                    end
                end
            end
        else
            for y = 0, h - 1 do
                local src_y = y * step
                local row = y * w
                for x = 0, w - 1 do
                    local r, g, b = sample(x * step, src_y)
                    local dr = r - background_r
                    if dr < 0 then
                        dr = -dr
                    end
                    local dg = g - background_g
                    if dg < 0 then
                        dg = -dg
                    end
                    local db = b - background_b
                    if db < 0 then
                        db = -db
                    end
                    local delta = dr > dg and (dr > db and dr or db) or (dg > db and dg or db)
                    if delta > ink_delta then
                        data[row + x] = 1
                        ink = ink + 1
                    end
                end
            end
        end
    end

    return {
        w = w,
        h = h,
        data = data,
        border = border,
        ink = ink,
        native_w = native_w,
        native_h = native_h,
        scale_x = native_w / w,
        scale_y = native_h / h,
        background = background,
        background_color = { r = background_r, g = background_g, b = background_b },
        inverted = background < 128,
    },
        border_cells,
        background_r,
        background_g,
        background_b
end

--- Build a page's binary ink map.
---
--- @param document table KOReader document object.
--- @param page number Document page number.
--- @param settings PPSettings Plugin settings.
--- @return PPPageMap|nil map Ink map, or nil when the page cannot be mapped.
--- @return string|nil reason Failure reason when `map` is nil.
function PageBitmap.build(document, page, settings)
    settings = settings or Settings.defaults

    local blocked = PageBitmap.getBlockReason(document)
    if blocked then
        return nil, blocked
    end

    local stop = Timing.span("page bitmap")
    local target_width = settings.segment_target_width or Settings.defaults.segment_target_width

    local map, reason, owned
    local ok, err = pcall(function()
        local bb, native = renderSmall(document, page, target_width)
        if not bb then
            reason = "render failed"
            return
        end

        local work, is_rgb
        work, owned, is_rgb = normalizeForSampling(bb)
        local src_w, src_h = work.w, work.h
        local sample, kind, raw_data, stride = makeSampler(work)

        -- Guard against a render path that ignored our zoom: subsample instead
        -- of scanning a full-resolution buffer cell by cell.
        local step = math.max(1, math.floor(src_w / target_width))
        local w = math.floor(src_w / step)
        local h = math.floor(src_h / step)
        if w < 16 or h < 16 then
            reason = "page too small to map"
            return
        end

        local border_cells, bg_r, bg_g, bg_b
        map, border_cells, bg_r, bg_g, bg_b =
            buildMapFromBuffer(work, sample, kind, raw_data, stride, is_rgb, native.w, native.h, settings, step, w, h)
        local free_mb = Timing.enabled and Timing.freeMB() or nil
        stop(
            string.format(
                "%dx%d %s bg=%d,%d,%d%s ink=%d%%%s%s",
                w,
                h,
                kind,
                bg_r,
                bg_g,
                bg_b,
                map.inverted and " inverted" or "",
                math.floor(map.ink * 100 / (w * h)),
                map.border and string.format(" border=%d%%", math.floor(border_cells * 100 / (w * h))) or "",
                free_mb and (" free=" .. free_mb .. "MB") or ""
            )
        )
    end)

    -- The normalized copy, if one was made, is ours; the rendered tile is not.
    if owned then
        pcall(owned.free, owned)
    end

    if not ok then
        logger.warn("[Panels+] page bitmap failed:", err)
        return nil, "error"
    end
    return map, reason
end

--- Build a binary ink map from an already-decoded image.
---
--- Reflow documents (EPUB/KEPUB/MOBI) cannot be mapped through `renderPage()`: the
--- returned page geometry belongs to the laid-out text flow, not to an image
--- embedded in it. KOReader can, however, give us that image's BlitBuffer
--- directly. Keeping this path here means it uses exactly the same
--- background-relative panel detector as fixed-layout pages.
---
--- @param bb table KOReader BlitBuffer returned by `getImageFromPosition()`.
--- @param settings PPSettings Plugin settings.
--- @return PPPageMap|nil map Ink map, or nil when the image cannot be mapped.
--- @return string|nil reason Failure reason when `map` is nil.
function PageBitmap.buildFromBlitbuffer(bb, settings)
    settings = settings or Settings.defaults
    if not bb then
        return nil, "no image"
    end

    local stop = Timing.span("embedded image bitmap")
    local target_width = settings.segment_target_width or Settings.defaults.segment_target_width
    -- Panel crops are taken from the retained full-resolution source, so map
    -- cells must convert back into this original image coordinate space.
    local native_w, native_h = bb.w, bb.h

    local map, reason, owned, raster_owned
    local ok, err = pcall(function()
        local raster, resampled
        raster, raster_owned, resampled = makeEmbeddedDetectionRaster(bb, target_width)
        if not raster then
            reason = "image has no dimensions"
            return
        end
        local work, is_rgb
        work, owned, is_rgb = normalizeForSampling(raster)
        local src_w, src_h = work.w, work.h
        local sample, kind, raw_data, stride = makeSampler(work)
        -- With enough headroom, the raster is explicitly resampled rather
        -- than sparsely sampled. This matches the fixed-page render path and
        -- gives connected-component detection the same line/gutter topology.
        -- Under memory pressure, keep the old bounded sampler: it adds no
        -- large buffers and lets a low-end device retain panel navigation.
        local step = resampled and 1 or embeddedSparseStep(src_w, src_h, target_width)
        local w = math.floor(src_w / step)
        local h = math.floor(src_h / step)
        if w < 16 or h < 16 then
            reason = "image too small to map"
            return
        end

        local border_cells, bg_r, bg_g, bg_b
        map, border_cells, bg_r, bg_g, bg_b =
            buildMapFromBuffer(work, sample, kind, raw_data, stride, is_rgb, native_w, native_h, settings, step, w, h)
        stop(
            string.format(
                "%dx%d %s bg=%d,%d,%d%s ink=%d%%%s",
                w,
                h,
                kind,
                bg_r,
                bg_g,
                bg_b,
                map.inverted and " inverted" or "",
                math.floor(map.ink * 100 / (w * h)),
                map.border and string.format(" border=%d%%", math.floor(border_cells * 100 / (w * h))) or ""
            )
        )
    end)

    if owned then
        pcall(owned.free, owned)
    end
    if raster_owned then
        pcall(raster_owned.free, raster_owned)
    end
    if not Memory.hasHeadroom(EMBEDDED_RESIZE_MIN_FREE_BYTES) then
        collectgarbage("collect")
    end
    if not ok then
        logger.warn("[Panels+] embedded image bitmap failed:", err)
        return nil, "error"
    end
    return map, reason
end

-- Exposed for the small, render-free colour-map specs.
PageBitmap._estimateBackground = estimateBackground
PageBitmap._estimateBackgroundGrey = estimateBackgroundGrey
PageBitmap._colourDistance = colourDistance
PageBitmap._luminance = luminance
PageBitmap._detectionRasterSize = detectionRasterSize
PageBitmap._embeddedResizeWorkingSetBytes = embeddedResizeWorkingSetBytes
PageBitmap._hasEmbeddedResizeHeadroom = hasEmbeddedResizeHeadroom
PageBitmap._embeddedSparseStep = embeddedSparseStep
PageBitmap._makeEmbeddedDetectionRaster = makeEmbeddedDetectionRaster

return PageBitmap
