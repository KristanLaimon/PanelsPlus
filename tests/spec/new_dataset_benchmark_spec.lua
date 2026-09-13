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
local Loader = require("tests.dataset-mangas.dataset_loader")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")
local ComponentDetector = require("src._componentdetector")
local BenchmarkTracker = require("tests.dataset-mangas.benchmark_tracker")

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
    for _, page in ipairs(book.pages) do
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
            assert.equals(expected.pages, #book.pages)

            local panel_count = 0
            for page_index, page in ipairs(book.pages) do
                assert.equals(page_index, page.page_index)
                assert.equals(expected.type, page.type)
                assert.equals(expected.type, page.reading_order)
                assert.is_true(#page.frames > 0, "Missing annotations on page " .. page_index)
                panel_count = panel_count + #page.frames
            end
            assert.equals(expected.panels, panel_count)
        end)

        it("preserves " .. expected.title .. " production accuracy", function()
            local book = findBook(expected.title)
            local available_images = countAvailableImages(book)
            if available_images ~= expected.pages then
                local reason =
                    string.format("%s: %d/%d images available", expected.title, available_images, expected.pages)
                assert.is_true(os.getenv("PANELSPLUS_REQUIRE_DATASETS") ~= "1", reason)
                framework.skip(reason .. "; full-volume accuracy was not measured")
            end
            local total_gt, total_detected, total_matched = 0, 0, 0
            local iou_sum, matched_pages = 0, 0

            for _, page in ipairs(book.pages) do
                local map = Loader.loadPageMap(page.image_path, { mode = page.reading_order })
                local detected = ComponentDetector.detectPage(map, { mode = page.reading_order })
                local result = Evaluator.evaluate(page.frames, detected, 0.50, 35)
                total_gt = total_gt + result.ground_truth_count
                total_detected = total_detected + result.detected_count
                total_matched = total_matched + result.true_positives
                if result.true_positives > 0 then
                    iou_sum = iou_sum + result.mean_iou
                    matched_pages = matched_pages + 1
                end
            end

            local precision = total_detected > 0 and total_matched / total_detected or 0
            local recall = total_gt > 0 and total_matched / total_gt or 0
            local f1 = total_gt + total_detected > 0 and 2 * total_matched / (total_gt + total_detected) or 0
            local mean_iou = matched_pages > 0 and iou_sum / matched_pages or 0
            local book_dir = "tests/dataset-mangas/dataset/" .. expected.title
            local baseline = BenchmarkTracker.load(book_dir)
            assert.is_not_nil(baseline and baseline.components_full_volume, "Missing production baseline")
            local ok, reason = BenchmarkTracker.verifyNoRegression({
                precision = precision,
                recall = recall,
                f1 = f1,
                mean_iou = mean_iou,
            }, baseline.components_full_volume)
            assert.is_true(ok, reason)
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
end)
