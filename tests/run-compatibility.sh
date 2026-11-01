#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../tools/plugin-compatibility/common.sh"
[[ $# -ge 1 && $# -le 3 ]] || plugin_error 'Usage: run-compatibility.sh PLUGIN [VERSION|rollingrelease] [REFERENCE]'
plugin="$(plugin_id "$1")"
version="${2:-}"
override="${3:-}"
[[ -z "$override" || -n "$version" ]] || plugin_error 'Reference override requires an exact suite selector'
if [[ -n "$override" ]]; then override="$(realpath -e -- "$override")"; fi
test_root="$PLUGIN_PROJECT_ROOT/tests/plugin-compatibility"
suites=()
if [[ -n "$version" ]]; then
    if [[ "$version" == rollingrelease ]]; then
        suites+=("$test_root/${plugin}__rollingrelease")
    else
        version="$(plugin_version "$version")"
        suites+=("$test_root/${plugin}__v${version//./_}")
    fi
else
    # Version-sort stable pins, then append the single rolling suite.
    if [[ -d "$test_root" ]]; then
        while IFS= read -r suite; do suites+=("$suite"); done < <(find "$test_root" -mindepth 1 -maxdepth 1 -type d -name "${plugin}__v*" | LC_ALL=C sort -V)
    fi
    [[ ! -d "$test_root/${plugin}__rollingrelease" ]] || suites+=("$test_root/${plugin}__rollingrelease")
fi
[[ ${#suites[@]} -gt 0 ]] || plugin_error "No compatibility suites for $plugin; add feature-specific specs first"
# Preflight the entire selection before running any suite.
for suite in "${suites[@]}"; do
    [[ -d "$suite" && ! -L "$suite" ]] || plugin_error "Missing/linked compatibility suite: $suite"
    [[ -n "$(find "$suite" -type f -name '*_spec.lua' -print -quit)" ]] || plugin_error "Empty compatibility suite: $suite"
done
cd -- "$PLUGIN_PROJECT_ROOT"
for suite in "${suites[@]}"; do
    suffix="${suite##*/}"
    if [[ "$suffix" == "${plugin}__rollingrelease" ]]; then
        selected_version=rollingrelease
        reference="${override:-$(plugin_rolling_source "$plugin")}"
        commit="$(git -C "$reference" rev-parse HEAD)"
    else
        selected_version="$(plugin_version "${suffix#"${plugin}__v"}")"
        reference="${override:-$PLUGIN_PROJECT_ROOT/references-repos/plugins/$plugin/stable/v${selected_version//./_}}"
        commit=''
        [[ -d "$reference" ]] || plugin_error "Missing stable pin: $reference"
        [[ "$(plugin_meta_version "$reference")" == "$selected_version" ]] || plugin_error 'Stable folder/metadata mismatch'
    fi
    [[ -f "$reference/main.lua" ]] || plugin_error "Missing plugin reference: $reference"
    specs=()
    while IFS= read -r -d '' spec; do specs+=("$spec"); done < <(find "$suite" -type f -name '*_spec.lua' -print0 | LC_ALL=C sort -z)
    printf '==> Compatibility: %s %s (%s)\n' "$plugin" "$selected_version" "$reference"
    PANELSPLUS_COMPATIBILITY_PLUGIN="$plugin" \
    PANELSPLUS_COMPATIBILITY_VERSION="$selected_version" \
    PANELSPLUS_COMPATIBILITY_REFERENCE="$reference" \
    PANELSPLUS_COMPATIBILITY_COMMIT="$commit" \
        lua tests/run_compatibility.lua "${specs[@]}"
done
