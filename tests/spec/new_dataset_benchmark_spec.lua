--[[
Panels+
File: tests/spec/new_dataset_benchmark_spec.lua
Name: Production dataset benchmark specs
Description: Guards full-volume component-detector accuracy baselines.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Full-volume production baselines for every local dataset.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local Manifest = require("tests.dataset-mangas.dataset_manifest")
local BenchmarkTracker = require("tests.dataset-mangas.benchmark_tracker")
local AlgorithmBenchmark = require("tests.dataset-mangas.algorithm_benchmark")

local DATASETS = require("tests.dataset-mangas.production_datasets")
local selected_dataset = os.getenv("PANELSPLUS_TEST_DATASET")
if selected_dataset then
    local selected = {}
    for _, dataset in ipairs(DATASETS) do
        if dataset.title == selected_dataset then
            selected[#selected + 1] = dataset
        end
    end
    assert.equals(1, #selected, "Unknown production dataset: " .. selected_dataset)
    DATASETS = selected
end

local function findBook(title)
    for _, book in ipairs(Manifest.loadManga()) do
        if book.book_title == title then
            return book
        end
    end
end

local function countAvailableImages(book)
    local count = 0
    for _, page in ipairs(Manifest.getMappedPages(book)) do
        local image = io.open(page.image_path, "r")
        if image then
            image:close()
            count = count + 1
        end
    end
    return count
end

describe("Manga and comic full-volume production benchmarks", function()
    for _, expected in ipairs(DATASETS) do
        it("validates " .. expected.title .. " metadata and annotations", function()
            local book = findBook(expected.title)
            assert.is_not_nil(book)
            assert.equals(expected.type, book.type)
            assert.is_true(#book.pages >= expected.pages)

            local panel_count = 0
            local seen = {}
            for _, page in ipairs(book.pages) do
                assert.is_true(page.page_index > 0)
                assert.is_nil(seen[page.page_index], "Duplicate page index")
                seen[page.page_index] = true
                assert.equals(expected.type, page.type)
                assert.equals(expected.type, page.reading_order)
                for _, frame in ipairs(page.frames) do
                    assert.is_true(frame.x >= 0 and frame.y >= 0 and frame.w > 0 and frame.h > 0)
                end
                panel_count = panel_count + #page.frames
            end
            assert.equals(expected.panels, panel_count)
        end)

        for _, algorithm in ipairs({ "safe", "smart" }) do
            it("preserves " .. expected.title .. " " .. algorithm .. " production accuracy", function()
                local book = findBook(expected.title)
                local available_images = countAvailableImages(book)
                if available_images ~= expected.pages then
                    local reason =
                        string.format("%s: %d/%d images available", expected.title, available_images, expected.pages)
                    assert.is_true(os.getenv("PANELSPLUS_REQUIRE_DATASETS") ~= "1", reason)
                    framework.skip(reason .. "; full-volume accuracy was not measured")
                end
                local current = AlgorithmBenchmark.evaluate(book, algorithm)
                local baseline_data = BenchmarkTracker.load(book.directory)
                assert.is_not_nil(
                    baseline_data and baseline_data[algorithm .. "_full_volume"],
                    "Missing algorithm baseline"
                )
                local baseline_ok, baseline_reason = AlgorithmBenchmark.verify(baseline_data, algorithm, current)
                assert.is_true(baseline_ok, baseline_reason)
                print(
                    string.format(
                        "%s [%s]: %d mapped pages, precision %.2f%%, recall %.2f%%, F1 %.2f%%, IoU %.4f",
                        expected.title,
                        algorithm,
                        current.pages_evaluated,
                        current.precision * 100,
                        current.recall * 100,
                        current.f1 * 100,
                        current.mean_iou
                    )
                )
                if algorithm == "safe" then
                    return -- Safe is guarded only by its own baseline, never Smart's accuracy target.
                end
                local precision, recall, f1 = current.precision, current.recall, current.f1
                local mean_iou = current.mean_iou
                print(
                    string.format(
                        "%s%s: %d mapped pages, precision %.2f%%, recall %.2f%%, F1 %.2f%% (target %.0f%%), IoU %.4f",
                        expected.title,
                        expected.experimental and " [experimental / hard]"
                            or expected.challenging and " [challenging]"
                            or "",
                        expected.pages,
                        precision * 100,
                        recall * 100,
                        f1 * 100,
                        expected.target_f1 * 100,
                        mean_iou
                    )
                )
                if expected.experimental then
                    return -- Report hard layouts without driving production tuning.
                end
                assert.is_true(
                    f1 > expected.minimum_f1,
                    string.format("Mapped-page F1 must exceed %.0f%% (got %.2f%%)", expected.minimum_f1 * 100, f1 * 100)
                )
                if not expected.gate_95 then
                    return
                end
                assert.is_true(
                    f1 > 0.95,
                    string.format(
                        "%s must remain above 95%% F1 (precision %.2f%%, recall %.2f%%, F1 %.2f%%)",
                        expected.title,
                        precision * 100,
                        recall * 100,
                        f1 * 100
                    )
                )
                assert.is_true(recall > 0.95, "Recall must remain above 95%")
                assert.is_true(mean_iou > 0.95, "Mean matched IoU must remain above 0.95")
            end)
        end
    end
end)
