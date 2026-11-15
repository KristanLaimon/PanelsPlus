--[[
The edited copy of a book that "Exact lines" for Make room uses.

A float needs an element to hang on. crengine has them at a paragraph's start and
end and at inline elements, so a room could only start there. With Exact lines on,
the first word of the line a room should start on is wrapped in an empty-looking
`<span class="iar">`, which the room then hangs on (ink/reader/exactmark.lua does
the editing of the page's XHTML).

Nothing of the book on the reader's storage changes. The book's file is only
read. The edited copy is built in Ink Away's own cache folder, named after the
book's content (KOReader's partial md5 of the file) and the words wrapped, so:

  * the original keeps its bytes, its md5 (reading progress sync, Calibre and
    cloud copies of the book all still see the same book), its name and place;
  * moving, renaming, copying or sending the book changes nothing here: the copy is
    found again from the content, or built again when it is missing;
  * the words wrapped live in the book's ink file (`exact_marks`), which follows
    the book and takes part in Ink Away's cloud sync; the copy itself is never
    synced or exported, it can always be rebuilt from the book and the marks;
  * crengine is told to read the copy in place of the book (a hook on
    CreDocument:loadDocument), while KOReader keeps the book's own path for
    everything else: its settings, highlights, history and digest.

If the copy cannot be made, or cannot be read, the book opens as it always did.
]]

local logger = require("logger")

local Exact = {}

-- (marks kept with a book carry a hash of their text node, not the whole node)
pcall(function()
    local sha2 = require("ffi/sha2")
    if sha2 and sha2.md5 then require("ink/reader/exactmark").hash = sha2.md5 end
end)

