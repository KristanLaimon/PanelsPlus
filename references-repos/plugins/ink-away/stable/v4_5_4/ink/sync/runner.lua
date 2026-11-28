--[[
Running a sync in the background (see ink/sync/). The work happens in a
short-lived process of its own (KOReader's runInSubProcess), so a slow
connection never freezes the reader and nothing runs once the sync is over. The
process and Ink Away talk through three small files in the sync's folder:

    progress.lua   what the run is doing now (written by the process)
    result.lua     how it ended (written once, at the end)
    stop           holds the number of the run the person asked to stop (read by the
                   process, which obeys only its own number: a request left over
                   from an earlier run must never stop a later one)

Where a system gives no background process, the work runs right here in small
steps instead. Plain files and Lua, so the file protocol is tested headless.
]]

local Project = require("ink/project")
local Storage = require("ink/storage")

local Runner = {}

Runner.POLL = 0.5
Runner.STALL = 20 * 60        -- seconds without any progress before the process is ended

local function p(dir, name) return Storage.join(dir, name) end

local function readValue(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return Project.decode(text)
end

-- Write the progress of the run (what the reader shows).
function Runner.writeProgress(dir, info)
    Storage.writeAtomic(p(dir, "progress.lua"), Project.encode(info))
end

function Runner.readProgress(dir) return readValue(p(dir, "progress.lua")) end

function Runner.writeResult(dir, result)
    Storage.writeAtomic(p(dir, "result.lua"), Project.encode(result))
end

function Runner.readResult(dir) return readValue(p(dir, "result.lua")) end

-- Ask run `id` to stop / has someone asked it? Without an id, any request counts.
function Runner.requestStop(dir, id)
    Storage.writeAtomic(p(dir, "stop"), tostring(id or "1"))
end
function Runner.stopRequested(dir, id)
    local f = io.open(p(dir, "stop"), "rb")
    if not f then return false end
    local asked = f:read("*a")
    f:close()
    return id == nil or asked == tostring(id)
end

local function clean(dir)
    os.remove(p(dir, "progress.lua")); os.remove(p(dir, "result.lua")); os.remove(p(dir, "stop"))
end

-- Do the work of a run: `work(report, stop)` returns the result table. The
-- result is written to a file whatever happens, a Lua error included.
function Runner.execute(dir, work, id)
    local last = -1
    local function report(info)
        local now = os.clock()
        if info.phase == "files" and last >= 0 and now - last < 0.3 then return end
        last = now
        Runner.writeProgress(dir, info)
    end
    local ok, res = pcall(work, report, function() return Runner.stopRequested(dir, id) end)
    if not ok then res = { crashed = tostring(res) } end
    Runner.writeResult(dir, res)
    return res
end

-- Start a run. `o`: dir, work, on_progress(info), on_done(result). Returns a
-- handle with :stop() and :alive(). A run that is already going must not be
-- started again (the caller checks).
function Runner.start(o)
    local UIManager = require("ui/uimanager")
    local util = require("ffi/util")
    local dir = o.dir
    clean(dir)
    Runner.serial = (Runner.serial or 0) + 1
    local handle = { dir = dir, done = false, id = os.time() .. "-" .. Runner.serial }
    local function finish(res)
        if handle.done then return end
        handle.done = true
        local out = res or Runner.readResult(dir) or { crashed = "the sync process ended without a word" }
        clean(dir)
        if o.on_done then o.on_done(out) end
    end
    function handle:stop()
        Runner.requestStop(dir, self.id)
        self.stopping = true
    end
    function handle:alive() return not self.done end

    local pid = util.runInSubProcess(function() Runner.execute(dir, o.work, handle.id) end, false, false)
    if not pid then
        -- no background process here: run in small steps in this one
        handle.inline = true
        UIManager:scheduleIn(0.3, function()
            local res = Runner.execute(dir, function(report, stop)
                return o.work(function(info)
                    report(info)
                    if o.on_progress then o.on_progress(info) end
                end, stop)
            end, handle.id)
            finish(res)
        end)
        return handle
    end
    local seen, stalled = nil, os.time()
    local function poll()
        if handle.done then return end
        local prog = Runner.readProgress(dir)
        if prog then
            local key = (prog.phase or "") .. "|" .. tostring(prog.done or "") .. "|" .. (prog.rel or "")
            if key ~= seen then
                seen = key
                stalled = os.time()
                if o.on_progress then o.on_progress(prog) end
            end
        end
        if util.isSubProcessDone(pid) then
            return finish(nil)
        end
        if os.time() - stalled > Runner.STALL then
            util.terminateSubProcess(pid)
            UIManager:scheduleIn(1, function() util.isSubProcessDone(pid) end)
            return finish({ crashed = "no progress for a long time" })
        end
        UIManager:scheduleIn(Runner.POLL, poll)
    end
    UIManager:scheduleIn(Runner.POLL, poll)
    handle.pid = pid
    return handle
end

return Runner
