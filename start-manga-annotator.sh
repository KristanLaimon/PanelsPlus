#!/usr/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
exec ./tools/manga_annotator/start.sh "$@"
