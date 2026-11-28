local util = require("util")
local logger = require("logger")

local Local = {}

-- Directory and file name of path; a bare name gives an empty directory.
local function splitPath(path)
    local dir, name = path:match("^(.*)[/\\]([^/\\]*)$")
    if not dir then
        return "", path
    end
    return dir, name
end

local function folderName(dir)
    return dir:match("([^/\\]+)$") or ""
end

-- Fold A-Z by hand: a device locale's tolower folds I differently.
local function asciiLower(s)
    return (s:gsub("[A-Z]", function(c)
        return string.char(c:byte() + 32)
    end))
end

-- A key, not a comparator: table.sort cannot see an inconsistent order.
-- Digits become \1 + 3-digit length + digits; pad \255 orders 2 before 10.
local function sortKey(name)
    local out = {}
    local i = 1
    while i <= #name do
        if name:byte(i) >= 48 and name:byte(i) <= 57 then
            local last = select(2, name:find("%d+", i))
            local run = name:sub(i, last)
            local digits = run:gsub("^0+", "")
            if digits == "" then
                digits = "0"
            end
            out[#out + 1] = "\1" .. string.format("%03d", #digits) .. digits
                .. string.rep("\255", #run - #digits)
            i = last + 1
        else
            out[#out + 1] = name:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

-- KOReader's util.findFiles, recursive=false; deliberately uncapped.
-- A listing missing the file being read is a failure, not "no neighbours".
local function runOf(path)
    local dir, base = splitPath(path)
    if dir == "" then
        return nil, "the file names no folder"
    end
    local lower_base = asciiLower(base)
    local self_ext = asciiLower(select(2, util.splitFileNameSuffix(base)) or "")

    local run = {}
    util.findFiles(dir, function(full, name)
        -- Never a book; on macOS cards these are AppleDouble companions.
        if name:sub(1, 1) == "." then
            return
        end
        -- Same extension as the current file, so .cbr or a marker never joins.
        if asciiLower(select(2, util.splitFileNameSuffix(name)) or "") ~= self_ext then
            return
        end
        run[#run + 1] = { path = full, name = name, key = sortKey(name) }
    end, false)

    local here
    for i = 1, #run do
        if asciiLower(run[i].name) == lower_base then
            here = run[i]
            break
        end
    end
    if not here then
        logger.warn("Meguru: cannot list the folder of", path,
            "(the listing does not contain it)")
        return nil, "the folder could not be listed, or does not contain this file"
    end

    -- Sorted by key; a position in the run, not arithmetic on a name.
    table.sort(run, function(a, b)
        return a.key < b.key
    end)
    local pos
    for i = 1, #run do
        if run[i] == here then
            pos = i
            break
        end
    end

    logger.dbg("Meguru: local folder", dir, "—", #run, "book(s), this one at", pos)
    return run, pos
end

-- nil unless the folder holds a second book, so a one-shot gets no rows.
function Local.seriesOf(path)
    local run = runOf(path)
    if not run or #run < 2 then
        return nil
    end
    return { name = folderName(splitPath(path)) }
end

-- Anything but "previous" reads as "next"; the reason is only for the log.
function Local.neighbor(path, which)
    local run, pos = runOf(path)
    if not run then
        return nil, pos
    end
    if #run < 2 then
        return nil, "nothing else in the folder"
    end
    local pick = run[which == "previous" and pos - 1 or pos + 1]
    if not pick then
        return nil, which == "previous" and "the first book in the folder"
            or "the last book in the folder"
    end
    return pick.path
end

return Local
