--[[
A picture laid over a page of a PDF, as an annotation, written straight into the
file. KOReader's PDF library can add ink, highlights and underlines to a page but
has no call to add a picture, so a page with something an annotation cannot hold
(text boxes, pictures, fills) gets one this way: it is the one thing in a PDF
that shows a picture over a page and that any viewer can still move or delete.

The page is first given a placeholder, a highlight over the whole page with a
tag in its text (see Pdfedit). The library writes it, and the page's updated
entry, as an incremental update at the end of the file. This module then reads
that update, finds the placeholders and writes a second update that gives each
placeholder's object number a stamp annotation with the picture instead. The
original bytes and the library's update are not touched.

A picture is { w, h, rgb, alpha } (its pixels, deflated: see Overlay.pack) and the
box it covers on the page, bx0, by0, bx1, by1, in the page's units from its top
left corner.

Only a plain, unencrypted PDF whose page is not turned is written this way;
anything else is refused (nil, why) and the caller keeps the page's ink as
annotations. Plain Lua and zlib.
]]

local Overlay = {}

Overlay.TAG = "InkAwayOverlay"

-- A picture ready to write: its pixels (`rgb`, `alpha`: strings of w*h*3 and w*h
-- bytes) deflated, and the box on the page it covers. With `jpeg` the colour is
-- that JPEG file's bytes instead (`rgb` is not deflated): for a picture with solid
-- colour all over, where it is a fifth of the size.
function Overlay.pack(w, h, rgb, alpha, bx0, by0, bx1, by1, jpeg)
    local zlib = require("ffi/zlib")
    return { w = w, h = h, rgb = jpeg and rgb or zlib.zlib_compress(rgb), dct = jpeg and true or nil,
        alpha = zlib.zlib_compress(alpha), bx0 = bx0, by0 = by0, bx1 = bx1, by1 = by1 }
end

