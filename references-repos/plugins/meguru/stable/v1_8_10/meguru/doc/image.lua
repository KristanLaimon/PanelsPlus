local Blitbuffer = require("ffi/blitbuffer")
local DrawContext = require("ffi/drawcontext")
local RenderImage = require("ui/renderimage")
local logger = require("logger")
local util = require("util")

local Settings = require("meguru/settings")

-- Guarded: no binding means RenderImage fallback, not a failed load.
local Mupdf
do
    local ok, mupdf = pcall(require, "ffi/mupdf")
    if ok and mupdf and mupdf.openDocumentFromText and mupdf.openDocument then
        Mupdf = mupdf
    end
end

local Image = {}

local function bbBytesPerPixel(bb_type)
    if bb_type == Blitbuffer.TYPE_BB8 then
        return 1
    elseif bb_type == Blitbuffer.TYPE_BB8A then
        return 2
    elseif bb_type == Blitbuffer.TYPE_BBRGB24 then
        return 3
    elseif bb_type == Blitbuffer.TYPE_BBRGB32 then
        return 4
    end
    return nil
end

-- The screen's own answers, taken once at plugin init. Android answers both
-- through JNI, and the cover browser opens a document inside a fork, where a
-- JNI call aborts the process (koreader#14628 fixed only the colour one).
local screen_color, screen_eink

-- Called from plugin init: the parent is the one place these may be asked.
function Image.rememberScreen()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" then
        return
    end
    local scr = Device.screen
    if scr and type(scr.isColorScreen) == "function" then
        local ok_color, value = pcall(scr.isColorScreen, scr)
        screen_color = ok_color and value == true or false
    end
    if type(Device.hasEinkScreen) == "function" then
        local ok_eink, value = pcall(Device.hasEinkScreen, Device)
        screen_eink = ok_eink and value == true or false
    end
end

function Image.einkScreen()
    return screen_eink == true
end

-- Paper: light on every channel and near-neutral. The bound is the caller's,
-- because the two callers want different leans: the crop trims at 170, night
-- mode inverts the letterbox only at 200. The spread is one definition: cream
-- paper is in, a colour is out by one dark channel or by a spread no paper has.
function Image.isPaperColor(r, g, b, min_channel)
    local lo = math.min(r, math.min(g, b))
    local hi = math.max(r, math.max(g, b))
    return lo >= min_channel and hi - lo <= 48
end

-- The reader's own colour row wins and is read live; only the screen's answer
-- is a cache (see rememberScreen). A failure costs colour, never a crash.
function Image.colorEnabled()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" then
        return false
    end
    local scr = Device.screen
    -- An 8-bit framebuffer would throw the colour away, whichever answer won.
    if not scr or scr.fb_bpp == 8 then
        return false
    end
    local g = rawget(_G, "G_reader_settings")
    if g and type(g.has) == "function" and g:has("color_rendering") then
        return g:isTrue("color_rendering")
    end
    return screen_color == true
end

-- Area, not longest edge: a tall strip is not punished more than a wide scan.
local function cappedDim(w, h, budget)
    if not w or not h or w < 1 or h < 1 then
        return w, h
    end
    local area = w * h
    if area <= budget then
        return w, h
    end
    local s = math.sqrt(budget / area)
    return math.max(1, math.floor(w * s + 0.5)),
           math.max(1, math.floor(h * s + 0.5))
end

-- One render may take a sixteenth of the free RAM, counted in bytes: four per
-- colour pixel and one per grayscale, so colour gets a quarter of the pixels.
local function renderBudget()
    local budget = Settings.get("max_native_pixels")
    local free = util.calcFreeMem()
    if free then
        local bytes = Image.colorEnabled() and 4 or 1
        local by_memory = math.max(1, math.floor(free / (16 * bytes)))
        if by_memory < budget then
            budget = by_memory
        end
    end
    return budget
end

-- Distinct from nil so callers refuse it rather than retry a fatal decode.
local DECODE_TOO_LARGE = {}

-- Bounds the 3-4 bytes/px transient of a lossless decode: ~60-80 MB here.
local MAX_LOSSLESS_NATIVE_PIXELS = 20 * 1024 * 1024 -- 20 Mpx
local JPEG_MAGIC = "\255\216\255" -- FF D8 FF

local function isJpegBytes(data)
    return type(data) == "string" and #data >= 3 and data:sub(1, 3) == JPEG_MAGIC
end

local PNG_MAGIC = "\137PNG\r\n\26\n" -- 89 50 4E 47 0D 0A 1A 0A

-- `magic` is required; nil raises a nameless "missing file type" exception.
-- Only libwrap-mupdf's listed types are claimed; image/webp falls through.
local function documentMagic(data)
    if type(data) ~= "string" or #data < 12 then
        return nil
    end
    if data:sub(1, 3) == JPEG_MAGIC then
        return "image/jpeg"
    end
    if data:sub(1, 8) == PNG_MAGIC then
        return "image/png"
    end
    if data:sub(1, 4) == "GIF8" then
        return "image/gif"
    end
    if data:sub(1, 2) == "BM" then
        return "image/bmp"
    end
    local tiff = data:sub(1, 4)
    if tiff == "II*\0" or tiff == "MM\0*" then
        return "image/tiff"
    end
    return nil
end

local function u16be(s, i)
    local a, b = s:byte(i, i + 1)
    return a * 256 + b
end

local function u16le(s, i)
    local a, b = s:byte(i, i + 1)
    return a + b * 256
end

local function u32be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a * 16777216 + b * 65536 + c * 256 + d
end

local function i32le(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    local v = a + b * 256 + c * 65536 + d * 16777216
    if v >= 2147483648 then
        v = v - 4294967296
    end
    return v
end

-- JPEG: skip segments to the frame header, which carries the pixel size.
local function jpegPixelSize(data)
    local i = 3
    while i + 1 <= #data do
        if data:byte(i) ~= 0xFF then
            return nil
        end
        local marker = data:byte(i + 1)
        if marker == 0xFF then
            i = i + 1
        elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9) then
            i = i + 2
        elseif marker == 0xDA then
            return nil
        else
            if i + 3 > #data then
                return nil
            end
            local len = u16be(data, i + 2)
            if marker >= 0xC0 and marker <= 0xCF
                and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                if i + 8 > #data then
                    return nil
                end
                local h = u16be(data, i + 5)
                local w = u16be(data, i + 7)
                if w > 0 and h > 0 then
                    return { w = w, h = h }
                end
                return nil
            end
            if len < 2 then
                return nil
            end
            i = i + 2 + len
        end
    end
    return nil
end

local function pngPixelSize(data)
    if #data < 24 or data:sub(13, 16) ~= "IHDR" then
        return nil
    end
    local w, h = u32be(data, 17), u32be(data, 21)
    if w > 0 and h > 0 then
        return { w = w, h = h }
    end
    return nil
end

local function gifPixelSize(data)
    if #data < 10 then
        return nil
    end
    local w, h = u16le(data, 7), u16le(data, 9)
    if w > 0 and h > 0 then
        return { w = w, h = h }
    end
    return nil
end

local function bmpPixelSize(data)
    if #data < 26 then
        return nil
    end
    local dib = u32be(data, 15)
    local w, h
    if dib == 12 then
        w, h = u16le(data, 19), u16le(data, 21)
    else
        w, h = i32le(data, 19), math.abs(i32le(data, 23))
    end
    if w and h and w > 0 and h > 0 then
        return { w = w, h = h }
    end
    return nil
end

-- WebP: the canvas is not stored the same way in all three chunk types.
local function webpPixelSize(data)
    if #data < 16 or data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WEBP" then
        return nil
    end
    local tag = data:sub(13, 16)
    if tag == "VP8X" and #data >= 30 then
        local w = 1 + data:byte(25) + data:byte(26) * 256 + data:byte(27) * 65536
        local h = 1 + data:byte(28) + data:byte(29) * 256 + data:byte(30) * 65536
        return { w = w, h = h }
    elseif tag == "VP8L" and #data >= 26 and data:byte(21) == 0x2F then
        local b1, b2, b3, b4 = data:byte(22, 25)
        local bits = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        local w = bits % 16384 + 1
        local h = math.floor(bits / 16384) % 16384 + 1
        return { w = w, h = h }
    elseif tag == "VP8 " and #data >= 30 and data:sub(24, 26) == "\157\001\042" then
        local w = u16le(data, 27) % 16384
        local h = u16le(data, 29) % 16384
        if w > 0 and h > 0 then
            return { w = w, h = h }
        end
    end
    return nil
end

-- The pixels an image holds, from its own header. MuPDF sizes an image page
-- by its stated density, which can be a fraction of what the file contains.
function Image.pixelSize(data)
    if type(data) ~= "string" or #data < 10 then
        return nil
    end
    local parse
    if data:sub(1, 3) == JPEG_MAGIC then
        parse = jpegPixelSize
    elseif data:sub(1, 8) == PNG_MAGIC then
        parse = pngPixelSize
    elseif data:sub(1, 4) == "GIF8" then
        parse = gifPixelSize
    elseif data:sub(1, 2) == "BM" then
        parse = bmpPixelSize
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        parse = webpPixelSize
    end
    if not parse then
        return nil
    end
    -- A malformed header costs the density fallback, never the page.
    local ok, size = pcall(parse, data)
    return ok and size or nil
end

-- A page's render may grow to the pixels its image really holds, never below
-- the density-derived size and never past the decode budget.
local function renderSize(fw, fh, source, budget)
    local cw, ch = cappedDim(fw, fh, budget)
    if not (source and source.w and source.h
        and source.w > 0 and source.h > 0) then
        return cw, ch
    end
    local ratio = math.sqrt((source.w * source.h) / (fw * fh))
    if ratio <= 1 then
        return cw, ch
    end
    -- Area, so an EXIF turn moves neither dimension nor scale.
    cw = math.max(1, math.floor(fw * ratio + 0.5))
    ch = math.max(1, math.floor(fh * ratio + 0.5))
    return cappedDim(cw, ch, budget)
end

-- Only the streamed path can refuse by size: it alone has the bytes to sniff.
local function renderMuPDFPage(doc, pageno, refuse_oversize, gamma, saturation,
                               fit_w, fit_h, source)
    local budget = renderBudget()
    local ok_page, page = pcall(doc.openPage, doc, pageno)
    local bb
    if ok_page and page then
        -- getSize is at zoom 1; a bare image measures in pixels, EXIF turn applied.
        local ok_size, pw, ph = pcall(page.getSize, page, DrawContext.new())
        if ok_size and pw and ph and pw > 0 and ph > 0 then
            local fw = math.max(1, math.floor(pw + 0.5))
            local fh = math.max(1, math.floor(ph + 0.5))
            if refuse_oversize and refuse_oversize(fw, fh) then
                page:close()
                return DECODE_TOO_LARGE
            end
            local cw, ch
            if fit_w and fit_h and fit_w > 0 and fit_h > 0 then
                -- Bound the draw itself: scaling afterwards holds the full render.
                local s = math.min(1, fit_w / fw, fit_h / fh)
                cw = math.max(1, math.floor(fw * s + 0.5))
                ch = math.max(1, math.floor(fh * s + 0.5))
                cw, ch = cappedDim(cw, ch, budget)
            else
                cw, ch = renderSize(fw, fh, source, budget)
            end
            if cw < 1 then cw = 1 end
            if ch < 1 then ch = 1 end
            local function draw(w, h)
                local dc = DrawContext.new()
                dc:setZoom(w / fw)
                if gamma and gamma ~= 1.0 then
                    dc:setGamma(gamma)
                end
                if saturation and saturation ~= 1.0 then
                    dc:setSaturation(saturation)
                end
                local ok_draw, rendered = pcall(page.draw_new, page,
                    dc, w, h, 0, 0)
                if ok_draw and rendered then
                    return rendered
                end
                logger.dbg("Meguru: MuPDF page render failed:",
                    tostring(rendered))
                return nil
            end
            bb = draw(cw, ch)
            if not bb and source and (cw > fw or ch > fh) then
                -- A failed source-sized render falls back to the density size.
                cw, ch = cappedDim(fw, fh, budget)
                logger.dbg(string.format(
                    "Meguru: page render retry at %dx%d after failure",
                    cw, ch))
                bb = draw(cw, ch)
            end
            if bb then
                logger.dbg(string.format(
                    "Meguru: MuPDF page render %dx%d -> %dx%d (budget %d px)",
                    fw, fh, cw, ch, budget))
            end
        else
            logger.dbg("Meguru: MuPDF page size lookup failed")
        end
        page:close()
    else
        logger.dbg("Meguru: MuPDF openPage failed:", tostring(page))
    end
    return bb
end

-- MuPDF decimates an oversized JPEG while decoding; nothing full-res is held.
local function decodeNativeMupdf(data, gamma, saturation, fit_w, fit_h)
    if not Mupdf then
        return nil
    end
    local magic = documentMagic(data)
    if not magic then
        return nil
    end
    local ok_doc, doc = pcall(Mupdf.openDocumentFromText, data, magic)
    if not ok_doc or not doc then
        logger.dbg("Meguru: MuPDF cannot open page bytes:", tostring(doc))
        return nil
    end
    if doc.setColorRendering then
        doc:setColorRendering(Image.colorEnabled())
    end
    local source = Image.pixelSize(data)
    -- The JPEG sniff runs only on the streamed bytes; a huge JPEG is exempt.
    local res = renderMuPDFPage(doc, 1, function(fw, fh)
        local pixels = source and source.w and source.h
            and source.w * source.h or fw * fh
        return not isJpegBytes(data) and pixels > MAX_LOSSLESS_NATIVE_PIXELS
    end, gamma, saturation, fit_w, fit_h, source)
    doc:close()
    return res
end

-- Fallback path; the one place a full-resolution decode can still happen.
local function decodeNativeRenderImage(data)
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok or not bb then
        return nil
    end
    local budget = renderBudget()
    local w, h = bb:getWidth(), bb:getHeight()
    local cw, ch = cappedDim(w, h, budget)
    if cw == w and ch == h then
        return bb
    end
    logger.dbg(string.format(
        "Meguru: page decode %dx%d over the %dpx budget, downscaling to %dx%d",
        w, h, budget, cw, ch))
    -- free_orig_bb=false keeps ownership of `bb` unambiguously ours on every path.
    local ok2, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb, cw, ch, false)
    if not ok2 then
        logger.warn("Meguru: downscale to", cw, "x", ch,
            "failed, keeping native decode:", tostring(scaled))
        return bb
    end
    if scaled ~= bb then
        bb:free() -- a distinct bounded copy exists; release the full-res input
        return scaled
    end
    return bb
