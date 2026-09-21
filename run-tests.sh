#!/usr/bin/env bash
# ==============================================================================
# run-tests.sh - Test runner for PanelsPlus and manga dataset specifications
# ==============================================================================
# Usage:
#   ./run-tests.sh                  # Runs linters, Lua unit tests, and dataset specs
#   ./run-tests.sh --quick          # Runs Lua test suite directly (skips check.sh)
#   ./run-tests.sh --quicker        # Skips lint/style checks and dataset Lua tests
#   ./run-tests.sh --check-only     # Runs only code style and linter checks
#   ./run-tests.sh <spec-path>      # Runs a specific spec file
# ==============================================================================

set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

print_help() {
    cat << 'EOF'
PanelsPlus Test Runner

Usage:
  ./run-tests.sh [OPTIONS] [SPEC_FILE...]

Options:
  -h, --help       Show this help message
  -q, --quick      Skip lint/format checks and run Lua tests immediately
      --quicker    Also skip dataset and benchmark Lua tests
  -c, --check-only Run only StyLua formatter and Luacheck linter
  -p, --python     Run only the Python annotator unit tests
  -j, --jobs N     Maximum parallel Lua workers (default: up to 4 CPUs; 1 for serial)

Examples:
  ./run-tests.sh
  ./run-tests.sh --quick
  ./run-tests.sh --quicker
  ./run-tests.sh tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8/bloom_into_you_spec.lua
EOF
}

CHECK_ONLY=false
QUICK=false
SKIP_DATASETS=false
PYTHON_ONLY=false
FORWARD_ARGS=()

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            print_help
            exit 0
            ;;
        -c|--check-only)
            CHECK_ONLY=true
            ;;
        -q|--quick)
            QUICK=true
            ;;
        --quicker)
            QUICK=true
            SKIP_DATASETS=true
            ;;
        -p|--python)
            PYTHON_ONLY=true
            ;;
        *)
            FORWARD_ARGS+=("$arg")
            ;;
    esac
done

if [ "$PYTHON_ONLY" = true ]; then
    echo "==> Running Python Unit Tests..."
    python3 -m unittest discover -s tests -p "test_*.py"
    if [ -f "tests/dataset-mangas/annotator/test_annotator.py" ]; then
        python3 -m unittest tests/dataset-mangas/annotator/test_annotator.py
    fi
    exit 0
fi

if [ "$CHECK_ONLY" = true ]; then
    echo "==> Running Lint & Code Style Checks..."
    ./check.sh
    exit 0
fi

if [ "$QUICK" = false ]; then
    echo "==> [1/3] Running Code Style and Linter Checks..."
    ./check.sh
fi

if command -v python3 &>/dev/null; then
    echo "==> [2/3] Running Python Unit and Annotator Tests..."
    python3 -m unittest discover -s tests -p "test_*.py"
    if [ -f "tests/dataset-mangas/annotator/test_annotator.py" ]; then
        python3 -m unittest tests/dataset-mangas/annotator/test_annotator.py
    fi
fi

if [ "$SKIP_DATASETS" = true ]; then
    echo "==> [3/3] Running Lua Test Suite (dataset and benchmark specs skipped)..."
    python3 tests/run_parallel.py --skip-datasets "${FORWARD_ARGS[@]}"
else
    echo "==> [3/3] Running Lua Test Suite & Manga Dataset Specs..."
    python3 tests/run_parallel.py "${FORWARD_ARGS[@]}"
fi

echo "==> All test suites passed successfully!"
