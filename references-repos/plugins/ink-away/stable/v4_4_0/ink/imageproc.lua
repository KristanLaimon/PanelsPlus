--[[
Pixel work on decoded pictures: RGBA conversion for export, background removal,
rotating and flipping, and fitting a picture onto a page.
]]

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local Fill = require("ink/fill")

local WHITE = Blitbuffer.COLOR_WHITE

local ImageProc = {}

-- Worked out once: are a BBRGB32 buffer's bytes laid out R,G,B,A (so they can be
-- copied straight into an RGBA export buffer) or B,G,R,A (so R and B must swap)?
local rgb32_is_rgba = nil
local function rgb32IsRGBA()
    if rgb32_is_rgba ~= nil then return rgb32_is_rgba end
    rgb32_is_rgba = true
    pcall(function()
        local probe = Blitbuffer.new(1, 1, Blitbuffer.TYPE_BBRGB32)
        probe:setPixel(0, 0, Blitbuffer.ColorRGB32(10, 20, 30, 40))
        local p = ffi.cast("uint8_t*", probe.data)
        rgb32_is_rgba = (p[0] == 10 and p[1] == 20 and p[2] == 30)
        probe:free()
    end)
    return rgb32_is_rgba
end

-- Convert a canvas-sized BBRGB32 into a packed RGBA FFI buffer, one memcpy per
-- row (R and B are swapped back where the layout is B,G,R,A). Returns buf or nil.
local function bbToRGBA(bb, W, H)
    if not bb then return nil end
    -- A grey or 16-bit screen gives a buffer that is not 4 bytes a pixel; copying
    -- it as if it were reads several rows into one and shows the page squeezed
    -- and repeated. Draw it onto an RGB32 page first.
    local own
    if bb:getType() ~= Blitbuffer.TYPE_BBRGB32 then
        local ok, conv = pcall(function()
            local c = Blitbuffer.new(bb:getWidth(), bb:getHeight(), Blitbuffer.TYPE_BBRGB32)
            c:fill(WHITE)
            c:blitFrom(bb, 0, 0, 0, 0, bb:getWidth(), bb:getHeight())
            return c
        end)
        if not ok or not conv then return nil end
        bb, own = conv, conv
    end
    local buf = ffi.new("uint8_t[?]", W * H * 4)
    local ok = pcall(function()
        local src = ffi.cast("uint8_t*", bb.data)
        local stride = bb.stride or (W * 4)
        for y = 0, H - 1 do ffi.copy(buf + y * W * 4, src + y * stride, W * 4) end
    end)
    if own then own:free() end
    if not ok then return nil end
    if not rgb32IsRGBA() then
        for i = 0, W * H - 1 do local o = i * 4; buf[o], buf[o + 2] = buf[o + 2], buf[o] end
    end
    return buf
end

