--[[
A drawing's cover for the Drawings shelf on Bookshelf (ink/drawingshelf.lua):
the drawing in one of twelve frames, from old regal ones to modern ones, each
in a few finishes:

  baroque    Gilded Baroque: shells and acanthus at the corners and middles,
             a laurel roll, pearls and egg-and-dart (gold, antique, silver gilt)
  louis      Louis XVI: a ribbon twist, water leaves and corner rosettes
  ripple     Dutch Ripple: rippled mouldings (ebony, tortoiseshell, walnut)
  victorian  Carved Victorian: carved wood with a gilt slip
  crafts     Arts and Crafts: oak rails and stiles, pegged at the joints
  deco       Art Deco: stepped lacquer with gold lines and sunburst fans
  museum     Museum Mat: a slim frame on a white mat with a bevelled cut
  floating   Floating Frame: the drawing raised on linen in a deep frame
  metal      Minimal Metal: a thin brushed metal frame
  painted    Painted Box: a flat frame in a satin colour
  canvas     Canvas Wrap: the drawing stretched round a canvas
  instant    Instant Photo: an instant photo card, its name written under it

The frames are not drawn here. They were rendered once, lit and carved, at
four times the size (tools/frames), and cut into pieces: four corners, a strip
for each half of each side whose carving and grain repeat exactly, and the
ornaments some frames have at each side's middle. Each finish is one small
JPEG of those pieces (ink/data/frames), and manifest.lua says where each piece
is. A cover takes one of two shapes, after Bookshelf's "True cover aspect"
setting. On, Bookshelf shows each cover in its own shape, so the frame hugs
the drawing, whatever its shape. Off (Bookshelf's default), every cover is
shown 2:3 and any other portrait cover would be stretched to it, so the cover
is 2:3 and the drawing fills the frame, trimmed evenly at its sides (never by
more than a quarter; past that, a thin mat takes the rest). Museum Mat keeps
its mat and Floating Frame its linen either way. The frame's pieces are
blitted round the edges, the strips repeated to fill each side. No pixel is worked out in Lua.

The drawing comes from the snapshot Ink Away keeps of it as it closes (see
DrawingShelf.takeSnapshot), never from its strokes.
]]

local Storage = require("ink/storage")
local _ = require("ink/l10n")

local FrameCover = {}

-- The cover's width in pixels. Its height follows the drawing's shape.
FrameCover.W = 480

-- The folder of the frames' pieces.
local function dataDir()
    local src = debug.getinfo(1, "S").source
    return ((src:match("^@(.*/)ink/")) or "./") .. "ink/data/frames/"
end
FrameCover.dataDir = dataDir

-- The manifest: { cover_w, frames = { { key, kind, ... } } }, read once.
local manifest, byKey
local function load()
    if manifest then return manifest end
    local f = loadfile(dataDir() .. "manifest.lua")
    local ok, m = false, nil
    if f then
        setfenv(f, {})
        ok, m = pcall(f)
    end
    manifest = (ok and type(m) == "table" and type(m.frames) == "table") and m or { frames = {} }
    byKey = {}
    for _, fr in ipairs(manifest.frames) do byKey[fr.key] = fr end
    return manifest
end

-- The frames, in the order they are offered.
function FrameCover.frames()
    local out = {}
    for i, fr in ipairs(load().frames) do out[i] = fr.key end
    return out
end

-- Frame `key`'s entry in the manifest, or nil.
function FrameCover.frame(key)
    load()
    return byKey[key]
end

-- The finishes of frame `key`, in order.
function FrameCover.options(key)
    local fr = FrameCover.frame(key)
    return fr and fr.options or {}
end

-- The frames' names, as the reader sees them.
function FrameCover.names()
    return { baroque = _("Gilded Baroque"), louis = _("Louis XVI"), ripple = _("Dutch Ripple"),
        victorian = _("Carved Victorian"), crafts = _("Arts and Crafts"), deco = _("Art Deco"),
        museum = _("Museum Mat"), floating = _("Floating Frame"), metal = _("Minimal Metal"),
        painted = _("Painted Box"), canvas = _("Canvas Wrap"), instant = _("Instant Photo") }
end

-- The name of finish `opt` of frame `key`.
function FrameCover.optionName(key, opt)
    local n = {
        gold = _("Gold"), antique = _("Antique gold"), white = _("White and gold"), ebony = _("Ebony"),
        tortoise = _("Tortoiseshell"), walnut = _("Walnut"), mahogany = _("Mahogany"), ebonised = _("Ebonised"),
        light = _("Light oak"), fumed = _("Fumed oak"), cherry = _("Cherry"), black = _("Black"),
        ivory = _("Ivory and silver"), emerald = _("Emerald and gold"), oak = _("Oak"), brass = _("Brass"),
        red = _("Red"), mustard = _("Mustard"), blue = _("Blue"), sage = _("Sage"), mint = _("Mint"),
        wrap = _("Picture on the sides"),
    }
    if key == "baroque" and opt == "silver" then return _("Silver gilt") end
    if key == "deco" and opt == "black" then return _("Black and gold") end
    if (key == "canvas" or key == "instant" or key == "museum" or key == "floating") and opt == "white" then
        return key == "canvas" and _("White sides") or _("White")
    end
    if key == "canvas" and opt == "black" then return _("Black sides") end
    if key == "louis" and opt == "silver" or key == "metal" and opt == "silver" then return _("Silver") end
    return n[opt] or opt
end

-- `key` and `opt` when they are a frame and one of its finishes; else that
-- frame's first finish, or nil for an unknown frame.
function FrameCover.lookOf(key, opt)
    local fr = FrameCover.frame(key)
    if not fr then return nil end
    for _, o in ipairs(fr.options) do if o == opt then return key, opt end end
    return key, fr.options[1]
end

------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------

-- A 2:3 cover's height, as Bookshelf shows covers by default.
FrameCover.H = math.floor(FrameCover.W * 1.5 + 0.5)

-- A cover's shapes: "true" (the drawing's own) and "fill" (2:3).
FrameCover.SHAPES = { "true", "fill" }