end

-- DECODE_TOO_LARGE skips the fallback, which would only repeat the same decode.
local function decodeNative(data, gamma, saturation, fit_w, fit_h)
    if Mupdf then
        local res = decodeNativeMupdf(data, gamma, saturation, fit_w, fit_h)
        if res == DECODE_TOO_LARGE then
            return DECODE_TOO_LARGE
        end
        if res then
            return res
        end
    end
    return decodeNativeRenderImage(data)
end

-- `planes` are {A,B,C} half-planes: inside is A*x+B*y+C <= 0.
local function maskToQuad(bb, planes, nx, ny, nw, nh, tw, th)
    if not (planes and #planes > 0) or tw < 1 or th < 1 then
        return
    end
    local EPS = 1e-9
    local mapped = {}
    for i = 1, #planes do
        local plane = planes[i]
        mapped[i] = {
            A = plane.A * nw / tw,
            B = plane.B * nh / th,
            C = plane.A * nx + plane.B * ny + plane.C,
        }
    end
    local color = Blitbuffer.COLOR_WHITE

    local run_lo, run_hi, run_from
    local function flush(upto)
        if not run_lo or upto <= run_from then
            return
        end
        local rows = upto - run_from
        if run_hi < run_lo then
            bb:paintRect(0, run_from, tw, rows, color)
            return
        end
        if run_lo > 0 then
            bb:paintRect(0, run_from, run_lo, rows, color)
        end
        if run_hi < tw - 1 then
            bb:paintRect(run_hi + 1, run_from, tw - run_hi - 1, rows, color)
        end
    end

    for ty = 0, th - 1 do
        local lo, hi = 0, tw - 1
        local yc = ty + 0.5
        for i = 1, #mapped do
            local plane = mapped[i]
            local v = plane.B * yc + plane.C
            if plane.A > EPS then
                -- A*(tx + 0.5) + v <= 0, so the largest tx inside is this.
                local cand = math.floor(-v / plane.A - 0.5)
                if cand < hi then
                    hi = cand
                end
            elseif plane.A < -EPS then
                local cand = math.ceil(-v / plane.A - 0.5)
                if cand > lo then
                    lo = cand
                end
            elseif v > 0 then
                lo, hi = tw, -1 -- the whole row is outside this half-plane
                break
            end
        end
        if lo < 0 then lo = 0 end
        if hi > tw - 1 then hi = tw - 1 end
        if lo ~= run_lo or hi ~= run_hi then
            flush(ty)
            run_lo, run_hi, run_from = lo, hi, ty
        end
    end
    flush(th)
end

-- `src_w` is the caller's full-page width: regions are in that space.
function Image.renderRegion(doc, pageno, nx, ny, nw, nh, tw, th, planes, gamma, saturation,
                            src_w)
    if not Mupdf or not doc then
        return nil
    end
    if not (nx and ny and nw and nh) or nw < 1 or nh < 1 then
        return nil
    end
    if (tw ~= nil and tw < 1) or (th ~= nil and th < 1) then
        return nil
    end
    local ok_page, page = pcall(doc.openPage, doc, pageno)
    if not ok_page or not page then
        logger.dbg("Meguru: region render openPage failed:", tostring(page))
        return nil
    end
    local bb
    local ok_size, pw, ph = pcall(page.getSize, page, DrawContext.new())
    if ok_size and pw and ph and pw > 0 and ph > 0 then
        local fw = math.max(1, math.floor(pw + 0.5))
        local fh = math.max(1, math.floor(ph + 0.5))
        local budget
        -- The caller's space, not this budget: crops must not follow free RAM.
        local space_w
        if src_w and src_w > 0 then
            space_w = src_w
        else
            budget = renderBudget()
            space_w = cappedDim(fw, fh, budget)
        end
        if space_w and space_w > 0 then
            local f = fw / space_w -- caller's space -> the MuPDF page's own
            local out_w, out_h = tw, th
            if not (out_w and out_h) then
                out_w = math.max(1, math.floor(nw * f + 0.5))
                out_h = math.max(1, math.floor(nh * f + 0.5))
                budget = budget or renderBudget()
                out_w, out_h = cappedDim(out_w, out_h, budget)
            end
            local zoom = out_w / (nw * f)
            if zoom > 0 then
                local dc = DrawContext.new()
                dc:setZoom(zoom)
                if gamma and gamma ~= 1.0 then
                    dc:setGamma(gamma)
                end
                if saturation and saturation ~= 1.0 then
                    dc:setSaturation(saturation)
                end
                local ox = math.floor(zoom * nx * f + 0.5)
                local oy = math.floor(zoom * ny * f + 0.5)
                local ok_draw, rendered = pcall(page.draw_new, page, dc, out_w, out_h, ox, oy)
                if ok_draw and rendered then
                    bb = rendered
                    if planes then
                        local ok_mask, err = pcall(maskToQuad,
                            bb, planes, nx, ny, nw, nh, out_w, out_h)
                        if not ok_mask then
                            logger.warn("Meguru: panel crop mask failed:", tostring(err))
                        end
                    end
                else
                    logger.dbg("Meguru: region render failed:", tostring(rendered))
                end
            end
        end
    else
        logger.dbg("Meguru: region page size lookup failed")
    end
    page:close()
    return bb
end


-- `getInverse()` is honoured, so an inverted page scans as the reader sees it.
-- BB8A takes the darker of its two channels: a PNG's alpha is not a brightness.
-- One copy beats one ffi cast per read, across tens of thousands of reads.
local function rasterFor(bb)
    if not (bb and bb.getWidth and bb.getHeight) then
        return nil
    end
    local w = bb:getWidth()
    local h = bb:getHeight()
    if not w or not h or w < 2 or h < 2 then
        return nil
    end
    local bpp = bbBytesPerPixel(bb:getType())
    if not bpp then
        return nil
    end
    local inv = bb:getInverse() == true
    local data = Blitbuffer.tostring(bb)
    local stride = tonumber(bb.stride)
    if not stride or stride < w * bpp then
        stride = w * bpp
    end
    if #data < stride * h then
        stride = w * bpp
        if #data < stride * h then
            return nil
        end
    end
    local function luma(y, x)
        local off = y * stride + x * bpp
        local lum
        if bpp == 1 then
            lum = data:byte(off + 1)
        elseif bpp == 2 then
            local a = data:byte(off + 1)
            local b = data:byte(off + 2)
            lum = a < b and a or b
        else
            -- Rec.601 luminance (RGB_To_A), not the channel mean; they differ by up to 65.
            -- 255*16385 is exact in a double, so no precision is lost under Lua 5.1.
            local r = data:byte(off + 1)
            local g = data:byte(off + 2)
            local b = data:byte(off + 3)
            lum = math.floor((4898 * r + 9618 * g + 1869 * b) / 16384)
        end
        if inv then
            lum = 255 - lum
        end
        return lum
    end
    return { w = w, h = h, luma = luma }
end
Image.rasterFor = rasterFor

Image.DECODE_TOO_LARGE = DECODE_TOO_LARGE
-- Exported so document.lua's log line can quote the limit.
Image.MAX_LOSSLESS_NATIVE_PIXELS = MAX_LOSSLESS_NATIVE_PIXELS
Image.bytesPerPixel = bbBytesPerPixel
Image.maskToQuad = maskToQuad
-- document.lua needs the sniffed type; the sniffer lives here once.
Image.magicFor = documentMagic
Image.renderMupdfPage = renderMuPDFPage
Image.decode = decodeNative

return Image
