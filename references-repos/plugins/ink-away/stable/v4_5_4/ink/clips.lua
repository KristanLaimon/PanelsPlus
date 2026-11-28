--[[
The screen clips (see ink/reader/capture.lua): the pictures of part of a book's
page, kept in the "screen clips" folder of Ink Away's folder. The folder holds
only what was copied and not used: a clip put on a page, in a notebook or as a
background is first copied out to a folder of its own ("clipped images", which
the library leaves out), so the page keeps its picture. What is left in the
folder is removed after a while, by default a week, which the person can change
or turn off from the folder's menu in the library (the ... button).

Plain Lua (the settings, the clock and the folders are passed in), so the
headless tests drive it.
]]

local Storage = require("ink/storage")

local Clips = {}

Clips.FOLDER = "screen clips"       -- under "ink away"
Clips.KEPT = "clipped images"       -- under "ink away": clips that are in use
Clips.AUTO = "inkaway_clips_auto"   -- settings: delete old clips (on unless false)
Clips.DAYS = "inkaway_clips_days"   -- settings: how many days a clip is kept
Clips.DEFAULT_DAYS = 7
Clips.CHOICES = { 1, 3, 7, 14, 30 }

-- The file name a clip is saved under (see Capture:copySelection).
function Clips.isClipName(name)
    return type(name) == "string" and name:match("^clip%-%d+%-%d+%.png$") ~= nil
end

-- The folder the clips are in, made if missing, or nil.
function Clips.dir()
    return Storage.appDir(Clips.FOLDER)
end

-- Is `dir` the clips folder (or inside it)? Without making it.
function Clips.isClipsDir(dir)
    local root = Storage.appRootPath()
    return dir ~= nil and root ~= nil and Storage.within(dir, Storage.join(root, Clips.FOLDER))
end

-- The person's choices: { auto = bool, days = n }. `get(key)` reads a setting.
function Clips.options(get)
    local auto = get and get(Clips.AUTO)
    local days = tonumber(get and get(Clips.DAYS))
    if not days or days < 1 then days = Clips.DEFAULT_DAYS end
    return { auto = auto ~= false, days = math.min(365, math.floor(days)) }
end

-- Delete the clips in `dir` not changed for `days` days before `now`. Only files
-- named as clips go, so nothing else the person put in the folder is touched.
-- Returns how many went.
function Clips.sweep(dir, days, now)
    if not dir then return 0 end
    local limit = (now or os.time()) - days * 86400
    local n = 0
    for _i, e in ipairs(Storage.list(dir)) do
        if e.mode == "file" and Clips.isClipName(e.name) and (e.mtime or 0) < limit then
            if Storage.removeTree(e.path) then n = n + 1 end
        end
    end
    return n
end

-- Sweep as the person's settings say (nothing when automatic deleting is off).
-- Returns how many went.
function Clips.sweepAuto(get, now)
    local o = Clips.options(get)
    if not o.auto then return 0 end
    local root = Storage.appRootPath()
    if not root then return 0 end
    return Clips.sweep(Storage.join(root, Clips.FOLDER), o.days, now)
end

-- Delete every clip in the folder. Returns how many went.
function Clips.deleteAll(dir)
    return Clips.sweep(dir, -1, os.time() + 86400)
end

-- How many clips the folder holds.
function Clips.count(dir)
    local n = 0
    for _i, e in ipairs(dir and Storage.list(dir) or {}) do
        if e.mode == "file" and Clips.isClipName(e.name) then n = n + 1 end
    end
    return n
end

-- A picture at `path` that is a clip still in the clips folder, put to use (on a
-- page, as a background): copy it into the folder of kept clips and give that
-- path, once (a second use finds the copy). Any other path, or a copy that
-- cannot be made, gives `path` back as it was.
function Clips.keep(path)
    local root = Storage.appRootPath()
    if not (path and root) then return path end
    local from = Storage.join(root, Clips.FOLDER)
    if Storage.dirName(path) ~= from or not Clips.isClipName(Storage.baseName(path)) then return path end
    local dir = Storage.appDir(Clips.KEPT)
    if not dir then return path end
    local to = Storage.join(dir, Storage.baseName(path))
    if Storage.exists(to) then return to end
    local ok = Storage.copyFile(path, to)
    return ok and to or path
end

return Clips
