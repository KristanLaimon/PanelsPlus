--[[
Long jobs (a PDF export, a search) run a step at a time from the UI loop, so
the screen keeps updating and Stop on the progress sheet can end them. Every
step runs protected: an error ends the job with a message instead of reaching
KOReader.
Part of InkAwayView (see ink/view.lua).
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("ink/l10n")

local InkAwayView = {}

-- Run a job in steps. `o` holds:
--   step()         does a little work; returns "done", or how far it got (a
--                  number up to o.max), or nil, err on failure, or "abort" to
--                  end quietly (the job was dropped elsewhere)
--   max, title     the progress bar's length and title
--   subtitle       a line under the title, when given
--   dismiss_text   asked before stopping, when given
--   quiet          seconds to work before the bar shows (0: show it at once);
--                  a job done by then never shows one
--   first, pause   seconds before the first step and between steps
--   on_done(), on_cancel(), on_error(err)
-- Returns the job: { over = bool, cancel = function, abort = function }; abort
-- ends it without calling anything (when Ink Away closes).
function InkAwayView:runSteps(o)
    local job = { over = false }
    local progress
    local started = os.clock()
    local function closeProgress()
        local p = progress
        progress = nil
        if p then pcall(p.close) end
    end
    -- (the job is marked over before its progress closes)
    local function stop(how, err)
        if job.over then return end
        job.over = true
        closeProgress()
        if how == "done" then
            if o.on_done then o.on_done() end
        elseif how == "cancel" then
            if o.on_cancel then o.on_cancel() end
        else
            logger.warn("InkAway: job failed:", err)
            if o.on_error then o.on_error(err) end
        end
    end
    job.cancel = function() stop("cancel") end
    job.abort = function()
        job.over = true
        closeProgress()
    end
    local function showProgress()
        if progress or job.over then return end
        progress = self:showProgress{ title = o.title, note = o.subtitle, max = o.max,
            stop_ask = o.dismiss_text, on_stop = function()
                progress = nil   -- (the reader stopped it)
                stop("cancel")
            end }
    end
    local function report(n)
        if progress then progress.report(n) end
    end
    local step
    step = function()
        if job.over then return end
        local ok, state, a = pcall(o.step)
        if not ok then return stop("error", state) end
        if state == nil then return stop("error", a) end
        if state == "abort" then return job.abort() end
        if state == "done" then
            report(o.max)
            return stop("done")
        end
        report(state)
        if not progress and os.clock() - started >= (o.quiet or 0) then showProgress() end
        UIManager:scheduleIn(o.pause or 0.05, step)   -- let the screen update and taps through
    end
    if (o.quiet or 0) <= 0 then showProgress() end
    UIManager:scheduleIn(o.first or 0.2, step)        -- let the progress bar paint first
    return job
end

return InkAwayView
