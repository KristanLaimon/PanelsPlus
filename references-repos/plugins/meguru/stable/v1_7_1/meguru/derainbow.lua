-- Vendored moiré filter; only TYPE_BBRGB32 with stride == w*4 may be filtered.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FS = require("meguru/fs")
local Paths = require("meguru/paths")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")

local Derainbow = {}

-- Filenames follow derainbowify's convention; provenance in libs/README.md.
local COLOR_LIB = "color_detect-%s.so"
local MOIRE_LIB = "moire_filter-%s.so"

-- Its constants, kept so a page matches one the other plugin filtered.
local COLOR_TOLERANCE = 20
local FILTER_STRENGTH = 0.9

-- Guarded: a repeated ffi.cdef is refused, and a refusal means they exist.
local CDEF = [[
bool is_page_colored(uint8_t* data, int width, int height, int stride, int tolerance);
void remove_moire(unsigned char *fb_data, int width, int height, int stride, bool is_colored, float strength);
int init_moire_resources();
void cleanup_moire_resources();
]]

-- Monotonic ms; the same clock doc/document times a paint with.
local function nowMs()
    local secs, usecs = ffiutil.gettime()
    return secs * 1000 + usecs / 1000
end

-- Settled by one probe and kept for the session; not re-asked per tile.
-- init is separate: allocating only when a page actually wants filtering.
local state = {
    probed = false,
    available = false,
    color = nil,
    moire = nil,
    initialized = false,
    filter_failed = false,
    active_reported = false,
}

-- A build lacking one of Device's predicates must cost the row, not the plugin.
local function deviceSays(method)
    local fn = Device and Device[method]
    if type(fn) ~= "function" then
        return false
    end
    local ok, answer = pcall(fn, Device)
    return ok and answer == true
end

-- Suffixes follow the other project's naming; nothing else can be inferred.
local function platformSuffix()
    if deviceSays("isDesktop") or deviceSays("isEmulator") then
        return "amd64"
    end
    if deviceSays("isKobo") then
        return "kobo"
    end
    if deviceSays("isPocketBook") then
        return "pocketbook"
    end
    if deviceSays("isKindle") then
        -- The two Kindle builds differ by ABI; the device's loader says which.
        return util.pathExists("/lib/ld-linux-armhf.so.3") and "kindlehf" or "kindle"
    end
    if deviceSays("isAndroid") then
        local arch = jit.arch
        if type(arch) == "string" and arch:sub(1, 3) == "arm" then
            return "android-" .. arch
        end
    end
    return nil
end

local function libPaths()
    local suffix = platformSuffix()
    if not suffix then
        return nil, nil
    end
    return Paths.lib(string.format(COLOR_LIB, suffix)),
           Paths.lib(string.format(MOIRE_LIB, suffix))
end

-- Load, don't look: an APK-hosted Android plugin has the files but cannot load.
local function probe()
    if not deviceSays("hasColorScreen") then
        return false
    end
    local color_path, moire_path = libPaths()
    if not (color_path and moire_path) then
        return false
    end
    if not (FS.exists(color_path) and FS.exists(moire_path)) then
        return false
    end

    local ok_color, color = pcall(ffi.load, color_path)
    local ok_moire, moire = pcall(ffi.load, moire_path)
    if not (ok_color and ok_moire and color and moire) then
        -- At warn once: files present but unloadable is a broken install.
        logger.warn("Meguru: derainbow libraries are present but would not load:",
            tostring(color), tostring(moire))
        return false
    end
    -- Guarded, not checked: a refusal means the symbols already exist.
    pcall(ffi.cdef, CDEF)

    state.color, state.moire = color, moire
    logger.dbg("Meguru: derainbow libraries loaded from", moire_path)
    return true
end

-- Four gates, the first being a colour panel; memoised, so it may load once.
function Derainbow.available()
    if not state.probed then
        state.probed = true
        state.available = probe()
    end
    return state.available
