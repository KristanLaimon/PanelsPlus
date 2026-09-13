--[[
Panels+
File: tools/benchmark_component_scan.lua
Name: Component scan benchmark
Description: Compares component-detector CPU time and exact outputs with a reference revision.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
-- Compare detector CPU time and exact outputs against a saved source revision.
-- Run from the repository root:
--   MAGICK_THREAD_LIMIT=1 luajit tools/benchmark_component_scan.lua reference.lua [pages_per_book]
-- Image decoding is excluded from timings. Only one page map is retained.
-- Neither annotations nor bestbenchmark.json records are modified.
assert(arg[1], "Usage: luajit tools/benchmark_component_scan.lua reference.lua [pages_per_book]")
package.path = "./?.lua;./?/init.lua;" .. package.path
require("ffi")
require("tests.spec.helper")
local before = dofile(arg[1])
local after = require("src._componentdetector")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local totals = {}
local limit = tonumber(arg[2])
assert(not arg[2] or (limit and limit >= 1 and limit == math.floor(limit)), "pages_per_book must be a positive integer")
local count = 0
for _, page in ipairs(Manifest.getAllPages()) do
    if not limit or page.page_index <= limit then
        local settings = { mode = page.reading_order }
        local map = Loader.loadPageMap(page.image_path, settings)
        local results, times = {}, {}
        for run = 1, 4 do
            -- Alternate execution order to reduce warm-cache bias.
            for slot = 1, 2 do
                local i = run % 2 == 0 and slot or 3 - slot
                local detector = i == 1 and before or after
                local start = os.clock()
                local panels, accepted, reason = detector.detectPage(map, settings)
                times[i] = (times[i] or 0) + os.clock() - start
                results[i] = { panels = panels, accepted = accepted, reason = reason }
            end
            assert(
                results[1].accepted == results[2].accepted and results[1].reason == results[2].reason,
                page.image_path
            )
            assert(#results[1].panels == #results[2].panels, page.image_path)
            for i, panel in ipairs(results[1].panels) do
                for _, key in ipairs({ "x", "y", "w", "h" }) do
                    assert(panel[key] == results[2].panels[i][key], page.image_path .. ":" .. key)
                end
            end
        end
        local t = totals[page.book_title] or { 0, 0, 0 }
        totals[page.book_title] = t
        t[1], t[2], t[3] = t[1] + times[1] / 4, t[2] + times[2] / 4, t[3] + 1
        count = count + 1
        if count % 100 == 0 then
            print("Compared " .. count)
            io.stdout:flush()
        end
    end
end
assert(count > 0, "No dataset pages found")
for book, t in pairs(totals) do
    print(
        string.format(
            "%s pages=%d before=%.3fms after=%.3fms reduction=%.1f%%",
            book,
            t[3],
            t[1] * 1000 / t[3],
            t[2] * 1000 / t[3],
            100 * (1 - t[2] / t[1])
        )
    )
end
