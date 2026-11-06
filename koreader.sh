#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${KOREADER_INSTALL_ROOT:-$HOME/.config}"

usage() {
    cat <<'EOF'
Usage: ./koreader.sh [COMMAND]

  system [ARGS...]       Launch system KOReader (default; native, then Flatpak)
  menu                   Choose system KOReader, install, or launch a version
  install [VERSION]      Download a release; lists available versions if omitted
  run VERSION [ARGS...]  Launch an installed release with this checkout linked
  --help                 Show this help

Examples:
  ./koreader.sh
  ./koreader.sh menu
  ./koreader.sh install 2025.04
  ./koreader.sh run 2025.04 /absolute/path/to/test.cbz

Linux only. Downloads require curl, tar, and xz; KOReader requires SDL2.
The available-version menu also requires Python 3 and internet access.
Releases live in ~/.config/koreader-_VERSION/{runtime,profile}.
Set KOREADER_INSTALL_ROOT to use a parent directory other than ~/.config.
EOF
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

set_version() {
    VERSION="${1#v}"
    [[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}([.-][[:alnum:]]+)*$ ]] || fail "Invalid release version: $1"
    VERSION_DIR="$INSTALL_ROOT/koreader-_$VERSION"
    RUNTIME_DIR="$VERSION_DIR/runtime"
    PROFILE_DIR="$VERSION_DIR/profile"
}

link_plugin() {
    local plugin="$PROFILE_DIR/plugins/panelsplus.koplugin"
    mkdir -p "$PROFILE_DIR/plugins"
    if [[ -L "$plugin" && "$(readlink -- "$plugin")" == "$REPO_DIR" ]]; then
        return
    fi
    [[ ! -e "$plugin" && ! -L "$plugin" ]] || fail "Plugin already exists at $plugin; move it aside to use this checkout."
    ln -s -- "$REPO_DIR" "$plugin"
}

choose_version() {
    local arch="$1" page=1 response parsed index choice default=1
    local -a versions=() page_lines=()
    command -v curl >/dev/null || fail 'Required tool missing: curl'
    command -v python3 >/dev/null || fail 'Python 3 is required to list releases; alternatively use install VERSION.'
    printf 'Fetching available KOReader releases...\n'
    while true; do
        response="$(curl -fsSL --retry 2 "https://api.github.com/repos/koreader/koreader/releases?per_page=100&page=$page")"
        parsed="$(python3 -c '
import json, re, sys
releases = json.load(sys.stdin)
if not isinstance(releases, list):
    sys.exit("GitHub did not return a release list.")
print(len(releases))
for release in releases:
    tag = release.get("tag_name", "")
    if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"v[0-9]{4}\.[0-9]{2}([.-][a-zA-Z0-9]+)*", tag):
        continue
    asset = "koreader-linux-" + sys.argv[1] + "-" + tag + ".tar.xz"
    if any(item.get("name") == asset for item in release.get("assets", [])):
        print(tag[1:])
