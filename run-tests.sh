#!/usr/bin/bash
# ==============================================================================
# run-tests.sh - Test runner for PanelsPlus and manga dataset specifications
# ==============================================================================
# Usage:
#   ./run-tests.sh                  # Runs linters, Lua unit tests, and dataset specs
#   ./run-tests.sh --graceful       # Gracefully omits tests if compiler/tool/uv not synced (by default)
#   ./run-tests.sh --strict         # Run all tests but if compilers/tools/uv not found, throws error.
#   ./run-tests.sh --quick          # Runs Lua test suite directly (skips check.sh)
#   ./run-tests.sh --quicker        # Skips lint/style checks and dataset Lua tests
#   ./run-tests.sh --check-only     # Runs only code style and linter checks
#   ./run-tests.sh <spec-path>      # Runs a specific spec file
#   ./run-tests.sh --panels         # Runs panel tests only
#   ./run-tests.sh --ocr            # Runs OCR tests only
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
  -g, --graceful   Gracefully omit tests for unavailable tools/compilers (default)
  -s, --strict     Fail strictly if any tool/compiler or uv sync is missing
  -q, --quick      Skip lint/format checks and run Lua tests immediately
      --quicker    Also skip dataset and benchmark Lua tests
  -c, --check-only Run only StyLua formatter and Luacheck linter
  -p, --python     Run only the Python annotator unit tests
      --panels     Run panel specs and panel datasets only
      --ocr        Run WordFinder/OCR specs and annotated-word dataset only
  -j, --jobs N     Maximum parallel Lua workers (default: up to 4 CPUs; 1 for serial)

Examples:
  ./run-tests.sh
  ./run-tests.sh --strict
  ./run-tests.sh --quick
  ./run-tests.sh --quicker
  ./run-tests.sh tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8/bloom_into_you_spec.lua
EOF
}

CHECK_ONLY=false
QUICK=false
SKIP_DATASETS=false
PYTHON_ONLY=false
GRACEFUL=true
FOCUS=""
FORWARD_ARGS=()

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            print_help
            exit 0
            ;;
        -g|--graceful)
            GRACEFUL=true
            ;;
        -s|--strict)
            GRACEFUL=false
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
        --panels|--ocr)
            if [ -n "$FOCUS" ]; then
                echo "Choose only one of --panels and --ocr" >&2
                exit 2
            fi
            FOCUS="${arg#--}"
            ;;
        *)
            FORWARD_ARGS+=("$arg")
            ;;
    esac
done

# Tool availability checks
HAS_GO=false
if command -v go &>/dev/null; then
    HAS_GO=true
fi

HAS_PYTHON=false
PYTHON_BIN=""
if command -v python3 &>/dev/null; then
    HAS_PYTHON=true
    PYTHON_BIN="python3"
elif command -v python &>/dev/null; then
    HAS_PYTHON=true
    PYTHON_BIN="python"
fi

PYTHON_UV_SYNC=false
if command -v uv &>/dev/null && [ -f "uv.lock" ]; then
    if uv sync --check &>/dev/null; then
        PYTHON_UV_SYNC=true
    fi
fi

if [ -n "$FOCUS" ]; then
    if [ "$CHECK_ONLY" = true ] || [ "$PYTHON_ONLY" = true ] || [ "$SKIP_DATASETS" = true ]; then
        echo "--$FOCUS cannot be combined with --check-only, --python, or --quicker" >&2
        exit 2
    fi
    if [ "$FOCUS" = "ocr" ]; then
        if [ "$HAS_GO" = true ]; then
            echo "==> Running Go OCR worker tests..."
            GOCACHE=/tmp/panelsplus-go-build-cache go test ./tools/ocr_worker
        elif [ "$GRACEFUL" = true ]; then
            echo "==> Skipping Go OCR worker tests (Go compiler not found; omitted in graceful mode)"
        else
            echo "Error: Go compiler is not installed. Install Go or use --graceful to omit Go tests." >&2
            exit 1
        fi
    fi
    echo "==> Running $FOCUS Lua tests..."
    if [ "$HAS_PYTHON" = true ]; then
        "$PYTHON_BIN" tests/run_parallel.py "--$FOCUS" "${FORWARD_ARGS[@]}"
    else
        lua tests/run_tests.lua "${FORWARD_ARGS[@]}"
    fi
    exit $?
