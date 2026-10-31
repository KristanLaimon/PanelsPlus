local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Cache = require("tests.helpers.ocr_cache")
local JSON = require("tests.helpers.json")

local function lines(items)
    local index = 0
    return function()
        index = index + 1
        local item = items[index]
        return type(item) == "table" and JSON.encode(item) or item
    end
end

local function response(id, text, err)
    return { id = id, text = text or "", error = err or "" }
end

describe("Go OCR streaming cache", function()
    it("checkpoints completed results and preserves empty recognition across reloads", function()
        local path = os.tmpname()
        local ok, err = pcall(function()
            local results, checkpoints = { previous = "kept" }, 0
            local received, reason = Cache.readStream(
                lines({ response("2"), response("1", "Hello"), response("3", "there") }),
                { ["1"] = "one", ["2"] = "empty", ["3"] = "three" },
                results,
                function(current)
                    checkpoints = checkpoints + 1
                    Cache.save(path, current)
                    local saved = Cache.load(path)
                    assert.equals("kept", saved.previous)
                    assert.is_false(saved.empty)
                end,
                2
            )
            assert.is_nil(reason)
            assert.equals(2, checkpoints)
            assert.equals("Hello", received.one)
            assert.equals("there", Cache.load(path).three)
        end)
        os.remove(path)
        assert.is_true(ok, tostring(err))
    end)

    it("preserves completed work if the stream is truncated", function()
        local checkpoints = 0
        local received, reason = Cache.readStream(
            lines({ response("1", "done") }),
            { ["1"] = "done", ["2"] = "pending" },
            {},
            function(saved)
                checkpoints = checkpoints + 1
                assert.equals("done", saved.done)
                assert.is_nil(saved.pending)
            end
        )
        assert.equals("done", received.done)
        assert.is_true(reason:find("incomplete", 1, true) ~= nil)
        assert.equals(1, checkpoints)
    end)

    it("drains failed jobs and rejects malformed, duplicate, and unknown responses", function()
        for _, bad in ipairs({
            "not json",
            response("unknown"),
            response("1", "duplicate"),
            response("2", "", "OCR failed"),
        }) do
            local results = {}
            local received, reason = Cache.readStream(
                lines({ response("1", "original"), bad, response("3", "later") }),
                { ["1"] = "first", ["2"] = "failed", ["3"] = "later" },
                results,
                function() end
            )
            assert.is_not_nil(reason)
            assert.equals("original", received.first)
            assert.equals("later", results.later)
            assert.is_nil(results.failed)
        end
    end)
end)