end

-- Deferred: allocating only on the first page that actually wants filtering.
-- Best-effort: a failed setup must not take the filter, or the page, down.
local function ensureInit()
    if state.initialized then
        return
    end
    state.initialized = true
    local ok_init, init_err = pcall(function()
        state.moire.init_moire_resources()
    end)
    if not ok_init then
        logger.warn("Meguru: derainbow init_moire_resources failed:", tostring(init_err))
    end
end

-- Refusal reasons already logged, so a per-tile loop says each one only once.
local reported = {}

-- The type test keeps a nil reason from raising in the paint path.
local function reportOnce(reason)
    if type(reason) ~= "string" or reported[reason] then
        return
    end
    reported[reason] = true
    logger.dbg("Meguru: derainbow skipped -", reason)
end

-- Raw geometry, or three nils plus the refusal word in the fourth slot.
-- The library walks stride bytes per row, so a padded stride is refused.
-- Dimensions come from the buffer's fields; accessors are only a fallback.
local function geometryFor(bb)
    if not (bb and type(bb.getType) == "function") then
        return nil, nil, nil, "no buffer"
    end
    local ok_type, bb_type = pcall(bb.getType, bb)
    if not ok_type or bb_type ~= Blitbuffer.TYPE_BBRGB32 then
        return nil, nil, nil, "not RGB32"
    end
    if type(bb.getRotation) == "function" then
        local ok_rot, rotation = pcall(bb.getRotation, bb)
        if ok_rot and rotation ~= 0 then
            return nil, nil, nil, "rotated"
        end
    end
    if type(bb.getInverse) == "function" then
        local ok_inv, inverse = pcall(bb.getInverse, bb)
        if ok_inv and inverse == true then
            return nil, nil, nil, "inverted"
        end
    end
    local w = tonumber(bb.w)
    local h = tonumber(bb.h)
    if not w and type(bb.getWidth) == "function" then
        local ok_w, width = pcall(bb.getWidth, bb)
        w = ok_w and tonumber(width) or nil
    end
    if not h and type(bb.getHeight) == "function" then
        local ok_h, height = pcall(bb.getHeight, bb)
        h = ok_h and tonumber(height) or nil
    end
    local stride = tonumber(bb.stride)
    if not (w and h and stride) or w < 1 or h < 1 then
        return nil, nil, nil, "no geometry"
    end
    if stride ~= w * 4 then
        return nil, nil, nil, "padded stride"
    end
    return w, h, stride
end

-- Filters in place, safe because the call site's buffer is fresh and uncached.
-- Any refusal returns the buffer untouched: an unfiltered page is the page.
function Derainbow.apply(bb)
    if not Derainbow.available() then
        return bb
    end
    local w, h, stride, refusal = geometryFor(bb)
    if not w then
        reportOnce(refusal)
        return bb
    end
    ensureInit()

    local t0 = nowMs()
    local ok, err = pcall(function()
        local ptr = ffi.cast("uint8_t*", bb.data)
        local is_colored = state.color.is_page_colored(ptr, w, h, stride, COLOR_TOLERANCE)
        state.moire.remove_moire(ptr, w, h, stride, is_colored, FILTER_STRENGTH)
    end)
    if not ok then
        -- Once per process: a throwing library throws on every tile.
        if not state.filter_failed then
            state.filter_failed = true
            logger.warn("Meguru: derainbow filter failed:", tostring(err))
        end
        return bb
    end
    -- One info line per session, then per-tile timing at dbg.
    if not state.active_reported then
        state.active_reported = true
        logger.info(string.format(
            "Meguru: derainbow filter running (%dx%d, %.1f ms)", w, h, nowMs() - t0))
    end
    logger.dbg(string.format("Meguru: derainbow %dx%d = %.1f ms", w, h, nowMs() - t0))
    return bb
end

return Derainbow
