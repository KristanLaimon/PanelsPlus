#!/usr/bin/env bash
set -euo pipefail

# this script expects you have installe koreader in your linux environment (koreader is not for windows yet (august/2026))
# throuh flatpak, google the installation steps if needed.
echo "Launching KOReader (Generic Desktop/Android/Kindle)..."
exec flatpak run rocks.koreader.KOReader "$@"
