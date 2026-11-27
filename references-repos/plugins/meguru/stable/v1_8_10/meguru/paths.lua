local DataStorage = require("datastorage")

local Paths = {}

-- The marker's last-resort home, and the one dir the plugin creates itself.
function Paths.cacheDir()
    return DataStorage:getDataDir() .. "/cache/meguru"
end

-- Not "mgru": two providers on one extension would race by install order.
Paths.MARKER_EXT = "meguru"

-- Injected by main.lua: the plugin may sit on media under any .koplugin name.
local plugin_dir

function Paths.setPluginDir(dir)
    plugin_dir = type(dir) == "string" and dir or nil
end

-- The updater needs this directory itself; nil just means init has not run.
function Paths.pluginDir()
    if type(plugin_dir) ~= "string" or plugin_dir == "" then
        return nil
    end
    return plugin_dir
end

-- Pure derivation: whether the file exists is the caller's question, not this.
function Paths.asset(name)
    if type(plugin_dir) ~= "string" or plugin_dir == "" then
        return nil
    end
    return plugin_dir .. "/assets/" .. name
end

-- Separate from asset: no artwork loses a picture, no libraries loses a row.
function Paths.lib(name)
    if type(plugin_dir) ~= "string" or plugin_dir == "" then
        return nil
    end
    return plugin_dir .. "/libs/" .. name
end

return Paths
