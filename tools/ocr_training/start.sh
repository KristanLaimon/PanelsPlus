#!/usr/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [ $# -eq 0 ]; then
    echo "Panels+ OCR Training Tool"
    echo ""
    echo "Usage:"
    echo "  ./start.sh annotated BOOK_DIR BASE_ENG_TRAINEDDATA NEW_OUTPUT_DIR"
    echo "  ./start.sh synthetic NEW_OUTPUT_DIR"
    echo ""
    echo "Defaulting to ./train-annotated.sh without arguments (shows usage):"
    exec ./train-annotated.sh
fi

case "$1" in
    annotated)
        shift
        exec ./train-annotated.sh "$@"
        ;;
    synthetic)
        shift
        exec ./train.sh "$@"
        ;;
    *)
        exec ./train-annotated.sh "$@"
        ;;
esac
