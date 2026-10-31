--[[
Panels+
File: tests/dataset_support_spec.lua
Name: Dataset support specs
Description: Verifies dataset metadata resolution, cache isolation, and regression thresholds.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Tracker = require("tests.dataset-mangas.benchmark_tracker")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")

describe("Dataset regression safeguards", function()
    it("measures ordering independently of detection quality against annotated sequence", function()
        local a = { x = 200, y = 0, w = 50, h = 50 }
        local b = { x = 100, y = 0, w = 50, h = 50 }
        local c = { x = 0, y = 100, w = 50, h = 50 }
        local ghost = { x = 400, y = 400, w = 50, h = 50 }
        for _, gt in ipairs({ { a, b, c }, { b, a, c } }) do
            local exact = Evaluator.evaluate(gt, gt)
            assert.is_true(exact.reading_order_correct)
            assert.equals(3, exact.reading_order_pairs_correct)
            local swapped = Evaluator.evaluate(gt, { gt[2], gt[1], gt[3] })
            assert.equals(1, swapped.f1)
            assert.is_false(swapped.reading_order_correct)
            assert.equals(2, swapped.reading_order_pairs_correct)
            local reverse = Evaluator.evaluate(gt, { gt[3], gt[2], gt[1] })
            assert.equals(0, reverse.reading_order_pairs_correct)
            local partial = Evaluator.evaluate(gt, { gt[3], ghost, gt[1] })
            assert.is_false(partial.reading_order_correct)
            assert.equals(1, partial.reading_order_pairs)
            assert.equals(0, partial.reading_order_pairs_correct)
            assert.equals("reading_order_mismatch", partial.failures[#partial.failures])
            local metrics = {}
            Evaluator.addReadingOrder(metrics, exact)
            Evaluator.addReadingOrder(metrics, partial)
            assert.equals(0.5, metrics.reading_order_accuracy)
            assert.equals(0.75, metrics.reading_order_pair_accuracy)
            local single = {}
            Evaluator.addReadingOrder(single, Evaluator.evaluate(gt, { gt[1] }))
            assert.equals(0, single.reading_order_accuracy)
            assert.equals(0, single.reading_order_pairs)
            assert.is_nil(single.reading_order_pair_accuracy)
        end
    end)

    it("persists order metrics on legacy records and rejects regressions before updating", function()
        local root = os.tmpname()
        os.remove(root)
        os.execute("mkdir -p " .. root)
        local ok, err = pcall(function()
            local metrics = { precision = 1, recall = 1, f1 = 1, mean_iou = 1 }
            Tracker.save(root, { preview = metrics })
            metrics.reading_order_pages = 2
            metrics.reading_order_pages_correct = 1
            metrics.reading_order_accuracy = 0.5
            metrics.reading_order_pairs = 3
            metrics.reading_order_pairs_correct = 2
            metrics.reading_order_pair_accuracy = 2 / 3
            assert.is_true(Tracker.checkAndUpdate(root, "preview", metrics, false))
            assert.is_nil(Tracker.load(root).preview.reading_order_accuracy)
            assert.is_true(Tracker.checkAndUpdate(root, "preview", metrics, true))
            local saved = Tracker.load(root).smart_segmenter_preview
            assert.equals(0.5, saved.reading_order_accuracy)
            assert.equals(0.6667, saved.reading_order_pair_accuracy)
            assert.equals(2, saved.reading_order_pairs_correct)
            metrics.reading_order_accuracy = 1 -- Improvement must not hide worse pair order.
            metrics.reading_order_pair_accuracy = 0.5
            assert.is_false(Tracker.checkAndUpdate(root, "preview", metrics, true))
            assert.equals(0.5, Tracker.load(root).smart_segmenter_preview.reading_order_accuracy)
            metrics.reading_order_pair_accuracy = nil
            assert.is_false(Tracker.verifyNoRegression(metrics, saved))
        end)
        os.remove(root .. "/bestbenchmark.json")
        os.remove(root)
        assert.is_true(ok, tostring(err))
    end)

    it("resolves per-book comic metadata in a shared root annotation file", function()
        local root = os.tmpname()
        os.remove(root)
        os.execute("mkdir -p " .. root .. "/A " .. root .. "/B")
        local function write(relative, content)
            local f = io.open(root .. relative, "w")
            assert.is_not_nil(f)
            f:write(content)
            f:close()
        end
        local ok, err = pcall(function()
            write("/annotation.json", '[{"book_title":"A","pages":[]},{"book_title":"B","pages":[]}]')
            write("/A/metadata.json", '{"type":"manga"}')
            write("/B/metadata.json", '{"type":"comic","color_mode":"colorless_b/w"}')
            local books = Manifest.loadManga(root)
            assert.equals("manga", books[1].type)
            assert.is_nil(books[1].color_mode)
            assert.equals("comic", books[2].type)
            assert.equals("colorless_b/w", books[2].color_mode)
            for _, invalid in ipairs({
                '{"type":"comic","color_mode":"grayscale"}',
                '{"type":"manga","color_mode":"true_b/w"}',
            }) do
                write("/B/metadata.json", invalid)
                Manifest._manga_cache[root] = nil
                local loaded = pcall(Manifest.loadManga, root)
                assert.is_false(loaded)
            end
        end)
        os.remove(root .. "/annotation.json")
        os.remove(root .. "/A/metadata.json")
        os.remove(root .. "/B/metadata.json")
        os.remove(root .. "/A")
        os.remove(root .. "/B")
        os.remove(root)
        assert.is_true(ok, tostring(err))
    end)

    it("discovers every mapped volume and excludes unmapped pages", function()
        local registry = require("tests.dataset-mangas.production_datasets")
        local registered = {}
        for _, entry in ipairs(registry) do
            registered[entry.title] = entry
        end
        for _, book in ipairs(Manifest.loadManga()) do
            local mapped = Manifest.getMappedPages(book)
            if book.type == "manhwa" then
                assert.is_nil(registered[book.book_title], "Manhwa uses a separate Safe benchmark")
            elseif #mapped > 0 then
                assert.is_not_nil(registered[book.book_title], "Unscheduled dataset: " .. book.book_title)
                assert.equals(#mapped, registered[book.book_title].pages)
            end
        end
        local unfinished = {
            pages = {
                { page_index = 1, frames = {} },
                { page_index = 3, frames = { { x = 0, y = 0, w = 100, h = 100 } } },
                { page_index = 5, frames = {} },
            },
        }
        local mapped = Manifest.getMappedPages(unfinished)
        assert.equals(1, #mapped)
        assert.equals(3, mapped[1].page_index)
    end)

    it("keeps manhwa out of legacy detector tuning and resource workloads", function()
        for _, book in ipairs(Manifest.loadMangaComic()) do
            assert.is_true(book.type ~= "manhwa")
        end
        for _, page in ipairs(Manifest.getMangaComicPages()) do
            assert.is_true(page.type ~= "manhwa")
        end
        local ok = pcall(
            require("tests.dataset-mangas.algorithm_benchmark").evaluate,
            { type = "manhwa", pages = {} },
            "smart"
        )
        assert.is_false(ok)
    end)

    it("rejects drops in every recorded metric, including precision and IoU", function()
        local baseline = { precision = 0.96, recall = 0.96, f1 = 0.96, mean_iou = 0.96 }
        for metric in pairs(baseline) do
            local current = { precision = 0.96, recall = 0.96, f1 = 0.96, mean_iou = 0.96 }
            current[metric] = 0.9599
            assert.is_false(Tracker.verifyNoRegression(current, baseline))
            current[metric] = 0.95996 -- Four-decimal JSON rounding only.
            assert.is_true(Tracker.verifyNoRegression(current, baseline))
        end
    end)

    it("bounds the page-map cache and separates settings for the same page", function()
        local page = Manifest.getPage("Scott_Pilgrim_Vol_5", 1)
        local manga = Loader.loadPageMap(page.image_path, { mode = "manga" })
        assert.equals(manga, Loader.loadPageMap(page.image_path, { mode = "manga" }))
        local comic = Loader.loadPageMap(page.image_path, { mode = "comic" })
        assert.is_true(comic ~= manga)
        local embedded = Loader.loadPageMap(page.image_path, { mode = "comic", embedded_image = true })
        assert.is_true(embedded ~= comic)
        assert.is_true(embedded.embedded_image)
        assert.is_false(comic.embedded_image)
        local count = 0
        for _ in pairs(Loader._cache) do
            count = count + 1
        end
        assert.equals(1, count)
    end)
    it("uses independent panel files and never falls back to Smart for pending Safe pages", function()
        local root = os.tmpname()
        os.remove(root)
        os.execute("mkdir -p " .. root .. "/book")
        local function write(name, content)
            local file = io.open(root .. "/book/" .. name, "w")
            assert.is_not_nil(file)
            file:write(content)
            file:close()
        end
        local ok, err = pcall(function()
            write(
                "annotation.json",
                '[{"book_title":"book","pages":[{"page_index":1,"frame":[{"x":99,"y":0,"w":100,"h":100}],"wordless":true,"word":[{"x":1,"y":1,"w":2,"h":2,"text":"shared"}]},{"page_index":2,"frame":[]}]}]'
            )
            local book = Manifest.loadManga(root)[1]
            assert.equals(99, Manifest.getMappedPages(book, "smart")[1].frames[1].x)
            assert.equals(0, #Manifest.getMappedPages(book, "safe"))
            write(
                "panels_smart.json",
                '{"algorithm":"smart","pages":[{"page_index":1,"frame":[{"x":10,"y":0,"w":100,"h":100}],"illustration_type":"double_page"}]}'
            )
            write(
                "panels_safe.json",
                '{"algorithm":"safe","pages":[{"page_index":1,"frame":[{"x":20,"y":0,"w":50,"h":100},{"x":70,"y":0,"w":50,"h":100}]},{"page_index":2,"frame":[]}]}'
            )
            Manifest._manga_cache[root] = nil
            book = Manifest.loadManga(root)[1]
            local smart, safe = Manifest.getMappedPages(book, "smart"), Manifest.getMappedPages(book, "safe")
            assert.equals(10, smart[1].frames[1].x)
            assert.equals(20, safe[1].frames[1].x)
            assert.equals(1, #safe)
            assert.is_true(smart[1].double_illustration)
            assert.is_false(safe[1].double_illustration)
            assert.is_nil(safe[1].illustration_type)
            assert.equals("shared", safe[1].words[1].text)
            write("panels_smart.json", '{"algorithm":"smart","pages":[]}')
            Manifest._manga_cache[root] = nil
            book = Manifest.loadManga(root)[1]
            assert.equals(0, #Manifest.getMappedPages(book, "smart"))
            assert.equals(1, #Manifest.getMappedPages(book, "safe"))
            -- A shared root file still resolves dedicated maps without metadata.json.
            local shared = io.open(root .. "/annotation.json", "w")
            assert.is_not_nil(shared)
            shared:write('[{"book_title":"book","pages":[{"page_index":1,"frame":[]}]}]')
            shared:close()
            os.remove(root .. "/book/annotation.json")
            Manifest._manga_cache[root] = nil
            book = Manifest.loadManga(root)[1]
            assert.equals(1, #Manifest.getMappedPages(book, "safe"))
            assert.equals(root .. "/book", book.directory)
            -- Draft annotations remain editable but do not count as reviewed
            -- ground truth, even when they contain valid panel rectangles.
            write(
                "panels_safe.json",
                '{"algorithm":"safe","status":"draft","pages":[{"page_index":1,"frame":[{"x":20,"y":0,"w":50,"h":100}]}]}'
            )
            Manifest._manga_cache[root] = nil
            book = Manifest.loadManga(root)[1]
            assert.equals(0, #Manifest.getMappedPages(book, "safe"))
            assert.equals(0, #Manifest.getMappedPages(book, "smart"))
        end)
        for _, name in ipairs({ "annotation.json", "panels_smart.json", "panels_safe.json" }) do
            os.remove(root .. "/book/" .. name)
        end
        os.remove(root .. "/book")
        os.remove(root .. "/annotation.json")
        os.remove(root)
        Manifest._manga_cache[root] = nil
        assert.is_true(ok, tostring(err))
    end)

    it("records Safe improvements without overwriting Smart or shared OCR benchmarks", function()
        local root = os.tmpname()
        os.remove(root)
        os.execute("mkdir -p " .. root)
        local ok, err = pcall(function()
            local smart = { precision = 1, recall = 1, f1 = 1, mean_iou = 1 }
            Tracker.save(root, { smart_preview = smart, ocr = { text = { correct = 9 } } })
            local safe = { precision = 0.5, recall = 0.5, f1 = 0.5, mean_iou = 0.5 }
            assert.is_true(Tracker.checkAndUpdate(root, "preview", safe, true, "safe"))
            local data = Tracker.load(root)
            assert.equals(1, data.smart_preview.f1)
            assert.equals(0.5, data.safe_preview.f1)
            assert.equals(9, data.ocr.text.correct)
            safe.f1 = 0.4
            assert.is_false(Tracker.checkAndUpdate(root, "preview", safe, true, "safe"))
            assert.equals(0.5, Tracker.load(root).safe_preview.f1)
        end)
        os.remove(root .. "/bestbenchmark.json")
        os.remove(root)
        assert.is_true(ok, tostring(err))
    end)
end)
