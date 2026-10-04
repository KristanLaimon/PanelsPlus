#!/usr/bin/env bash
# ==============================================================================
# run-benchmark.sh - Manga/comic panel detection benchmark tool
# ==============================================================================
# Usage:
#   ./run-benchmark.sh                    # Benchmark Bloom_Into_You_Vol_8
#   ./run-benchmark.sh --all              # Benchmark all discovered datasets
#   ./run-benchmark.sh --update-best      # Benchmark and update bestbenchmark.json if better
#   ./run-benchmark.sh --book <title>     # Benchmark a specific book
#   ./run-benchmark.sh --failures-only    # Show only pages with missed panels
# ==============================================================================

set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

print_help() {
    cat << 'EOF'
PanelsPlus Manga/Comic Detection Benchmark

Usage:
  ./run-benchmark.sh [OPTIONS]

Options:
  -h, --help           Show this help message
  -b, --book <title>   Benchmark a specific book (default: Bloom_Into_You_Vol_8)
  -p, --page <number>  Benchmark a specific 1-indexed page
  -a, --all            Benchmark all books discovered in tests/dataset-mangas/dataset/
  -u, --update-best    Update bestbenchmark.json if the current run beats the historical record
  -f, --failures-only  Display only pages with detection or reading-order issues
  --summary-only       Display aggregate metrics only
  -t, --threshold <n>  IoU threshold for true positive match (default: 0.50)
  --detector <name>    segmenter (default) or experimental components

Examples:
  ./run-benchmark.sh
  ./run-benchmark.sh --update-best
  ./run-benchmark.sh --book Bloom_Into_You_Vol_8 --page 12
  ./run-benchmark.sh --failures-only
EOF
}

# If no arguments provided, default to Bloom_Into_You_Vol_8
ARGS=()
HAS_TARGET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -a|--all)
            HAS_TARGET=true
            ARGS+=("--all")
            shift
            ;;
        -b|--book)
            HAS_TARGET=true
            ARGS+=("--book" "$2")
            shift 2
            ;;
        -p|--page)
            ARGS+=("--page" "$2")
            shift 2
            ;;
        -u|--update-best|--update)
            ARGS+=("--update-best")
            shift
            ;;
        -f|--failures-only)
            ARGS+=("--failures-only")
            shift
            ;;
        -t|--threshold)
            ARGS+=("--threshold" "$2")
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

if [ "$HAS_TARGET" = false ]; then
    ARGS+=("--book" "Bloom_Into_You_Vol_8")
fi

echo "==> Running Manga/Comic Panel Detection Benchmark..."
exec lua tools/benchmarking/benchmark_panels.lua "${ARGS[@]}"
