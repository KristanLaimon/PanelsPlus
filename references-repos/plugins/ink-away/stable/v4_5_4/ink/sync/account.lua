--[[
The signed-in account of the cloud sync, kept in the sync's own folder (see
ink/sync/manager.lua): which service, the refresh token the service gave
(never a password), the name to show, and this reader's name for the others. The
file is for this reader's owner only. Plain Lua apart from the files.
]]

local Project = require("ink/project")
local Storage = require("ink/storage")

local Account = {}

Account.FILE = "account.lua"

local function path(dir) return Storage.join(dir, Account.FILE) end

-- The account saved in `dir`, or nil.
function Account.load(dir)
    local f = io.open(path(dir), "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local v = Project.decode(text)
    if type(v) ~= "table" or type(v.provider) ~= "string" or type(v.refresh_token) ~= "string" then return nil end
    return v
end

-- Keep `account` in `dir`, readable only by the owner. Returns ok, err.
function Account.save(dir, account)
    Storage.ensureDir(dir)
    local p = path(dir)
    local ok, err = Storage.writeAtomic(p, Project.encode(account))
    if ok then pcall(os.execute, "chmod 600 '" .. p:gsub("'", "'\\''") .. "' 2>/dev/null") end
    return ok, err
end

-- Forget the account (the notebooks stay as they are).
function Account.clear(dir)
    os.remove(path(dir))
end

-- A name for this reader that the person can change: the device's model, else "Reader".
function Account.defaultDeviceName()
    local ok, Device = pcall(require, "device")
    local model = ok and Device and Device.model
    if type(model) == "string" and model ~= "" then return model:sub(1, 24) end
    return "Reader"
end

return Account
