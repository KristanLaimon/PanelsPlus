--[[
The page each notebook was left on, so it opens there again. Kept in this
reader's settings, not in the notebook's file: turning pages changes nothing in
the file (no save, nothing for the cloud sync to send or to call a conflict),
and each reader opens a notebook where it was left on that reader.

{ [notebook path] = { id = <the page's id>, t = <when> }, ... }: the page's id,
not its number, so pages added, moved or deleted before it keep it found. The
most recent LastPage.MAX notebooks are kept. Plain Lua (the settings are passed
in and out), so the headless tests drive it.
]]

local LastPage = {}

LastPage.SETTING = "inkaway_nb_last_page"
LastPage.MAX = 300

-- The id of the page notebook `path` was left on, or nil.
function LastPage.get(map, path)
    local e = type(map) == "table" and path and map[path]
    return type(e) == "table" and e.id or nil
end

-- Where page `id` is in `pages` (a notebook's), or nil.
function LastPage.indexOf(pages, id)
    if id == nil then return nil end
    for i, p in ipairs(pages or {}) do
        if p.id == id then return i end
    end
end

-- `map` with notebook `path` left on page `id` (at time `now`), the oldest
-- dropped past LastPage.MAX; or nil when nothing changes (it is kept already).
function LastPage.put(map, path, id, now)
    if not (path and id) then return nil end
    map = type(map) == "table" and map or {}
    local e = map[path]
    if type(e) == "table" and e.id == id then return nil end
    local out, n = {}, 0
    for k, v in pairs(map) do
        if type(v) == "table" then out[k] = v; n = n + 1 end
    end
    if not out[path] then n = n + 1 end
    out[path] = { id = id, t = now or os.time() }
    while n > LastPage.MAX do
        local oldest, ot
        for k, v in pairs(out) do
            if k ~= path and (not ot or (v.t or 0) < ot) then oldest, ot = k, v.t or 0 end
        end
        if not oldest then break end
        out[oldest] = nil
        n = n - 1
    end
    return out
end

-- `map` with the notebooks at `old` (a file, or every one in a folder) now at
-- `new`; or nil when none was there.
function LastPage.moved(map, old, new)
    if type(map) ~= "table" or not (old and new) or old == new then return nil end
    local out, changed = {}, false
    for k, v in pairs(map) do
        if k == old or k:sub(1, #old + 1) == old .. "/" then
            out[new .. k:sub(#old + 1)] = v
            changed = true
        else
            out[k] = v
        end
    end
    return changed and out or nil
end

return LastPage
