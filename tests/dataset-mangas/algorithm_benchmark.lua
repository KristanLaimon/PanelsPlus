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
        local map =
            Loader.loadPageMap(page.image_path, { mode = page.reading_order, embedded_image = page.embedded_image })
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

-- Both algorithms share production targets, evaluated against their own annotations.
function Benchmark.verifyProductionTargets(expected, metrics)
    if expected.experimental and not expected.gate_95 then
        return true
    end
    if (metrics.f1 or 0) <= expected.minimum_f1 then
        return false, string.format("Mapped-page F1 must exceed %.0f%%", expected.minimum_f1 * 100)
    end
    if not expected.gate_95 then
        return true
    end
    for _, key in ipairs({ "precision", "recall", "f1", "mean_iou" }) do
        if (metrics[key] or 0) <= 0.95 then
            return false, key .. " must remain above 95%"
        end
    end
    -- Pair accuracy isolates sequencing. With no comparable pairs (e.g. all
    -- single-panel pages), use the measured exact-page ordering score instead.
    local ordering = metrics.reading_order_pair_accuracy
    if (metrics.reading_order_pairs or 0) == 0 then
        ordering = metrics.reading_order_accuracy
    end
    if ordering == nil or ordering <= 0.95 then
        return false, "Correct panel reading order must remain above 95%"
    end
    return true
end

-- Explicitly establish records for reviewed annotation changes. Old records
-- remain available, and unchanged coverage still enforces every regression gate.
function Benchmark.establishBaseline(book, algorithm, metrics)
    local pages, panels = Manifest.getMappedPages(book, algorithm), 0
    for _, page in ipairs(pages) do
        panels = panels + #page.frames
    end
    if #pages == 0 or #pages ~= metrics.pages_evaluated or panels ~= metrics.total_ground_truth then
        return false, "Baseline establishment requires every mapped page and panel"
    end
    if metrics.iou_threshold ~= 0.5 or metrics.gap_tolerance ~= 35 then
        return false, "Baseline establishment requires the standard evaluator settings"
    end
    local ok, reason = Benchmark.verifyProductionTargets({ minimum_f1 = 0.95, gate_95 = true }, metrics)
    if not ok then
        return false, reason
    end
    local data = Tracker.load(book.directory) or {}
    local key = algorithm .. "_full_volume"
    local previous = data[key]
    if previous and Benchmark.baseline(data, algorithm, metrics) then
        return Tracker.checkAndUpdate(book.directory, "full_volume", metrics, true, algorithm)
    end
    if previous then
        data.annotation_baseline_history = data.annotation_baseline_history or {}
        data.annotation_baseline_history[#data.annotation_baseline_history + 1] = {
            key = key,
            metrics = previous,
            archived_at = os.date("%Y-%m-%d"),
            reason = "Reviewed panel annotation coverage changed",
        }
    end
    local record = {}
    for _, field in ipairs({
        "pages_evaluated",
        "total_ground_truth",
        "total_detected",
        "true_positives",
        "false_positives",
        "precision",
        "recall",
        "f1",
        "mean_iou",
        "iou_threshold",
        "gap_tolerance",
        "reading_order_accuracy",
        "reading_order_pages",
        "reading_order_pages_correct",
        "reading_order_pair_accuracy",
        "reading_order_pairs",
        "reading_order_pairs_correct",
    }) do
        record[field] = metrics[field]
    end
    data[key] = record
    data.book_title, data.updated_at = book.book_title, os.date("%Y-%m-%d")
    if algorithm == "safe" then
        data.safe_mapping_status = "mapped"
    end
    Tracker.save(book.directory, data)
    return true
end

return Benchmark