-- The drawing's shape is kept between these heights per width (Bookshelf
-- trims a cover taller than about 1.65 anyway).
FrameCover.MIN_ASPECT, FrameCover.MAX_ASPECT = 0.5, 1.65

-- At most this share of a drawing's width (or height) is trimmed to fill a
-- 2:3 frame; past it, a mat fills the rest.
FrameCover.MAX_TRIM = 0.25

local function aspectOf(pw, ph)
    local a = (pw and ph and pw > 0 and ph > 0) and ph / pw or 4 / 3
    return math.max(FrameCover.MIN_ASPECT, math.min(FrameCover.MAX_ASPECT, a))
end

-- Where things go on frame `fr`'s cover for a picture `pw` x `ph` in
-- `shape` ("true", or "fill" by default): the cover's width and height, the
-- opening inside the frame { x, y, w, h } and the box the picture fills in
-- it { x, y, w, h } (the picture is trimmed to it, see FrameCover.MAX_TRIM).
function FrameCover.layout(fr, pw, ph, shape)
    local W = FrameCover.W
    local a = aspectOf(pw, ph)
    local own = shape == "true"
    if fr.kind == "card" then
        local ww = W - fr.left - fr.right
        if own then
            local wh = math.floor(ww * a + 0.5)
            local pic = { x = fr.left, y = fr.top, w = ww, h = wh }
            return W, fr.top + wh + fr.bottom, pic, pic
        end
        local H = FrameCover.H
        local pic = { x = fr.left, y = fr.top, w = ww, h = H - fr.top - math.floor(fr.bottom * 0.75) }
        return W, H, pic, pic
    elseif fr.kind == "canvas" then
        local m, D = math.floor(W * 0.035 + 0.5), math.floor(W * 0.03 + 0.5)
        local fw = W - 2 * m - D
        local fh = own and math.floor(fw * a + 0.5) or FrameCover.H - 2 * m - D
        local pic = { x = m, y = m, w = fw, h = fh, depth = D }
        return W, fh + 2 * m + D, pic, pic
    end
    local t = fr.t
    local ow = W - 2 * t
    local m = math.floor(ow * (fr.margin or 0) + 0.5)   -- a mat or linen of the frame's own
    local H
    if own then
        H = math.floor((ow - 2 * m) * a + 0.5) + 2 * m + 2 * t
    else
        H = FrameCover.H
    end
    local open = { x = t, y = t, w = ow, h = H - 2 * t }
    local pic = { x = open.x + m, y = open.y + m, w = open.w - 2 * m, h = open.h - 2 * m }
    return W, H, open, pic
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

