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
--- Runs every `_spec.lua` file under `tests/` with `PanelsPlusTestFramework`.
---
--- No external dependencies (no busted, no luarocks) -- just plain Lua 5.4.
--- Usage: `lua tests/run_tests.lua`, invoked from the plugin's repo root.

local script_dir = arg[0]:match("(.*/)") or "./"
local repo_root = script_dir .. "../"

package.path = repo_root .. "?.lua;" .. repo_root .. "?/init.lua;" .. package.path

require("tests.helper")

-- Discover in filename order so new specifications cannot be silently omitted.
local spec_modules = {}
local pipe = assert(io.popen('find "' .. script_dir .. '" -maxdepth 1 -type f -name "*_spec.lua"', "r"))
for path in pipe:lines() do
    local name = assert(path:match("([^/]+)%.lua$"))
    spec_modules[#spec_modules + 1] = "tests." .. name
end
assert(pipe:close(), "Failed to discover test specifications")
assert(#spec_modules > 0, "No test specifications found")
table.sort(spec_modules)

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
