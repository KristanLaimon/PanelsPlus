--[[
Updates, the rules: which of Ink Away's GitHub releases may be offered, and as
what. Plain Lua (no network, files or widgets), so the headless tests drive it.

  * A release is GitHub's: published (never a draft), tagged with a version
    ("v4.1.0", "v4.2.0-beta.1"), and carrying its zip,
    "ink-away.koplugin-<tag>.zip", uploaded to GitHub with a SHA-256 digest.
    GitHub's prerelease flag says which channel it is in.
  * The release offered is always the newest one. An older release is never
    offered, not even to go back to.
  * A prerelease is offered only when it is newer than the newest release;
    from a prerelease (or a test build) the newest release is offered to go
    back to, the one downgrade there is.
]]

local Policy = {}

Policy.REPO = "EmirErtorer/ink-away.koplugin"
Policy.API = "https://api.github.com/repos/" .. Policy.REPO .. "/releases?per_page=40"
Policy.PLUGIN = "ink-away.koplugin"
Policy.DAY = 24 * 3600            -- between automatic checks
Policy.RETRY = 3600               -- after an automatic check that failed
Policy.MAX_FEED = 1024 * 1024     -- the release list, in bytes
Policy.MAX_ZIP = 16 * 1024 * 1024
Policy.MAX_UNPACKED = 64 * 1024 * 1024
Policy.MAX_ENTRIES = 2048

-- Hosts a request may go to (the API, and where GitHub sends a download).
Policy.HOSTS = { ["api.github.com"] = true, ["github.com"] = true,
    ["objects.githubusercontent.com"] = true, ["release-assets.githubusercontent.com"] = true }

