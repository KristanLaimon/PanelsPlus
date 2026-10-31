--[[
Placed images (decoding, move, resize, rotate, flip, background removal and the
image menu) and the background image a drawing sits on.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local ImageProc = require("ink/imageproc")
local Library = require("ink/library")
local Storage = require("ink/storage")
local ThumbGrid = require("ink/ui/thumbgrid")

local Screen = Device.screen
local bbToRGBA = ImageProc.bbToRGBA
local bgRemovedRGBA = ImageProc.bgRemovedRGBA
local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB
local resampleOriented = ImageProc.resampleOriented

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local IMG_MIN    = 24   -- smallest image side, in canvas px

local InkAwayView = {}

------------------------------------------------------------------------------
-- Background image
------------------------------------------------------------------------------

-- Copy the background into a canvas-sized RGBA buffer for export. A BBRGB32 is
-- already r,g,b,a in memory, so this is one memcpy per row. Alpha is kept, so a
-- transparent PNG stays transparent. Returns the buffer, or nil.
function InkAwayView:buildBgRGBA()
    return bbToRGBA(self.bg_bb, self.view.canvas_w, self.view.canvas_h)
end

-- Place an already-rendered source BlitBuffer as the background: fit it inside
-- the canvas keeping aspect (no stretching), centre it on a canvas-sized RGB32
-- buffer with white margins, and take ownership of `img` (it is freed here).
function InkAwayView:placeBackground(img, path)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local bg = fitIntoCanvasBB(img, W, H)
    if self.bg_bb then self.bg_bb:free() end
    self.bg_bb = bg
    self._bg_src = nil   -- a picture, not a cached PDF page
    self.bg_path = path
    self.bg_rgba = self:buildBgRGBA()
    self:markDirty()
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "full")
end

function InkAwayView:loadBackground(path)
    local ok, img = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if not ok or not img then
        self:tell(_("Could not open that image."))
        return
    end
    self:placeBackground(img, path)
end

function InkAwayView:removeBackground()
    if self.bg_bb then self.bg_bb:free() end
    self.bg_bb, self.bg_rgba, self.bg_path, self._bg_src = nil, nil, nil, nil
    self:markDirty()
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "full")
end

-- Let the reader pick a PNG or JPEG, starting in KOReader's home folder.
function InkAwayView:pickImageFile(on_pick, start)
    self:pickFile(start or self:homeDir(), on_pick, self.isPictureName, nil,
        _("No pictures or folders here."))
end

function InkAwayView:chooseBackground()
    self:pickImageFile(function(path) self:loadBackground(path) end)
end

------------------------------------------------------------------------------
-- Placed images: a PNG or JPEG on the page. An image is an op:
--   { kind="image", x, y, w, h (canvas px), path, natw, nath,
--     angle (degrees), flip_h, flip_v }
-- Decoded pixels are cached by path and never saved, so a project stores the
-- path, box and orientation and decodes again on load. Images compose into the
-- master and export like any other op. A picture picked with Pan (or the lasso)
-- is a selection like any other: moved, resized, turned, mirrored and
-- reordered there (see view/selection.lua).
------------------------------------------------------------------------------

-- Free every decoded, scaled, oriented and display buffer and drop the caches.
-- Buffers can be shared (a scaled copy is its source when the sizes match), so a
-- `seen` set frees each one exactly once.
function InkAwayView:freeImageCache()
    local seen = {}
    local function drop(bb)
        if bb and bb.free and not seen[bb] then seen[bb] = true; pcall(function() bb:free() end) end
    end
    if self._img_disp then drop(self._img_disp.bb); self._img_disp = nil end
    if self._img_render then for _, e in pairs(self._img_render) do drop(e.bb) end; self._img_render = nil end
    if self._img_scaled then for _, e in pairs(self._img_scaled) do drop(e.bb) end; self._img_scaled = nil end
    if self._img_bb then for _, bb in pairs(self._img_bb) do drop(bb) end; self._img_bb = nil end
