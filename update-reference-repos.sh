#!/usr/bin/env bash
# ==============================================================================
# update-reference-repos.sh - Update and stage reference submodule commit pointers
# ==============================================================================
# Usage:
#   ./update-reference-repos.sh                    # Update all reference repos
#   ./update-reference-repos.sh --kobo             # Update only kobo.koplugin
#   ./update-reference-repos.sh --koreader         # Update only koreader
#   ./update-reference-repos.sh --meguru           # Update only meguru.koplugin
#   ./update-reference-repos.sh --ink-away         # Update only ink-away.koplugin
#   ./update-reference-repos.sh --kobo --meguru    # Update both selected repos
#   ./update-reference-repos.sh --meguru.koplugin  # Full folder names also work
#   ./update-reference-repos.sh --help             # Show available repository flags
#
# Initializes missing submodules and follows their configured remote branch,
# or remote HEAD when no branch is configured. Nested dependencies stay pinned.
# Logs commit hashes, commits added/removed from history, file/line change stats,
# and totals. Duplicate selections update a repo once; unknown flags stop before
# any updates. Stops on failures and preserves updates already completed.
# Stages only selected submodule pointers; review git diff --cached and commit.
# Does not force checkout or commit automatically. Runs from any working directory.
# ==============================================================================

set -euo pipefail

# Run from the project root even when invoked from another directory.
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

paths=()
# Git config's null-delimited output keeps paths with spaces intact.
while IFS= read -r -d '' entry; do
    path=${entry#*$'\n'}
    [[ "$path" == references-repos/* ]] || continue
    paths+=("$path")
done < <(git config --file .gitmodules --null --get-regexp '^submodule\..*\.path$')

usage() {
    printf 'Usage: %s [--<repo> ...]\n\n' "${0##*/}"
    printf 'Without flags, update and stage all reference submodules.\n'
    printf 'Select one or more repositories using:\n'
    for path in "${paths[@]}"; do
        name=${path##*/}
        if [[ "$name" == *.koplugin ]]; then
            printf '  --%s (also --%s)\n' "${name%.koplugin}" "$name"
        else
            printf '  --%s\n' "$name"
        fi
    done
    printf '  --help, -h  Show this help.\n'
}

# Validate every flag before fetching or staging any repository.
selected=()
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
    esac
    matched=false
    for i in "${!paths[@]}"; do
        name=${paths[i]##*/}
        if [[ "$arg" == "--$name" || "$arg" == "--${name%.koplugin}" ]]; then
            selected[i]=true
            matched=true
        fi
    done
    if [[ "$matched" == false ]]; then
        printf 'ERROR: Unknown repository flag: %s\n\n' "$arg" >&2
        usage >&2
        exit 2
    fi
done

updated=0
unchanged=0
total_added=0
total_removed=0

updated_paths=()
for i in "${!paths[@]}"; do
    if (( $# > 0 )) && [[ "${selected[i]:-false}" != true ]]; then
        continue
    fi
    path=${paths[i]}
    updated_paths+=("$path")

    printf '\nUpdating: %s...\n' "${path##*/}"
    if [[ -e "$path/.git" ]]; then
        before=$(git -C "$path" rev-parse HEAD)
    else
        # Compare a newly initialized submodule against its recorded commit.
        before=$(git rev-parse ":$path")
        printf '  Initializing submodule.\n'
    fi

    # Follow the configured branch, or remote HEAD when none is configured.
    # Nested dependencies keep their pinned commits. No --force: Git stops
    # if a checkout would overwrite local changes.
    if ! git submodule update --init --remote --checkout -- "$path"; then
        printf 'ERROR: Could not update %s. Stopping; earlier updates remain.\n' "$path" >&2
        exit 1
    fi
    after=$(git -C "$path" rev-parse HEAD)

    # Stage only the submodule commit pointer in the parent repository.
    # Also handle a previously updated HEAD whose pointer was not yet staged.
    git add -- "$path"
    printf '  Staged commit pointer: %s.\n' "${after:0:12}"

    if [[ "$before" == "$after" ]]; then
        printf '  Already up to date (%s). Commits: +0 / -0.\n' "${after:0:12}"
        unchanged=$((unchanged + 1))
        continue
    fi

    # Count commits entering/leaving HEAD's history, including branch rewinds.
    read -r removed added < <(git -C "$path" rev-list --left-right --count "$before...$after")
    printf '  %s -> %s\n' "${before:0:12}" "${after:0:12}"
    printf '  Commits: +%s added / -%s removed from history.\n' "$added" "$removed"
    git -C "$path" diff --shortstat "$before" "$after" --
    updated=$((updated + 1))
    total_added=$((total_added + added))
    total_removed=$((total_removed + removed))
done

printf '\nDone: %s updated, %s unchanged. Commits: +%s / -%s.\n' \
    "$updated" "$unchanged" "$total_added" "$total_removed"

printf '\nReference submodule commits:\n'
if (( ${#updated_paths[@]} > 0 )); then
    git submodule status -- "${updated_paths[@]}"
fi
printf '\nCommit pointers are staged. Review git diff --cached, then commit when ready.\n'
