local Job = {}

local POLL = 0.25
local DEADLINE = 90
local MAX_RESULT = 256 * 1024
local active

-- A private folder for the child's answer: in /tmp, or in KOReader's cache
-- where there is no /tmp (Android).
local function tempDirectory(ffi)
    pcall(ffi.cdef, "char *mkdtemp(char *template);")
    local lfs = require("libs/libkoreader-lfs")
    local base = "/tmp"
    if lfs.attributes(base, "mode") ~= "directory" then
        base = require("datastorage"):getDataDir() .. "/cache"
        if lfs.attributes(base, "mode") ~= "directory" then lfs.mkdir(base) end
    end
    local template = base .. "/inkaway-ocr-XXXXXX"
    local buffer = ffi.new("char[?]", #template + 1, template)
    local path = ffi.C.mkdtemp(buffer)
    return path ~= nil and ffi.string(path) or nil
end

local function cleanup(paths)
    os.remove(paths.result)
    os.remove(paths.part)
    if paths.dir then os.remove(paths.dir) end
end

local function writeResult(paths, text, err)
    local ok, payload = pcall(function()
        if type(text) == "string" and #text > 0 and #text <= MAX_RESULT then
            return "S\n" .. text
        end
        if type(err) == "string" and #err <= 256 and not err:find("[%z\1-\31\127]") then
            return "E\n" .. err
        end
        return "E\nOCR failed."
    end)
    if not ok then payload = "E\nOCR failed." end
    local file = io.open(paths.part, "wb")
    if not file then return end
    local wrote = file:write(payload)
    local flushed = wrote and file:flush()
    file:close()
    if flushed then os.rename(paths.part, paths.result) else os.remove(paths.part) end
end

local function readResult(path)
    local file = io.open(path, "rb")
    if not file then return nil, "OCR job stopped." end
    local data = file:read(MAX_RESULT + 3)
    local extra = file:read(1)
    file:close()
    if extra or not data or #data < 3 then return nil, "OCR job returned invalid data." end
    local tag, value = data:sub(1, 1), data:sub(3)
    if tag == "S" and value ~= "" then return value end
    if tag == "E" then return nil, value end
    return nil, "OCR job returned invalid data."
end

function Job.start(work, done)
    if type(work) ~= "function" or type(done) ~= "function" then
        return nil, "Invalid OCR job."
    end
    if active and active.orphaned then
        -- The initial UI scheduler failed after fork. The child was killed,
        -- but retain its slot and private directory until a later nonblocking
        -- poll can collect it; never pretend the job stopped before waitpid.
        local reaped_ok, reaped = pcall(active.util.isSubProcessDone, active.pid)
        if reaped_ok and reaped then
            cleanup(active.paths)
            active = nil
        end
    end
    if active then return nil, "An OCR job is already running." end

    local ok, ffi, util, UIManager, socket = pcall(function()
        return require("ffi"), require("ffi/util"), require("ui/uimanager"), require("socket")
    end)
    if not ok then return nil, "Background OCR is unavailable." end
    local dir_ok, dir = pcall(tempDirectory, ffi)
    if not dir_ok or not dir then return nil, "Could not create a private OCR workspace." end
    local paths = { dir = dir, result = dir .. "/result", part = dir .. "/result.part" }

    local spawned, pid = pcall(util.runInSubProcess, function()
        local worked, text, err = pcall(work)
        if worked then writeResult(paths, text, err) else writeResult(paths, nil, "OCR failed.") end
    end, false, false)
    if not spawned or type(pid) ~= "number" or pid <= 0 then
        cleanup(paths)
        return nil, "Could not start background OCR."
    end

    local job = { pid = pid, cancelled = false, finished = false, paths = paths,
        started = socket.gettime(), util = util, socket = socket, done = done }
    active = job
    local function finish(text, err)
        if job.finished then return end
        job.finished = true
        cleanup(paths)
        if active == job then active = nil end
        if not job.cancelled then pcall(job.done, text, err) end
    end
    local function poll()
        if job.finished then return end
        if not job.timed_out and socket.gettime() - job.started >= DEADLINE then
            job.timed_out = true
            util.terminateSubProcess(pid)
        end
        if util.isSubProcessDone(pid) then
            if job.timed_out then return finish(nil, "OCR timed out.") end
            if job.cancelled then return finish(nil, "OCR cancelled.") end
            local text, err = readResult(paths.result)
            return finish(text, err)
        end
        UIManager:scheduleIn(POLL, poll)
    end
    local scheduled = pcall(UIManager.scheduleIn, UIManager, POLL, poll)
    if not scheduled then
        util.terminateSubProcess(pid)
        job.orphaned = true
        return nil, "Background OCR is unavailable."
    end
    return function()
        if not job.finished then job.cancelled = true end
    end
end

return Job
