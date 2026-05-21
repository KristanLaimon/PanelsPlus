#!/usr/bin/env bash
set -eu

PLUGIN_NAME="${1:-mangacomicsmoother}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/dist"
PLUGIN_DIR="$OUT_DIR/${PLUGIN_NAME}.koplugin"

rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"

find "$SCRIPT_DIR" -maxdepth 1 -type f \( -name "*.lua" -o -name "_meta.lua" \) \
    -exec cp -p {} "$PLUGIN_DIR/" \;
cp -Rp "$SCRIPT_DIR/msr" "$PLUGIN_DIR/"

echo "Created: $PLUGIN_DIR"
echo "Copy this folder to your Kindle KOReader plugins folder:"
echo "  /mnt/us/koreader/plugins/${PLUGIN_NAME}.koplugin"

if command -v explorer.exe >/dev/null 2>&1; then
    explorer.exe "$(wslpath -w "$PLUGIN_DIR")" >/dev/null 2>&1 &
fi
