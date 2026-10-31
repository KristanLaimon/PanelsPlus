--[[
Panels+
File: tools/benchmarking/benchmark_component_resources.lua
Name: Component detector resource benchmark
Description: Measures warmed detector CPU, temporary allocations, and scratch storage.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
-- Run from the repository root with LuaJIT. Use a separate process per version:
--   luajit tools/benchmarking/benchmark_component_resources.lua safe [reference.lua] [reference_smart.lua]
-- Five evenly spaced pages per book, four warmups and four timed detections.
-- Decoding, cleanup, and allocation sampling are outside the CPU measurement.
-- Garbage means allocations during one warmed detection with GC temporarily
-- stopped, not resident memory. Retained heap also includes LuaJIT bookkeeping.
-- Only one page map is retained; annotations and benchmark records are read-only.
require("ffi")
require("tests.helper")
io.stdout:setvbuf("line")
local algorithm = arg[1] or "safe"
assert(algorithm == "safe" or algorithm == "smart", "algorithm must be safe or smart")
local implementation = arg[2] or "working tree"
-- Safe at 6086013 imports Smart: isolate that dependency when measuring it.
if arg[3] then
    package.loaded["src._smartcomponentdetector"] = dofile(arg[3])
end
local detector = arg[2] and dofile(arg[2]) or require("src._" .. algorithm .. "componentdetector")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local cpu, count, garbage, retained = 0, 0, 0, 0
local maximum_buffers = 0
local ffi = require("ffi")
for _, book in ipairs(Manifest.loadManga()) do
    for sample = 1, 5 do
        local page = book.pages[1 + math.floor((sample - 1) * (#book.pages - 1) / 4)]
        local settings = { mode = page.reading_order, embedded_image = page.embedded_image }
        local map = Loader.loadPageMap(page.image_path, settings)
        detector.clearScratch()
        collectgarbage("collect")
        local initial = collectgarbage("count")
        local original_new, buffers = ffi.new, 0
        ffi.new = function(...)
            local buffer = original_new(...)
            buffers = buffers + ffi.sizeof(buffer)
            return buffer
        end
        local ok, err = pcall(function()
            for _ = 1, 4 do
                detector.detectPage(map, settings)
            end
        end)
        ffi.new = original_new
        assert(ok, err)
        maximum_buffers = math.max(maximum_buffers, buffers)
        collectgarbage("collect")
        local warm = collectgarbage("count")
        retained = math.max(retained, warm - initial)
        for _ = 1, 4 do
            local start = os.clock()
            detector.detectPage(map, settings)
            cpu = cpu + os.clock() - start
        end
        collectgarbage("collect")
        collectgarbage("stop")
        local memory = collectgarbage("count")
        detector.detectPage(map, settings)
        garbage = garbage + collectgarbage("count") - memory
        collectgarbage("restart")
        detector.clearScratch()
        collectgarbage("collect")
        count = count + 1
    end
    print(book.book_title)
end
print(
    string.format(
        "%s %s %d pages %.3f ms/page %.1f KiB/page garbage %.1f KiB max retained %.1f KiB maximum FFI buffers",
        implementation,
        algorithm,
        count,
        1000 * cpu / (count * 4),
        garbage / count,
        retained,
        maximum_buffers / 1024
    )
)