-- A version string ("v4.1.0", "4.2.0-beta.1") as { major, minor, patch, pre },
-- pre being nil or the list of its dot-separated parts; nil if it is not one.
function Policy.parse(s)
    if type(s) ~= "string" then return nil end
    local a, b, c, rest = s:match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a then return nil end
    local v = { tonumber(a), tonumber(b), tonumber(c) }
    if rest ~= "" then
        local pre = rest:match("^%-([%w%.%-]+)$")
        if not pre then return nil end
        v.pre = {}
        for part in pre:gmatch("[^%.]+") do v.pre[#v.pre + 1] = tonumber(part) or part end
    end
    return v
end

-- -1, 0 or 1 as version a comes before, is, or comes after b (semantic
-- versioning: 4.1.0-beta.2 comes before 4.1.0); nil when either is not one.
function Policy.compare(a, b)
    a, b = type(a) == "table" and a or Policy.parse(a), type(b) == "table" and b or Policy.parse(b)
    if not (a and b) then return nil end
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
    end
    if not a.pre and not b.pre then return 0 end
    if not a.pre then return 1 end
    if not b.pre then return -1 end
    for i = 1, math.max(#a.pre, #b.pre) do
        local x, y = a.pre[i], b.pre[i]
        if x == nil then return -1 end
        if y == nil then return 1 end
        if x ~= y then
            local nx, ny = type(x) == "number", type(y) == "number"
            if nx and ny then return x < y and -1 or 1 end
            if nx ~= ny then return nx and -1 or 1 end   -- numbers before words
            return x < y and -1 or 1
        end
    end
    return 0
end

-- The version without its "v".
function Policy.bare(tag)
    return type(tag) == "string" and (tag:gsub("^v", "")) or tag
end

local function hostOf(url)
    return type(url) == "string" and url:match("^https://([^/:%?#]+)[/%?#]") or nil
end

-- May a request go to this URL?
function Policy.allowed(url)
    local host = hostOf(url)
    return host ~= nil and Policy.HOSTS[host] == true
end

-- One of GitHub's releases as Ink Away may use it, or nil and why not.
function Policy.release(r)
    if type(r) ~= "table" then return nil, "not a release" end
    if r.draft ~= false then return nil, "a draft" end
    local v = Policy.parse(r.tag_name)
    if not v then return nil, "not a version tag" end
    local name = Policy.PLUGIN .. "-" .. r.tag_name .. ".zip"
    local url = "https://github.com/" .. Policy.REPO .. "/releases/download/" .. r.tag_name .. "/" .. name
    for _i, a in ipairs(type(r.assets) == "table" and r.assets or {}) do
        if type(a) == "table" and a.name == name and a.state == "uploaded" and a.browser_download_url == url
                and type(a.size) == "number" and a.size > 0 and a.size % 1 == 0 and a.size <= Policy.MAX_ZIP
                and type(a.digest) == "string" and a.digest:match("^sha256:%x+$") and #a.digest == 71 then
            return {
                tag = r.tag_name, version = Policy.bare(r.tag_name), v = v,
                pre = r.prerelease == true,
                url = url, size = a.size, digest = a.digest:sub(8):lower(),
                notes = type(r.body) == "string" and r.body or "",
                date = type(r.published_at) == "string" and r.published_at:sub(1, 10) or nil,
            }
        end
    end
    return nil, "no verified zip"
end

-- What the release list offers to the installed version `current`:
--   stable   the newest release (or nil)
--   pre      the newest prerelease, when it is newer than that release
--   on_pre   the installed version is a prerelease (listed as one, or with a
--            "-beta" kind of suffix) or a test build newer than the release
--   stable_action  "update" (newer than installed), "back" (going back from a
--                  prerelease or test build to it) or "current"
--   pre_action     "try" (newer than installed) or "current", nil when none
--   since    the releases newer than the installed version, newest first,
--            for their notes
-- `list` is GitHub's parsed JSON array.
function Policy.offers(list, current)
    local cur = Policy.parse(current)
    local stable, pre
    local listed_pre = false
    local all = {}
    for _i, r in ipairs(type(list) == "table" and list or {}) do
        local rel = Policy.release(r)
        if rel then
            all[#all + 1] = rel
            if cur and Policy.compare(rel.v, cur) == 0 and rel.pre then listed_pre = true end
            if rel.pre then
                if not pre or Policy.compare(rel.v, pre.v) > 0 then pre = rel end
            elseif not stable or Policy.compare(rel.v, stable.v) > 0 then
                stable = rel
            end
        end
    end
    if pre and stable and Policy.compare(pre.v, stable.v) <= 0 then pre = nil end
    local out = { stable = stable, pre = pre }
    out.on_pre = cur ~= nil and (listed_pre or cur.pre ~= nil
        or (stable ~= nil and Policy.compare(cur, stable.v) > 0))
    if stable then
        local c = cur and Policy.compare(stable.v, cur)
        if not c or c > 0 then out.stable_action = "update"
        elseif c < 0 or out.on_pre then out.stable_action = "back"
        else out.stable_action = "current" end
    end
    if pre then
        local c = cur and Policy.compare(pre.v, cur)
        if not c or c > 0 then out.pre_action = "try"
        elseif c == 0 then out.pre_action = "current" end
    end
    -- the notes worth reading: what is new since the installed version, in the
    -- channel the reader is offered
    local since = {}
    for _i, rel in ipairs(all) do
        if not rel.pre and (not cur or Policy.compare(rel.v, cur) > 0) then since[#since + 1] = rel end
    end
    table.sort(since, function(a, b) return Policy.compare(a.v, b.v) > 0 end)
    out.since = since
    return out
end

-- Is an automatic check due? `last` is when the last one succeeded, `tried`
-- when the last one was tried (both os.time, or nil).
function Policy.due(now, last, tried)
    local function bad(t) return type(t) ~= "number" or t ~= t or t > now end
    if not bad(tried) and now - tried < Policy.RETRY then return false end
    return bad(last) or now - last >= Policy.DAY
end

-- An entry of the update zip as a path inside the plugin folder ("" for the
-- folder itself), or nil when it may not be unpacked: anything outside
-- "ink-away.koplugin/", absolute, with "..", control characters or
-- backslashes, or not a plain file or folder.
function Policy.entry(path, mode)
    if type(path) ~= "string" or (mode ~= "file" and mode ~= "directory")
            or path:find("[%c\\]") or path:sub(1, 1) == "/" then return nil end
    path = path:gsub("/$", "")
    if path == Policy.PLUGIN then return mode == "directory" and "" or nil end
    local prefix = Policy.PLUGIN:gsub("%p", "%%%0")   -- (the name holds "-" and ".")
    local rel = path:match("^" .. prefix .. "/(.+)$")
    if not rel or rel:find("//", 1, true) or rel:sub(1, 1) == "/" then return nil end
    for part in rel:gmatch("[^/]+") do
        if part == "." or part == ".." then return nil end
    end
    return rel
end

-- Release notes (GitHub's Markdown) as blocks to show: { kind = "h" | "p" |
-- "li", text }, with links, emphasis and code marks taken out and pictures left
-- out. "li" carries `depth` (0 for a top-level bullet).
function Policy.notes(md)
    local blocks, para = {}, nil
    local function flush()
        if para then blocks[#blocks + 1] = { kind = "p", text = para }; para = nil end
    end
    local function clean(s)
        s = s:gsub("!%b[]%b()", "")                       -- pictures
        s = s:gsub("%[([^%]]*)%]%b()", "%1")              -- links: their text
        s = s:gsub("<[^>]+>", "")                         -- html tags
        s = s:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
        s = s:gsub("`([^`]*)`", "%1")
        s = s:gsub("%f[%w%*]%*([^%*\n]+)%*", "%1")
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        return s
    end
    for line in ((md or ""):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        local heading = line:match("^%s*#+%s+(.+)$")
        local indent, bullet = line:match("^(%s*)[%-%*%+]%s+(.+)$")
        local nindent, numbered = line:match("^(%s*)%d+[%.%)]%s+(.+)$")
        if line:match("^%s*$") or line:match("^%s*[%-%*_][%-%*_][%-%*_]+%s*$") then
            flush()
        elseif heading then
            flush()
            local t = clean(heading)
            if t ~= "" then blocks[#blocks + 1] = { kind = "h", text = t } end
        elseif bullet or numbered then
            flush()
            local t = clean(bullet or numbered)
            if t ~= "" then
                blocks[#blocks + 1] = { kind = "li", text = t,
                    depth = math.min(2, math.floor(#(indent or nindent) / 2)) }
            end
        else
            local t = clean(line)
            if t ~= "" then
                -- a line under a bullet carries on that bullet
                local last = not para and blocks[#blocks]
                if last and last.kind == "li" and line:match("^%s+") then
                    last.text = last.text .. " " .. t
                else
                    para = para and (para .. " " .. t) or t
                end
            end
        end
    end
    flush()
    return blocks
end

return Policy
