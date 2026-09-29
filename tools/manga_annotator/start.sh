#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if command -v uv &>/dev/null && [ -f "uv.lock" ]; then
    exec uv run python tools/manga_annotator/app.py "$@"
else
    exec python3 tools/manga_annotator/app.py "$@"
fi
