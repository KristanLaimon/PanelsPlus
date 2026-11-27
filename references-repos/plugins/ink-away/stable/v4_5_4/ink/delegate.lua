--[[
An event that many can listen to, for the integration API (ink/integration.lua):
listeners run in the order they subscribed, each gets its own copy of the event,
one that fails is logged and the others still run, and unsubscribing (or
disposing of the event) takes effect at once, even during a dispatch.

From Kristan Laimon's PR #80.
]]

--- Ordered multicast event. Unsubscription takes effect during dispatch;
--- subscriptions added during dispatch run on the next emission.
---@class InkDelegate<T>
---@field private _listeners { callback: fun(event: T), active: boolean }[]
---@field private _report fun(err: unknown)
---@field private _disposed boolean?
local Delegate = {}
Delegate.__index = Delegate

---@generic T
---@param report fun(err: unknown) Callback errors are isolated and reported here.
---@return InkDelegate<T>
function Delegate.new(report)
    return setmetatable({ _listeners = {}, _report = report }, Delegate)
end

---@generic T
---@param self InkDelegate<T>
---@param callback fun(event: T)
---@return fun() unsubscribe Idempotent; also safe after disposal.
function Delegate:subscribe(callback)
    assert(not self._disposed, "event delegate has closed")
    assert(type(callback) == "function", "an event listener must be a function")
    local entry = { callback = callback, active = true }
    local listeners = self._listeners
    listeners[#listeners + 1] = entry
    return function()
        entry.active = false
        for i, listener in ipairs(listeners) do
            if listener == entry then table.remove(listeners, i); break end
        end
    end
end

--- Each observer receives its own payload, so mutations cannot affect the next.
---@generic T
---@param self InkDelegate<T>
---@param payload fun(): T
function Delegate:emit(payload)
    local snapshot = {}
    for i, entry in ipairs(self._listeners) do snapshot[i] = entry end
    for _, entry in ipairs(snapshot) do
        if entry.active then
            local ok, err = pcall(function() entry.callback(payload()) end)
            if not ok then self._report(err) end
        end
    end
end

--- Also disables listeners in a dispatch snapshot already in progress.
function Delegate:dispose()
    if self._disposed then return end
    self._disposed = true
    for _, entry in ipairs(self._listeners) do entry.active = false end
    self._listeners = {}
end

return Delegate