' "$arch" <<< "$response")"
        mapfile -t page_lines <<< "$parsed"
        versions+=("${page_lines[@]:1}")
        if (( page_lines[0] < 100 )); then break; fi
        page=$((page + 1))
    done
    [[ ${#versions[@]} -gt 0 ]] || fail "No Linux $arch releases are available."
    printf '\nAvailable KOReader releases for Linux %s:\n' "$arch"
    for index in "${!versions[@]}"; do
        printf '%3d) %s\n' "$((index + 1))" "${versions[index]}"
        if [[ "${versions[index]}" == 2025.04 ]]; then default=$((index + 1)); fi
    done
    printf '  0) Cancel\n'
    while true; do
        read -r -p "Release [$default = ${versions[default - 1]}]: " choice || return 0
        choice="${choice:-$default}"
        if [[ "$choice" == 0 ]]; then return 0; fi
        if [[ "$choice" =~ ^[1-9][0-9]{0,3}$ ]] && (( choice <= ${#versions[@]} )); then
            SELECTED_VERSION="${versions[choice - 1]}"
            return
        fi
        printf 'Choose a listed number, or 0 to cancel.\n'
    done
}

install_version() {
    local version="${1:-}" arch asset
    [[ "$(uname -s)" == Linux ]] || fail 'Downloaded releases require Linux (WSL needs GUI support).'
    case "$(uname -m)" in
        x86_64|aarch64|armv7l) arch="$(uname -m)" ;;
        *) fail "Unsupported Linux architecture: $(uname -m)" ;;
    esac
    if [[ -z "$version" ]]; then
        SELECTED_VERSION=""
        choose_version "$arch"
        [[ -n "$SELECTED_VERSION" ]] || return 0
        version="$SELECTED_VERSION"
    fi
    set_version "$version"

    if [[ ! -e "$RUNTIME_DIR" ]]; then
        for tool in curl tar xz; do
            command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
        done
        mkdir -p "$VERSION_DIR"
        INSTALL_STAGING="$(mktemp -d "$VERSION_DIR/.install.XXXXXX")"
        # Only the temporary download/extraction is removed if installation fails.
        trap 'rm -rf -- "$INSTALL_STAGING"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        asset="koreader-linux-$arch-v$VERSION.tar.xz"
        printf 'Downloading %s...\n' "$asset"
        curl -fL --retry 2 "https://github.com/koreader/koreader/releases/download/v$VERSION/$asset" -o "$INSTALL_STAGING/release.tar.xz"
        mkdir "$INSTALL_STAGING/runtime"
        tar -xJf "$INSTALL_STAGING/release.tar.xz" --no-same-owner -C "$INSTALL_STAGING/runtime"
        [[ -x "$INSTALL_STAGING/runtime/bin/koreader" ]] || fail 'Archive does not contain bin/koreader.'
        mv -- "$INSTALL_STAGING/runtime" "$RUNTIME_DIR"
        rm -rf -- "$INSTALL_STAGING"
        trap - EXIT INT TERM
    fi
    [[ -x "$RUNTIME_DIR/bin/koreader" ]] || fail "Incomplete installation at $RUNTIME_DIR; move it aside and try again."
    link_plugin
    printf 'Ready: %s\nLaunch: %s run %s\n' "$VERSION_DIR" "$0" "$VERSION"
}

run_version() {
    [[ $# -gt 0 ]] || fail 'Usage: ./koreader.sh run VERSION [ARGS...]'
    set_version "$1"
    shift
    [[ -x "$RUNTIME_DIR/bin/koreader" ]] || fail "Install this release first: $0 install $VERSION"
    link_plugin
    printf 'Launching KOReader %s with profile %s\n' "$VERSION" "$PROFILE_DIR"
    exec env KO_HOME="$PROFILE_DIR" "$RUNTIME_DIR/bin/koreader" "$@"
}

run_system() {
    if command -v koreader >/dev/null; then
        exec koreader "$@"
    elif command -v flatpak >/dev/null && flatpak info rocks.koreader.KOReader >/dev/null 2>&1; then
        exec flatpak run rocks.koreader.KOReader "$@"
    fi
    fail "System KOReader was not found. Install a test release with: $0 install 2025.04"
}

menu() {
    local choice directory version
    while true; do
        printf '\nKOReader development menu\nInstalled test releases:\n'
        for directory in "$INSTALL_ROOT"/koreader-_*/runtime/bin/koreader; do
            [[ -x "$directory" ]] || continue
            version="${directory%/runtime/bin/koreader}"
            printf '  %s\n' "${version##*/koreader-_}"
        done
        printf '\n1) Launch system KOReader (default)\n2) Install a release\n3) Launch a test release\n0) Exit\n'
        read -r -p 'Choice [1]: ' choice || return 0
        case "${choice:-1}" in
            1) run_system ;;
            2) install_version ;;
            3)
                read -r -p 'KOReader release [2025.04]: ' version
                run_version "${version:-2025.04}"
                ;;
            0) return 0 ;;
            *) printf 'Choose 0, 1, 2, or 3.\n' ;;
        esac
    done
}

command="${1:-system}"
if [[ $# -gt 0 ]]; then shift; fi
case "$command" in
    system) run_system "$@" ;;
    menu) menu ;;
    install)
        [[ $# -le 1 ]] || fail 'Usage: ./koreader.sh install [VERSION]'
        install_version "${1:-}"
        ;;
    run) run_version "$@" ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
