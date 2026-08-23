globals = {
    "os", "io", "table", "string", "math", "debug", "G_reader_settings",
    "require", "pcall", "type", "tostring", "tonumber", "ipairs", "pairs",
    "error", "assert", "setmetatable", "getmetatable", "print", "unpack",
    "math", "coroutine", "_",
    "logger", "Device",
}
ignore = { "212" } -- Ignore unused argument warnings (common in callbacks)
max_line_length = false

exclude_files = {
    "koreader/**/*.lua",
    "kobo.koplugin/**/*.lua",
    "zen_ui.koplugin/**/*.lua",
    "vendor/**/*.lua",
    "dist/**/*.lua",
    ".luarocks/**/*.lua",
}
