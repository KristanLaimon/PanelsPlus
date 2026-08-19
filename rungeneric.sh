#!/usr/bin/env bash
set -euo pipefail

echo "Launching KOReader (Generic Desktop/Android/Kindle)..."
exec flatpak run rocks.koreader.KOReader "$@"
