#!/usr/bin/env bash
# Exercise destructive boundaries only inside a fresh temporary KOReader tree.
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d '/tmp/panelsplus workflow.XXXXXXXX')"
passed=0
new_case() {
    local label="$1"
    root="$fixture/$label/koreader"
    repo="$root/plugins/panels_plus_development.koplugin"
    mkdir -p "$repo/references-repos/plugins/kobo/stable/v0_4_1" "$root/settings" "$repo/tests" "$repo/tools"
    touch "$root/settings.reader.lua"
    cp -a "$project/tools/plugin-compatibility" "$repo/tools/"
    cp "$project"/tests/{run-compatibility.sh,run_compatibility.lua,helper.lua,PanelsPlusTestFramework.lua} "$repo/tests/"
    cp "$project/run-tests.sh" "$repo/"
    pin="$repo/references-repos/plugins/kobo/stable/v0_4_1"
    printf 'return { version = "0.4.1" }\n' > "$pin/main.lua"
    printf 'return {\n    version = "0.4.1",\n}\n' > "$pin/_meta.lua"
    deploy="$repo/tools/plugin-compatibility/deploy.sh"
}
run_install() { bash "$deploy" --plugin=kobo --mode=stable --version=0.4.1 --install > "$fixture/last.log" 2>&1; }
expect_refusal() {
    if run_install; then echo "Expected refusal: $1" >&2; exit 1; fi
    grep -q -- "$1" "$fixture/last.log" || { cat "$fixture/last.log"; exit 1; }
}
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
new_case plan
bash "$deploy" --plugin=kobo --mode=stable --version=0.4.1 > "$fixture/last.log"
[[ ! -e "$root/plugins/kobo.koplugin" && ! -e "$repo/.cache/plugin-compatibility/builds" ]]
pass 'preview has no mutations'

new_case laboratory
lab="$repo/references-repos/plugins/kobo/laboratory/v0_4_1/bluetooth-fix"
mkdir -p "$lab"
cp -a "$pin/." "$lab/"
printf 'laboratory patch\n' >> "$lab/main.lua"
if bash "$deploy" --plugin=kobo --mode=laboratory --version=0.4.1 > "$fixture/last.log" 2>&1; then exit 1; fi
grep -q -- '--experiment is required' "$fixture/last.log"
if bash "$deploy" --plugin=kobo --mode=laboratory --version=0.4.1 --experiment=../escape > "$fixture/last.log" 2>&1; then exit 1; fi
grep -q 'Experiment must be a simple name' "$fixture/last.log"
pass 'laboratory requires an explicit experiment and rejects path traversal'
bash "$deploy" --plugin=kobo --mode=laboratory --version=0.4.1 --experiment=bluetooth-fix --install > "$fixture/last.log" 2>&1
grep -q 'laboratory patch' "$root/plugins/kobo.koplugin/main.lua"
! grep -q 'laboratory patch' "$pin/main.lua"
pass 'laboratory deployment installs patched copy and preserves original pin'

new_case duplicates
cp -a "$pin" "$root/plugins/kobo.koplugin"
cp -a "$pin" "$root/plugins/kobo__v0_4_1"
cp -a "$pin" "$root/plugins/kobo__v0_4_0.koplugin"
mkdir "$root/plugins/unrelated.koplugin"
printf 'keep\n' > "$root/plugins/unrelated.koplugin/sentinel"
run_install
[[ -f "$root/plugins/kobo.koplugin/.panelsplus-deployment/SHA256SUMS" ]]
[[ ! -e "$root/plugins/kobo__v0_4_1" && ! -e "$root/plugins/kobo__v0_4_0.koplugin" ]]
[[ "$(find "$root/.panelsplus-plugin-backups" -name main.lua | wc -l)" == 3 ]]
[[ "$(cat "$root/plugins/unrelated.koplugin/sentinel")" == keep ]]
run_install
pass 'all known duplicates backed up, unrelated plugin preserved, managed reinstall succeeds'
printf 'local edit\n' >> "$root/plugins/kobo.koplugin/main.lua"
expect_refusal 'locally changed'
grep -q 'local edit' "$root/plugins/kobo.koplugin/main.lua"
pass 'managed local modifications block replacement'

new_case unmanaged
cp -a "$pin" "$root/plugins/kobo.koplugin"
printf 'custom\n' >> "$root/plugins/kobo.koplugin/main.lua"
expect_refusal 'locally changed'
pass 'unmanaged custom copy blocks replacement'

