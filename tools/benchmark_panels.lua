#!/usr/bin/env lua
--[[
Panels+
File: tools/benchmark_panels.lua
Name: Panel benchmark CLI
Description: Runs detector benchmarks over annotated datasets and reports evaluation metrics.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Panel segmentation benchmark and evaluation tool for manga and comic datasets.
---
--- Usage:
---   lua tools/benchmark_panels.lua                         # Evaluates golden manga pages
---   lua tools/benchmark_panels.lua --all                   # Evaluates all discovered datasets
---   lua tools/benchmark_panels.lua --book tojime_no_siora  # Evaluates one book
---   lua tools/benchmark_panels.lua --book tojime_no_siora --page 2 # Detailed box inspect
---   lua tools/benchmark_panels.lua --failures-only         # Only reports pages with issues
---   lua tools/benchmark_panels.lua --summary-only          # Only reports aggregate metrics
---   lua tools/benchmark_panels.lua --threshold 0.75        # Strict IoU threshold

local script_dir = arg[0]:match("(.*/)") or "./"
local repo_root = script_dir .. "../"
package.path = repo_root .. "?.lua;" .. repo_root .. "?/init.lua;" .. package.path

require("tests.spec.helper")

local Manifest = require("tests.dataset-mangas.dataset_manifest")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")
local Segmenter = require("src._segmenter")
local BenchmarkTracker = require("tests.dataset-mangas.benchmark_tracker")

-- Parse CLI arguments
local target_book = nil
local target_page = nil
local run_all = false
local failures_only = false
local summary_only = false
local update_best = false
local detector_name = "segmenter"
local iou_threshold = 0.5
local dataset_dir = repo_root .. "tests/dataset-mangas/dataset"

local idx = 1
while idx <= #arg do
    local a = arg[idx]
    if a == "--all" then
        run_all = true
    elseif a == "--failures-only" then
        failures_only = true
    elseif a == "--summary-only" then
        summary_only = true
    elseif a == "--update-best" or a == "--update" then
        update_best = true
    elseif a == "--book" and arg[idx + 1] then
        idx = idx + 1
        target_book = arg[idx]
    elseif a == "--page" and arg[idx + 1] then
        idx = idx + 1
        target_page = tonumber(arg[idx])
    elseif a == "--threshold" and arg[idx + 1] then
        idx = idx + 1
        iou_threshold = tonumber(arg[idx]) or 0.5
    elseif a == "--dataset" and arg[idx + 1] then
        idx = idx + 1
        dataset_dir = arg[idx]
    elseif a == "--detector" and arg[idx + 1] then
        idx = idx + 1
        detector_name = arg[idx]
    end
    idx = idx + 1
end

local detector = Segmenter
if detector_name == "components" then
    detector = require("src._componentdetector")
elseif detector_name ~= "segmenter" then
    io.stderr:write("Unknown detector: " .. detector_name .. " (choose segmenter or components)\n")
    os.exit(1)
end

-- Select pages to evaluate
local pages = {}
if target_book and target_page then
    local p = Manifest.getPage(target_book, target_page, dataset_dir)
    if not p then
        io.stderr:write(string.format("Page not found: book=%s, page=%d\n", target_book, target_page))
        os.exit(1)
    end
    table.insert(pages, p)
elseif target_book then
    local books = Manifest.loadManga(dataset_dir)
    for _, b in ipairs(books) do
        if b.book_title == target_book then
            for _, p in ipairs(b.pages) do
                table.insert(pages, p)
            end
        end
    end
    if #pages == 0 then
        io.stderr:write(string.format("Book not found: %s\n", target_book))
        os.exit(1)
    end
elseif run_all then
    pages = Manifest.getAllPages(dataset_dir)
else
    pages = Manifest.getGoldenPages(dataset_dir)
end

if #pages == 0 then
    print(string.format("No pages found in dataset directory '%s'.", dataset_dir))
    print("Run the annotator app (python3 tests/dataset-mangas/annotator.py) to build your dataset,")
    print("or specify --dataset <path> pointing to your annotated dataset folder.")
    os.exit(0)
end

print(string.format("Evaluating %d page(s) (IoU threshold: %.2f)...", #pages, iou_threshold))
print("Detector: " .. detector_name)
print(string.rep("-", 80))

local total_gt = 0
local total_det = 0
local total_tp = 0
local sum_f1 = 0
local sum_iou = 0
local evaluated_count = 0
local total_order_ok = 0
local page_count = 0
local failure_count = 0
local book_metrics = {}

for _, page in ipairs(pages) do
    if page.frames and #page.frames > 0 then
        local map = Loader.loadPageMap(page.image_path, { mode = page.reading_order })
        local detected = detector.detectPage(map, { mode = page.reading_order })
        local result = Evaluator.evaluate(page.frames, detected, iou_threshold, 35)

        local metrics = book_metrics[page.book_title]
        if not metrics then
            metrics = {
                pages_evaluated = 0,
                total_ground_truth = 0,
                total_detected = 0,
                true_positives = 0,
                iou_sum = 0,
                matched_pages = 0,
            }
            book_metrics[page.book_title] = metrics
        end
        metrics.pages_evaluated = metrics.pages_evaluated + 1
        metrics.total_ground_truth = metrics.total_ground_truth + result.ground_truth_count
        metrics.total_detected = metrics.total_detected + result.detected_count
        metrics.true_positives = metrics.true_positives + result.true_positives
        if result.true_positives > 0 then
            metrics.iou_sum = metrics.iou_sum + result.mean_iou
            metrics.matched_pages = metrics.matched_pages + 1
        end

        total_gt = total_gt + result.ground_truth_count
        total_det = total_det + result.detected_count
        total_tp = total_tp + result.true_positives
        sum_f1 = sum_f1 + result.f1
        if result.true_positives > 0 then
            sum_iou = sum_iou + result.mean_iou
            evaluated_count = evaluated_count + 1
        end
        if result.reading_order_correct then
            total_order_ok = total_order_ok + 1
        end
        page_count = page_count + 1

        local is_imperfect = (result.f1 < 0.99 or not result.reading_order_correct)
        if is_imperfect then
            failure_count = failure_count + 1
        end

        if not summary_only and (not failures_only or is_imperfect) then
            local status_symbol = is_imperfect and "[x]" or "[o]"
            print(
                string.format(
                    "%s %-16s p.%-2d | GT: %d  Det: %d  TP: %d | Prec: %5.1f%%  Rec: %5.1f%%  F1: %5.1f%% | mIoU: %.2f | Order: %s",
                    status_symbol,
                    page.book_title,
                    page.page_index,
                    result.ground_truth_count,
                    result.detected_count,
                    result.true_positives,
                    result.precision * 100,
                    result.recall * 100,
                    result.f1 * 100,
                    result.mean_iou,
                    result.reading_order_correct and "OK     " or "MISMATCH"
                )
            )

            if #result.failures > 0 then
                print("    Issues: " .. table.concat(result.failures, ", "))
            end

            -- If single-page mode, print detailed box coordinates
            if target_page then
                print("\n  Ground Truth Panels:")
                for gi, gb in ipairs(page.frames) do
                    print(string.format("    GT %d: x=%4d y=%4d w=%4d h=%4d", gi, gb.x, gb.y, gb.w, gb.h))
                end
                print("\n  Detected Panels:")
                for di, db in ipairs(detected) do
                    print(
                        string.format(
                            "    Det %d: x=%4d y=%4d w=%4d h=%4d",
                            di,
                            math.floor(db.x),
                            math.floor(db.y),
                            math.floor(db.w),
                            math.floor(db.h)
                        )
                    )
                end
            end
        end
    end
end

print(string.rep("-", 80))
local global_prec = total_det > 0 and (total_tp / total_det) or 0
local global_rec = total_gt > 0 and (total_tp / total_gt) or 0
local global_f1 = (global_prec + global_rec > 0) and (2 * global_prec * global_rec / (global_prec + global_rec)) or 0
local avg_page_f1 = page_count > 0 and (sum_f1 / page_count) or 0
local avg_m_iou = evaluated_count > 0 and (sum_iou / evaluated_count) or 0

print("SUMMARY METRICS:")
print(string.format("  Pages Evaluated:       %d (%d with issues)", page_count, failure_count))
print(string.format("  Total Panels:          %d Ground Truth, %d Detected, %d Matched", total_gt, total_det, total_tp))
print(string.format("  Global Precision:      %.1f%%", global_prec * 100))
print(string.format("  Global Recall:         %.1f%%", global_rec * 100))
print(string.format("  Global F1 Score:       %.1f%%", global_f1 * 100))
print(string.format("  Average Page F1:       %.1f%%", avg_page_f1 * 100))
print(string.format("  Average Matched IoU:   %.2f", avg_m_iou))
print(
    string.format(
        "  Perfect Reading Order: %d/%d (%.1f%%)",
        total_order_ok,
        page_count,
        page_count > 0 and (total_order_ok * 100 / page_count) or 0
    )
)

local regressed = false
if not target_page and (target_book or run_all) and iou_threshold == 0.5 then
    for _, book in ipairs(Manifest.loadManga(dataset_dir)) do
        local metrics = book_metrics[book.book_title]
        if metrics then
            local book_dir = book.directory
            local mode = metrics.pages_evaluated == #book.pages and "full_volume" or "preview"
            if detector_name == "components" then
                mode = "components_" .. mode
            end
            metrics.precision = metrics.total_detected > 0 and metrics.true_positives / metrics.total_detected or 0
            metrics.recall = metrics.total_ground_truth > 0 and metrics.true_positives / metrics.total_ground_truth or 0
            local denominator = metrics.total_ground_truth + metrics.total_detected
            metrics.f1 = denominator > 0 and 2 * metrics.true_positives / denominator or 0
            metrics.mean_iou = metrics.matched_pages > 0 and metrics.iou_sum / metrics.matched_pages or 0
            metrics.gap_tolerance, metrics.iou_threshold = 35, iou_threshold
            print(
                string.format(
                    "  %s: Precision %.2f%%, Recall %.2f%%, F1 %.2f%%, IoU %.4f",
                    book.book_title,
                    metrics.precision * 100,
                    metrics.recall * 100,
                    metrics.f1 * 100,
                    metrics.mean_iou
                )
            )
            local ok, reason = BenchmarkTracker.checkAndUpdate(book_dir, mode, metrics, update_best)
            if not ok then
                print("\n  [REGRESSION ALERT] " .. book.book_title .. ": " .. tostring(reason))
                regressed = true
            end
        end
    end
end
if regressed then
    os.exit(1)
end
