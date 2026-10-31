--[[
An editable PDF: a copy of the original PDF with the ink and the highlights
added as annotations (see ink/export/annots.lua), written with the MuPDF
KOReader already has. The original file is never touched and its pages stay as
they are, text and all, so the copy is about the original's size plus the ink.

The copy is made first and the annotations are appended to it as an incremental
update, so a long PDF is not written out again; a PDF MuPDF will not append to
is written out whole instead. The job works a page a step, so the progress
sheet can stop it, and removes the copy if it is stopped or fails.

  job = Pdfedit.job(src, dst, pages)
  pages: list of { page = n, groups = { ... } (Annots.convert), marks = { ... },
                   overlay = function() -> a picture (see below) or nil }
  job.step() -> "page", i, n | "done" | nil, err        job.cancel()
A mark is a highlight of the reader's: { pboxes, drawer, color (hex), note }.

A page with an `overlay` gets, instead of its `groups`, one picture over the page
(see ink/export/pdfoverlay.lua): all that page's ink as it looks, for a page with
something an annotation cannot hold. `overlay()` makes the picture when the page's
turn comes (Overlay.pack) and returns nil when there is nothing to show, and the
page keeps its groups. When the picture cannot be written (an encrypted or turned
page, a PDF the library will not append to), the job starts the copy again with
every page's groups and no pictures, and sets job.fell_back.
]]

local ffi = require("ffi")
local Overlay = require("ink/export/pdfoverlay")

local Pdfedit = {}

local CHUNK = 1048576   -- bytes copied per step

-- Can this KOReader write ink annotations? Its MuPDF must be there with the
-- call that makes them (older builds have only the highlights); the call is
-- found on a page of `path`, the PDF about to be written to.
function Pdfedit.available(path)
    local ok, yes = pcall(function()
        local M = require("ffi/mupdf")
        local doc = M.openDocument(path)
        local page = doc:openPage(1)
        local has = page.addInkAnnotation ~= nil
        page:close()
        doc:close()
        return has
    end)
    return ok and yes == true
end

-- "#RRGGBB" as { r, g, b } (0-255), or nil.
local function rgb(hex)
    local r, g, b = tostring(hex or ""):match("^#(%x%x)(%x%x)(%x%x)")
    if not r then return nil end
    return { r = tonumber(r, 16), g = tonumber(g, 16), b = tonumber(b, 16) }
end

-- The quad points of a highlight's boxes, in the order MuPDF wants (see
-- KOReader's own frontend/document/pdfdocument.lua).
local function quads(pboxes)
    local n = #pboxes
    local q = ffi.new("fz_quad[?]", n)
    for i = 1, n do
        local b = pboxes[i]
        q[i - 1].ll.x, q[i - 1].ll.y = b.x, b.y + b.h - 1
        q[i - 1].lr.x, q[i - 1].lr.y = b.x + b.w - 1, b.y + b.h - 1
        q[i - 1].ul.x, q[i - 1].ul.y = b.x, b.y
        q[i - 1].ur.x, q[i - 1].ur.y = b.x + b.w - 1, b.y
    end
    return q, n
end