local function BB() return require("ffi/blitbuffer") end
local function scale(bb, w, h) return require("ui/renderimage"):scaleBlitBuffer(bb, w, h, false) end

-- Where picture `pic` (pw x ph) goes to fill box `r`: the part of it that
-- shows (sx, sy, sw, sh) and where, in `r` (dx, dy, dw, dh): trimmed evenly to
-- the box's shape, but never by more than FrameCover.MAX_TRIM, the rest left
-- to whatever is under it.
local function placement(pw, ph, r)
    local ra, pa = r.h / r.w, ph / pw
    local sw, sh = pw, ph
    if pa < ra then
        sw = math.max(pw * (1 - FrameCover.MAX_TRIM), ph / ra)
    else
        sh = math.max(ph * (1 - FrameCover.MAX_TRIM), pw * ra)
    end
    local k = math.min(r.w / sw, r.h / sh)
    local dw, dh = math.floor(sw * k + 0.5), math.floor(sh * k + 0.5)
    dw, dh = math.min(dw, r.w), math.min(dh, r.h)
    return math.floor((pw - sw) / 2), math.floor((ph - sh) / 2), math.floor(sw), math.floor(sh),
        r.x + math.floor((r.w - dw) / 2), r.y + math.floor((r.h - dh) / 2), dw, dh
end