new_case ambiguous
cp -a "$pin" "$root/plugins/kobo_development.koplugin"
expect_refusal 'Ambiguous installed folder'
[[ -f "$root/plugins/kobo_development.koplugin/main.lua" ]]
pass 'ambiguous folder blocks replacement'

new_case symlink
ln -s "$pin" "$root/plugins/kobo.koplugin"
expect_refusal 'Protected checkout/symlink'
[[ -L "$root/plugins/kobo.koplugin" && -f "$pin/main.lua" ]]
pass 'symlink installation rejected without following it'

new_case git
cp -a "$pin" "$root/plugins/kobo.koplugin"
mkdir "$root/plugins/kobo.koplugin/.git"
expect_refusal 'Git checkout'
pass 'Git working copy protected'

new_case source_symlink
ln -s "$fixture" "$pin/escape"
expect_refusal 'Unsupported payload entry'
pass 'payload symlink rejected'

new_case metadata
sed -i 's/0.4.1/0.4.2/' "$pin/_meta.lua"
expect_refusal 'disagrees with metadata'
pass 'folder/metadata mismatch rejected'

new_case bad_root
mv "$root/settings.reader.lua" "$root/not-settings.lua"
expect_refusal 'not a recognized KOReader'
[[ ! -e "$root/plugins/kobo.koplugin" ]]
pass 'non-KOReader root rejected'

new_case self
if bash "$deploy" --plugin=panels_plus --mode=rolling --install > "$fixture/last.log" 2>&1; then exit 1; fi
# Give the fixture a real Panels+ stable reference; the working checkout itself must block it.
mkdir -p "$repo/references-repos/plugins/panels_plus/stable/v0_4_1"
cp -a "$pin/." "$repo/references-repos/plugins/panels_plus/stable/v0_4_1/"
if bash "$deploy" --plugin=panels_plus --mode=stable --version=0.4.1 --install > "$fixture/last.log" 2>&1; then exit 1; fi
grep -q 'Protected checkout' "$fixture/last.log"
[[ -f "$repo/run-tests.sh" ]]
pass 'current Panels+ development project protected'

new_case rollback
cp -a "$pin" "$root/plugins/kobo.koplugin"
cp -a "$pin" "$root/plugins/kobo__v0_4_1"
mkdir "$fixture/bin"
cat > "$fixture/bin/mv" <<'WRAPPER'
#!/usr/bin/env bash
for item in "$@"; do
    if [[ "$item" == */.panelsplus-stage.* ]]; then exit 17; fi
done
exec /usr/bin/mv "$@"
WRAPPER
chmod +x "$fixture/bin/mv"
if PATH="$fixture/bin:$PATH" run_install; then echo 'Expected injected failure' >&2; exit 1; fi
cmp "$pin/main.lua" "$root/plugins/kobo.koplugin/main.lua"
cmp "$pin/main.lua" "$root/plugins/kobo__v0_4_1/main.lua"
pass 'failed final placement restores both previous copies'

