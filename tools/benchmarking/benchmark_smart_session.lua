--[[
Panels+
File: tools/benchmarking/benchmark_smart_session.lua
Name: Smart sustained-session benchmark
Description: Repeats Smart detection with normal garbage collection and no per-page scratch resets.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
-- Run from the repository root with LuaJIT, optionally supplying a saved
-- Smart implementation. Five sampled pages per book, thirty calls per page.
-- Compare warmed calls 6-10 with 26-30. Image decoding is outside the CPU
-- timings. The heap includes input maps, dataset metadata, and JIT state;
-- it does not measure KOReader rendering, framebuffer work, or device RSS.
require("ffi")
require("tests.helper")
io.stdout:setvbuf("line")
local detector = arg[1] and dofile(arg[1]) or require("src._smartcomponentdetector")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local count, cpu, first, last, peak = 0, 0, 0, 0, 0
collectgarbage("collect")
local initial = collectgarbage("count")
for _, book in ipairs(Manifest.loadManga()) do
    local book_cpu, pages = 0, 0
    for sample = 1, 5 do
        local page = book.pages[1 + math.floor((sample - 1) * (#book.pages - 1) / 4)]
        local settings = { mode = page.reading_order, embedded_image = page.embedded_image }
        local map = Loader.loadPageMap(page.image_path, settings)
        for run = 1, 30 do
            local start = os.clock()
            detector.detectPage(map, settings)
            local elapsed = os.clock() - start
            book_cpu = book_cpu + elapsed
            if run >= 6 and run <= 10 then
                first = first + elapsed
            end
            if run >= 26 then
                last = last + elapsed
            end
            peak = math.max(peak, collectgarbage("count"))
            count = count + 1
        end
        pages = pages + 1
    end
    cpu = cpu + book_cpu
    print(
        string.format(
            "%s %d detections %.3f ms/detection heap=%.0f KiB",
            book.book_title,
            pages * 30,
            book_cpu * 1000 / (pages * 30),
            collectgarbage("count")
        )
    )
end
collectgarbage("collect")
print(
    string.format(
        "TOTAL %d detections %.3f ms/detection early=%.3f ms late=%.3f ms peak_heap=%.0f KiB retained_delta=%.0f KiB",
        count,
        cpu * 1000 / count,
        first * 1000 / (count / 6),
        last * 1000 / (count / 6),
        peak,
        collectgarbage("count") - initial
    )
)
