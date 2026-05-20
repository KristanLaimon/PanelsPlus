How to Debug
We have a helper function called logger.dbg to help with debugging. You can use that function to print string and tables:

local logger = require("logger")
a = {"1", "2", "3"}
logger.dbg("table a: ", a)
Anything printed by logger.dbg starts with DEBUG.

On most target platforms, log output is saved to crash.log in the koreader directory.

 04/06/17-21:44:53 DEBUG foo
In production code, remember that arguments are always evaluated in Lua, so, don't inline complex computations in logger functions' arguments. If you really have to, hide the whole thing behind a dbg.is_on branch, like in frontend/device/input.lua.