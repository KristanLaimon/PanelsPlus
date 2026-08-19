#!/usr/bin/env bash
set -euo pipefail

echo "Launching KOReader (Kobo Emulation Mode)..." #At least, the most I can emulate kobo devices. I dont have one...
exec flatpak run \
    --env=EMULATE_READER_W=632 \
    --env=EMULATE_READER_H=840 \
    --env=EMULATE_READER_DPI=300 \
    --env=EMULATE_BW_SCREEN=1 \
    rocks.koreader.KOReader "$@"
