-- The "Meguru this series" row's artwork: a row, not a book with no cover.
-- Decoded once per process; returned as authored, never freed by the widget.
local logger = require("logger")

local FS = require("meguru/fs")
local Paths = require("meguru/paths")

local RowCover = {}

RowCover.FILE = "meguru-this-series.png"

-- false means looked-and-none, kept apart from nil meaning not looked yet.
local cached

function RowCover.bitmap()
    if cached == nil then
        cached = false

        local path = Paths.asset(RowCover.FILE)
        if not path or not FS.exists(path) then
            -- info, not warn: a missing file is an allowed state, not a fault.
            logger.info("Meguru: no row artwork at", path or RowCover.FILE,
                "- the series row uses the browser's placeholder")
            return nil
        end

        local ok, bb = pcall(function()
            -- Lazy: pulls in the image backends only after a file is found.
            local RenderImage = require("ui/renderimage")
            return RenderImage:renderImageFile(path)
        end)
        -- Two branches, not ok and nil or bb: that evaluates to bb either way.
        if not ok then
            logger.warn("Meguru: could not decode the row artwork at", path, "-", bb)
            return nil
        end
        if not bb then
            logger.warn("Meguru: the row artwork at", path, "decoded to nothing")
            return nil
        end

        cached = bb
    end

    if not cached then
        return nil
    end

    -- Returned as authored; ImageWidget applies night mode itself.
    return cached
end

return RowCover
