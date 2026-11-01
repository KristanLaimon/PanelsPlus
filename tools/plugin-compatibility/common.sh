#!/usr/bin/env bash
# Shared path/identifier handling; sourced by the Bash compatibility tools.
PLUGIN_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
plugin_error() { echo "Error: $*" >&2; exit 2; }
plugin_id() {
    case "${1,,}" in
        panels|panels+|panelsplus|panels_plus|panelsplus.koplugin) echo panels_plus ;;
        meguru|meguru.koplugin) echo meguru ;;
        kobo|kobo.koplugin) echo kobo ;;
        ink-away|inkaway|ink-away.koplugin) echo ink-away ;;
        *) plugin_error "Unknown plugin '$1'; establish its relationship and register its build recipe first." ;;
    esac
}
plugin_version() {
    local version="${1#v}"
    version="${version//_/.}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]] || plugin_error "Invalid version: $1"
    echo "$version"
}
plugin_folder() {
    if [[ "$1" == panels_plus ]]; then echo panelsplus.koplugin; else echo "$1.koplugin"; fi
}
plugin_rolling_source() {
    if [[ "$1" == panels_plus ]]; then echo "$PLUGIN_PROJECT_ROOT"; else echo "$PLUGIN_PROJECT_ROOT/references-repos/plugins/$1/rolling.koplugin"; fi
}
plugin_meta_version() {
    local version
    version="$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$1/_meta.lua")"
    plugin_version "$version"
}
