#!/usr/bin/env bash
# Plan, build, or install a known plugin. Replacement uses moves, never deletion.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
usage() {
    cat <<'HELP'
Usage: deploy.sh --plugin=NAME --mode=stable|laboratory|rolling [OPTIONS]
  --version=1.7.1       Required for stable/laboratory (underscores accepted)
  --source=/worktree   Rolling worktree override
  --experiment=NAME    Required for laboratory; selects a named experiment
  --build-only         Build/stage locally without installing
  --install            Back up known unchanged installed copies and install
Default: print plan only. No downloads, Git updates, or live changes.
HELP
}
plugin='' mode='' version='' override='' experiment='' action=plan
for arg in "$@"; do
    case "$arg" in
        --plugin=*) plugin="$(plugin_id "${arg#*=}")" ;;
        --mode=*) mode="${arg#*=}" ;;
        --version=*) version="$(plugin_version "${arg#*=}")" ;;
        --source=*) override="${arg#*=}" ;;
        --experiment=*)
            experiment="${arg#*=}"
            [[ "$experiment" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || plugin_error 'Experiment must be a simple name (letters, digits, underscores, hyphens)'
            ;;
        --build-only|--install)
            [[ "$action" == plan ]] || plugin_error 'Choose one of --build-only and --install'
            action="${arg#--}"
            ;;
        -h|--help) usage; exit 0 ;;
        *) plugin_error "Unknown option: $arg" ;;
    esac
done
[[ -n "$plugin" ]] || plugin_error '--plugin is required'
[[ -z "$override" || "$mode" == rolling ]] || plugin_error '--source requires rolling mode'
[[ -z "$experiment" || "$mode" == laboratory ]] || plugin_error '--experiment requires laboratory mode'
case "$mode" in
    stable|laboratory)
        [[ -n "$version" ]] || plugin_error '--version is required for stable/laboratory'
        payload="$PLUGIN_PROJECT_ROOT/references-repos/plugins/$plugin/stable/v${version//./_}"
        if [[ "$mode" == laboratory ]]; then
            [[ -n "$experiment" ]] || plugin_error '--experiment is required for laboratory mode'
            payload="$PLUGIN_PROJECT_ROOT/references-repos/plugins/$plugin/laboratory/v${version//./_}/$experiment"
        fi
        ;;
    rolling)
        [[ -z "$version" ]] || plugin_error 'Rolling version is derived from source; omit --version'
        payload="${override:-$(plugin_rolling_source "$plugin")}"
        ;;
    *) plugin_error '--mode must be stable, laboratory, or rolling' ;;
esac
[[ -d "$payload" && ! -L "$payload" ]] || plugin_error "Missing/linked source: $payload"
payload="$(realpath -e -- "$payload")"
[[ -f "$payload/main.lua" && -f "$payload/_meta.lua" ]] || plugin_error 'Missing main.lua or _meta.lua'
meta_version="$(plugin_meta_version "$payload")"
if [[ "$mode" == rolling ]]; then
    version="$meta_version"
    commit="$(git -C "$payload" rev-parse HEAD)"
    dirty="$(git -C "$payload" status --porcelain --untracked-files=normal)"
else
    [[ "$version" == "$meta_version" ]] || plugin_error "Pin $version disagrees with metadata $meta_version"
    commit='' dirty=''