end

-- Free just the one screen-scaled display buffer (rebuilt on the next paint).
function InkAwayView:freeImageDisplay()
    local d = self._img_disp
    if d and d.bb and d.bb.free then pcall(function() d.bb:free() end) end
    self._img_disp = nil
end

-- A short signature of an op's orientation, used as a cache key so a rotation or
-- flip invalidates the oriented and scaled buffers.
local function orientSig(op)
    return ((op.angle or 0) % 360) .. "/" .. (op.flip_h and 1 or 0) .. "/" .. (op.flip_v and 1 or 0)
end

-- Decode a picture file into a BBRGB32 (keeping alpha), shrunk to fit the canvas
-- with its aspect kept: an image is never shown or exported larger than the page,
-- and a full-resolution photo would take tens of MB. Returns the buffer or nil.
-- Not cached; imageSrc caches per path, and the background remover decodes the
-- original file directly.
function InkAwayView:decodeCapped(path)
    if not path then return nil end
    local ok, img = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if not (ok and img) then return nil end
    local iw, ih = img:getWidth(), img:getHeight()
    local W, H = self.view.canvas_w, self.view.canvas_h
    local cap = math.min(1, W / iw, H / ih)          -- <=1: only ever shrink
    local sw = math.max(1, math.floor(iw * cap + 0.5))
    local sh = math.max(1, math.floor(ih * cap + 0.5))
    local source = img
    if sw ~= iw or sh ~= ih then
        local sok, s = pcall(function() return RenderImage:scaleBlitBuffer(img, sw, sh, false) end)
        if sok and s then source = s end
    end
    -- Normalise to a BBRGB32 with a transparent ground, so the on-screen alpha-blit
    -- and the raw-bytes export both see a uniform r,g,b,a layout.
    local n = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)
    n:fill(Blitbuffer.ColorRGB32(0, 0, 0, 0))
    pcall(function() n:blitFrom(source, 0, 0, 0, 0, sw, sh) end)
    if source ~= img and source.free then source:free() end
    if img.free then img:free() end
    return n
end

-- The decoded picture for an op, cached by path. A `false` entry caches a failed
-- decode so it is not retried on every frame.
function InkAwayView:imageSrc(op)
    if not op or not op.path then return nil end
    self._img_bb = self._img_bb or {}
    local c = self._img_bb[op.path]
    if c ~= nil then return c or nil end
    local norm = self:decodeCapped(op.path) or false
    self._img_bb[op.path] = norm
    return norm or nil
end

-- The axis-aligned bounding box (canvas coords) of an image op at its angle,
-- computed without a buffer: op.w and op.h are the unrotated size and the box
-- grows as it turns. Returns x, y, w, h.
local function imageBBox(op)
    local a = math.rad((op.angle or 0) % 360)
    local c, s = math.abs(math.cos(a)), math.abs(math.sin(a))
    local bw = op.w * c + op.h * s
    local bh = op.w * s + op.h * c
    local cx, cy = op.x + op.w / 2, op.y + op.h / 2
    return cx - bw / 2, cy - bh / 2, bw, bh
end

-- The picture scaled to the op's on-page size (canvas px), unrotated. One copy is
-- kept per path and rebuilt only on a size change, so a resize drag never piles
-- up buffers and a move drag reuses the cached scale.
function InkAwayView:imageScaled(op)
    local src = self:imageSrc(op)
    if not src then return nil end
    local w = math.max(1, math.floor(op.w + 0.5))
    local h = math.max(1, math.floor(op.h + 0.5))
    self._img_scaled = self._img_scaled or {}
    local e = self._img_scaled[op.path]
    if e and e.w == w and e.h == h then return e.bb or nil end
    if e and e.bb and e.bb ~= src and e.bb.free then pcall(function() e.bb:free() end) end
    local scaled
    if w == src:getWidth() and h == src:getHeight() then
        scaled = src
    else
        local ok, s = pcall(function() return RenderImage:scaleBlitBuffer(src, w, h, false) end)
        scaled = (ok and s) or false
    end
    self._img_scaled[op.path] = { w = w, h = h, bb = scaled or false }
    return scaled or nil
