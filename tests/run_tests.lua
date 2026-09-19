#!/usr/bin/env lua
--[[
Panels+
File: tests/run_tests.lua
Name: Lua test runner
Description: Discovers and executes the Panels+ Lua specification suite.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Runs every `_spec.lua` file under `tests/spec/` with `PanelsPlusTestFramework`.
---
--- No external dependencies (no busted, no luarocks) -- just plain Lua 5.4.
--- Usage: `lua tests/run_tests.lua`, invoked from the plugin's repo root.

local script_dir = arg[0]:match("(.*/)") or "./"
local repo_root = script_dir .. "../"

package.path = repo_root .. "?.lua;" .. repo_root .. "?/init.lua;" .. package.path

require("tests.spec.helper")

local spec_modules = {
    "tests.spec.doc_settings_spec",
    "tests.spec.doublespread_spec",
    "tests.spec.panelviewer_gotoviewrel_spec",
    "tests.spec.panelviewer_kobo_bluetooth_spec",
    "tests.spec.native_panel_zoom_spec",
    "tests.spec.memory_spec",
    "tests.spec.embedded_image_spec",
    "tests.spec.nativedetector_spec",
    "tests.spec.panelviewer_reader_gesture_spec",
    "tests.spec.viewer_controller_rotation_spec",
    "tests.spec.viewer_controller_more_config_spec",
    "tests.spec.panelviewer_leftedge_spec",
    "tests.spec.panelviewer_keyboard_nav_spec",
    "tests.spec.panelviewer_tapnav_spec",
    "tests.spec.panelviewer_transform_spec",
    "tests.spec.panelviewer_margin_spec",
    "tests.spec.panelviewer_highlight_spec",
    "tests.spec.panelviewer_refineword_spec",
    "tests.spec.ocrdebug_spec",
    "tests.spec.ocrdebug_report_spec",
    "tests.spec.geometry_spec",
    "tests.spec.panelviewport_spec",
    "tests.spec.wordfinder_spec",
    "tests.spec.pagebitmap_spec",
    "tests.spec.segmenter_spec",
    "tests.spec.componentdetector_spec",
    "tests.spec.panelcollector_spec",
    "tests.spec.panelviewer_navtransition_spec",
    "tests.spec.dataset_benchmark_spec",
    "tests.spec.dataset_support_spec",
    "tests.spec.textbasedformats_dataset_spec",
    "tests.spec.new_dataset_benchmark_spec",
}

-- Dynamically discover and run per-manga specs in tests/dataset-mangas/dataset/<manganame>/*_spec.lua
local dataset_dir = repo_root .. "tests/dataset-mangas/dataset"
local dataset_pipe = io.popen(string.format('ls "%s"/*/*_spec.lua 2>/dev/null', dataset_dir), "r")
if dataset_pipe then
    for line in dataset_pipe:lines() do
        local path = line:match("^%s*(.-)%s*$")
        if path and #path > 0 then
            local rel = path
            if rel:sub(1, #repo_root) == repo_root then
                rel = rel:sub(#repo_root + 1)
            end
            local mod = rel:gsub("%.lua$", ""):gsub("[/\\]", ".")
            table.insert(spec_modules, mod)
        end
    end
    dataset_pipe:close()
end

-- Machine-readable discovery for the parallel runner; do not execute specs.
if arg[1] == "--list" then
    for _, mod in ipairs(spec_modules) do
        print(mod)
    end
    os.exit(0)
elseif arg[1] == "--list-datasets" then
    for _, dataset in ipairs(require("tests.dataset-mangas.production_datasets")) do
        print(dataset.title)
    end
    os.exit(0)
end

if #arg > 0 then
    spec_modules = {}
    for _, path in ipairs(arg) do
        assert(not path:match("^%-"), "Unknown option: " .. path)
        local mod = path:gsub("^%./", ""):gsub("%.lua$", ""):gsub("[/\\]", ".")
        spec_modules[#spec_modules + 1] = mod
    end
end

for _, mod in ipairs(spec_modules) do
    print("\n== " .. mod .. " ==")
    require(mod)
end

local framework = require("tests.PanelsPlusTestFramework")
local all_passed = framework.summary()
os.exit(all_passed and 0 or 1)
