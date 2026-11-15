--[[
The files a notebook uses besides itself: the pictures pasted on its pages, its
background, and the PDF it writes on. A notebook stores these as full paths of
the reader that made it, which mean nothing on another reader. So the sync
(1) finds them in the notebook's text, and (2) after a second reader has
downloaded the notebook, finds each file again by its place in the library or
among the files the sync brought along (see ink/sync/portable.lua). Nothing in
a notebook is ever rewritten.

Plain Lua, so the headless tests drive it.
]]

local Refs = {}

local KEYS = { "path", "src_path", "pdf_path", "bg" }

-- The paths a notebook's text refers to, each once, in the order found. A path
-- with a backslash or control character is left out.
function Refs.paths(text)
    local out, seen = {}, {}
    if type(text) ~= "string" then return out end
    for _i, key in ipairs(KEYS) do
        local needle = '["' .. key .. '"]="'
        local from = 1
        while true do
            local a, b = text:find(needle, from, true)
            if not a then break end
            local e = text:find('"', b + 1, true)
            if not e then break end
            local p = text:sub(b + 1, e - 1)
            if p ~= "" and not p:find("[\\%c]") and not seen[p] then
                seen[p] = true
                out[#out + 1] = p
            end
            from = e + 1
        end
    end
    return out
end

-- The paths of the file at `path`.
function Refs.ofFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return Refs.paths(text)
end

return Refs