end

-- The flipped and rotated bitmap at on-page size, and its top-left in canvas
-- coords (which moves away from op.x, op.y once rotated, as the box grows).
-- Cached per path and rebuilt only when the size or orientation changes. With no
-- orientation it is the plain scaled buffer at op.x, op.y, so the common case
-- allocates nothing extra.
function InkAwayView:imageRendered(op)
    local scaled = self:imageScaled(op)
    if not scaled then return nil end
    local cx, cy = op.x + op.w / 2, op.y + op.h / 2
    if orientSig(op) == "0/0/0" then return scaled, op.x, op.y end
    local sig = orientSig(op)
    local w, h = math.max(1, math.floor(op.w + 0.5)), math.max(1, math.floor(op.h + 0.5))
    self._img_render = self._img_render or {}
    local e = self._img_render[op.path]
    if not (e and e.sig == sig and e.w == w and e.h == h and e.bb) then
        if e and e.bb and e.bb ~= scaled and e.bb.free then pcall(function() e.bb:free() end) end
        local bb = resampleOriented(scaled, (op.angle or 0) % 360, op.flip_h, op.flip_v)
        e = { sig = sig, w = w, h = h, bb = bb or false }
        self._img_render[op.path] = e
    end
    if not e.bb then return nil end
    return e.bb, cx - e.bb:getWidth() / 2, cy - e.bb:getHeight() / 2
end

-- RGBA byte buffer for export: the oriented picture at on-page size. Returns
-- buf, w, h, ox, oy (canvas top-left). Injected into Export as Export.image_raster.
function InkAwayView:exportImageRaster(op)
    local bb, ox, oy = self:imageRendered(op)
    if not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    local buf = bbToRGBA(bb, w, h)
    if not buf then return nil end
    return buf, w, h, ox, oy
end

-- Blit an image op into the canvas-space master `dst`, at its (rotated) top-left,
-- clipped to the canvas, or to `region` (a canvas rect) when given.
function InkAwayView:blitImageInto(dst, op, region)
    local bb, ox, oy = self:imageRendered(op)
    if not bb then return end
    local r = region or { x0 = 0, y0 = 0, x1 = self.view.canvas_w, y1 = self.view.canvas_h }
    local dx, dy = math.floor(ox + 0.5), math.floor(oy + 0.5)
    local cx0, cy0 = math.max(r.x0, dx), math.max(r.y0, dy)
    local cw = math.min(dx + bb:getWidth(), r.x1) - cx0
    local ch = math.min(dy + bb:getHeight(), r.y1) - cy0
    if cw > 0 and ch > 0 then
        pcall(function() dst:alphablitFrom(bb, cx0, cy0, cx0 - dx, cy0 - dy, cw, ch) end)
    end
end

-- Pick the image under a canvas point (topmost first). Uses the rotated bounding
-- box so a turned picture is still grabbable over its whole visible area.
function InkAwayView:hitTestImage(sx, sy)
    local cx, cy = self:toCanvasClamped(sx, sy)
    local ops = self.canvas.ops
    for i = #ops, 1, -1 do
        local op = ops[i]
        if op.kind == "image" and self:editableOp(op) then
            local bx, by, bw, bh = imageBBox(op)
            if cx >= bx and cx <= bx + bw and cy >= by and cy <= by + bh then
                return { op = op, idx = i }
            end
        end
    end
    return nil
end

