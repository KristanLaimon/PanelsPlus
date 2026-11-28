--[[
Editable project files. A drawing is a list of ops, so a project is that list
written out, and a reopened project stays fully editable. The file is a small Lua
chunk ("return { ... }") loaded in a sandbox with no globals, so a tampered file
can define data but cannot run code.
]]

local Storage = require("ink/storage")

local Project = {}

Project.EXT = "inkaway"

-- Serialize a Lua value into `out`: numbers, booleans, strings, and tables with
-- an array part and string keys, which is all an ops list holds.
local function ser(v, out)
    local t = type(v)
    if t == "number" then
        -- six digits keep files small; a large whole number (a time) is written
        -- exactly, as six digits would round it
        if (v >= 1e6 or v <= -1e6) and v == math.floor(v) and v < 2^53 and v > -2^53 then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.6g", v)
        end
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "table" then
        out[#out + 1] = "{"
        local n = #v
        for i = 1, n do ser(v[i], out); out[#out + 1] = "," end
        for k, val in pairs(v) do
            if type(k) == "string" then
                out[#out + 1] = "[" .. string.format("%q", k) .. "]="
                ser(val, out)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = "nil"
    end
end

-- LuaJIT loads a chunk only while each of its functions holds at most 65536
-- constants, and in a file of literals every table and string is one (#92: a
-- notebook of some 70 pages of handwriting would no longer open). A big file is
-- therefore written as small functions that each fill part of a table, which any
-- Lua reads as before, and a file written in one piece is split the same way when
-- it is read. SPLIT_AT is how many a single function is given at most; a file
-- whose tables and strings stay under ROOM is written exactly as it always was.
local SPLIT_AT = 16000
local ROOM = 40000

-- A rough count of the constants in serialized text: its tables and strings
-- (never fewer than LuaJIT counts).
local function cost(s)
    return select(2, s:gsub("[{\"]", ""))
end
Project.cost = cost

-- Where the string opening at s[i] (a quote) ends: the index after its closing
-- quote, or nil.
local function skipString(s, i)
    local j = i + 1
    while true do
        local k = s:find('["\\]', j)
        if not k then return nil end
        if s:byte(k) == 92 then j = k + 2 else return k + 1 end
    end
end

-- Where the table opening at s[i] ends: the index after its closing brace, and
-- how many tables and strings it holds; or nil.
local function skipTable(s, i)
    local depth, j, n = 0, i, 0
    while true do
        local k = s:find('[{}"]', j)
        if not k then return nil end
        local c = s:byte(k)
        if c == 34 then
            j = skipString(s, k)
            if not j then return nil end
            n = n + 1
        elseif c == 123 then
            depth, n, j = depth + 1, n + 1, k + 1
        else
            depth, j = depth - 1, k + 1
            if depth == 0 then return j, n end
        end
    end
end

-- The fields of the table opening at s[i], as { key = "[...]" or nil, a, b, n }
-- (its value is s:sub(a, b - 1) and holds n tables and strings), and the index
-- after the table; or nil when the text is not what Project writes.
local function fields(s, i)
    local list, j = {}, i + 1
    while true do
        j = s:find("[^%s]", j)
        if not j then return nil end
        local c = s:byte(j)
        if c == 125 then return list, j + 1 end
        local key
        if c == 91 then
            local k = s:find("[^%s]", j + 1)
            if not k then return nil end
            local after = s:byte(k) == 34 and skipString(s, k) or k
            local rb = after and s:find("]", after, true)
            local eq = rb and s:find("[^%s]", rb + 1)
            if not eq or s:byte(eq) ~= 61 then return nil end
            key = s:sub(j, rb)
            j = s:find("[^%s]", eq + 1)
            if not j then return nil end
            c = s:byte(j)
        end
        local b, n
        if c == 123 then b, n = skipTable(s, j)
        elseif c == 34 then b, n = skipString(s, j), 1
        else b, n = s:find("[,}]", j), 0 end
        if not b then return nil end
        list[#list + 1] = { key = key, a = j, b = b, n = n }
        j = s:find("[^%s]", b)
        if not j then return nil end
        if s:byte(j) == 44 then j = j + 1 end
    end
end

-- The table literal opening at s[i] as an expression that builds the same table
-- in functions of at most SPLIT_AT constants each; or nil.
local function splitTable(s, i)
    local list = fields(s, i)
    if not list then return nil end
    local out, pos, budget, open = { "(function() local t={}; " }, 0, 0, false
    for _, f in ipairs(list) do
        local val, n = s:sub(f.a, f.b - 1), f.n + 1
        if f.n > SPLIT_AT and s:byte(f.a) == 123 then
            val = splitTable(s, f.a)
            if not val then return nil end
            n = 1
        end
        if open and budget + n > SPLIT_AT then out[#out + 1] = "end)(); "; open = false end
        if not open then out[#out + 1] = "(function() "; open, budget = true, 0 end
        local target
        if f.key then target = "t" .. f.key else pos = pos + 1; target = "t[" .. pos .. "]" end
        out[#out + 1] = target .. "=" .. val .. "; "
        budget = budget + n
    end
    if open then out[#out + 1] = "end)(); " end
    out[#out + 1] = "return t end)()"
    return table.concat(out)
end

-- A chunk "return {...}" rewritten so LuaJIT can load it however big it is, or
-- nil when it is not a single table literal.
function Project.split(str)
    local i = str:find("{", 1, true)
    if not i or not str:sub(1, i - 1):match("^%s*return%s*$") then return nil end
    local e = select(1, skipTable(str, i))
    if not e or str:find("[^%s]", e) then return nil end
    local body = splitTable(str, i)
    return body and ("return " .. body) or nil
end

-- Load a chunk of data in a sandbox; a file LuaJIT finds too big in one piece is
-- split and loaded again.
local function loadData(str, name)
    local chunk, err = load(str, name, "t", {})   -- sandbox: no env
    if not chunk and type(err) == "string" and err:find("constants", 1, true) then
        local split = Project.split(str)
        if split then
            local chunk2 = load(split, name, "t", {})
            if chunk2 then return chunk2 end
        end
    end
    return chunk, err
end

-- `str` as written, or split when it holds too many constants for one function.
local function fit(str, n)
    if (n or cost(str)) <= ROOM then return str end
    return Project.split(str) or str
end
Project.fit = fit
Project.ROOM = ROOM

local function serializeRoot(root)
    local out = { "return " }
    ser(root, out)
    return fit(table.concat(out))
end

-- Copy the string-keyed fields of `extra` (background, notes about the file)
-- into `root`.
local function addExtra(root, extra)
    if extra then
        for k, v in pairs(extra) do root[k] = v end
    end
    return root
end

-- Serialize a single-page canvas (v1) to a project string. `extra` adds fields
-- such as the background picture's path.
function Project.serialize(canvas, extra)
    return serializeRoot(addExtra({ v = 1, w = canvas.w, h = canvas.h, ops = canvas.ops }, extra))
end

-- The list of page titles a notebook file carries before its pages, so a
-- search by name reads only the start of the file: { n = page count,
-- { p = page number, i = page id, t = title }, ... } for the titled pages.
function Project.toc(pages)
    local toc = { n = #pages }
    for i, p in ipairs(pages) do
        if type(p) == "table" and type(p.title) == "string" and p.title ~= "" then
            toc[#toc + 1] = { p = i, i = p.id, t = p.title }
        end
    end
    return toc
end

-- Each page's text and its count of tables and strings, from the last save.
local page_cost = setmetatable({}, { __mode = "k" })

-- Serialize a multi-page notebook (v2): the template plus one entry per page.
-- `cache` (optional, keyed by page) keeps each page's text from the last save,
-- so only pages missing from it are written out again; the caller drops a page
-- from the cache whenever that page changes.
function Project.serializeNotebook(nb, cache, extra)
    local head = addExtra({ v = 2, w = nb.w, h = nb.h, template = nb.template, toc = Project.toc(nb.pages) }, extra)
    local out = { "return " }
    ser(head, out)
    out[#out] = "[\"pages\"]={"   -- reopen the root table: replace its closing brace
    local first, texts, total = #out, {}, 0
    for i = 1, #nb.pages do
        local page = nb.pages[i]
        local s = cache and cache[page]
        if not s then
            local p = {}
            ser(page, p)
            s = table.concat(p)
            if cache then cache[page] = s end
        end
        local known = page_cost[page]
        if not known or known.s ~= s then known = { s = s, n = cost(s) }; page_cost[page] = known end
        texts[i], total = known, total + known.n
        out[#out + 1] = s
        out[#out + 1] = ","
    end
    if total <= ROOM then
        out[#out + 1] = "},}"
        return table.concat(out)
    end
    -- a big notebook (#92): each page in a function of its own, and with very
    -- many pages the list of them filled in parts too
    local exprs = {}
    for i, t in ipairs(texts) do
        local body = t.n > SPLIT_AT and Project.split("return " .. t.s)
        exprs[i] = body and ("(function() " .. body .. " end)()") or ("(function() return " .. t.s .. " end)()")
    end
    if #exprs <= SPLIT_AT then
        for i, e in ipairs(exprs) do out[first + 2 * i - 1] = e end
        out[#out + 1] = "},}"
        return table.concat(out)
    end
    out[first] = "[\"pages\"]="
    return table.concat(out, "", 1, first) .. Project.listOf(exprs) .. ",}"
end

-- An expression that builds the list of the given element expressions in parts
-- of at most SPLIT_AT constants. costs[i] is how many element i holds (1 when
-- omitted: an element that is a function of its own).
function Project.listOf(exprs, costs)
    local out, budget, open = { "(function() local t={}; " }, 0, false
    for i, e in ipairs(exprs) do
        local n = (costs and costs[i] or 1) + 1
        if open and budget + n > SPLIT_AT then out[#out + 1] = "end)(); "; open = false end
        if not open then out[#out + 1] = "(function() "; open, budget = true, 0 end
        out[#out + 1] = "t[" .. i .. "]=" .. e .. "; "
        budget = budget + n
    end
    if open then out[#out + 1] = "end)(); " end
    out[#out + 1] = "return t end)()"
    return table.concat(out)
end

-- Any plain value (numbers, strings, booleans, tables of them) as a chunk that
-- Project.decode reads back. Small files beside the projects use it too.
function Project.encode(value)
    return serializeRoot(value)
end

-- Read a value written by Project.encode, in a sandbox. Returns it, or nil, err.
function Project.decode(str)
    if type(str) ~= "string" or str == "" then return nil, "empty" end
    local chunk, err = loadData(str, "inkaway-data")
    if not chunk then return nil, err end
    local ok, value = pcall(chunk)
    if not ok then return nil, value end
    return value
end

-- Parse a project string. Returns a table { w, h, ops } or nil, error.
function Project.deserialize(str)
    if type(str) ~= "string" or str == "" then return nil, "empty" end
    local chunk, err = loadData(str, "inkaway-project")
    if not chunk then return nil, err end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then return nil, "not a project" end
    if type(data.w) ~= "number" or type(data.h) ~= "number"
        or (type(data.ops) ~= "table" and type(data.pages) ~= "table") then
        return nil, "missing fields"
    end
    -- a notebook from another reader names its pictures and PDF by that reader's paths
    -- (see ink/sync/portable.lua): the ones missing here are looked for in this library
    local portable = package.loaded["ink/sync/portable"]
    if portable and portable.root then
        local rooted, root = pcall(portable.root)
        if rooted and root then pcall(portable.apply, data, root) end
    end
    return data
end

-- Is this parsed project a multi-page notebook (v2) rather than a single canvas?
function Project.isNotebook(data)
    return type(data) == "table" and type(data.pages) == "table"
end

-- Write the canvas to a file at `path`. Returns ok, err.
function Project.save(canvas, path, extra)
    return Storage.writeAtomic(path, Project.serialize(canvas, extra))
end

-- Write a notebook to a file at `path`. Returns ok, err.
function Project.saveNotebook(nb, path, cache, extra)
    return Storage.writeAtomic(path, Project.serializeNotebook(nb, cache, extra))
end

-- Read a project file. Returns { w, h, ops } or nil, err. A save cut short
-- after its temporary file was written leaves only that file; it is read then.
function Project.load(path)
    local f, err = io.open(path, "rb")
    if not f then f = io.open(path .. ".tmp", "rb") end
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return Project.deserialize(data)
end

return Project
