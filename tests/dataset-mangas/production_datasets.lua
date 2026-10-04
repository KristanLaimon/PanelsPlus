--[[
Panels+
File: tests/dataset-mangas/production_datasets.lua
Name: ProductionDatasets
Description: Lists annotated volumes covered by production accuracy regressions.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Discover every annotated volume, including unfinished books' mapped pages.
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local datasets = {}
for _, book in ipairs(Manifest.loadManga()) do
    local pages, panels = 0, 0
    for _, page in ipairs(book.pages) do
        if #page.frames > 0 then
            pages = pages + 1
            panels = panels + #page.frames
        end
    end
    if pages > 0 then
        local tier = book.panel_benchmark_tier
        local experimental = tier == "experimental"
        local challenging = tier == "challenging"
        datasets[#datasets + 1] = {
            title = book.book_title,
            type = book.type,
            pages = pages,
            panels = panels,
            experimental = experimental,
            challenging = challenging,
            target_f1 = experimental and 0.50 or challenging and 0.90 or 0.95,
            minimum_f1 = experimental and 0 or challenging and 0.85 or 0.90,
            gate_95 = book.book_title == "Komi_Can't_Communicate_Vol_1" or book.book_title == "Scott_Pilgrim_Vol_5",
        }
    end
end
return datasets