-- Remove the selected picture's background (see ImageProc.bgRemovedRGBA). The cut-out
-- is saved as a transparent PNG and the op points at it, so decoding and export
-- need no special case; op.src_path keeps the original for a re-run. It is a
-- copy-on-write edit, so Undo brings the original back.
function InkAwayView:removeImageBackground()
    local idx = self.selection and #self.selection.idxs == 1 and self.selection.idxs[1]
    local op = idx and self.canvas.ops[idx]
    if not (op and op.kind == "image") then return end
    local src_path = op.src_path or op.path
    local src = self:decodeCapped(src_path)
    if not src then
        self:tell(_("Couldn't read that image."))
        return
    end
    local w, h = src:getWidth(), src:getHeight()
    local rgba = bgRemovedRGBA(src)
    if src.free then pcall(function() src:free() end) end
    if not rgba then
        self:tell(_("Couldn't process that image."))
        return
    end
    -- the cut-out goes beside the online images, never over the original
    local dir = Storage.appDir("processed images")
    if not dir then
        self:tell(_("Couldn't prepare a folder for the image."))
        return
    end
    self._img_proc_seq = (self._img_proc_seq or 0) + 1
    local path = string.format("%s/nobg-%d-%d.png", dir, os.time(), self._img_proc_seq)
    local wok = pcall(function() require("ffi/png").encodeToFile(path, rgba, w, h, 4) end)
    if not wok then
        self:tell(_("Couldn't save the processed image."))
        return
    end
    -- copy-on-write: repoint at the cut-out, remember the original for a re-run
    self:editOp(idx, op, function(o)
        o.src_path = src_path
        o.path = path
        o.natw, o.nath = w, h
    end)
    self:freeImageCache()   -- the path changed: drop the old decode, decode the cut-out
    self:recompose()
end

-- Insert a new image from a file: fit it to ~60% of the visible area (so its
-- corners show for dragging), centre it in the viewport and select it.
function InkAwayView:insertImage(path)
    local tmp = { kind = "image", path = path, x = 0, y = 0, w = 1, h = 1 }
    local src = self:imageSrc(tmp)
    if not src then
        self:tell(_("Could not open that image."))
        return
    end
    local natw, nath = src:getWidth(), src:getHeight()
    local v = self.view
    local maxw = 0.6 * v.area_w / v.zoom
    local maxh = 0.6 * v.area_h / v.zoom
    local s = math.min(maxw / natw, maxh / nath)
    if s <= 0 then s = 1 end
    local op = { kind = "image", path = path, natw = natw, nath = nath,
                 w = math.max(IMG_MIN, natw * s), h = math.max(IMG_MIN, nath * s) }
    local ccx = v.pan_x + (v.area_w / 2) / v.zoom
    local ccy = v.pan_y + (v.area_h / 2) / v.zoom
    op.x = math.max(0, math.min(v.canvas_w - op.w, ccx - op.w / 2))
    op.y = math.max(0, math.min(v.canvas_h - op.h, ccy - op.h / 2))
    self:layerReady()
    self.canvas:pushHistory()
    local _op, at = self.canvas:placeOp(op)
    self:markDirty()
    -- Switch to Pan with the picture selected and its menu open, as if it had been
    -- tapped there, so a new image is ready to move, resize or delete at once.
    self:setTool("pan")
    self:recompose()
    self:selectOps({ at }, "pan")
    self:openSelectionMenu()
end

