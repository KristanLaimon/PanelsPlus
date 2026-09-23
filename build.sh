#!/usr/bin/env bash
set -eu

PLUGIN_NAME="${1:-panelsplus}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/dist"
BUNDLED_DIR="$OUT_DIR/${PLUGIN_NAME}_with_ocrmodels.koplugin"
MANUAL_DIR="$OUT_DIR/${PLUGIN_NAME}.koplugin"
OCR_DIR="$SCRIPT_DIR/data/ocr"

# A package missing a model would silently fall back to KOReader's data.
# Keep builds reproducible by checking all three pinned files first.
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OCR_DIR" && sha256sum -c SHA256SUMS)
elif command -v shasum >/dev/null 2>&1; then
    (cd "$OCR_DIR" && shasum -a 256 -c SHA256SUMS)
else
    echo "A SHA-256 checker (sha256sum or shasum) is required to package OCR data" >&2
    exit 1
fi

copy_plugin() {
    local destination="$1"
    mkdir -p "$destination"
    find "$SCRIPT_DIR" -maxdepth 1 -type f \( -name "*.lua" -o -name "_meta.lua" \) \
        -exec cp -p {} "$destination/" \;
    cp -Rp "$SCRIPT_DIR/src" "$destination/"
    cp -Rp "$SCRIPT_DIR/locales" "$destination/"
    cp -Rp "$SCRIPT_DIR/data" "$destination/"
}

rm -rf "$BUNDLED_DIR" "$MANUAL_DIR" "$OUT_DIR/${PLUGIN_NAME}-manual-ocr.koplugin"
copy_plugin "$BUNDLED_DIR"
copy_plugin "$MANUAL_DIR"
rm -rf "$MANUAL_DIR/data/ocr"

echo "Bundled OCR: $BUNDLED_DIR"
echo "Manual OCR:  $MANUAL_DIR"
echo "Install only one of these folders in KOReader's plugins directory."
