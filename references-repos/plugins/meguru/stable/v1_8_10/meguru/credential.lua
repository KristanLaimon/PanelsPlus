
local Credential = {}

Credential.PLACEHOLDER = "<redacted>"

local UUID_SEGMENT = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

-- Escaped once at load: as a pattern a `-` or `.` in the placeholder is magic.
-- Restore would then splice the key over adjacent bytes, silently.
local PLACEHOLDER_PATTERN = Credential.PLACEHOLDER:gsub("%W", "%%%0")

-- `scheme://host:port`, the part two URLs must share to splice a key.
-- Matched as a pattern: url.parse's host drops the port this comparison needs.
-- Returns nil, or "" for a string that is not a URL; both are a refusal.
local function originOf(url_str)
    if type(url_str) ~= "string" then
        return nil
    end
    return url_str:match("^(%a[%w+.-]*://[^/]+)")
end

-- The key the catalogue root's `/opds/<key>/` carries, and its start index.
-- Only the positional rule: the value the template was stripped of.
-- A root already redacted returns nil, so a miscalled root is a refusal.
-- It is never a no-op substitution that looks like success.
function Credential.keyFromRoot(root)
    if type(root) ~= "string" or root == "" then
        return nil
    end
    local at = root:find("/opds/", 1, true)
    if not at then
        return nil
    end
    local from = at + #"/opds/"
    -- Sliced before matching: `^` anchoring to init is Lua-version-dependent.
    local key = root:sub(from):match("^([^/?]+)")
    if not key or key == "" or key == Credential.PLACEHOLDER then
        return nil
    end
    return key, from
end

-- Kavita's artwork URLs: `?apiKey=<key>` or `&apiKey=<key>`.
-- Value cut at `&` and `#`: restore can only put back what replaced one value.
local APIKEY_PATTERN = "([?&]apiKey=)[^&#]*"

-- The marker form: the `/opds/` and `apiKey` positions, never the UUID guess.
-- A wrong guess would blank part of a URL that restore cannot repair.
function Credential.redactTemplate(str)
    if type(str) ~= "string" or str == "" then
        return str
    end
    local out = str:gsub("(/opds/)[^/?]+", "%1" .. Credential.PLACEHOLDER)
    return (out:gsub(APIKEY_PATTERN, "%1" .. Credential.PLACEHOLDER))
end

-- Logs only: also blanks UUID-shaped segments, a guess not safe in a marker.
function Credential.redact(str)
    if type(str) ~= "string" or str == "" then
        return str
    end
    -- Rewritten in place: gmatch("[^/]+") drops a slash of the scheme's //.
    local out = Credential.redactTemplate(str)
    return (out:gsub("/([^/]+)", function(segment)
        return segment:match(UUID_SEGMENT) and "/" .. Credential.PLACEHOLDER
            or "/" .. segment
    end))
end

-- Put `root`'s key back only within the same scheme://host:port.
-- Splicing into another host would send one server's credential to another.
-- Returns `restored, count`; the caller decides what a count of 0 means.
function Credential.restoreTemplate(template, root)
    if type(template) ~= "string" or template == "" then
        return template, 0
    end
    local at = template:find(Credential.PLACEHOLDER, 1, true)
    if not at then
        return template, 0
    end
    -- Everything before the placeholder; compared by prefix, not for equality.
    local prefix = template:sub(1, at - 1)
    local key = Credential.keyFromRoot(root)
    if not key then
        return template, 0
    end
    local origin = originOf(root)
    -- An unparseable root is refused explicitly: `sub(1, 0)` would match.
    if not origin or origin == "" or prefix:sub(1, #origin) ~= origin then
        return template, 0
    end
    -- Function replacement, not a string: `%` in a key makes gsub raise.
    -- That raise would land inside the page-fetch path on the device.
    -- No parentheses: `return (gsub(...))` truncates to one value.
    -- That drops the count the caller branches on, nil-ing the successful path.
    return template:gsub(PLACEHOLDER_PATTERN, function() return key end)
end

return Credential
