-- Plugin prefs in G_reader_settings keys; per-book values live in the sidecar.

local logger = require("logger")

local Settings = {}

-- Sentinel for "unset by default": a nil default would vanish from the literal.
local UNSET = {}
Settings.UNSET = UNSET

local DEFAULTS = {
    marker_dir        = UNSET,        -- base for markers; unset = home folder

    -- Nest markers as <base>/<server>/<series>; two servers can share a name.
    marker_server_dir = true,

    -- One key per server; meguru/seriescover owns the list of kinds.
    folder_cover_suwayomi = true,
    folder_cover_kavita   = true,
    folder_cover_komga    = true,

    -- One key per server; only Komga accepts a write.
    report_progress_komga = true,

    hide_status_bar   = true,
    auto_next_item    = true,
    manga_order       = true,

    -- Flashes each page turn in a Meguru book; KOReader's rate governs the rest.
    refresh_each_page = false,

    -- Local .cbz: title and fields from the archive's own ComicInfo.xml.
    comic_info        = true,

    -- Seed for a book's kopt_panel_view; "window" shows the page uncropped.
    panel_view        = "window",

    -- Who answers the long-press while Panels+ is the rival: "panelsplus" | "meguru".
    panel_owner       = "panelsplus",

    -- Panel turn: "off" | "on" | "auto" by the panel's shape; unset = stock's.
    panel_rotate      = UNSET,

    -- Window zoom as a multiple of page width; 1.7 is the middle preset.
    panel_zoom_level  = 1.7,

    -- Free view's scale in screen px per page px; false = nothing chosen yet.
    free_zoom_scale   = false,

    -- Records the .cbz claim offer, so turning the row off is not undone.
    cbz_default_claimed = false,

    -- Retained-decode budget for one page (10 Mpx); no menu writes it.
    max_native_pixels = 10 * 1024 * 1024,

    -- Semantic fit, not zoom_mode names: the crop changes the mapping.
    fit               = "full",       -- "full" | "width" | "height"

    -- Plugin-wide fallbacks a book with no value of its own picks up, once.
    page_scroll       = 0,            -- 0 = page view, 1 = continuous
    trim_page         = 1,            -- 1 = auto crop; 3 = none
    rotate_wide       = 1,            -- 0 = off, 1 = right, 2 = left

    -- Pages shown at once: "off" (default), "auto" (landscape), "on".
    spread            = "off",

    -- 0 = no offset; otherwise the page the offset is anchored at.
    -- 0 is truthy in Lua, so this is always compared, never tested for truth.
    spread_offset     = 0,

    -- Keep the gutter the crop removed; on by default, asked by _pairLayout.
    spread_gutter     = 1,
    night_mode        = true,         -- pre-invert pages, not a stark negative

    -- MuPDF contrast seed; 1.0 = as arrived; row presets live in ui/reader.
    contrast          = 1.0,

    -- Colour intensity seed; 1.0 = the file's own colour; colour screens only.
    saturation        = 1.0,

    -- Deliberately unset: the device's own dither answer stands until a tap.
    dither            = UNSET,

    -- Unset too: nothing imposed, so the row's default is the panel's answer.
    hw_dither         = UNSET,

    -- Off by default: a Fourier pass is worth it only on a colour e-ink panel.
    derainbow         = 0,

    -- Deliberately unset: no rotation is imposed until the reader chooses one.
    rotation_mode     = UNSET,
}

-- Read also from the render path and early plugin init, so tolerate it absent.
local function readStore()
    local s = rawget(_G, "G_reader_settings")
    if s and type(s.readSetting) == "function" then
        return s
    end
    return nil
end

function Settings.get(name)
    local default = DEFAULTS[name]
    if default == nil then
        logger.warn("Meguru: unknown setting", name)
        return nil
    end
    if default == UNSET then
        default = nil
    end

    local s = readStore()
    if not s then
        return default
    end
    local value = s:readSetting("meguru_" .. name)
    if value == nil then
        return default
    end
    return value
end

function Settings.set(name, value)
    if DEFAULTS[name] == nil then
        logger.warn("Meguru: unknown setting", name)
        return false
    end
    local s = readStore()
    if not s then
        return false
    end
    s:saveSetting("meguru_" .. name, value)
    s:flush()
    return true
end

function Settings.toggle(name)
    local value = not Settings.get(name)
    Settings.set(name, value)
    return value
end

return Settings
