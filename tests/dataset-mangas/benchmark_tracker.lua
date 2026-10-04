--[[
Panels+
File: tests/dataset-mangas/benchmark_tracker.lua
Name: BenchmarkTracker
Description: Loads, compares, and records panel-detection benchmark regression metrics.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Regression guard and record tracker for manga panel detection benchmarks.
---
--- Ensures that algorithmic refactors and changes never degrade detection accuracy
--- below the historical best metrics stored in `bestbenchmark.json` per manga folder.
--- When a run beats the best known score, `bestbenchmark.json` is updated with the new record.

local JSON = require("tests.helpers.json")

local BenchmarkTracker = {}
local ORDER_RATES = { "reading_order_accuracy", "reading_order_pair_accuracy" }
local ORDER_COUNTS = {
    "reading_order_pages",
    "reading_order_pages_correct",
    "reading_order_pairs",
    "reading_order_pairs_correct",
}

--- Load the best benchmark baseline for a book.
---
--- @param book_dir string Path to the manga folder (e.g. tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8)
--- @return table|nil baseline The parsed benchmark table, or nil if not found.
function BenchmarkTracker.load(book_dir)
    local path = book_dir .. "/bestbenchmark.json"
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    if not content or not content:find("%S") then
        return nil
    end
    return JSON.decode(content)
end

--- Save updated benchmark data to `bestbenchmark.json`.
---
--- @param book_dir string Path to the manga folder
--- @param data table Benchmark table to serialize
function BenchmarkTracker.save(book_dir, data)
    local path = book_dir .. "/bestbenchmark.json"
    local f = io.open(path, "w")
    if not f then
        error("Failed to write to: " .. path)
    end
    local content = JSON.encode(data)
    f:write(content .. "\n")
    f:close()
end

--- Determine if current metrics represent an improvement over best metrics.
---
--- Recognizes new/improved ordering measurements, then F1, Recall, and Mean IoU.
--- The caller must check all regression guards before saving an improvement.
---
--- @param current table Current evaluation metrics {f1, recall, precision, mean_iou}
--- @param best table Best benchmark metrics {f1, recall, precision, mean_iou}
--- @return boolean is_better
function BenchmarkTracker.isBetter(current, best)
    if not best then
        return true
    end
    for _, key in ipairs(ORDER_RATES) do
        if current[key] ~= nil and (best[key] == nil or current[key] > best[key] + 0.00005) then
            return true
        end
    end
    local f1_diff = (current.f1 or 0) - (best.f1 or 0)
    if f1_diff > 0.001 then
        return true
    end
    if math.abs(f1_diff) <= 0.001 then
        local rec_diff = (current.recall or 0) - (best.recall or 0)
        if rec_diff > 0.001 then
            return true
        end
        if math.abs(rec_diff) <= 0.001 then
            return (current.mean_iou or 0) > (best.mean_iou or 0) + 0.005
        end
    end
    return false
end

--- Check whether current metrics have regressed compared to best benchmark.
---
--- Only allow the rounding error of the four-decimal JSON records by default.
---
--- @param current table Current metrics {f1, recall, precision, mean_iou}
--- @param best table Best baseline metrics {f1, recall, precision, mean_iou}
--- @param tolerance number|nil Explicit margin override (default 0.00005)
--- @return boolean ok True if equal or better (no regression)
--- @return string|nil error Message describing the regression if failed
function BenchmarkTracker.verifyNoRegression(current, best, tolerance)
    if not best then
        return true, nil
    end
    local tol = tolerance or 0.000050000001
    for _, key in ipairs(ORDER_RATES) do
        if best[key] ~= nil then
            if current[key] == nil then
                return false, "Missing recorded ordering metric: " .. key
            end
            if current[key] < best[key] - tol then
                return false,
                    string.format("REGRESSION in %s: got %.2f%%, best %.2f%%", key, current[key] * 100, best[key] * 100)
            end
        end
    end

    -- Precision was previously unguarded, so added false positives could pass.
    if (current.precision or 0) < (best.precision or 0) - tol then
        return false,
            string.format("REGRESSION in Precision: got %.6f, best %.6f", current.precision or 0, best.precision or 0)
    end

    -- 1. Check F1 score regression
    if (current.f1 or 0) < (best.f1 or 0) - tol then
        return false,
            string.format(
                "REGRESSION in F1 Score: got %.2f%%, expected at least %.2f%% (best was %.2f%%)",
                (current.f1 or 0) * 100,
                ((best.f1 or 0) - tol) * 100,
                (best.f1 or 0) * 100
            )
    end

    -- 2. Check Recall regression
    if (current.recall or 0) < (best.recall or 0) - tol then
        return false,
            string.format(
                "REGRESSION in Recall: got %.2f%%, expected at least %.2f%% (best was %.2f%%)",
                (current.recall or 0) * 100,
                ((best.recall or 0) - tol) * 100,
                (best.recall or 0) * 100
            )
    end

    -- 3. Check Mean IoU regression
    if (current.mean_iou or 0) < (best.mean_iou or 0) - tol then
        return false,
            string.format(
                "REGRESSION in Mean IoU: got %.2f, expected at least %.2f (best was %.2f)",
                current.mean_iou or 0,
                (best.mean_iou or 0) - tol,
                best.mean_iou or 0
            )
    end

    -- 4. Check False Positives regression (should be as low as possible)
    if best.false_positives and current.false_positives then
        if current.false_positives > best.false_positives then
            return false,
                string.format(
                    "REGRESSION in False Positives: got %d, best was %d",
                    current.false_positives,
                    best.false_positives
                )
        end
    end

    return true, nil
end

--- Evaluate current metrics against baseline:
--- - If regressed: throws an error (or returns false, reason)
--- - If improved: updates `bestbenchmark.json` and prints notification
---
--- @param book_dir string Path to the manga directory
--- @param mode '"full_volume"'|'"preview"' Mode being tested
--- @param current table Current metrics
--- @param update_on_better boolean|nil Whether to write to bestbenchmark.json if better (default true)
--- @return boolean ok
--- @return string|nil message
function BenchmarkTracker.checkAndUpdate(book_dir, mode, current, update_on_better)
    local best_data = BenchmarkTracker.load(book_dir) or {}
    local best_target = best_data[mode]

    -- An improvement in one metric must never overwrite a regression in another.
    local ok, reason = BenchmarkTracker.verifyNoRegression(current, best_target)
    if not ok then
        return false, reason
    end

    if BenchmarkTracker.isBetter(current, best_target) then
        if update_on_better ~= false then
            best_data.book_title = best_data.book_title or book_dir:match("([^/]+)$")
            best_data.updated_at = os.date("%Y-%m-%d")
            best_data[mode] = {
                pages_evaluated = current.pages_evaluated,
                total_ground_truth = current.total_ground_truth,
                total_detected = current.total_detected,
                true_positives = current.true_positives,
                false_positives = current.false_positives
                    or ((current.total_detected and current.true_positives) and (current.total_detected - current.true_positives))
                    or 0,
                precision = math.floor((current.precision or 0) * 10000 + 0.5) / 10000,
                recall = math.floor((current.recall or 0) * 10000 + 0.5) / 10000,
                f1 = math.floor((current.f1 or 0) * 10000 + 0.5) / 10000,
                mean_iou = math.floor((current.mean_iou or 0) * 10000 + 0.5) / 10000,
                gap_tolerance = current.gap_tolerance or 35,
                iou_threshold = current.iou_threshold or 0.50,
            }
            for _, key in ipairs(ORDER_RATES) do
                if current[key] ~= nil then
                    best_data[mode][key] = math.floor(current[key] * 10000 + 0.5) / 10000
                end
            end
            for _, key in ipairs(ORDER_COUNTS) do
                best_data[mode][key] = current[key]
            end
            BenchmarkTracker.save(book_dir, best_data)
            print(
                string.format(
                    "\n  [NEW RECORD] %s (%s): F1 %.2f%% (Recall: %.2f%%, Prec: %.2f%%, IoU: %.2f). Updated bestbenchmark.json!\n",
                    best_data.book_title,
                    mode,
                    (current.f1 or 0) * 100,
                    (current.recall or 0) * 100,
                    (current.precision or 0) * 100,
                    current.mean_iou or 0
                )
            )
        end
        return true, nil
    end

    return true, nil
end

return BenchmarkTracker
