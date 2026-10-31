
local logger = require("logger")

local Base = require("meguru/driver/base")
local Net = require("meguru/net")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")

Base.loadDrivers()

local Progress = {}

-- Kinds this may report to, and `ui/menu`'s row list.
-- An absent kind is never asked, which is what keeps Suwayomi off.
Progress.KINDS = { "komga" }

-- The settings key a kind's switch is stored under.
local function settingFor(kind)
    return "report_progress_" .. kind
end
Progress.settingFor = settingFor

-- Asked per report, not cached, so turning the row off takes effect next page.
function Progress.wanted(kind)
    for _, known in ipairs(Progress.KINDS) do
        if known == kind then
            return Settings.get(settingFor(kind)) and true or false
        end
    end
    return false
end

-- Lazy: it is device state, and this module must load before any UI is up.
local function isConnected()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr ~= nil and NetworkMgr:isConnected()
end

-- The marker's recorded page, the server's number and not the reader's.
-- Clamped to `total`; nil when nothing is recorded.
function Progress.floorFor(desc, total)
    if type(desc) ~= "table" then
        return nil
    end
    local recorded = tonumber(desc.last_read)
    if not recorded or recorded < 1 then
        return nil
    end
    if total and total >= 1 and recorded > total then
        return total
    end
    return math.floor(recorded)
end

-- The one definition of "ahead of the recorded floor", with three callers.
function Progress.moved(floor, page)
    page = tonumber(page)
    if not page or page < 1 then
        return false
    end
    if not floor then
        return true
    end
    return page > floor
end

-- Returns true, or nil and a reason. "off"/"offline"/"behind" are not faults.
-- "network"/"http" are; the caller debounces and gives up after a few.
function Progress.report(marker_path, desc, page, total)
    if type(desc) ~= "table" then
        return nil, "desc"
    end
    if not Progress.wanted(desc.server_kind) then
        return nil, "off"
    end
    local driver = Base.forKind(desc.server_kind)
    if not (driver and type(driver.progressRequest) == "function") then
        return nil, "hook"
    end

    page = math.floor(tonumber(page) or 0)
    total = tonumber(total)
    if page < 1 or not total or total < 1 then
        return nil, "page"
    end

    if not Progress.moved(Progress.floorFor(desc, total), page) then
        return nil, "behind"
    end

    -- Asked before the request, so an offline read costs no timeout per turn.
    if not isConnected() then
        return nil, "offline"
    end

    local request = driver.progressRequest(desc, page)
    if type(request) ~= "table" or type(request.url) ~= "string" then
        return nil, "hook"
    end

    -- marker_path gives the session's resolved credential, not the catalog's.
    local username, password = Sources.credentials(desc.server_name, marker_path)
    local code = Net.patch(request.url, request.body or "", {
        content_type = request.content_type,
        username     = username,
        password     = password,
        timeout      = "progress",
    })
    if code and code >= 200 and code <= 299 then
        logger.dbg("Meguru: reported page", page, "of", total,
            "to", Net.redactUrl(request.url))
        return true
    end

    -- Split as `Net.fetchFeed` splits it; `Net.patch` already logged which.
    return nil, code and "http" or "network"
end

return Progress
