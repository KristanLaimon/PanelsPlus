--[[
Panels+
File: tests/spec/pagerender_spec.lua
Name: PageRender specs
Description: Verifies that panel crops inherit KOReader render adjustments.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local PageRender = require("src._pagerender")

local function fixedDocument(render_call)
    return {
        GAMMA_NO_GAMMA = 1.0,
        transformRect = function(_, rect, zoom)
            return { x = rect.x * zoom, y = rect.y * zoom, w = rect.w * zoom, h = rect.h * zoom }
        end,
        renderPage = function(_, ...)
            render_call.args = { ... }
            return { bb = render_call.bb }
        end,
    }
end

describe("Panel page rendering adjustments", function()
    it("passes the reader's active contrast and saturation to renderPage", function()
        local call = { bb = {} }
        local ui = {
            document = fixedDocument(call),
            view = { state = { gamma = 2.0, saturation = 1.6 } },
        }

        local bb, rotate = PageRender.drawPagePart(ui, 7, { x = 10, y = 20, w = 300, h = 400 }, 0)

        assert.equals(call.bb, bb)
        assert.is_false(rotate)
        assert.equals(7, call.args[1])
        assert.equals(2.0, call.args[5])
        assert.equals(1.6, call.args[6])
        assert.is_true(call.args[7])
    end)

    it("falls back to the document's per-document adjustments", function()
        local call = { bb = {} }
        local document = fixedDocument(call)
        document.configurable = { contrast = 1.5, saturation = 1.8 }

        PageRender.drawPagePart({ document = document }, 3, { x = 0, y = 0, w = 200, h = 400 }, 0)

        assert.equals(1.5, call.args[5])
        assert.equals(1.8, call.args[6])
    end)

    it("keeps the document fallback for non-fixed-layout renderers", function()
        local received
        local fallback_bb = {}
        local document = {
            drawPagePart = function(_, page, rect, rotation)
                received = { page, rect, rotation }
                return fallback_bb, true
            end,
        }

        local bb, rotate = PageRender.drawPagePart({ document = document }, 4, { x = 1, y = 2, w = 3, h = 4 }, 90)

        assert.equals(fallback_bb, bb)
        assert.is_true(rotate)
        assert.equals(4, received[1])
        assert.equals(90, received[3])
    end)

    it("uses the supplied spread zoom without enabling auto-rotation", function()
        local call = { bb = {} }
        local ui = { document = fixedDocument(call) }
        local old_settings = G_reader_settings
        G_reader_settings = {
            isTrue = function()
                return true
            end,
        }

        local _, rotate = PageRender.drawPagePart(ui, 1, { x = 0, y = 0, w = 1000, h = 500 }, 0, 0.8)

        G_reader_settings = old_settings
        assert.is_false(rotate)
        assert.equals(0.8, call.args[3])
        assert.equals(800, call.args[2].scaled_rect.w)
    end)
end)
