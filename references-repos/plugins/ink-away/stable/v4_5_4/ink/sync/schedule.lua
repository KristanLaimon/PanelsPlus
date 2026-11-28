--[[
When the cloud sync runs by itself (see ink/sync/). The person chooses which of
these happen; every one of them only asks, and this decides whether a run is
due. Plain Lua, so the headless tests drive it.

    manual      the person asked: always
    open        a notebook is about to open: a quick check of that notebook
    close       a notebook was closed
    pause       the person stopped drawing for a while after a change
    interval    every so many minutes (a day is 1440)
    sleep       the reader is going to sleep
    start       Ink Away started and a run is overdue

Runs by themselves keep a gap between them, and wait longer after failures so a
bad connection does not drain the battery.
]]

local Schedule = {}

Schedule.MIN_GAP = 30                   -- seconds between automatic runs
Schedule.INTERVALS = { 0, 15, 30, 60, 180, 720, 1440 }     -- minutes; 0 is off
Schedule.PAUSES = { 0, 30, 60, 120, 300 }                  -- seconds; 0 is off

-- The settings, with the defaults: sync on closing a notebook, nothing else (a
-- notebook opens without waiting for the cloud), and never turning Wi-Fi on by itself. `get(key)` reads a setting.
function Schedule.options(get)
    local function v(k, d) local x = get and get(k); if x == nil then return d end return x end
    return {
        enabled = v("inkaway_sync_enabled", false) == true,
        on_close = v("inkaway_sync_on_close", true) ~= false,
        on_open = v("inkaway_sync_on_open", false) == true,   -- (off: opening can wait for the cloud)
        on_sleep = v("inkaway_sync_on_sleep", false) == true,
        pause_s = tonumber(v("inkaway_sync_pause", 0)) or 0,
        interval_min = tonumber(v("inkaway_sync_interval", 0)) or 0,
        wifi_on = v("inkaway_sync_wifi_on", false) == true,   -- may turn Wi-Fi on itself
        device = v("inkaway_sync_device", nil),
    }
end

-- How long to wait after `failures` runs in a row failed, in seconds.
function Schedule.backoff(failures)
    if not failures or failures <= 0 then return 0 end
    return math.min(60 * 2 ^ (failures - 1), 3600)
end

-- Does anything make it sync by itself (and so use battery and Wi-Fi in the
-- background)? `opts` as from Schedule.options.
function Schedule.automatic(opts)
    return opts.enabled and (opts.on_close or opts.on_open or opts.on_sleep
        or (opts.pause_s or 0) > 0 or (opts.interval_min or 0) > 0) or false
end

-- Is a run due for `event`? `st` is { last = time of the last run, failures = in a row,
-- dirty = a change not yet sent, running = a run is on }.
function Schedule.due(opts, event, now, st)
    st = st or {}
    if st.running then return false end
    if event == "manual" then return true end
    if not opts.enabled then return false end
    if st.last and now - st.last < Schedule.MIN_GAP then return false end
    if st.failures and st.failures > 0 and st.last and now - st.last < Schedule.backoff(st.failures) then return false end
    local every, pause = opts.interval_min or 0, opts.pause_s or 0
    local overdue = every > 0 and (not st.last or now - st.last >= every * 60)
    if event == "open" then return opts.on_open end
    if event == "close" then return opts.on_close and st.dirty == true end
    if event == "pause" then return pause > 0 and st.dirty == true end
    if event == "interval" then return overdue end
    if event == "sleep" then return opts.on_sleep and (st.dirty == true or overdue) end
    if event == "start" then return overdue or (opts.on_open and not st.last) end
    return false
end

return Schedule
