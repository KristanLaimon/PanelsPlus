--[[
Searching the library: folder and document names and page titles, and on
request the typed text inside pages (text boxes, including handwriting turned
into text). Plain Lua, so the headless tests drive it; ink/view/search.lua runs
it a little at a time behind a progress bar.

Nothing here runs unless a search is asked for. A notebook file keeps a short
list of its page titles before its pages, written with every save,
so a names search reads only the start of each notebook (Project.toc). Looking inside pages
loads whole documents; what it finds is kept in a hidden file in the library
(Search.CACHE), keyed by each file's time and size, so the next search reads
only the documents that changed since.

  * Search.walk(root, skip)          the folders and documents under root
  * Search.newIndex(cache)           an index over a saved cache
  * index:document(e, inside)        a document's titles (and text), from the cache or its file
  * Search.find(entries, index, query, lower, inside)   the matches
]]

local Project = require("ink/project")
local Storage = require("ink/storage")

local Search = {}

Search.CACHE = ".inkaway-search"
local VERSION = 1

------------------------------------------------------------------------------
-- What there is to search
------------------------------------------------------------------------------

-- The folders and documents under `root`, depth first, without hidden entries
-- and without the folders named in `skip` (at the top only). Each entry is
-- { kind = "folder" | "doc", name, path, dir, mtime, size }.
function Search.walk(root, skip)
    local out = {}
    local function visit(dir, top)
        local ok, list = pcall(Storage.list, dir)
        if not ok or type(list) ~= "table" then return end
        table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
        for _, e in ipairs(list) do
            if e.name:sub(1, 1) ~= "." and not (top and skip and skip[e.name]) then
                if e.mode == "directory" then
                    out[#out + 1] = { kind = "folder", name = e.name, path = e.path, dir = dir }
                    visit(e.path, false)
                elseif e.mode == "file" and e.name:lower():match("%." .. Project.EXT .. "$") then
                    out[#out + 1] = { kind = "doc", name = Storage.stem(e.path), path = e.path, dir = dir,
                        mtime = e.mtime, size = e.size }
                end
            end
        end
    end
    visit(root, true)
    return out
end

------------------------------------------------------------------------------
-- Reading documents
------------------------------------------------------------------------------

local PAGES_KEY = '["pages"]={'

-- The start of a notebook file up to its pages, as a table (its template and
-- page-title list), without reading the pages. Nil for a drawing or a file that
-- cannot be read.
function Search.readHead(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local seen, found = {}, nil
    local tail = ""
    local total = 0
    while true do
        local chunk = f:read(16384)
        if not chunk then break end
        local s = tail .. chunk
        local at = s:find(PAGES_KEY, 1, true)
        if at then
            seen[#seen + 1] = s:sub(#tail + 1, at - 1)
            found = true
            break
        end
        seen[#seen + 1] = chunk
        tail = chunk:sub(-#PAGES_KEY)
        total = total + #chunk
        -- a drawing lists its ops early, and a head is small: stop looking
        if chunk:find('["ops"]={', 1, true) or total > 1048576 then break end
    end
    f:close()
    if not found then return nil end
    local head = Project.decode(table.concat(seen) .. "}")
    return type(head) == "table" and head or nil
end

-- The plain text of a page's ops: its text boxes, one per line.
local function opsText(ops, Text)
    if type(ops) ~= "table" then return nil end
    local t = {}
    for _, op in ipairs(ops) do
        if type(op) == "table" and op.kind == "text" and type(op.paras) == "table" then
            local ok, s = pcall(Text.plain, op)
            if ok and s and s ~= "" then t[#t + 1] = s end
        end
    end
    return #t > 0 and table.concat(t, "\n") or nil
end

-- Everything search needs from a document file: whether it is a notebook, and
-- its pages as { { n = number, i = id, t = title, x = text }, ... }. With
-- `inside` false only the titles are needed, and for a notebook that carries
-- its title list only the start of the file is read. Returns the record, or
-- nil when the file cannot be read.
function Search.readDocument(path, inside)
    local f = io.open(path, "rb")
    if not f then return nil end
    f:close()
    if not inside then
        local head = Search.readHead(path)
        if head and type(head.toc) == "table" then
            local pages = {}
            for _, e in ipairs(head.toc) do
                if type(e) == "table" and type(e.t) == "string" then
                    pages[#pages + 1] = { n = tonumber(e.p) or 1, i = e.i, t = e.t }
                end
            end
            return { nb = true, pages = pages, full = false }
        end
        -- a drawing has no titles to find; only its name is searched
        if not head and not Search.looksLikeNotebook(path) then return { nb = false, pages = {}, full = false } end
    end
    local data = Project.load(path)
    if type(data) ~= "table" then return nil end
    local Text = require("ink/text")
    local pages = {}
    if Project.isNotebook(data) then
        for i, p in ipairs(data.pages) do
            if type(p) == "table" then
                local ops = p.ops or (p.src == nil and p.id == nil and p) or nil
                local title = type(p.title) == "string" and p.title ~= "" and p.title or nil
                local text = opsText(ops, Text)
                if title or text then pages[#pages + 1] = { n = i, i = p.id, t = title, x = text } end
            end
        end
        return { nb = true, pages = pages, full = true }
    end
    local text = opsText(data.ops, Text)
    if text then pages[1] = { n = 1, x = text } end
    return { nb = false, pages = pages, full = true }
end

-- Is the document a notebook? Reads only the start of the file.
function Search.looksLikeNotebook(path)
    return require("ink/library").isNotebookFile(path)
end

------------------------------------------------------------------------------
-- The index and its cache
------------------------------------------------------------------------------

local Index = {}
Index.__index = Index

-- An index over `cache` (a table read back from Search.CACHE, or nil).
function Search.newIndex(cache)
    local docs = (type(cache) == "table" and cache.v == VERSION and type(cache.docs) == "table") and cache.docs or {}
    return setmetatable({ docs = docs, seen = {}, changed = false }, Index)
end

-- The record of document entry `e` (from Search.walk): from the cache while
-- its file is unchanged (and, for `inside`, the cache holds its text), else
-- read from the file. Nil when the file cannot be read.
function Index:document(e, inside)
    self.seen[e.path] = true
    -- kept as strings: project files write numbers to six digits
    local m, s = tostring(e.mtime), tostring(e.size)
    local r = self.docs[e.path]
    if type(r) == "table" and r.m == m and r.s == s and (r.full or not inside) then return r end
    local ok, rec = pcall(Search.readDocument, e.path, inside)
    if not ok or not rec then return nil end
    rec.m, rec.s = m, s
    self.docs[e.path] = rec
    self.changed = true
    return rec
end

-- The cache to save: only the documents still there.
function Index:toCache()
    local docs = {}
    for path, r in pairs(self.docs) do
        if self.seen[path] then docs[path] = r end
    end
    return { v = VERSION, docs = docs }
end

-- Read the cache file in library folder `root` (nil when there is none).
function Search.loadCache(root)
    local f = io.open(Storage.join(root, Search.CACHE), "rb")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    return Project.decode(raw)
end

function Search.saveCache(root, index)
    return Storage.writeAtomic(Storage.join(root, Search.CACHE), Project.encode(index:toCache()))
end

------------------------------------------------------------------------------
-- Matching
------------------------------------------------------------------------------

-- The words of `query`, lowered with `lower`.
local function terms(query, lower)
    local t = {}
    for w in lower(query):gmatch("%S+") do t[#t + 1] = w end
    return t
end

-- Does `text` (already lowered) hold every term? Returns the place of the first.
local function holds(text, ts)
    if not text then return nil end
    local first
    for _, w in ipairs(ts) do
        local at = text:find(w, 1, true)
        if not at then return nil end
        first = first or at
    end
    return first
end

-- A short piece of `text` around byte `at`, on one line, cut at whole
-- characters.
local function snippet(text, at, want)
    want = want or 60
    local a = math.max(1, at - 20)
    local b = math.min(#text, a + want)
    -- move to character starts: UTF-8 continuation bytes are 0x80-0xBF
    while a > 1 and text:byte(a) and text:byte(a) >= 0x80 and text:byte(a) < 0xC0 do a = a - 1 end
    while b < #text and text:byte(b + 1) and text:byte(b + 1) >= 0x80 and text:byte(b + 1) < 0xC0 do b = b + 1 end
    local s = text:sub(a, b):gsub("%s+", " ")
    if a > 1 then s = "\u{2026}" .. s end
    if b < #text then s = s .. "\u{2026}" end
    return s
end

-- The matches for `query` among `entries` (Search.walk), whose documents'
-- records `records[path]` hold. `lower` lowers a string (any case folding);
-- with `inside` the text of pages is searched too. Returns a list of
-- { kind = "folder" | "doc" | "page", path, name, dir, page = number, id,
-- title, text = snippet, nb = bool }: folders, then documents, then pages.
function Search.find(entries, records, query, lower, inside)
    local ts = terms(query or "", lower)
    if #ts == 0 then return {} end
    local folders, docs, pages = {}, {}, {}
    for _, e in ipairs(entries) do
        local r = e.kind == "doc" and records[e.path] or nil
        if holds(lower(e.name), ts) then
            local hit = { kind = e.kind, path = e.path, name = e.name, dir = e.dir, nb = r and r.nb }
            if e.kind == "folder" then folders[#folders + 1] = hit else docs[#docs + 1] = hit end
        end
        if r then
            for _, p in ipairs(r.pages or {}) do
                local t_at = p.t and holds(lower(p.t), ts)
                local x_at = inside and p.x and holds(lower(p.x), ts)
                if t_at or x_at then
                    pages[#pages + 1] = { kind = "page", path = e.path, name = e.name, dir = e.dir,
                        page = p.n, id = p.i, title = p.t, nb = r.nb,
                        text = (not t_at and x_at) and snippet(p.x, x_at) or nil }
                end
            end
        end
    end
    local out = {}
    for _, list in ipairs({ folders, docs, pages }) do
        for _, h in ipairs(list) do out[#out + 1] = h end
    end
    return out
end

return Search
