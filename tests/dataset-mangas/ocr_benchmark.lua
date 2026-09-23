-- OCR regression records use exact counts rather than rounded percentages.
local BenchmarkTracker = require("tests.dataset-mangas.benchmark_tracker")

local OCRBenchmark = {}

function OCRBenchmark.checkAndUpdate(book_dir, metric, current)
    if current.evaluated ~= current.total then
        return true, "partial dataset: full-dataset OCR record was not compared or updated"
    end
    if current.evaluated <= 0 or current.correct < 0 or current.correct > current.evaluated then
        return false, "invalid OCR benchmark counts"
    end
    local data = BenchmarkTracker.load(book_dir) or {}
    data.ocr = data.ocr or {}
    local best = data.ocr[metric]
    if best and current.correct * best.evaluated < best.correct * current.evaluated then
        return false,
            string.format(
                "OCR REGRESSION (%s): %d/%d (%.4f%%), best %d/%d (%.4f%%)",
                metric,
                current.correct,
                current.evaluated,
                current.correct / current.evaluated * 100,
                best.correct,
                best.evaluated,
                best.correct / best.evaluated * 100
            )
    end
    if not best or current.correct * best.evaluated > best.correct * current.evaluated then
        local record = {}
        for key, value in pairs(current) do
            record[key] = value
        end
        record.accuracy_percent = current.correct / current.evaluated * 100
        record.updated_at = os.date("%Y-%m-%d")
        data.ocr[metric] = record
        BenchmarkTracker.save(book_dir, data)
        return true, string.format("saved OCR best (%s): %.4f%%", metric, record.accuracy_percent)
    end
    return true
end

return OCRBenchmark
