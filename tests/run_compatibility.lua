-- Execute one pinned compatibility suite without translating paths into module names.
package.path = "./?.lua;./?/init.lua;" .. package.path
require("tests.helper")
assert(#arg > 0, "No compatibility specifications selected")
for _, path in ipairs(arg) do
    print("\n== " .. path .. " ==")
    assert(loadfile(path))()
end
os.exit(require("tests.PanelsPlusTestFramework").summary() and 0 or 1)