-- Picture `pic` (a BlitBuffer, or nil for blank paper) in box `r` (see
-- placement). Returns the rect it covers.
local function paintPicture(out, pic, r)
    if not pic then
        out:paintRectRGB32(r.x, r.y, r.w, r.h, BB().ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
        return r
    end
    local sx, sy, sw, sh, dx, dy, dw, dh = placement(pic:getWidth(), pic:getHeight(), r)
    local s = scale(pic:viewport(sx, sy, sw, sh), dw, dh)
    out:blitFrom(s, dx, dy, 0, 0, dw, dh)
    s:free()
    return { x = dx, y = dy, w = dw, h = dh }
end

-- The frame's shadow on the drawing, inside the top and left of opening `r`
-- (the light comes from the top left), and a trace of it at the bottom and
-- right: `rows` rows fading from `strength`.
local function innerShadow(out, r, rows, strength)
    if not rows or rows <= 0 or not strength or strength <= 0 then return end
    for i = 0, rows - 1 do
        local a = strength * (1 - i / rows) ^ 2
        out:darkenRect(r.x, r.y + i, r.w, 1, a)
        out:darkenRect(r.x + i, r.y + i + 1, 1, r.h - i - 1, a)
        if i < 2 then
            out:darkenRect(r.x, r.y + r.h - 1 - i, r.w, 1, a * 0.25)
            out:darkenRect(r.x + r.w - 1 - i, r.y, 1, r.h, a * 0.25)
        end
    end
end

-- Fill rect `r` with tile `bb` repeated.
local function tileFill(out, bb, r)
    local tw, th = bb:getWidth(), bb:getHeight()
    for y = r.y, r.y + r.h - 1, th do
        for x = r.x, r.x + r.w - 1, tw do
            out:blitFrom(bb, x, y, 0, 0, math.min(tw, r.x + r.w - x), math.min(th, r.y + r.h - y))
        end
    end
end

-- The mat's bevelled cut round picture box `r`: its white core, the top and
-- left faces a little in shade (the light comes from the top left).
local function bevel(out, r)
    local C = BB()
    local core = C.ColorRGB32(0xFF, 0xFF, 0xFC, 0xFF)
    local b = 3
    out:paintRectRGB32(r.x - b, r.y - b, r.w + 2 * b, b, core)
    out:paintRectRGB32(r.x - b, r.y + r.h, r.w + 2 * b, b, core)
    out:paintRectRGB32(r.x - b, r.y, b, r.h, core)
    out:paintRectRGB32(r.x + r.w, r.y, b, r.h, core)
    out:darkenRect(r.x - b, r.y - b, r.w + 2 * b, b, 0.10)
    out:darkenRect(r.x - b, r.y, b, r.h, 0.07)
    out:darkenRect(r.x - b - 1, r.y - b - 1, r.w + 2 * b + 2, 1, 0.08)
    out:darkenRect(r.x - b - 1, r.y - b, 1, r.h + 2 * b + 1, 0.06)
end

-- The soft shadow a picture raised off its linen throws, down and right.
local function floatShadow(out, r)
    for k = 1, 7 do
        out:darkenRect(r.x + 3 + k, r.y + 4 + k, r.w - 2 * k + 6, r.h - 2 * k + 6, 0.045)
    end
end

-- Fill `len` pixels of a side from (x, y) with strip `p` ({ x, y, w, h } in
-- `atlas`) repeated: a whole number of times, each stretched a little to fit.
-- `along_x`: a top or bottom side. Scaled strips are kept in `cache`.
local function tile(out, atlas, p, x, y, len, along_x, cache)
    if not p or len <= 0 then return end
    local ls = along_x and p[3] or p[4]
    local n = math.max(1, math.floor(len / ls + 0.5))
    local pos = 0
    for k = 1, n do
        local e = math.floor(k * len / n + 0.5)
        local seg = e - pos
        if seg > 0 then
            local dx, dy = along_x and x + pos or x, along_x and y or y + pos
            if seg == ls then
                out:blitFrom(atlas, dx, dy, p[1], p[2], p[3], p[4])
            else
                local id = tostring(p) .. ":" .. seg
                local s = cache[id]
                if not s then
                    local view = atlas:viewport(p[1], p[2], p[3], p[4])
                    s = scale(view, along_x and seg or p[3], along_x and p[4] or seg)
                    cache[id] = s
                end
                out:blitFrom(s, dx, dy, 0, 0, s:getWidth(), s:getHeight())
            end
        end
        pos = e
    end
end

-- One side between its corners: [a, b) along it, the strips `half1` and
-- `half2` for its two halves, and its middle ornament `mid` if it has one
-- and there is room.
local function side(out, atlas, a, b, fixed, along_x, half1, half2, mid, cache)
    local function at(v) if along_x then return v, fixed end return fixed, v end
    if b <= a then return end
    local m1, m2
    if mid then
        local mw = along_x and mid[3] or mid[4]
        if b - a >= mw + 4 then
            m1 = math.floor((a + b - mw) / 2)
            m2 = m1 + mw
        end
    end
    if not m1 then m1 = math.floor((a + b) / 2); m2 = m1 end
    local x1, y1 = at(a)
    tile(out, atlas, half1, x1, y1, m1 - a, along_x, cache)
    local x2, y2 = at(m2)
    tile(out, atlas, half2, x2, y2, b - m2, along_x, cache)
    if m2 > m1 then
        local x3, y3 = at(m1)
        out:blitFrom(atlas, x3, y3, mid[1], mid[2], mid[3], mid[4])
    end
end

-- A mitred frame round the opening of a W x H cover, from `atlas`.
local function paintFrame(out, fr, atlas, W, H)
    local P, t, c = fr.pieces, fr.t, fr.c
    local cache = {}
    side(out, atlas, c, W - c, 0, true, P.top_l, P.top_r, P.top_c, cache)
    side(out, atlas, c, W - c, H - t, true, P.bottom_l, P.bottom_r, P.bottom_c, cache)
    side(out, atlas, c, H - c, 0, false, P.left_t, P.left_b, P.left_c, cache)
    side(out, atlas, c, H - c, W - t, false, P.right_t, P.right_b, P.right_c, cache)
    for _, s in pairs(cache) do s:free() end
    -- the corners, each as its two arms (on a short side, as far as its middle)
    local cx, cy = math.min(c, math.floor(W / 2)), math.min(c, math.floor(H / 2))
    local tl, tr, bl, br = P.tl, P.tr, P.bl, P.br
    out:blitFrom(atlas, 0, 0, tl[1], tl[2], cx, t)
    out:blitFrom(atlas, 0, 0, tl[1], tl[2], t, cy)
    out:blitFrom(atlas, W - cx, 0, tr[1] + c - cx, tr[2], cx, t)
    out:blitFrom(atlas, W - t, 0, tr[1] + c - t, tr[2], t, cy)
    out:blitFrom(atlas, 0, H - t, bl[1], bl[2] + c - t, cx, t)
    out:blitFrom(atlas, 0, H - cy, bl[1], bl[2] + c - cy, t, cy)
    out:blitFrom(atlas, W - cx, H - t, br[1] + c - cx, br[2] + c - t, cx, t)
    out:blitFrom(atlas, W - t, H - cy, br[1] + c - t, br[2] + c - cy, t, cy)
end

-- Write `name` centred in rect `r` in Noto Serif Italic (KOReader's own),
-- as large as fits from `px` down, in colour `rgb`.
local function caption(out, r, name, rgb, px)
    name = (name or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if name == "" then return end
    local Font = require("ui/font")
    local RenderText = require("ui/rendertext")
    local per = require("device").screen:scaleBySize(1000) / 1000
    local fg = BB().ColorRGB32(rgb[1], rgb[2], rgb[3], 0xFF)
    local face
    for size = px, math.floor(px * 0.6), -2 do
        local ok, f = pcall(Font.getFace, Font, "NotoSerif-Italic.ttf", size / per)
        face = ok and f or Font:getFace("cfont", size / per)
        if RenderText:sizeUtf8Text(0, r.w * 4, face, name, true, false).x <= r.w then break end
    end
    local text = name
    local w = RenderText:sizeUtf8Text(0, r.w * 4, face, text, true, false).x
    if w > r.w then   -- still too long at the smallest size: cut short
        text = RenderText:truncateTextByWidth(name, face, r.w, true, false)
        w = RenderText:sizeUtf8Text(0, r.w * 4, face, text, true, false).x
    end
    local base = r.y + math.floor((r.h + face.size * 0.7) / 2)
    RenderText:renderUtf8Text(out, r.x + math.floor((r.w - w) / 2), base, face, text, true, false, fg)
end

-- An instant photo card: its paper tiled from `atlas`, the drawing in its
-- window and its name under it.
local function paintCard(out, fr, opt, atlas, W, H, box, name)
    local n = fr.tile
    for y = 0, H - 1, n do
        for x = 0, W - 1, n do
            out:blitFrom(atlas, x, y, 0, 0, math.min(n, W - x), math.min(n, H - y))
        end
    end
    -- a faint edge, so a white card stands out on a white shelf
    out:darkenRect(0, 0, W, 1, 0.10); out:darkenRect(0, H - 1, W, 1, 0.16)
    out:darkenRect(0, 0, 1, H, 0.10); out:darkenRect(W - 1, 0, 1, H, 0.16)
    return function()
        local ink = fr.ink and fr.ink[opt] or { 52, 52, 64 }
        local top = box.y + box.h
        caption(out, { x = fr.left, y = top, w = W - fr.left - fr.right, h = math.min(H - top, math.floor(fr.bottom * 0.62)) },
            name, ink, math.floor(W * 0.062))
    end
end

-- A canvas seen a little from the top left: the drawing on its face, its
-- right and bottom sides going back (the drawing's edges wrapped round them,
-- or painted white or black), on a white wall with a soft shadow, and a fine
-- edge so a white canvas still stands off a white shelf.
local function paintCanvas(out, opt, pic, W, H, box)
    local C = BB()
    local x0, y0, D = box.x, box.y, box.depth
    out:paintRectRGB32(0, 0, W, H, C.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
    -- the face's own size: the picture trimmed as little as it can be
    local fx, fy, fw, fh = x0, y0, box.w, box.h
    local src
    if pic then
        local sx, sy, sw, sh, dx, dy, dw, dh = placement(pic:getWidth(), pic:getHeight(), box)
        src = { sx, sy, sw, sh }
        fx, fy, fw, fh = dx, dy, dw, dh
    end
    -- the shadow on the wall, soft at its edges
    for k = 1, 8 do
        out:darkenRect(fx + D + k - 2, fy + D + k, fw + D - 2 * k + 6, fh + D - 2 * k + 6, 0.03)
    end
    -- the sides: the strips just past the face's edges (a gallery wrap), or paint
    local right, bottom
    if opt == "wrap" and pic then
        local sx, sy, sw, sh = src[1], src[2], src[3], src[4]
        local dx = math.max(1, math.floor(sw * D / fw + 0.5))
        local dy = math.max(1, math.floor(sh * D / fh + 0.5))
        local rx = math.min(sx + sw, pic:getWidth() - dx)
        local by = math.min(sy + sh, pic:getHeight() - dy)
        right = scale(pic:viewport(rx, sy, dx, sh), D, fh)
        bottom = scale(pic:viewport(sx, by, sw, dy), fw, D)
    end
    local paint = opt == "black" and C.ColorRGB32(0x22, 0x22, 0x24, 0xFF) or C.ColorRGB32(0xF4, 0xF3, 0xEE, 0xFF)
    for j = 0, D - 1 do
        local x, y = fx + fw + j, fy + j + 1
        if right then out:blitFrom(right, x, y, j, 0, 1, fh) else out:paintRectRGB32(x, y, 1, fh, paint) end
        out:darkenRect(x, y, 1, fh, (opt == "black" and 0.05 or 0.24) + 0.08 * j / D)
    end
    for i = 0, D - 1 do
        local x, y = fx + i + 1, fy + fh + i
        if bottom then out:blitFrom(bottom, x, y, 0, i, fw, 1) else out:paintRectRGB32(x, y, fw, 1, paint) end
        out:darkenRect(x, y, fw, 1, (opt == "black" and 0.02 or 0.12) + 0.06 * i / D)
    end
    -- the far corner where the two sides meet
    for j = 0, D - 1 do out:paintRectRGB32(fx + fw + j, fy + fh + j, 1, 1, paint) end
    if right then right:free() end
    if bottom then bottom:free() end
    if pic then
        local s = scale(pic:viewport(src[1], src[2], src[3], src[4]), fw, fh)
        out:blitFrom(s, fx, fy, 0, 0, fw, fh)
        s:free()
    else
        out:paintRectRGB32(fx, fy, fw, fh, C.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
    end
    -- the canvas turning at its edges: a fine line round the face, a little
    -- shade along its right and bottom
    out:darkenRect(fx, fy, fw, 1, 0.14); out:darkenRect(fx, fy, 1, fh, 0.14)
    out:darkenRect(fx + fw - 1, fy, 1, fh, 0.20); out:darkenRect(fx, fy + fh - 1, fw, 1, 0.18)
    out:darkenRect(fx + fw - 4, fy + 1, 3, fh - 2, 0.05)
    out:darkenRect(fx + 1, fy + fh - 4, fw - 2, 3, 0.04)
end

-- The atlas of finish `opt` of frame `fr` (or tile `tile`), decoded, or nil.
-- `keep`, when given, holds decoded atlases by file for the caller to free
-- (see FrameCover.free); else the caller frees it.
local function atlasOf(fr, opt, keep, tilefile)
    local file = dataDir() .. (tilefile or (fr.key .. "-" .. opt .. ".jpg"))
    if keep and keep[file] then return keep[file] end
    local ok, bb = pcall(function() return require("ui/renderimage"):renderImageFile(file, false) end)
    if not (ok and bb) then return nil end
    if keep then keep[file] = bb end
    return bb
end

-- The cover of a drawing as an RGB32 BlitBuffer, or nil when frame `key`
-- is unknown or its pieces can't be read. `look`: frame, option, shape ("true"
-- or "fill", see FrameCover.layout), name (an instant photo's caption), and the drawing as `picture` (a BlitBuffer, not
-- freed) or `file` (a snapshot PNG); blank paper without either. `keep`
-- (optional) keeps the atlases and the decoded picture for more covers of the
-- same drawing (the frame picker); FrameCover.free(keep) frees them.
function FrameCover.render(look, keep)
    local key, opt = FrameCover.lookOf(look.frame, look.option)
    local fr = key and FrameCover.frame(key)
    if not fr then return nil end
    local C = BB()
    local pic, own_pic = look.picture, false
    if not pic and look.file then
        pic = keep and keep[look.file]
        if not pic then
            local ok, img = pcall(function() return require("ui/renderimage"):renderImageFile(look.file, false) end)
            if ok and img then
                pic = img
                if keep then keep[look.file] = img else own_pic = true end
            end
        end
    end
    local W, H, open, box = FrameCover.layout(fr, pic and pic:getWidth(), pic and pic:getHeight(), look.shape)
    local out = C.new(W, H, C.TYPE_BBRGB32)
    local ok, err = pcall(function()
        if fr.kind == "canvas" then
            paintCanvas(out, opt, pic, W, H, box)
            return
        end
        local atlas = atlasOf(fr, opt, keep)
        if not atlas then error("no pieces for " .. key .. "-" .. opt) end
        local after
        if fr.kind == "card" then
            after = paintCard(out, fr, opt, atlas, W, H, box, look.name)
            local r = paintPicture(out, pic, box)
            innerShadow(out, r, fr.shadow and fr.shadow[1], fr.shadow and fr.shadow[2])
        else
            -- the mat (or linen) inside the frame: the frame's own, or under
            -- a drawing too wide or tall to fill it
            local mats = (fr.margin or 0) > 0
            if not mats and pic then
                local _sx, _sy, _sw, _sh, _dx, _dy, dw, dh = placement(pic:getWidth(), pic:getHeight(), box)
                mats = dw < box.w or dh < box.h
            end
            if mats then
                local tiles = load().tiles or {}
                local mat = atlasOf(fr, opt, keep, tiles[fr.mat or "mat"] or "mat.jpg")
                if mat then
                    tileFill(out, mat, open)
                    if not keep then mat:free() end
                else
                    out:paintRectRGB32(open.x, open.y, open.w, open.h, C.ColorRGB32(0xF6, 0xF3, 0xEC, 0xFF))
                end
            end
            if (fr.margin or 0) > 0 then
                -- Museum Mat and Floating Frame: the frame's shadow on the mat,
                -- the drawing in its bevelled window or raised off the linen
                innerShadow(out, open, fr.shadow and fr.shadow[1], fr.shadow and fr.shadow[2])
                if fr.float then
                    local px = { placement(pic and pic:getWidth() or box.w, pic and pic:getHeight() or box.h, box) }
                    floatShadow(out, { x = px[5], y = px[6], w = px[7], h = px[8] })
                end
                local drawn = paintPicture(out, pic, box)
                if not fr.float then bevel(out, drawn); innerShadow(out, drawn, 3, 0.18) end
            else
                local drawn = paintPicture(out, pic, box)
                if mats then bevel(out, drawn) end
                innerShadow(out, open, fr.shadow and fr.shadow[1], fr.shadow and fr.shadow[2])
            end
            paintFrame(out, fr, atlas, W, H)
        end
        if after then after() end
        if not keep then atlas:free() end
    end)
    if own_pic then pic:free() end
    if not ok then
        out:free()
        error(err)
    end
    return out
end

-- Free what FrameCover.render kept in `keep`.
function FrameCover.free(keep)
    for k, bb in pairs(keep or {}) do
        pcall(function() bb:free() end)
        keep[k] = nil
    end
end

-- Draw a drawing's cover (see FrameCover.render for `look`) to PNG `file`.
-- Returns whether it was written.
function FrameCover.write(file, look)
    local ok, bb = pcall(FrameCover.render, look)
    if not (ok and bb) then return false end
    local tmp = file .. ".tmp"
    local wrote = pcall(function() bb:writePNG(tmp) end)
    bb:free()
    if not (wrote and Storage.exists(tmp)) then os.remove(tmp); return false end
    return os.rename(tmp, file) == true
end

return FrameCover
