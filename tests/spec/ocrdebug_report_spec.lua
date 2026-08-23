--- Specs for `tools/ocrdebug_report.lua`: the JSON round-trip and the
--- geometry-only box_bug/engine_miss classifier, pinned against real
--- shapes pulled from an actual OCR debug session (see the chat history
--- for the manual, image-by-image classification this is checked against).

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local Report = require("tools.ocrdebug_report")

describe("ocrdebug_report JSON round-trip", function()
    it("decodes a log line shaped like OcrDebug.writeLog's own output", function()
        local line =
            [[{"document":"/books/x.cbz","page":141,"box":{"x":696,"y":122.5,"w":88,"h":17},"verdict":"correct","ocr_word":"OH","tap":{"x":712.6,"y":131.1}}]]
        local decoded, err = Report.jsonDecode(line)
        assert.is_true(decoded ~= nil, "expected a decoded table, got error: " .. tostring(err))
        assert.equals("141", tostring(decoded.page))
        assert.equals(696, decoded.box.x)
        assert.equals("correct", decoded.verdict)
        assert.equals(712.6, decoded.tap.x)
    end)

    it("round-trips escaped slashes the way KOReader's json.encode produces them", function()
        local decoded = Report.jsonDecode([[{"image":"OCR.debug.session.images\/foo.png"}]])
        assert.equals("OCR.debug.session.images/foo.png", decoded.image)
    end)
end)

describe("ocrdebug_report.classify", function()
    it("passes through a 'correct' verdict untouched", function()
        local e = Report.classify({ verdict = "correct", ocr_word = "OH" })
        assert.equals("correct", e.classification)
    end)

    it("classifies a captureFailure('no_box') record", function()
        local e = Report.classify({ verdict = "incorrect", ocr_failed = "no_box" })
        assert.equals("total_miss_no_box", e.classification)
    end)

    it("classifies a captureFailure('no_word') record", function()
        local e = Report.classify({ verdict = "incorrect", ocr_failed = "no_word" })
        assert.equals("total_miss_no_word", e.classification)
    end)

    it("classifies incorrect with no drawn user_box as unclassified", function()
        local e = Report.classify({ verdict = "incorrect", ocr_word = "x", box = { x = 0, y = 0, w = 10, h = 10 } })
        assert.equals("unclassified", e.classification)
    end)

    it("classifies a same-size, well-aligned box as engine_miss (real 'INNOCENT'/'mmis' case)", function()
        local e = Report.classify({
            verdict = "incorrect",
            ocr_word = "mmis",
            correct_text = "INNOCENT",
            box = { x = 693.5, y = 196.5, w = 98, h = 16.5 },
            user_box = { x = 691.645, y = 194.03, w = 99.65, h = 18.73 },
        })
        assert.equals("engine_miss", e.classification)
    end)

    it("classifies an oversized merged box as box_bug via size_ratio (real 'OH GOD...' case)", function()
        local e = Report.classify({
            verdict = "incorrect",
            ocr_word = "OH",
            correct_text = "GOD...",
            box = { x = 696, y = 122.5, w = 88, h = 17 },
            user_box = { x = 728.36, y = 120.6, w = 56.94, h = 17.98 },
        })
        assert.equals("box_bug", e.classification)
    end)

    it("classifies a wrong-region box as box_bug via low containment", function()
        local e = Report.classify({
            verdict = "incorrect",
            ocr_word = "x",
            box = { x = 0, y = 0, w = 20, h = 20 },
            user_box = { x = 500, y = 500, w = 20, h = 20 },
        })
        assert.equals("box_bug", e.classification)
        assert.equals(0, e.overlap_ratio)
    end)

    it("classifies a same-area but shifted-edge box as box_bug (real 'ES'/'PRIMOR-' case)", function()
        -- This is the case size_ratio alone gets wrong: the merged "ES
        -- PRIMOR-" box is almost exactly the same *area* as the correct
        -- "PRIMOR-"-only box (918.75 vs 911.7), so only the edge-offset
        -- check catches that it starts ~22px too far left.
        local e = Report.classify({
            verdict = "incorrect",
            ocr_word = "ES",
            correct_text = "PRIMOR-",
            box = { x = 177, y = 122, w = 73.5, h = 12.5 },
            user_box = { x = 198.475, y = 119.176, w = 53.55, h = 17.025 },
        })
        assert.equals("box_bug", e.classification)
        assert.is_true(e.size_ratio < 1.3, "size_ratio alone should NOT have flagged this one")
    end)
end)
