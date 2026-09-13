--[[
Panels+
File: tests/dataset-mangas/dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/miss_kobayashi_spec.lua
Name: Miss Kobayashi dataset spec
Description: Defines annotated-volume regression checks for Miss Kobayashi's Dragon Maid Volume 2.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Spec tests for the human-annotated Miss Kobayashi's Dragon Maid (Vol. 2) manga dataset.
---
--- Located directly within `tests/dataset-mangas/dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/`.
---
--- Validates 100% of panel annotations across all 143 pages from json, ensures 'en' language paths,
--- verifies metadata, and gracefully warns + skips full page checks if running from a public clone
--- with only preview pages (00.png, 01.png, 02.png) due to DMCA protection.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local JSON = require("tests.helpers.json")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")
local Segmenter = require("src._segmenter")
local BenchmarkTracker = require("tests.dataset-mangas.benchmark_tracker")

local BOOK_TITLE = "Miss_Kobayashi's_Dragon_Maid_Vol_2"
local BOOK_DIR = "tests/dataset-mangas/dataset/" .. BOOK_TITLE

-- Check available images on disk to distinguish full dataset vs public DMCA preview clone
local function countAvailableImages(book_dir, max_pages)
    local count = 0
    for i = 0, max_pages - 1 do
        local img_path = string.format("%s/%02d.png", book_dir, i)
        local f = io.open(img_path, "r")
        if f then
            f:close()
            count = count + 1
        end
    end
    return count
end

describe("Miss Kobayashi's Dragon Maid human-annotated dataset validation", function()
    local available_images = countAvailableImages(BOOK_DIR, 143)
    local is_full_volume = (available_images == 143)

    if not is_full_volume then
        print(
            string.format(
                "\n  [WARNING] %s: Only %d/143 pages found on disk (public clone / DMCA preview mode).",
                BOOK_TITLE,
                available_images
            )
        )
        print("  [WARNING] Skipping full-volume page-by-page tests. To run 100% validation, extract complete volume.\n")
    end

    it("loads book metadata correctly", function()
        local meta_path = BOOK_DIR .. "/metadata.json"
        local f = io.open(meta_path, "r")
        assert.is_not_nil(f, "metadata.json must exist in " .. BOOK_DIR)
        local content = f:read("*a")
        f:close()

        local meta = JSON.decode(content)
        assert.is_not_nil(meta, "metadata.json must be valid JSON")
        assert.equals(143, meta.total_pages)
        assert.is_true(meta.finished == true, "Dataset must be marked as finished")
        assert.is_not_nil(meta.book_title)
    end)

    it("verifies 100% of panel annotations across all 143 pages in JSON", function()
        local books = Manifest.loadManga()
        local target_book = nil
        for _, b in ipairs(books) do
            if b.book_title == BOOK_TITLE then
                target_book = b
                break
            end
        end

        assert.is_not_nil(target_book, "Book " .. BOOK_TITLE .. " must be loaded by Manifest")
        assert.equals(143, #target_book.pages, "Must contain exactly 143 pages in JSON")

        local total_panels = 0
        local expected_page_indices = {}
        for i = 1, 143 do
            expected_page_indices[i] = false
        end

        -- Check 100% of pages in json
        for _, page in ipairs(target_book.pages) do
            local p_idx = page.page_index
            assert.is_not_nil(p_idx, "Page index must not be nil")
            assert.is_true(p_idx >= 1 and p_idx <= 143, "Page index must be between 1 and 143")
            expected_page_indices[p_idx] = true

            -- Verify image path format
            assert.is_not_nil(page.image_path, "Image path must not be nil for page " .. p_idx)
            assert.is_true(#page.image_path > 0, "Image path must not be empty for page " .. p_idx)

            -- Verify 100% of panel annotations on this page
            assert.is_not_nil(page.frames, "Frames table must exist for page " .. p_idx)
            assert.is_true(#page.frames >= 1, "Page " .. p_idx .. " must have at least 1 annotated panel")

            for f_idx, frame in ipairs(page.frames) do
                total_panels = total_panels + 1
                assert.is_not_nil(frame.x, string.format("p.%d f.%d: x must not be nil", p_idx, f_idx))
                assert.is_not_nil(frame.y, string.format("p.%d f.%d: y must not be nil", p_idx, f_idx))
                assert.is_not_nil(frame.w, string.format("p.%d f.%d: w must not be nil", p_idx, f_idx))
                assert.is_not_nil(frame.h, string.format("p.%d f.%d: h must not be nil", p_idx, f_idx))

                -- Panel geometry validation
                assert.is_true(frame.x >= 0, string.format("p.%d f.%d: x must be >= 0 (got %d)", p_idx, f_idx, frame.x))
                assert.is_true(frame.y >= 0, string.format("p.%d f.%d: y must be >= 0 (got %d)", p_idx, f_idx, frame.y))
                assert.is_true(frame.w > 0, string.format("p.%d f.%d: w must be > 0 (got %d)", p_idx, f_idx, frame.w))
                assert.is_true(frame.h > 0, string.format("p.%d f.%d: h must be > 0 (got %d)", p_idx, f_idx, frame.h))

                -- Must fit within native page bounds (1264x1680)
                assert.is_true(
                    frame.x + frame.w <= 1264,
                    string.format(
                        "p.%d f.%d: panel right (%d) exceeds native width 1264",
                        p_idx,
                        f_idx,
                        frame.x + frame.w
                    )
                )
                assert.is_true(
                    frame.y + frame.h <= 1680,
                    string.format(
                        "p.%d f.%d: panel bottom (%d) exceeds native height 1680",
                        p_idx,
                        f_idx,
                        frame.y + frame.h
                    )
                )
            end
        end

        -- Ensure every single page from 1 to 143 was covered with no gaps
        for i = 1, 143 do
            assert.is_true(expected_page_indices[i], "Missing page index in dataset: " .. i)
        end

        -- Verify total panels count (586 hand-annotated panels)
        assert.equals(586, total_panels)
    end)

    it("verifies raw annotation.json uses 'en' key instead of 'ja'", function()
        local ann_path = BOOK_DIR .. "/annotation.json"
        local f = io.open(ann_path, "r")
        assert.is_not_nil(f, "annotation.json must exist in " .. BOOK_DIR)
        local raw_json = f:read("*a")
        f:close()

        local data = JSON.decode(raw_json)
        assert.is_not_nil(data, "raw annotation.json must decode")
        assert.equals(1, #data)
        local pages = data[1].pages
        assert.equals(143, #pages)

        for _, p in ipairs(pages) do
            local img_paths = p.image_paths
            assert.is_not_nil(img_paths, "image_paths must exist on page " .. p.page_index)
            assert.is_not_nil(img_paths.en, "image_paths must use 'en' key on page " .. p.page_index)
            assert.is_nil(img_paths.ja, "image_paths must NOT use 'ja' on page " .. p.page_index)
            assert.is_true(
                img_paths.en:find("^Miss_Kobayashi's_Dragon_Maid_Vol_2/%d%d+%.png$") ~= nil,
                "image_paths.en must match pattern Miss_Kobayashi's_Dragon_Maid_Vol_2/XX.png (got "
                    .. tostring(img_paths.en)
                    .. ")"
            )
        end
    end)

    it("checks page image files on disk (full volume or preview mode)", function()
        if is_full_volume then
            -- Full volume available: check all 143 images on disk
            for p_idx = 1, 143 do
                local img_path = string.format("%s/%02d.png", BOOK_DIR, p_idx - 1)
                local f = io.open(img_path, "r")
                assert.is_not_nil(f, "Page image must exist: " .. img_path)
                if f then
                    f:close()
                end
            end
        else
            -- Public clone / preview mode: verify the preview pages exist (00.png, 01.png, 02.png)
            for p_idx = 1, math.min(3, available_images) do
                local img_path = string.format("%s/%02d.png", BOOK_DIR, p_idx - 1)
                local f = io.open(img_path, "r")
                assert.is_not_nil(f, "Preview page image must exist: " .. img_path)
                if f then
                    f:close()
                end
            end
        end
    end)

    it("evaluates panel recognition on available Miss Kobayashi pages", function()
        local max_test_pages = is_full_volume and 143 or math.min(3, available_images)
        local total_gt, total_det, total_tp = 0, 0, 0
        local total_iou, evaluated_count = 0, 0

        for p_idx = 1, max_test_pages do
            local page = Manifest.getPage(BOOK_TITLE, p_idx)
            assert.is_not_nil(page, "Page " .. p_idx .. " must be retrieved by Manifest")

            local map = Loader.loadPageMap(page.image_path, { mode = page.reading_order })
            assert.equals(1264, map.native_w)
            assert.equals(1680, map.native_h)
            assert.is_true(map.ink > 0)

            local detected = Segmenter.detectPage(map, { mode = page.reading_order })
            assert.is_true(#detected > 0, "Segmenter must detect panels on page " .. p_idx)

            -- Evaluate extracted panels against ground truth with 35px failing gap tolerance or IoU >= 0.50
            local result = Evaluator.evaluate(page.frames, detected, 0.50, 35)

            total_gt = total_gt + result.ground_truth_count
            total_det = total_det + result.detected_count
            total_tp = total_tp + result.true_positives
            if result.true_positives > 0 then
                total_iou = total_iou + result.mean_iou
                evaluated_count = evaluated_count + 1
            end
        end

        assert.is_true(total_tp >= 1, "Expected at least 1 true positive match")
        local global_precision = total_det > 0 and (total_tp / total_det) or 0
        local global_recall = total_gt > 0 and (total_tp / total_gt) or 0
        local global_f1 = (global_precision + global_recall > 0)
                and (2 * global_precision * global_recall / (global_precision + global_recall))
            or 0
        local mean_iou = evaluated_count > 0 and (total_iou / evaluated_count) or 0

        -- General sanity thresholds
        assert.is_true(
            global_recall >= 0.50,
            string.format("Expected global recall >= 50%% across tested pages (got %.1f%%)", global_recall * 100)
        )
        assert.is_true(
            mean_iou >= 0.70,
            string.format("Expected mean IoU >= 0.70 across tested pages (got %.2f)", mean_iou)
        )

        -- Enforce regression protection against bestbenchmark.json:
        -- Tests verify records without rewriting their own baselines.
        local current_metrics = {
            pages_evaluated = max_test_pages,
            total_ground_truth = total_gt,
            total_detected = total_det,
            true_positives = total_tp,
            precision = global_precision,
            recall = global_recall,
            f1 = global_f1,
            mean_iou = mean_iou,
            gap_tolerance = 35,
            iou_threshold = 0.50,
        }
        local mode = is_full_volume and "full_volume" or "preview"
        local ok, regression_err = BenchmarkTracker.checkAndUpdate(BOOK_DIR, mode, current_metrics, false)
        assert.is_true(ok, tostring(regression_err))
    end)
end)