-- Add one page's annotations to the open `doc`. With `images` (a table) a page that
-- has an overlay gets a placeholder and its picture is kept in `images` instead of
-- its groups. Returns false, err when the build cannot write ink.
local function addPage(doc, p, images)
    local page = doc:openPage(p.page)
    local ok, err = pcall(function()
        local pic = images and p.overlay and p.overlay()
        if pic then
            local w, h = page:getSize({ zoom = 1, rotate = 0 })
            local q = ffi.new("fz_quad[1]")
            q[0].ll.x, q[0].ll.y, q[0].lr.x, q[0].lr.y = 0, h, w, h
            q[0].ul.x, q[0].ul.y, q[0].ur.x, q[0].ur.y = 0, 0, w, 0
            page:addMarkupAnnotation(q, 1, ffi.C.PDF_ANNOT_HIGHLIGHT, { r = 255, g = 255, b = 0 })
            local a = page:getMarkupAnnotation(q, 1)
            if not a then error("could not place the picture") end
            page:updateMarkupAnnotation(a, Overlay.TAG .. p.page)
            images[p.page] = pic
        else
            if #p.groups > 0 and not page.addInkAnnotation then error("no ink annotations in this KOReader") end
            for _i, g in ipairs(p.groups) do
                page:addInkAnnotation(g.strokes, g.color, g.width, g.opacity)
            end
        end
        for _i, m in ipairs(p.marks or {}) do
            if m.pboxes and #m.pboxes > 0 then
                local q, n = quads(m.pboxes)
                -- one KOReader already wrote into the file ("Write highlights
                -- into PDF") is there once
                local have = page:getMarkupAnnotation(q, n)
                if not have then
                    local kind = ffi.C.PDF_ANNOT_HIGHLIGHT
                    if m.drawer == "underscore" then kind = ffi.C.PDF_ANNOT_UNDERLINE
                    elseif m.drawer == "strikeout" then kind = ffi.C.PDF_ANNOT_STRIKE_OUT end
                    page:addMarkupAnnotation(q, n, kind, rgb(m.color))
                    if m.note and m.note ~= "" then
                        local a = page:getMarkupAnnotation(q, n)
                        if a then page:updateMarkupAnnotation(a, m.note) end
                    end
                end
            end
        end
    end)
    page:close()
    return ok, err
end

-- Copy `src` to `dst` a chunk per call: returns a function giving true when done.
local function copier(src, dst)
    local fi, e1 = io.open(src, "rb")
    if not fi then return nil, e1 end
    local fo, e2 = io.open(dst, "wb")
    if not fo then fi:close(); return nil, e2 end
    return function()
        local chunk = fi:read(CHUNK)
        if chunk then
            if not fo:write(chunk) then fi:close(); fo:close(); return nil, "could not write the PDF (is the storage full?)" end
            return false
        end
        fi:close(); fo:close()
        return true
    end
end

function Pdfedit.job(src, dst, pages)
    local M = require("ffi/mupdf")
    local job = { i = 0, n = #pages }
    local copy, doc, finished
    local images, orig_size = {}, 0
    local function drop()
        if doc then pcall(function() doc:close() end); doc = nil end
        os.remove(dst)
        job.over = true
    end
    local function fail(e)
        drop()
        return nil, e
    end
    -- the pages again, every page as annotations and no pictures, on a fresh copy
    -- (appended to, else written out whole)
    local function again()
        if doc then pcall(function() doc:close() end); doc = nil end
        os.remove(dst)
        local c, e = copier(src, dst)
        if not c then return false, e end
        local done
        repeat done, e = c() until done ~= false
        if not done then return false, e end
        local ok, err = pcall(function()
            local d = M.openDocument(dst)
            local ok2, e2 = pcall(function()
                for _i, p in ipairs(pages) do
                    local ok3, e3 = addPage(d, p, nil)
                    if not ok3 then error(e3) end
                end
                d:writeDocument(dst)
            end)
            pcall(function() d:close() end)
            if not ok2 then error(e2) end
        end)
        if ok then return true end
        -- the library would not append: the pages on a handle of the original, written whole
        os.remove(dst)
        local d = M.openDocument(src)
        local ok4, err4 = pcall(function()
            for _i, p in ipairs(pages) do
                local ok5, e5 = addPage(d, p, nil)
                if not ok5 then error(e5) end
            end
            d:writeDocument(dst)
        end)
        pcall(function() d:close() end)
        return ok4, err4 or err
    end
    function job.step()
        if job.over then return nil, "finished" end
        if not copy then
            local c, e = copier(src, dst)
            if not c then return fail(e) end
            copy = c
        end
        if not doc then
            local done, e = copy()
            if done == nil then return fail(e) end
            if not done then return "page", 0, job.n end
            local f = io.open(dst, "rb")
            orig_size = f and f:seek("end") or 0
            if f then f:close() end
            local ok, d = pcall(M.openDocument, dst)
            if not ok then return fail(d) end
            doc = d
        end
        if job.i < job.n then
            job.i = job.i + 1
            local ok, e = addPage(doc, pages[job.i], images)
            if not ok then return fail(e) end
            return "page", job.i, job.n
        end
        if not finished then
            finished = true
            local ok = pcall(function() doc:writeDocument(dst) end)
            if ok and next(images) then
                pcall(function() doc:close() end); doc = nil
                local applied, why = Overlay.apply(dst, orig_size, images)
                if not applied then
                    ok = false
                    job.fell_back = why or true
                end
            end
            if not ok then
                if next(images) then job.fell_back = job.fell_back or true end
                local ok2, err2 = again()
                if not ok2 then return fail(err2) end
            end
            if doc then pcall(function() doc:close() end); doc = nil end
            job.over = true
            return "done"
        end
        return nil, "finished"
    end
    function job.cancel()
        if job.over then return end
        drop()
    end
    return job
end

return Pdfedit
