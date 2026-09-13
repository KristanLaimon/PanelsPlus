--[[
Panels+
File: tests/spec/dataset_support_spec.lua
Name: Dataset support specs
Description: Verifies dataset metadata resolution, cache isolation, and regression thresholds.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Tracker = require("tests.dataset-mangas.benchmark_tracker")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local Loader = require("tests.dataset-mangas.dataset_loader")

describe("Dataset regression safeguards", function()
    it("resolves per-book comic metadata in a shared root annotation file", function()
        local root = os.tmpname()
        os.remove(root)
        os.execute("mkdir -p " .. root .. "/A " .. root .. "/B")
        local function write(relative, content)
            local f = io.open(root .. relative, "w")
            assert.is_not_nil(f)
            f:write(content)
            f:close()
        end
        local ok, err = pcall(function()
            write("/annotation.json", '[{"book_title":"A","pages":[]},{"book_title":"B","pages":[]}]')
            write("/A/metadata.json", '{"type":"manga"}')
            write("/B/metadata.json", '{"type":"comic","color_mode":"colorless_b/w"}')
            local books = Manifest.loadManga(root)
            assert.equals("manga", books[1].type)
            assert.is_nil(books[1].color_mode)
            assert.equals("comic", books[2].type)
            assert.equals("colorless_b/w", books[2].color_mode)
            for _, invalid in ipairs({
                '{"type":"comic","color_mode":"grayscale"}',
                '{"type":"manga","color_mode":"true_b/w"}',
            }) do
                write("/B/metadata.json", invalid)
                Manifest._manga_cache[root] = nil
                local loaded = pcall(Manifest.loadManga, root)
                assert.is_false(loaded)
            end
        end)
        os.remove(root .. "/annotation.json")
        os.remove(root .. "/A/metadata.json")
        os.remove(root .. "/B/metadata.json")
        os.remove(root .. "/A")
        os.remove(root .. "/B")
        os.remove(root)
        assert.is_true(ok, tostring(err))
    end)

    it("rejects drops in every recorded metric, including precision and IoU", function()
        local baseline = { precision = 0.96, recall = 0.96, f1 = 0.96, mean_iou = 0.96 }
        for metric in pairs(baseline) do
            local current = { precision = 0.96, recall = 0.96, f1 = 0.96, mean_iou = 0.96 }
            current[metric] = 0.9599
            assert.is_false(Tracker.verifyNoRegression(current, baseline))
            current[metric] = 0.95996 -- Four-decimal JSON rounding only.
            assert.is_true(Tracker.verifyNoRegression(current, baseline))
        end
    end)

    it("bounds the page-map cache and separates settings for the same page", function()
        local page = Manifest.getPage("Scott_Pilgrim_Vol_5", 1)
        local manga = Loader.loadPageMap(page.image_path, { mode = "manga" })
        assert.equals(manga, Loader.loadPageMap(page.image_path, { mode = "manga" }))
        local comic = Loader.loadPageMap(page.image_path, { mode = "comic" })
        assert.is_true(comic ~= manga)
        local count = 0
        for _ in pairs(Loader._cache) do
            count = count + 1
        end
        assert.equals(1, count)
    end)
end)
