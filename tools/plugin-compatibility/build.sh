#!/usr/bin/env bash
# Runtime file lists mirror each upstream release recipe; never mutate references.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $# == 3 ]] || plugin_error 'Usage: build.sh PLUGIN SOURCE EMPTY_OUTPUT'
plugin="$(plugin_id "$1")"
source_dir="$(realpath -e -- "$2")"
output="$(realpath -e -- "$3")"
[[ -d "$output" && -z "$(find "$output" -mindepth 1 -print -quit)" ]] || plugin_error 'Build output must be an empty directory'
[[ -f "$source_dir/_meta.lua" && -f "$source_dir/main.lua" ]] || plugin_error 'Source is not a plugin'
case "$plugin" in
    meguru) files=(_meta.lua main.lua LICENSE libs assets meguru) ;;
    ink-away) files=(_meta.lua main.lua ink README.md NOTICE.md LICENSE) ;;
    kobo)
        files=(_meta.lua main.lua)
        for file in src patches README.md CHANGELOG.md LICENSE.md LICENSE version.txt; do
            [[ ! -e "$source_dir/$file" ]] || files+=("$file")
        done
        ;;
    panels_plus)
        # Existing Panels+ packager checks model checksums and includes runtime data.
        (cd -- "$source_dir" && bash ./build.sh panelsplus)
        cp -a -- "$source_dir/dist/panelsplus.koplugin/." "$output/"
        exit 0
        ;;
esac
for file in "${files[@]}"; do
    [[ -e "$source_dir/$file" ]] || plugin_error "Missing runtime input: $file"
    cp -a -- "$source_dir/$file" "$output/"
done