Exact.SETTING = "inkaway_exact_rooms"
Exact.KEEP = 6   -- copies kept in the cache folder, newest first
-- The copy's files are stored as they are, not compressed again: building it is
-- about four times faster (a reader's CPU is slow at deflate), the copy a little
-- bigger, and only one copy of a book is kept (Exact.prune).
Exact.STORE_ALL = true

-- Is making rooms on exact lines switched on?
function Exact.enabled()
    local s = rawget(_G, "G_reader_settings")
    return s ~= nil and s:readSetting(Exact.SETTING) == true
end

function Exact.setEnabled(on)
    local s = rawget(_G, "G_reader_settings")
    if s then s:saveSetting(Exact.SETTING, on and true or false) end
end

-- The folder holding the copies.
function Exact.dir()
    local ok, DataStorage = pcall(require, "datastorage")
    local base = ok and DataStorage:getDataDir() or "."
    return base .. "/cache/ink-away-exact"
end

local function isFile(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function makeDir(d)
    local ok, util = pcall(require, "util")
    if ok and util.makePath then pcall(util.makePath, d) end
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    return lfs_ok and lfs.attributes(d, "mode") == "directory"
end

local sig_memo = setmetatable({}, { __mode = "k" })

-- A short signature of the marks: their ids, in order of id (a mark is never
-- changed once made, only added).
function Exact.signature(marks)
    -- (a list of marks is replaced, never changed, so its signature is kept with it)
    local memo = marks and sig_memo[marks]
    if memo and memo.n == #marks then return memo.sig end
    local sig = Exact.signatureOf(marks)
    if marks then sig_memo[marks] = { n = #marks, sig = sig } end
    return sig
end

-- The signature worked out, without the memo.
function Exact.signatureOf(marks)
    local ids = {}
    for _i, m in ipairs(marks or {}) do ids[#ids + 1] = tostring(m.id) end
    table.sort(ids)
    local text = table.concat(ids, ",")
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.md5 then return sha2.md5(text):sub(1, 10) end
    -- (no md5 here: a plain checksum is enough to tell sets of ids apart)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return string.format("%08x%02x", h, #ids % 256)
end

-- The name of the copy for `file` with `marks`: its content and the marks.
function Exact.keyFor(file, marks)
    local ok, util = pcall(require, "util")
    local md5 = ok and util.partialMD5 and util.partialMD5(file)
    if not md5 then return nil end
    return md5 .. "-" .. Exact.signature(marks)
end

function Exact.pathFor(file, marks)
    local key = Exact.keyFor(file, marks)
    return key and (Exact.dir() .. "/" .. key .. ".epub") or nil
end

-- Which entries are stored as they are (already compressed).
local STORED = { jpg = true, jpeg = true, png = true, gif = true, webp = true, woff = true, woff2 = true,
    mp3 = true, mp4 = true, m4a = true, ogg = true, zip = true }

local function extension(path) return (path:match("%.([%w]+)$") or ""):lower() end

-- Copies of the marks, safe to hand to ExactMark.apply (which writes each mark's
-- `split`, how the word was cut out of its text node, into the table it is given).
function Exact.copyMarks(marks)
    local function copy(v)
        if type(v) ~= "table" then return v end
        local out = {}
        for k, x in pairs(v) do out[k] = copy(x) end
        return out
    end
    local out = {}
    for i, m in ipairs(marks or {}) do out[i] = copy(m) end
    return out
end

-- Marks made small to be kept with the book: the text node they were checked
-- against becomes its hash (ExactMark.hash), when there is one.
function Exact.slim(marks)
    local hash = require("ink/reader/exactmark").hash
    if not hash then return marks end
    for _i, m in ipairs(marks or {}) do
        if type(m.node_text) == "string" then
            m.node_md5 = hash(m.node_text)
            m.node_text = nil
        end
    end
    return marks
end

-- The DOM version crengine numbers a book's fragments by.
local function domVersion()
    local ok, v = pcall(function()
        local CreDocument = require("document/credocument")
        return CreDocument:getDomVersionWithNormalizedXPointers()
    end)
    return ok and v or nil
end

-- The marks applied to `file`: { marks = <copies, each with its `split`>, results,
-- entries (the edited chapters, by path), reader (open on the book) } or nil and
-- why. Reads only the chapters the marks are in. The caller closes the reader.
-- What was read of the last books asked about: their spine and the chapters read,
-- so a box dragged in the Make room tool reads nothing from the file again (the
-- file is known by its path, size and time; a changed one is read afresh).
local sources = {}
local SOURCES_KEPT, CHAPTERS_KEPT = 2, 6

local function fileStamp(file)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    local attr = ok and lfs.attributes(file)
    if not attr then return nil end
    return file .. "|" .. tostring(attr.size) .. "|" .. tostring(attr.modification)
end

-- The book's source: { spine, chapter(path) -> bytes or nil }, or nil and why.
function Exact.source(file)
    local stamp = fileStamp(file)
    if not stamp then return nil, "unreadable" end
    for i, src in ipairs(sources) do
        if src.stamp == stamp then
            if i > 1 then table.remove(sources, i); table.insert(sources, 1, src) end
            return src
        end
    end
    local Archiver = require("ffi/archiver")
    local ExactMark = require("ink/reader/exactmark")
    local reader = Archiver.Reader:new()
    if not reader:open(file) then return nil, "unreadable" end
    -- (the reader knows an entry only once it has been through the list)
    for _e in reader:iterate() do end
    local ok, spine = pcall(ExactMark.spine, function(path) return reader:extractToMemory(path) end,
        { dom_version = domVersion() })
    reader:close()
    if not (ok and spine and #spine > 0) then return nil, "no_spine" end
    local src = { stamp = stamp, file = file, spine = spine, chapters = {}, order = {} }
    function src.chapter(path)
        local bytes = src.chapters[path]
        if bytes ~= nil then return bytes or nil end
        local r = Archiver.Reader:new()
        if r:open(src.file) then
            for _e in r:iterate() do end
            bytes = r:extractToMemory(path)
            r:close()
        end
        src.chapters[path] = bytes or false
        src.order[#src.order + 1] = path
        if #src.order > CHAPTERS_KEPT then src.chapters[table.remove(src.order, 1)] = nil end
        return bytes
    end
    table.insert(sources, 1, src)
    if #sources > SOURCES_KEPT then table.remove(sources) end
    return src
end

-- Forget what was read (the tests, and a book's copy built from changed marks).
function Exact.forgetSources() sources = {} end

-- The marks applied to `file`: { marks = <copies, each with its `split`>, results,
-- entries (the edited chapters, by path) } or nil and why. Reads only the
-- chapters the marks are in (once: Exact.source keeps them).
function Exact.compute(file, marks)
    local ExactMark = require("ink/reader/exactmark")
    local src, why = Exact.source(file)
    if not src then return nil, why end
    local spine = src.spine
    local chapters = {}
    for _i, m in ipairs(marks) do
        local path = spine[m.frag]
        if path and chapters[path] == nil then chapters[path] = src.chapter(path) or false end
    end
    for _path, bytes in pairs(chapters) do
        if not bytes then return nil, "missing_chapter" end
    end
    local copies = Exact.copyMarks(marks)
    local aok, entries, results = pcall(ExactMark.apply, chapters, copies, spine)
    if not (aok and entries) then return nil, aok and results or entries end
    return { marks = copies, results = results or {}, entries = entries }
end

-- The element xpointer of each mark's span in the edited copy ({ [mark id] = xp }),
-- and the marks with their `split` for ExactMark.toNew and toOld. Nil and why when
-- the book is not the one the marks were made in.
function Exact.spanXPointers(file, marks)
    local c, why = Exact.compute(file, marks)
    if not c then return nil, why end
    local out = {}
    for i, r in ipairs(c.results) do
        if r.applied and r.xp then out[marks[i].id] = r.xp end
    end
    return out, c.marks
end

-- Build the copy of `file` with `marks` at `dest` (through a temporary file, so a
-- half-written one is never read). Returns dest and the marks left out (a list of
-- { mark, why }: the book is not the one they were made in), or nil and why.
function Exact.build(file, marks, dest)
    local Archiver = require("ffi/archiver")
    local c, why = Exact.compute(file, marks)
    if not c then return nil, why end
    local entries = c.entries
    local reader = Archiver.Reader:new()
    if not reader:open(file) then return nil, "unreadable" end
    for _e in reader:iterate() do end
    local function read(path) return reader:extractToMemory(path) end
    local skipped = {}
    for i, r in ipairs(c.results) do
        if not r.applied then skipped[#skipped + 1] = { mark = marks[i], why = r.why } end
    end
    makeDir(Exact.dir())
    local tmp = dest .. ".part"
    os.remove(tmp)
    local writer = Archiver.Writer:new()
    if not writer:open(tmp, "epub") then reader:close(); return nil, "unwritable" end
    local ok, err = pcall(function()
        -- the mimetype first, stored, as an EPUB has it
        local mime = read("mimetype")
        if mime then
            writer:setZipCompression("store")
            assert(writer:addFileFromMemory("mimetype", mime))
        end
        for e in reader:iterate() do
            if e.mode == "file" and e.path ~= "mimetype" then
                local bytes = entries[e.path] or reader:extractToMemory(e.path)
                if not bytes then error("could not read " .. e.path) end
                writer:setZipCompression((Exact.STORE_ALL or STORED[extension(e.path)]) and "store" or "deflate")
                assert(writer:addFileFromMemory(e.path, bytes))
            end
        end
    end)
    writer:close()
    reader:close()
    if not ok then
        os.remove(tmp)
        return nil, tostring(err)
    end
    os.remove(dest)
    if not os.rename(tmp, dest) then
        os.remove(tmp)
        return nil, "rename_failed"
    end
    return dest, skipped
end

-- Keep the newest `Exact.KEEP` copies, and none for an older state of `keep_file`'s
-- own book (same content, other marks), which nothing can ask for again.
function Exact.prune(keep_path)
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then return end
    local dir = Exact.dir()
    local files = {}
    local ok = pcall(function()
        for name in lfs.dir(dir) do
            if name:match("%.epub$") or name:match("%.epub%.part$") then
                local p = dir .. "/" .. name
                local m = lfs.attributes(p, "modification") or 0
                files[#files + 1] = { path = p, name = name, time = m }
            end
        end
    end)
    if not ok then return end
    local keep_book = keep_path and keep_path:match("([^/]+)%-[^/%-]+%.epub$")
    table.sort(files, function(a, b) return a.time > b.time end)
    local kept = 0
    for _i, f in ipairs(files) do
        local same_book = keep_book and f.name:sub(1, #keep_book + 1) == keep_book .. "-"
        if f.path == keep_path then
            kept = kept + 1
        elseif f.name:match("%.part$") or same_book or kept >= Exact.KEEP then
            os.remove(f.path)
        else
            kept = kept + 1
        end
    end
end

-- The marks of the book at `file`: from its ink file, without reading the strokes.
function Exact.marksOf(file)
    local ok, BookInk = pcall(require, "ink/reader/bookink")
    if not ok then return nil end
    local lok, where = pcall(BookInk.locate, file)
    if not (lok and where and where.dir) then return nil end
    local pok, marks = pcall(BookInk.peekMarks, where.dir)
    return pok and marks or nil
end

-- The path crengine should read for `file`: the edited copy (built now when it
-- is not in the cache), or nil to read the book itself.
function Exact.resolve(file)
    local marks = Exact.marksOf(file)
    if not marks then return nil end
    local dest = Exact.pathFor(file, marks)
    if not dest then return nil end
    if isFile(dest) then
        pcall(function()   -- (touched, so the newest are the ones in use)
            local lfs = require("libs/libkoreader-lfs")
            lfs.touch(dest)
        end)
        return dest
    end
    local built, skipped = Exact.build(file, marks, dest)
    if not built then
        logger.warn("Ink Away: the book's edited copy could not be made:", skipped)
        return nil
    end
    if skipped and #skipped > 0 then
        logger.warn("Ink Away: marks left out of the edited copy:", #skipped)
    end
    pcall(Exact.prune, built)
    return built
end

-- Make crengine read the edited copy of a book that has one. Once for the whole
-- session; the book's path (document.file) is the book's everywhere but in the
-- one call that opens the file.
function Exact.install()
    if Exact._installed then return end
    local ok, CreDocument = pcall(require, "document/credocument")
    if not ok then return end
    Exact._installed = true
    local orig = CreDocument.loadDocument
    CreDocument.loadDocument = function(self, full_document)
        if self._loaded or full_document == false or not self.file then return orig(self, full_document) end
        local rok, copy = pcall(Exact.resolve, self.file)
        if not (rok and copy) then
            if not rok then logger.warn("Ink Away: edited copy:", copy) end
            return orig(self, full_document)
        end
        local real = self.file
        self.file = copy
        local lok, loaded = pcall(orig, self, full_document)
        self.file = real
        if lok and loaded then
            self._ink_exact_copy = copy
            return loaded
        end
        -- (the copy would not open: the book itself does)
        logger.warn("Ink Away: the edited copy would not open, the book opens as it is")
        self._loaded = false
        os.remove(copy)
        return orig(self, full_document)
    end
end

return Exact