-- Remove the background from a decoded picture, for a transparent PNG. A scanline
-- flood from the borders takes in pixels close to the background colour (the mean
-- of the four borders), and only those are made transparent, so parts of the
-- subject not joined to the edge stay solid even where they match the background
-- (a global threshold would fade them). The tolerance adapts to how noisy the
-- border is, and the mask edge is softened. Works on any solid background colour;
-- it needs a background that reaches the edges and differs from the subject.
-- `src` is a BBRGB32; returns a packed RGBA buffer for ffi/png.encodeToFile, or nil.
local function bgRemovedRGBA(src)
    if not src then return nil end
    local w, h = src:getWidth(), src:getHeight()
    if w < 3 or h < 3 then return nil end
    local out = ffi.new("uint8_t[?]", w * h * 4)
    local ok = pcall(function()
        local rgba = rgb32IsRGBA()
        local ri = rgba and 0 or 2      -- byte offset of R (B when the panel is BGRA)
        local bi = rgba and 2 or 0      -- byte offset of B; G is always 1, alpha 3
        local sp = ffi.cast("uint8_t*", src.data)
        local ss = src.stride or (w * 4)
        -- background reference colour: the mean of the four borders
        local sr, sg, sb, cnt = 0, 0, 0, 0
        local function accum(o) sr = sr + sp[o + ri]; sg = sg + sp[o + 1]; sb = sb + sp[o + bi]; cnt = cnt + 1 end
        for x = 0, w - 1 do accum(x * 4); accum((h - 1) * ss + x * 4) end
        for y = 0, h - 1 do accum(y * ss); accum(y * ss + (w - 1) * 4) end
        local br, bgc, bbc = sr / cnt, sg / cnt, sb / cnt
        -- colour distance (Manhattan) from that reference
        local function distO(o)
            local dr = sp[o + ri] - br; if dr < 0 then dr = -dr end
            local dg = sp[o + 1] - bgc; if dg < 0 then dg = -dg end
            local db = sp[o + bi] - bbc; if db < 0 then db = -db end
            return dr + dg + db
        end
        -- adapt the tolerance to how varied the border is (a clean border gets a
        -- tight tolerance so little of the subject is caught; a noisy one gets more)
        local mad, m2 = 0, 0
        for x = 0, w - 1 do mad = mad + distO(x * 4) + distO((h - 1) * ss + x * 4); m2 = m2 + 2 end
        for y = 0, h - 1 do mad = mad + distO(y * ss) + distO(y * ss + (w - 1) * 4); m2 = m2 + 2 end
        mad = mad / math.max(1, m2)
        local tol = math.max(80, math.min(260, 2.5 * mad + 60))
        local feather = tol * 0.5      -- reached pixels this close to the tol edge fade in
        local core = tol - feather
        -- flood from the borders through pixels within tol of the bg
        local seen = ffi.new("uint8_t[?]", w * h)   -- 0 unknown, 1 background
        local function free_at(x, y) return seen[y * w + x] == 0 and distO(y * ss + x * 4) <= tol end
        local seeds = {}
        local function seed(x, y)
            if free_at(x, y) then seeds[#seeds + 1] = x; seeds[#seeds + 1] = y end
        end
        for x = 0, w - 1 do seed(x, 0); seed(x, h - 1) end
        for y = 0, h - 1 do seed(0, y); seed(w - 1, y) end
        Fill.scan(w, h, seeds, free_at, function(xl, xr, y)
            local row = y * w
            for xx = xl, xr do seen[row + xx] = 1 end
        end)
        -- build RGBA: subject opaque; background transparent, fading in near the edge
        local i = 0
        for y = 0, h - 1 do
            local so, row = y * ss, y * w
            for x = 0, w - 1 do
                local o = so + x * 4
                local a
                if seen[row + x] == 1 then
                    local d = distO(o)
                    if d <= core then a = 0
                    else a = math.floor((d - core) / feather * 255 + 0.5); if a > 255 then a = 255 end end
                else
                    a = 255
                end
                out[i] = sp[o + ri]; out[i + 1] = sp[o + 1]; out[i + 2] = sp[o + bi]; out[i + 3] = a
                i = i + 4
            end
        end
    end)
    if not ok then return nil end
    return out
end

-- Fit a source BlitBuffer inside a W x H page keeping its aspect, centre it on a
-- white RGB32 page, and free the source. Returns the new page BlitBuffer.
local function fitIntoCanvasBB(img, W, H)
    local iw, ih = img:getWidth(), img:getHeight()
    local scale = math.min(W / iw, H / ih)
    local dw = math.max(1, math.floor(iw * scale + 0.5))
    local dh = math.max(1, math.floor(ih * scale + 0.5))
    local fitted = img
    if dw ~= iw or dh ~= ih then fitted = RenderImage:scaleBlitBuffer(img, dw, dh, false) end
    local bg = Blitbuffer.new(W, H, Blitbuffer.TYPE_BBRGB32)
    bg:fill(WHITE)
    bg:blitFrom(fitted, math.floor((W - dw) / 2), math.floor((H - dh) / 2), 0, 0, dw, dh)
    if fitted ~= img and fitted.free then fitted:free() end
    if img.free then img:free() end
    return bg
end

-- Build a copy of `src` with the flips and any rotation baked in. A quarter turn
-- is an exact pixel permutation (it swaps the dimensions); any other angle is a
-- nearest-neighbour resample into the rotated bounding box, with transparent
-- corners. Returns the new buffer, or nil if the pixels cannot be read.
local function resampleOriented(src, angleDeg, fh, fv)
    local sw, sh = src:getWidth(), src:getHeight()
    local a = angleDeg % 360
    if a == 0 or a == 90 or a == 180 or a == 270 then
        local quarter = (a == 90 or a == 270)
        local dw = quarter and sh or sw
        local dh = quarter and sw or sh
        local dst = Blitbuffer.new(dw, dh, Blitbuffer.TYPE_BBRGB32)
        pcall(function() ffi.fill(dst.data, dst.stride * dst:getHeight(), 0) end)   -- true transparent (colour fill sets alpha opaque)
        local ok = pcall(function()
            for sy = 0, sh - 1 do
                local yy = fv and (sh - 1 - sy) or sy
                for sx = 0, sw - 1 do
                    local xx = fh and (sw - 1 - sx) or sx
                    local dx, dy
                    if a == 90 then dx, dy = sh - 1 - yy, xx
                    elseif a == 180 then dx, dy = sw - 1 - xx, sh - 1 - yy
                    elseif a == 270 then dx, dy = yy, sw - 1 - xx
                    else dx, dy = xx, yy end
                    dst:setPixel(dx, dy, src:getPixel(sx, sy))
                end
            end
        end)
        if not ok then if dst.free then dst:free() end; return nil end
        return dst
    end
    local ar = math.rad(a)
    local cosA, sinA = math.cos(ar), math.sin(ar)
    local bw = math.max(1, math.ceil(math.abs(sw * cosA) + math.abs(sh * sinA)))
    local bh = math.max(1, math.ceil(math.abs(sw * sinA) + math.abs(sh * cosA)))
    local dst = Blitbuffer.new(bw, bh, Blitbuffer.TYPE_BBRGB32)
    pcall(function() ffi.fill(dst.data, dst.stride * dst:getHeight(), 0) end)   -- true transparent (colour fill sets alpha opaque)
    local cxs, cys, cxd, cyd = sw / 2, sh / 2, bw / 2, bh / 2
    local ok = pcall(function()
        for dy = 0, bh - 1 do
            local ry = dy + 0.5 - cyd
            for dx = 0, bw - 1 do
                local rx = dx + 0.5 - cxd
                local ux = rx * cosA + ry * sinA + cxs   -- inverse rotate to source
                local uy = -rx * sinA + ry * cosA + cys
                if fh then ux = sw - ux end
                if fv then uy = sh - uy end
                local sxi = math.floor(ux)
                local syi = math.floor(uy)
                if sxi >= 0 and sxi < sw and syi >= 0 and syi < sh then
                    dst:setPixel(dx, dy, src:getPixel(sxi, syi))
                end
            end
        end
    end)
    if not ok then if dst.free then dst:free() end; return nil end
    return dst
end

ImageProc.bbToRGBA = bbToRGBA
ImageProc.bgRemovedRGBA = bgRemovedRGBA
ImageProc.fitIntoCanvasBB = fitIntoCanvasBB
ImageProc.resampleOriented = resampleOriented

return ImageProc