new_case tests
mkdir -p "$repo/tests/plugin-compatibility/kobo__v0_4_1/nested" "$repo/tests/plugin-compatibility/kobo__rollingrelease"
cp -a "$pin" "$repo/references-repos/plugins/kobo/rolling.koplugin"
git -C "$repo/references-repos/plugins/kobo/rolling.koplugin" init -q
git -C "$repo/references-repos/plugins/kobo/rolling.koplugin" -c user.name=Fixture -c user.email=fixture@example.invalid add .
git -C "$repo/references-repos/plugins/kobo/rolling.koplugin" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
cat > "$repo/tests/plugin-compatibility/kobo__v0_4_1/nested/pin_spec.lua" <<'LUA'
local t = require("tests.PanelsPlusTestFramework")
t.it("selects the real pinned counterpart", function()
    local reference = assert(os.getenv("PANELSPLUS_COMPATIBILITY_REFERENCE"))
    assert(assert(loadfile(reference .. "/_meta.lua"))().version == "0.4.1")
    assert(os.getenv("PANELSPLUS_COMPATIBILITY_VERSION") == "0.4.1")
    local log = assert(io.open(assert(os.getenv("WORKFLOW_ORDER_LOG")), "a"))
    log:write("stable\n")
    log:close()
    _G.workflow_pin_state = true
end)
LUA
cat > "$repo/tests/plugin-compatibility/kobo__rollingrelease/rolling_spec.lua" <<'LUA'
local t = require("tests.PanelsPlusTestFramework")
t.it("runs rolling in a separate Lua process after stable", function()
    assert(_G.workflow_pin_state == nil)
    assert(os.getenv("PANELSPLUS_COMPATIBILITY_VERSION") == "rollingrelease")
    assert(#assert(os.getenv("PANELSPLUS_COMPATIBILITY_COMMIT")) == 40)
    local log = assert(io.open(assert(os.getenv("WORKFLOW_ORDER_LOG")), "r"))
    assert(log:read("*a") == "stable\n")
    log:close()
end)
LUA
WORKFLOW_ORDER_LOG="$fixture/order" bash "$repo/run-tests.sh" --compatibility-plugin=kobo > "$fixture/last.log" 2>&1
pass 'compatibility selector loads nested stable suite then isolated rolling suite'
override="$repo/references-repos/plugins/kobo/laboratory/v0_4_1/bluetooth-fix"
mkdir -p "$override"
cp -a "$pin/." "$override/"
WORKFLOW_ORDER_LOG="$fixture/order" bash "$repo/run-tests.sh" --compatibility-plugin=kobo --compatibility-plugin-version=0.4.1 --compatibility-reference="$override" > "$fixture/last.log" 2>&1
grep -Fq -- "$override" "$fixture/last.log"
pass 'exact-version suite can select a laboratory reference explicitly'
if bash "$repo/run-tests.sh" --compatibility-plugin=kobo --compatibility-plugin-version=9.9.9 > "$fixture/last.log" 2>&1; then exit 1; fi
grep -q 'Missing/linked compatibility suite' "$fixture/last.log"
pass 'missing explicitly selected suite fails'
cat > "$repo/tests/plugin-compatibility/kobo__v0_4_1/nested/pin_spec.lua" <<'LUA'
require("tests.PanelsPlusTestFramework").it("propagates failure", function() error("expected") end)
LUA
if bash "$repo/run-tests.sh" --compatibility-plugin=kobo --compatibility-plugin-version=0.4.1 > "$fixture/last.log" 2>&1; then exit 1; fi
grep -q '1 failed' "$fixture/last.log"
pass 'compatibility assertion failures reach shell status'

new_case updater
cp "$project/run-sync-submodules.sh" "$project/.gitmodules" "$repo/"
mkdir "$fixture/updater-bin"
cat > "$fixture/updater-bin/git" <<'WRAPPER'
#!/usr/bin/env bash
case "$1" in
    config) exec /usr/bin/git "$@" ;;
    rev-parse) printf '%040d\n' 1 ;;
    submodule)
        printf '%s\n' "$*" >> "$WORKFLOW_UPDATE_LOG"
        exit 1 # Stop before any network access or staging.
        ;;
    *) echo "Unexpected Git call in updater test: $*" >&2; exit 99 ;;
esac
WRAPPER
chmod +x "$fixture/updater-bin/git"
for plugin in kobo meguru ink-away; do
    : > "$fixture/update.log"
    if PATH="$fixture/updater-bin:$PATH" WORKFLOW_UPDATE_LOG="$fixture/update.log" bash "$repo/run-sync-submodules.sh" "--$plugin" > "$fixture/last.log" 2>&1; then exit 1; fi
    grep -Fq -- "references-repos/plugins/$plugin/rolling.koplugin" "$fixture/update.log"
    [[ "$(wc -l < "$fixture/update.log")" == 1 ]]
    pass "updater --$plugin selects its nested rolling checkout"
done
: > "$fixture/update.log"
if PATH="$fixture/updater-bin:$PATH" WORKFLOW_UPDATE_LOG="$fixture/update.log" bash "$repo/run-sync-submodules.sh" --kobo.koplugin > "$fixture/last.log" 2>&1; then exit 1; fi
grep -Fq -- 'references-repos/plugins/kobo/rolling.koplugin' "$fixture/update.log"
pass 'updater retains the plugin.koplugin flag alias'
: > "$fixture/update.log"
if PATH="$fixture/updater-bin:$PATH" WORKFLOW_UPDATE_LOG="$fixture/update.log" bash "$repo/run-sync-submodules.sh" --rolling.koplugin > "$fixture/last.log" 2>&1; then exit 1; fi
[[ ! -s "$fixture/update.log" ]]
grep -q 'Unknown repository flag' "$fixture/last.log"
pass 'ambiguous rolling folder name rejected before any update'
printf '\n%d workflow checks passed. Temporary fixture: %s\n' "$passed" "$fixture"
