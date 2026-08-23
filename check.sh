#!/usr/bin/env bash
set -e

if ! command -v stylua &> /dev/null; then
    echo "Error: 'stylua' is not installed or not in your PATH."
    echo "Please install StyLua to format the code (e.g., via 'cargo install stylua' or downloading from GitHub)."
    exit 1
fi

if ! command -v luacheck &> /dev/null; then
    echo "Error: 'luacheck' is not installed or not in your PATH."
    echo "Please install Luacheck to lint the code (e.g., via 'luarocks install luacheck')."
    exit 1
fi

echo "Formatting Lua files with StyLua..."
stylua .

echo "Linting Lua files with Luacheck..."
luacheck .

echo "All checks passed!"
