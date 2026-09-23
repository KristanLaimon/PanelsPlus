--[[
Panels+
File: tools/benchmark_ocr_native.lua
Name: Native OCR dataset runner
Description: Runs annotated word tests with KOReader's installed OCR library.
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
-- Run from the KOReader installation directory, with an absolute script path:
-- PANELSPLUS_OCR_NATIVE=1 PANELSPLUS_OCR_TESSDATA=/path/to/tessdata \
--     luajit /path/to/plugin/tools/benchmark_ocr_native.lua
-- ImageMagick supplies crops; this does not initialize the reader UI.
assert(os.getenv("PANELSPLUS_OCR_NATIVE") == "1", "set PANELSPLUS_OCR_NATIVE=1")
assert(os.getenv("PANELSPLUS_OCR_TESSDATA"), "set PANELSPLUS_OCR_TESSDATA to KOReader's tessdata directory")
local root = assert(arg[0]:match("^(/.*)/tools/benchmark_ocr_native%.lua$"), "use an absolute script path")
require("setupkoenv")
require("ffi/koptcontext")
require("ffi/blitbuffer")
local lfs = require("libs/libkoreader-lfs")
assert(lfs.chdir(root))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
require("tests.spec.helper")
require("tests.dataset-mangas.dataset.Bloom_Into_You_Vol_8.bloom_ocr_spec")
local framework = require("tests.PanelsPlusTestFramework")
os.exit(framework.summary() and 0 or 1)
