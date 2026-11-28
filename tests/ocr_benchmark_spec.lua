local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Tracker = require("tests.dataset-mangas.benchmark_tracker")
local OCRBenchmark = require("tests.dataset-mangas.ocr_benchmark")

local function withRecords(callback)
    local dir = os.tmpname()
    os.remove(dir)
    local made = os.execute("mkdir '" .. dir:gsub("'", "'\\''") .. "'")
    assert.is_true(made == true or made == 0)
    Tracker.save(dir, { preview = { precision = 0.975 } })
    local ok, err = pcall(callback, dir)
    os.remove(dir .. "/bestbenchmark.json")
    os.remove(dir)
    if not ok then
        error(err)
    end
end

describe("OCR best benchmark regression guard", function()
    it("records the measured percentage even before the 90% target is met", function()
        withRecords(function(dir)
            assert.is_true(OCRBenchmark.checkAndUpdate(dir, "text_cli_bundled_eng", {
                correct = 221,
                evaluated = 266,
                total = 266,
            }))
            local data = Tracker.load(dir)
            assert.equals(221, data.ocr.text_cli_bundled_eng.correct)
            assert.equals(83.0827, data.ocr.text_cli_bundled_eng.accuracy_percent)
            assert.equals(0.975, data.preview.precision)
        end)
    end)

    it("rejects a one-word regression and preserves the higher record", function()
        withRecords(function(dir)
            OCRBenchmark.checkAndUpdate(dir, "text", { correct = 241, evaluated = 266, total = 266 })
            local ok, message = OCRBenchmark.checkAndUpdate(dir, "text", {
                correct = 240,
                evaluated = 266,
                total = 266,
            })
            assert.is_false(ok)
            assert.is_true(message:find("REGRESSION", 1, true) ~= nil)
            assert.equals(241, Tracker.load(dir).ocr.text.correct)
        end)
    end)

    it("accepts equal fractions and raises the record on improvement", function()
        withRecords(function(dir)
            OCRBenchmark.checkAndUpdate(dir, "text", { correct = 118, evaluated = 133, total = 133 })
            assert.is_true(OCRBenchmark.checkAndUpdate(dir, "text", {
                correct = 236,
                evaluated = 266,
                total = 266,
            }))
            assert.is_true(OCRBenchmark.checkAndUpdate(dir, "text", {
                correct = 237,
                evaluated = 266,
                total = 266,
            }))
            assert.equals(237, Tracker.load(dir).ocr.text.correct)
        end)
    end)

    it("does not replace a complete record with a perfect partial dataset", function()
        withRecords(function(dir)
            OCRBenchmark.checkAndUpdate(dir, "text", { correct = 221, evaluated = 266, total = 266 })
            assert.is_true(OCRBenchmark.checkAndUpdate(dir, "text", {
                correct = 6,
                evaluated = 6,
                total = 266,
            }))
            assert.equals(221, Tracker.load(dir).ocr.text.correct)
        end)
    end)
end)
