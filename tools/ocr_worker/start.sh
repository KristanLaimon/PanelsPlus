#!/usr/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
exec go run . "$@"
