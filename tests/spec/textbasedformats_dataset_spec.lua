--[[
Panels+
File: tests/spec/textbasedformats_dataset_spec.lua
Name: Text-format image dataset specs
Description: Verifies equivalent Deep detection for EPUB, KEPUB, and MOBI embedded images.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Regression coverage for converted manga images embedded in EPUB, KEPUB, and MOBI.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local BenchmarkTracker = require("tests.dataset-mangas.benchmark_tracker")
local ComponentDetector = require("src._componentdetector")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")
local JSON = require("tests.helpers.json")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Manifest = require("tests.dataset-mangas.dataset_manifest")

local DATASET_DIR = "tests/dataset-mangas/dataset-textbasedformats"
local EXPECTED_COUNTS = { 2, 3, 6 }
local FORMATS = {
    { name = "EPUB", source_format = "epub", source_file = "source.epub" },
    { name = "KEPUB", source_format = "kepub.epub", source_file = "source.kepub.epub" },
    { name = "MOBI", source_format = "mobi", source_file = "source.mobi" },
}

local function readFile(path, mode)
    local file = io.open(path, mode or "r")
    assert.is_not_nil(file, "Missing fixture: " .. path)
    local contents = file:read("*a")
    file:close()
    return contents
end

local function findBook(books, title)
    for _, book in ipairs(books) do
        if book.book_title == title then
            return book
        end
    end
end

describe("EPUB, KEPUB, and MOBI embedded manga compatibility", function()
    local books = Manifest.loadManga(DATASET_DIR)

    it("loads one focused dataset for every converted format", function()
        assert.equals(#FORMATS, #books)
        for _, format in ipairs(FORMATS) do
            local title = "Bloom_Into_You_Vol_8_" .. format.name
            local book_dir = DATASET_DIR .. "/" .. title
            local metadata = JSON.decode(readFile(book_dir .. "/metadata.json"))
            local book = findBook(books, title)
            assert.is_not_nil(book)
            assert.equals("manga", book.type)
            assert.equals(3, #book.pages)
            assert.equals(format.source_format, metadata.source_format)
            assert.equals(format.source_file, metadata.source_file)
            assert.equals(7, metadata.source_pages[1])
            assert.equals(8, metadata.source_pages[2])
            assert.equals(11, metadata.source_pages[3])
        end
    end)

    it("keeps representative decoded pixels identical across all three formats", function()
        local epub_dir = DATASET_DIR .. "/Bloom_Into_You_Vol_8_EPUB"
        for page = 0, 2 do
            local filename = string.format("/%02d.png", page)
            local expected = readFile(epub_dir .. filename, "rb")
            for _, format in ipairs({ "KEPUB", "MOBI" }) do
                assert.equals(
                    expected,
                    readFile(DATASET_DIR .. "/Bloom_Into_You_Vol_8_" .. format .. filename, "rb"),
                    format .. filename .. " must contain the same decoded source image"
                )
            end
        end
    end)

    for _, format in ipairs(FORMATS) do
        local title = "Bloom_Into_You_Vol_8_" .. format.name
        it("preserves multi-panel detection for " .. format.name, function()
            local book = findBook(books, title)
            local total_ground_truth, total_detected, total_matched = 0, 0, 0
            local iou_sum, matched_pages = 0, 0

            for page_index, page in ipairs(book.pages) do
                assert.equals(EXPECTED_COUNTS[page_index], #page.frames)
                local map = Loader.loadPageMap(page.image_path, { mode = "manga" })
                local detected, accepted = ComponentDetector.detectPage(map, { mode = "manga" })
                assert.is_true(accepted, format.name .. " page " .. page_index .. " must pass detection guards")
                assert.equals(
                    EXPECTED_COUNTS[page_index],
                    #detected,
                    format.name .. " page " .. page_index .. " must not collapse into one full-page panel"
                )
                local result = Evaluator.evaluate(page.frames, detected, 0.50, 35)
                total_ground_truth = total_ground_truth + result.ground_truth_count
                total_detected = total_detected + result.detected_count
                total_matched = total_matched + result.true_positives
                iou_sum = iou_sum + result.mean_iou
                matched_pages = matched_pages + 1
            end

            local current = {
                precision = total_matched / total_detected,
                recall = total_matched / total_ground_truth,
                f1 = 2 * total_matched / (total_ground_truth + total_detected),
                mean_iou = iou_sum / matched_pages,
            }
            local baseline = BenchmarkTracker.load(DATASET_DIR .. "/" .. title)
            assert.is_not_nil(baseline and baseline.preview, "Missing text-format preview baseline")
            local ok, reason = BenchmarkTracker.verifyNoRegression(current, baseline.preview)
            assert.is_true(ok, tostring(reason))
        end)
    end
end)
