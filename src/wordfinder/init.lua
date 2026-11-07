--[[
Panels+
File: src/wordfinder/init.lua
Name: WordFinder
Description: Composes comic-lettering word detection and OCR.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Timing = require("src._timing")
local logger = require("logger")

--- Comic-lettering-aware replacement for KOReader's native word-box finder.
---
--- KOReader locates a tapped word with a generic gap-detection pass tuned for
--- justified prose (`KoptInterface:getWordFromBoxes`), then OCRs whatever box
--- that pass produced. Stylized/bold comic lettering has irregular, often very
--- tight kerning, so that generic pass routinely finds the wrong gap and OCR
--- then faithfully transcribes the wrong crop -- a box that "looks about
--- right" on screen but contains half a word, two words, or worse.
---
--- This module finds a word box at native document resolution with thresholds
--- relative to the local line height. On paging documents it renders that box
--- through KOReader's kopt context and reads it with the bundled OCR engine in
--- single-word mode. Other documents fall back to `document:getOCRWord`.
---
--- @class PPWordFinder
local WordFinder = {}

--- Appends a diagnostic log entry to the KOReader log, and -- only while
--- `debug_mode` is on -- to `panels_wordfinder.log` next to the running
--- KOReader install and in `/tmp`.
---
--- The file writes are deliberately gated: this runs on *every* long-press,
--- so unconditional appends mean a synchronous open/write/close pair per tap
--- on device flash for output nobody is reading.
---
--- @param msg string Main log message.
--- @param details table|nil Key-value details to format.
function WordFinder.logDiagnostic(msg, details)
    if not Timing.enabled then
        return
    end
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s] [Panels+ WordFinder] %s", timestamp, msg)
    if details then
        local parts = {}
        for k, v in pairs(details) do
            table.insert(parts, string.format("%s=%s", tostring(k), tostring(v)))
        end
        table.sort(parts)
        line = line .. " | " .. table.concat(parts, ", ")
    end
    logger.info(line)
    for _, path in ipairs({ "./panels_wordfinder.log", "/tmp/panels_wordfinder.log" }) do
        local f = io.open(path, "a")
        if f then
            f:write(line .. "\n")
            f:close()
        end
    end
end

require("src.wordfinder.models")(WordFinder)
require("src.wordfinder.ocr")(WordFinder)
require("src.wordfinder.detection")(WordFinder)

return WordFinder
