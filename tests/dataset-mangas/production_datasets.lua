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
--- Volumes covered by production accuracy regression tests.
return {
    { title = "Bloom_Into_You_Vol_8", type = "manga", pages = 213, panels = 726 },
    { title = "Miss_Kobayashi's_Dragon_Maid_Vol_2", type = "manga", pages = 143, panels = 586 },
    {
        title = "Komi_Can't_Communicate_Vol_1",
        type = "manga",
        pages = 190,
        panels = 747,
        gate_95 = true,
    },
    {
        title = "Scott_Pilgrim_Vol_5",
        type = "comic",
        pages = 218,
        panels = 838,
        gate_95 = true,
    },
}
