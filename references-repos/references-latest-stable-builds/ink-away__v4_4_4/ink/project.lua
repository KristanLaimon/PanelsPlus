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

local function serializeRoot(root)
    local out = { "return " }
    ser(root, out)
    return table.concat(out)
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

-- Serialize a multi-page notebook (v2): the template plus one entry per page.
-- `cache` (optional, keyed by page) keeps each page's text from the last save,
-- so only pages missing from it are written out again; the caller drops a page
-- from the cache whenever that page changes.
function Project.serializeNotebook(nb, cache, extra)
    local head = addExtra({ v = 2, w = nb.w, h = nb.h, template = nb.template, toc = Project.toc(nb.pages) }, extra)
    local out = { "return " }
    ser(head, out)
    out[#out] = "[\"pages\"]={"   -- reopen the root table: replace its closing brace
    for i = 1, #nb.pages do
        local page = nb.pages[i]
        local s = cache and cache[page]
        if not s then
            local p = {}
            ser(page, p)
            s = table.concat(p)
            if cache then cache[page] = s end
        end
        out[#out + 1] = s
        out[#out + 1] = ","
    end
    out[#out + 1] = "},}"
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
    local chunk, err = load(str, "inkaway-data", "t", {})
    if not chunk then return nil, err end
    local ok, value = pcall(chunk)
    if not ok then return nil, value end
    return value
end

-- Parse a project string. Returns a table { w, h, ops } or nil, error.
function Project.deserialize(str)
    if type(str) ~= "string" or str == "" then return nil, "empty" end
    local chunk, err = load(str, "inkaway-project", "t", {})   -- sandbox: no env
    if not chunk then return nil, err end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then return nil, "not a project" end
    if type(data.w) ~= "number" or type(data.h) ~= "number"
        or (type(data.ops) ~= "table" and type(data.pages) ~= "table") then
        return nil, "missing fields"
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
