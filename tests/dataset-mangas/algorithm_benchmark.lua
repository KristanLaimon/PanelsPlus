-- Shared production evaluator for Safe and Smart. Every mapped page is evaluated.
local Loader = require("tests.dataset-mangas.dataset_loader")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local Tracker = require("tests.dataset-mangas.benchmark_tracker")
local Benchmark = {}
Benchmark.detectors = {
    safe = require("src._safecomponentdetector"),
    smart = require("src._smartcomponentdetector"),
}

function Benchmark.evaluate(book, algorithm)
    assert(Benchmark.detectors[algorithm], "Unknown panel algorithm")
    local metrics = { pages_evaluated = 0, total_ground_truth = 0, total_detected = 0, true_positives = 0 }
    local iou_sum, matched_pages = 0, 0
    for _, page in ipairs(Manifest.getMappedPages(book, algorithm)) do
        local map = Loader.loadPageMap(page.image_path, { mode = page.reading_order })
        local detected = Benchmark.detectors[algorithm].detectPage(map, { mode = page.reading_order })
        local result = Evaluator.evaluate(page.frames, detected, 0.50, 35)
        Evaluator.addReadingOrder(metrics, result)
        metrics.pages_evaluated = metrics.pages_evaluated + 1
        metrics.total_ground_truth = metrics.total_ground_truth + result.ground_truth_count
        metrics.total_detected = metrics.total_detected + result.detected_count
        metrics.true_positives = metrics.true_positives + result.true_positives
        if result.true_positives > 0 then
            iou_sum = iou_sum + result.mean_iou
            matched_pages = matched_pages + 1
        end
    end
    metrics.precision = metrics.total_detected > 0 and metrics.true_positives / metrics.total_detected or 0
    metrics.recall = metrics.total_ground_truth > 0 and metrics.true_positives / metrics.total_ground_truth or 0
    local denominator = metrics.total_ground_truth + metrics.total_detected
    metrics.f1 = denominator > 0 and 2 * metrics.true_positives / denominator or 0
    metrics.false_positives = metrics.total_detected - metrics.true_positives
    metrics.mean_iou = matched_pages > 0 and iou_sum / matched_pages or 0
    metrics.iou_threshold, metrics.gap_tolerance = 0.50, 35
    return metrics
end

function Benchmark.baseline(data, algorithm, metrics)
    local record = data and data[algorithm .. "_full_volume"]
    if not record and algorithm == "smart" then
        record = data and data.components_conservative_full_volume
    end
    if
        record
        and record.pages_evaluated == metrics.pages_evaluated
        and record.total_ground_truth == metrics.total_ground_truth
        and record.iou_threshold == metrics.iou_threshold
        and record.gap_tolerance == metrics.gap_tolerance
    then
        return record
    end
end

function Benchmark.verify(data, algorithm, metrics)
    local record = data and data[algorithm .. "_full_volume"]
    if
        record
        and (
            record.pages_evaluated ~= metrics.pages_evaluated
            or record.total_ground_truth ~= metrics.total_ground_truth
            or record.iou_threshold ~= metrics.iou_threshold
            or record.gap_tolerance ~= metrics.gap_tolerance
        )
    then
        return false,
            "Dataset coverage changed or evaluator settings changed; establish a reviewed complete-volume baseline before regression testing"
    end
    return Tracker.verifyNoRegression(metrics, Benchmark.baseline(data, algorithm, metrics))
end

return Benchmark