-- Ask where a new image comes from: a local file (the primary button) or an
-- online search. Browsing is optional; Ink Away never needs a connection.
function InkAwayView:chooseImage()
    self:dropSelection()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_img_src_dialog") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        local function hint(text)
            add(vspan(4))
            add(self:sheetHint(text, content_w))
        end
        add(self:sheetTitle(_("Add image"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(self:actionButton(_("From this reader"), content_w, function()
            closeSelf(); self:chooseLocalImage() end, true, nil, "reader"))
        hint(_("A picture file on this reader."))
        -- pictures sent from a phone or computer (see ink/view/receive.lua)
        local sent = self:importedImageCount()
        if sent > 0 then
            add(vspan(12))
            add(self:actionButton(string.format(_("Sent from your phone (%d)"), sent), content_w, function()
                closeSelf(); self:chooseSentPicture() end, nil, nil, "inbox"))
            hint(_("From Library › Imported › Pictures."))
        end
        add(vspan(12))
        add(self:actionButton(_("Get from your phone or computer"), content_w, function()
            closeSelf(); self:openSend{ adding = true } end, nil, nil, "qr"))
        hint(_("Scan a QR code to send pictures over Wi-Fi."))
        add(vspan(12))
        add(self:actionButton(_("Search online"), content_w, function()
            closeSelf(); self:browseOnlineImages() end, nil, nil, "globe"))
        hint(_("Free pictures from Wikimedia and Openverse. Needs Wi-Fi."))
        if not (self.notebook or self.reader_mode) then   -- a notebook's paper, or the book, is the background
            add(vspan(14))
            add(self:actionButton(_("Background\u{2026}"), content_w, function()
                closeSelf(); self:openBackground() end, nil, nil, "background"))
        end
        return content
    end
    self:showSheet("_img_src_dialog", build)
end

-- The pictures sent from a phone or computer, as a grid of them: a tap puts
-- one on the page.
function InkAwayView:chooseSentPicture()
    local dir = self:importedImagesDir()
    local _f, _d, pics = Library.list(dir or "", nil, "recent")
    local items = {}
    for _i, p in ipairs(pics or {}) do
        items[#items + 1] = { label = Storage.stem(p.name), path = p.path, picture = true }
    end
    local grid
    grid = ThumbGrid:new{
        title = _("Sent from your phone"),
        items = items,
        flash_open = false,
        close_label = _("Cancel"),
        empty_text = _("Nothing sent yet."),
        render = function(it, w, h) return self:pictureThumb(it.path, w, h) end,
        on_pick = function(it) grid:close(); self:insertImage(it.path) end,
        -- (the grid covered the toolbar too: repaint all of the view, not just
        -- the area the new picture asks for)
        on_close = function() self:uncovered() end,
    }
    UIManager:show(grid)
end

-- The background sheet: open a picture to draw over, or remove it.
function InkAwayView:openBackground()
    self:closeSheet("_bg_dialog")
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_bg_dialog") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Background image"), content_w, _("Done"), closeSelf))
        add(vspan(16))
        add(self:actionButton(_("Open image as background"), content_w,
            function() closeSelf(); self:chooseBackground() end, nil, nil, "image"))
        if self.bg_bb then
            add(vspan(8))
            add(self:actionButton(_("Remove the background picture"), content_w,
                function() closeSelf(); self:removeBackground() end, true, nil, "trash"))
        end
        add(vspan(12))
        local hint = self.bg_bb
            and _("At save time you can include the picture or export just your drawing. The grid is always left out.")
            or _("Draw over a photo or screenshot; your drawing sits on top. To write on a PDF, start a notebook from it: File, New, From PDF.")
        add(self:sheetHint(hint, content_w, 15))
        return content
    end
    self:showSheet("_bg_dialog", build)
end

-- Pick a local PNG or JPEG and insert it.
-- How many pictures were sent to the reader (see ink/view/receive.lua).
function InkAwayView:importedImageCount()
    local dir = Storage.join(self:importedFolder(), self.IMPORTED_SUB.image)   -- (not made just to count)
    local n = 0
    for _i, e in ipairs(dir and Storage.list(dir) or {}) do
        if e.mode == "file" and e.name:sub(1, 1) ~= "." and e.name:lower():match("%.[jp][pn]e?g$") then n = n + 1 end
    end
    return n
end

function InkAwayView:chooseLocalImage()
    self:pickImageFile(function(path) self:insertImage(path) end)
end

-- Remove any loaded background image (used when switching into notebook mode).
function InkAwayView:clearBackground()
    if self.bg_bb then pcall(function() self.bg_bb:free() end) end
    self.bg_bb, self.bg_rgba, self.bg_path, self._bg_src = nil, nil, nil, nil
end

return InkAwayView
