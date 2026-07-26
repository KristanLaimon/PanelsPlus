local Blitbuffer = require("ffi/blitbuffer")
local Document = require("document/document")
local Geom = require("ui/geometry")
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
--- @field inverted boolean Whether the page background is dark.

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
    local configurable = document.configurable
    if not configurable then
        return "no configurable"
    end
    if configurable.text_wrap == 1 then
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
    local rect = Geom:new{ x = 0, y = 0, w = native.w, h = native.h }
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

--- Build the fastest available luminance accessor for a blitbuffer.
---
--- 8bpp greyscale is the common case for manga, and reading its bytes directly
--- avoids a Lua object allocation per pixel. Everything else goes through the
--- generic blitbuffer API.
---
--- @param bb table Rendered blitbuffer.
--- @return fun(x:integer, y:integer):integer sample Luminance accessor.
--- @return string kind Accessor name, for timing logs.
local function makeSampler(bb)
    if bb:getType() == Blitbuffer.TYPE_BB8 then
        local ok, data = pcall(ffi.cast, "uint8_t *", bb.data)
        if ok and data ~= nil then
            local stride = tonumber(bb.stride)
            return function(x, y)
                return data[y * stride + x]
            end, "bb8"
        end
    end

    return function(x, y)
        return bb:getPixel(x, y):getColor8().a
    end, "generic"
end

--- Estimate the page background luminance from its outer border.
---
--- The border of a comic page is the page's own paper (or its inked backdrop),
--- never panel content, so its median luminance is a reliable background
--- reference for both normal and inverted artwork.
---
--- @param sample fun(x:integer, y:integer):integer Luminance accessor.
--- @param w integer Source width.
--- @param h integer Source height.
--- @return integer background Median border luminance (0-255).
local function estimateBackground(sample, w, h)
    local histogram = {}
    for value = 0, 255 do
        histogram[value] = 0
    end

    local ring = math.max(1, math.floor(math.min(w, h) * 0.01))
    local total = 0

    local function tally(x, y)
        local value = sample(x, y)
        histogram[value] = histogram[value] + 1
        total = total + 1
    end

    for offset = 0, ring - 1 do
        for x = 0, w - 1 do
            tally(x, offset)
            tally(x, h - 1 - offset)
        end
        for y = ring, h - 1 - ring do
            tally(offset, y)
            tally(w - 1 - offset, y)
        end
    end

    if total == 0 then
        return 255
    end

    local half, seen = total / 2, 0
    for value = 0, 255 do
        seen = seen + histogram[value]
        if seen >= half then
            return value
        end
    end
    return 255
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
    local ink_delta = settings.segment_ink_delta or Settings.defaults.segment_ink_delta

    local map, reason
    local ok, err = pcall(function()
        local bb, native = renderSmall(document, page, target_width)
        if not bb then
            reason = "render failed"
            return
        end

        local src_w, src_h = bb.w, bb.h
        local sample, kind = makeSampler(bb)

        -- Guard against a render path that ignored our zoom: subsample instead
        -- of scanning a full-resolution buffer cell by cell.
        local step = math.max(1, math.floor(src_w / target_width))
        local w = math.floor(src_w / step)
        local h = math.floor(src_h / step)
        if w < 16 or h < 16 then
            reason = "page too small to map"
            return
        end

        local background = estimateBackground(sample, src_w, src_h)
        local data = ffi.new("uint8_t[?]", w * h)
        local ink = 0

        for y = 0, h - 1 do
            local src_y = y * step
            local row = y * w
            for x = 0, w - 1 do
                local value = sample(x * step, src_y)
                local delta = value - background
                if delta < 0 then
                    delta = -delta
                end
                if delta > ink_delta then
                    data[row + x] = 1
                    ink = ink + 1
                end
            end
        end

        map = {
            w = w,
            h = h,
            data = data,
            ink = ink,
            native_w = native.w,
            native_h = native.h,
            scale_x = native.w / w,
            scale_y = native.h / h,
            background = background,
            inverted = background < 128,
        }
        stop(string.format("%dx%d %s bg=%d%s ink=%d%%",
            w, h, kind, background, map.inverted and " inverted" or "",
            math.floor(ink * 100 / (w * h))))
    end)

    if not ok then
        logger.warn("[Panels+] page bitmap failed:", err)
        return nil, "error"
    end
    return map, reason
end

return PageBitmap