fi
folder="$(plugin_folder "$plugin")"
plugins="$(dirname -- "$PLUGIN_PROJECT_ROOT")"
koreader="$(dirname -- "$plugins")"
validate_install_root() {
    [[ "$(basename -- "$plugins")" == plugins && "$plugins" != / ]] || plugin_error 'Project must be directly inside a KOReader plugins directory'
    [[ ! -L "$plugins" && ! -L "$koreader" ]] || plugin_error 'Linked installation roots are not supported'
    if [[ ! ( -f "$koreader/reader.lua" && -d "$koreader/frontend" ) && ! ( -f "$koreader/settings.reader.lua" && -d "$koreader/settings" ) ]]; then
        plugin_error 'Parent is not a recognized KOReader runtime/configuration root'
    fi
}
# Reject ambiguous payload structures; manifests are generated locally, not executed.
validate_payload() {
    local dir="$1" bad
    [[ -f "$dir/main.lua" && -f "$dir/_meta.lua" ]] || plugin_error "Incomplete plugin: $dir"
    bad="$(find "$dir" -mindepth 1 \( -name .git -o -type l -o \( ! -type f ! -type d \) \) -print -quit)" || plugin_error "Cannot inspect payload: $dir"
    [[ -z "$bad" ]] || plugin_error "Unsupported payload entry: $bad"
}
snapshot() {
    (cd -- "$1" && find . -type f ! -path './.panelsplus-deployment/*' -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}
known_unchanged() {
    local dir="$1" pin current expected
    validate_payload "$dir"
    current="$(snapshot "$dir")" || return 1
    if [[ -d "$dir/.panelsplus-deployment" ]]; then
        [[ "$(cat "$dir/.panelsplus-deployment/plugin")" == "$plugin" ]] || return 1
        expected="$(cat "$dir/.panelsplus-deployment/SHA256SUMS")" || return 1
        [[ "$current" == "$expected" ]]
        return
    fi
    for pin in "$PLUGIN_PROJECT_ROOT/references-repos/plugins/$plugin/stable/v"*; do
        [[ -d "$pin" ]] || continue
        if expected="$(snapshot "$pin")" && [[ "$expected" == "$current" ]]; then return 0; fi
    done
    return 1
}
collect_old() {
    local dir name suffix prefix
    old=()
    for dir in "$plugins"/*; do
        [[ -d "$dir" || -L "$dir" ]] || continue
        name="$(basename -- "$dir")"
        [[ "$name" != *.disabled ]] || continue
        prefix="$plugin"
        [[ "$plugin" != panels_plus ]] || prefix=panelsplus
        if [[ "$name" != "$folder" && "$name" != "$plugin"* && "$name" != "$prefix"* ]]; then continue; fi
        # An exact source-tree guard comes before every identity/contents check.
        [[ ! -L "$dir" && "$(realpath -e -- "$dir")" != "$PLUGIN_PROJECT_ROOT" ]] || plugin_error "Protected checkout/symlink: $dir"
        [[ ! -e "$dir/.git" ]] || plugin_error "Refusing to replace Git checkout: $dir"
        if [[ "$name" != "$folder" ]]; then
            suffix="${name#"${plugin}__v"}"
            suffix="${suffix%.koplugin}"
            [[ "$name" == "${plugin}__v"* && "$suffix" =~ ^[0-9]+_[0-9]+_[0-9]+(-[A-Za-z0-9]+([_-][A-Za-z0-9]+)*)?$ ]] || plugin_error "Ambiguous installed folder: $dir"
        fi
        known_unchanged "$dir" || plugin_error "Unmanaged or locally changed plugin: $dir; preserve and inspect it before migration"
        old+=("$dir")
    done
}
if [[ "$action" == install ]]; then validate_install_root; fi
printf 'Plugin: %s\nMode: %s\nVersion: %s\nSource: %s\nDestination: %s/%s\n' "$plugin" "$mode" "$version" "$payload" "$plugins" "$folder"
[[ -z "$commit" ]] || printf 'Commit: %s\nDirty source: %s\n' "$commit" "$([[ -z "$dirty" ]] && echo no || echo yes)"
if [[ "$action" == plan ]]; then
    echo 'Plan only. Use --build-only to build/stage or --install to replace live copies.'
    exit 0
fi
# Create an isolated build, retaining previous artifacts for reproducibility/recovery.
artifact_root="$PLUGIN_PROJECT_ROOT/.cache/plugin-compatibility/builds/$plugin/v${version//./_}"
mkdir -p -- "$artifact_root"
build="$(mktemp -d "$artifact_root/build.XXXXXXXX")"
if [[ "$mode" == rolling ]]; then
    source_payload="$payload"
    mkdir -- "$build/$folder"
    bash "$PLUGIN_PROJECT_ROOT/tools/plugin-compatibility/builders/$plugin.sh" "$payload" "$build/$folder"
    payload="$build/$folder"
else
    source_payload="$payload"
    validate_payload "$payload"
    [[ ! -e "$payload/.panelsplus-deployment" ]] || plugin_error 'Source contains reserved deployment metadata'
    mkdir -- "$build/$folder"
    cp -a -- "$payload/." "$build/$folder/"
    payload="$build/$folder"
fi
validate_payload "$payload"
[[ ! -e "$payload/.panelsplus-deployment" ]] || plugin_error 'Build contains reserved deployment metadata'
[[ "$(plugin_meta_version "$payload")" == "$version" ]] || plugin_error 'Build changed plugin version unexpectedly'
mkdir -- "$payload/.panelsplus-deployment"
printf '%s\n' "$plugin" > "$payload/.panelsplus-deployment/plugin"
printf 'mode=%s\nversion=%s\nsource=%s\ncommit=%s\ndirty=%s\n' "$mode" "$version" "$source_payload" "$commit" "$dirty" > "$payload/.panelsplus-deployment/provenance"
if [[ "$mode" == rolling ]]; then
    git -C "$source_payload" diff HEAD --binary > "$payload/.panelsplus-deployment/source.patch"
fi
snapshot "$payload" > "$payload/.panelsplus-deployment/SHA256SUMS"
printf 'Artifact: %s\n' "$payload"
[[ "$action" == install ]] || exit 0
# flock releases automatically on exit, including a failed transaction.
exec 9> "$koreader/.panelsplus-plugin-deploy.lock"
flock -n 9 || plugin_error 'Another plugin deployment is running'
collect_old
for dir in "${old[@]}"; do printf 'Replace (backup first): %s\n' "$dir"; done
backup_root="$koreader/.panelsplus-plugin-backups"
[[ ! -L "$backup_root" ]] || plugin_error 'Backup root must not be a symlink'
mkdir -p -- "$backup_root"
backup="$(mktemp -d "$backup_root/${plugin}.XXXXXXXX")"
stage="$(mktemp -d "$plugins/.panelsplus-stage.XXXXXXXX")"
moved=() committed=false
rollback() {
    local status=$? original saved
    trap - EXIT
    if [[ "$committed" == false ]]; then
        for original in "${moved[@]}"; do
            saved="$backup/$(basename -- "$original")"
            if [[ ! -e "$original" && -d "$saved" ]]; then
                mv -T -- "$saved" "$original" || echo "Recovery needed: $saved -> $original" >&2
            fi
        done
        echo "Deployment stopped; retained backup/staging: $backup $stage" >&2
    fi
    exit "$status"
}
trap rollback EXIT
cp -a -- "$payload/." "$stage/"
known_unchanged "$stage" || plugin_error 'Staged payload verification failed'
for dir in "${old[@]}"; do
    [[ ! -L "$dir" && -d "$dir" ]] || plugin_error 'Installed directory changed during deployment'
    known_unchanged "$dir" || plugin_error 'Installed contents changed during deployment'
    mv -T -- "$dir" "$backup/$(basename -- "$dir")"
    moved+=("$dir")
done
[[ ! -e "$plugins/$folder" && ! -L "$plugins/$folder" ]] || plugin_error 'Destination appeared during deployment'
mv -T -- "$stage" "$plugins/$folder"
committed=true
printf 'Installed: %s/%s\nBackups: %s\nRestart KOReader to test.\n' "$plugins" "$folder" "$backup"