-- The placeholders in the update `app` and the trailer it ends with. Returns
-- { holders = { [page] = { num, page_ref, x0, y0, x1, y1 } }, size, root, info,
-- id, prev }, or nil, why.
local function parse(app)
    local holders, n = {}, 0
    for num, body in app:gmatch("(%d+) 0 obj%s*(<<.-)endobj") do
        local page = body:match("/Contents%s*%(" .. Overlay.TAG .. "(%d+)%)")
        if page and body:find("/Subtype%s*/Highlight") then
            local ref = body:match("/P%s+(%d+ %d+) R")
            local q = {}
            for v in (body:match("/QuadPoints%s*%[([^%]]*)%]") or ""):gmatch("%S+") do q[#q + 1] = tonumber(v) end
            if not (ref and #q == 8) then return nil, "placeholder unreadable" end
            -- the quad is the page itself, upper left, upper right, lower left, lower
            -- right: anything else is a turned page
            local ulx, uly, urx, ury, llx, lly = q[1], q[2], q[3], q[4], q[5], q[6]
            if not (urx > ulx and uly > lly and math.abs(ulx - llx) < 0.01 and math.abs(uly - ury) < 0.01) then
                return nil, "turned page"
            end
            holders[tonumber(page)] = { num = tonumber(num), page_ref = ref, x0 = llx, y0 = lly, x1 = urx, y1 = uly }
            n = n + 1
        end
    end
    if n == 0 then return nil, "no placeholders" end
    -- the trailer of the update (a table's, or an xref stream's own dictionary)
    local from = 1
    for p in app:gmatch("()trailer") do from = p end
    if from == 1 then
        for p in app:gmatch("()/Type%s*/XRef") do from = p end
    end
    if from == 1 then return nil, "no trailer" end
    local win = app:sub(from)
    if win:find("/Encrypt", 1, true) then return nil, "encrypted" end
    local prev
    for v in app:gmatch("startxref%s+(%d+)") do prev = tonumber(v) end
    local size, root = win:match("/Size%s+(%d+)"), win:match("/Root%s+(%d+ %d+) R")
    if not (size and root and prev) then return nil, "trailer unreadable" end
    return { holders = holders, size = tonumber(size), root = root, info = win:match("/Info%s+(%d+ %d+) R"),
        id = win:match("/ID%s*(%b[])"), prev = prev }
end

local function num(v)
    if v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.3f", v)
end

-- Write the pictures in as stamps. `path` is the PDF, `orig_size` the size it had
-- before the library appended its update; `images` maps a page number to its
-- picture. Returns true, or nil, why (the file is then as the library left it,
-- which still holds a placeholder: the caller starts that file again).
function Overlay.apply(path, orig_size, images)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    f:seek("set", orig_size)
    local app = f:read("*a") or ""
    f:close()
    local info, why = parse(app)
    if not info then return nil, why end
    for page in pairs(images) do
        if not info.holders[page] then return nil, "no placeholder for page " .. page end
    end
    local base = orig_size + #app
    local out, objs, nxt = { "\n" }, {}, info.size
    local len = 1
    local function put(s) out[#out + 1] = s; len = len + #s end
    local function object(n_, dict, data)
        objs[#objs + 1] = { n = n_, at = base + len }
        put(n_ .. " 0 obj\n" .. dict)
        if data then put("\nstream\n" .. data .. "\nendstream") end
        put("\nendobj\n")
    end
    local pages = {}
    for page in pairs(images) do pages[#pages + 1] = page end
    table.sort(pages)
    for _i, page in ipairs(pages) do
        local im, h = images[page], info.holders[page]
        local img_n, mask_n, form_n = nxt, nxt + 1, nxt + 2
        nxt = nxt + 3
        object(img_n, string.format("<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB"
            .. " /BitsPerComponent 8 /Filter /%s /SMask %d 0 R /Length %d >>", im.w, im.h, im.dct and "DCTDecode" or "FlateDecode",
            mask_n, #im.rgb), im.rgb)
        object(mask_n, string.format("<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray"
            .. " /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>", im.w, im.h, #im.alpha), im.alpha)
        -- the picture's box on the page, from the page's upper left corner down
        local x0, x1 = h.x0 + im.bx0, h.x0 + im.bx1
        local y1, y0 = h.y1 - im.by0, h.y1 - im.by1
        local w, hh = x1 - x0, y1 - y0
        local content = string.format("q %s 0 0 %s 0 0 cm /Im0 Do Q", num(w), num(hh))
        object(form_n, string.format("<< /Type /XObject /Subtype /Form /BBox [0 0 %s %s]"
            .. " /Resources << /XObject << /Im0 %d 0 R >> >> /Length %d >>", num(w), num(hh), img_n, #content), content)
        object(h.num, string.format("<< /Type /Annot /Subtype /Stamp /Rect [%s %s %s %s] /F 4 /P %s R"
            .. " /NM (InkAwayOverlay%d) /AP << /N %d 0 R >> >>", num(x0), num(y0), num(x1), num(y1), h.page_ref, page, form_n))
    end
    -- the cross reference: one run of entries for each stretch of object numbers
    table.sort(objs, function(a, b) return a.n < b.n end)
    local xref_at = base + len
    local xr = { "xref\n" }
    local i = 1
    while i <= #objs do
        local j = i
        while objs[j + 1] and objs[j + 1].n == objs[j].n + 1 do j = j + 1 end
        xr[#xr + 1] = string.format("%d %d\n", objs[i].n, j - i + 1)
        for k = i, j do xr[#xr + 1] = string.format("%010d 00000 n \n", objs[k].at) end
        i = j + 1
    end
    xr[#xr + 1] = string.format("trailer\n<< /Size %d /Root %s R%s /Prev %d%s >>\nstartxref\n%d\n%%%%EOF\n",
        nxt, info.root, info.info and (" /Info " .. info.info .. " R") or "", info.prev,
        info.id and (" /ID " .. info.id) or "", xref_at)
    put(table.concat(xr))
    local wf, werr = io.open(path, "ab")
    if not wf then return nil, werr end
    local ok = wf:write(table.concat(out))
    wf:close()
    if not ok then return nil, "could not write the PDF (is the storage full?)" end
    return true
end

return Overlay