fi

if [ "$PYTHON_ONLY" = true ]; then
    if [ "$HAS_PYTHON" = false ]; then
        if [ "$GRACEFUL" = true ]; then
            echo "==> Skipping Python tests (Python interpreter not found; omitted in graceful mode)"
            exit 0
        else
            echo "Error: Python interpreter not found. Install python3 or use --graceful to omit." >&2
            exit 1
        fi
    fi
    if [ "$PYTHON_UV_SYNC" = false ]; then
        if [ "$GRACEFUL" = true ]; then
            echo "==> Skipping Python annotator tests (Python environment not synced with uv; omitted in graceful mode)"
            exit 0
        else
            echo "Error: Python environment is not synced with uv. Run 'uv sync' or use --graceful to omit." >&2
            exit 1
        fi
    fi
    echo "==> Running Python Unit Tests..."
    uv run python -m unittest discover -s tests -p "test_*.py"
    if [ -f "tools/manga_annotator/test_annotator.py" ]; then
        uv run python -m unittest tools/manga_annotator/test_annotator.py
    fi
    exit 0
fi

if [ "$CHECK_ONLY" = true ]; then
    echo "==> Running Lint & Code Style Checks..."
    ./check.sh
    exit 0
fi

if [ "$QUICK" = false ]; then
    echo "==> [1/4] Running Code Style and Linter Checks..."
    ./check.sh
fi

# Step 2: Python Unit and Annotator Tests
if [ "$HAS_PYTHON" = true ] && [ "$PYTHON_UV_SYNC" = true ]; then
    echo "==> [2/4] Running Python Unit and Annotator Tests..."
    uv run python -m unittest discover -s tests -p "test_*.py"
    if [ -f "tools/manga_annotator/test_annotator.py" ]; then
        uv run python -m unittest tools/manga_annotator/test_annotator.py
    fi
elif [ "$HAS_PYTHON" = true ]; then
    if [ "$GRACEFUL" = true ]; then
        echo "==> [2/4] Skipping Python annotator tests (Python environment not synced with uv; omitted in graceful mode)"
    else
        echo "Error: Python environment is not synced with uv. Run 'uv sync' or use --graceful to omit." >&2
        exit 1
    fi
elif [ "$GRACEFUL" = true ]; then
    echo "==> [2/4] Skipping Python tests (Python interpreter not found; omitted in graceful mode)"
else
    echo "Error: Python interpreter not found. Install python3 or use --graceful to omit." >&2
    exit 1
fi

# Step 3: Go OCR Worker Tests
if [ "$HAS_GO" = true ]; then
    echo "==> [3/4] Running Go OCR Worker Tests..."
    GOCACHE=/tmp/panelsplus-go-build-cache go test ./tools/ocr_worker
elif [ "$GRACEFUL" = true ]; then
    echo "==> [3/4] Skipping Go OCR Worker Tests (Go compiler not found; omitted in graceful mode)"
else
    echo "Error: Go compiler is not installed. Install Go or use --graceful to omit." >&2
    exit 1
fi

# Step 4: Lua Test Suite
if [ "$SKIP_DATASETS" = true ]; then
    echo "==> [4/4] Running Lua Test Suite (dataset and benchmark specs skipped)..."
    if [ "$HAS_PYTHON" = true ]; then
        "$PYTHON_BIN" tests/run_parallel.py --skip-datasets "${FORWARD_ARGS[@]}"
    else
        lua tests/run_tests.lua "${FORWARD_ARGS[@]}"
    fi
else
    echo "==> [4/4] Running Lua Test Suite & Manga Dataset Specs..."
    if [ "$HAS_PYTHON" = true ]; then
        "$PYTHON_BIN" tests/run_parallel.py "${FORWARD_ARGS[@]}"
    else
        lua tests/run_tests.lua "${FORWARD_ARGS[@]}"
    fi
fi

echo "==> All test suites passed successfully!"
