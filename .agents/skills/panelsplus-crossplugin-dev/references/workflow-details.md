# Compatibility test and live deployment details

## Tests

The current scope of `tests/plugin-compatibility/` is coexistence coverage. Existing standalone Panels+ unit tests remain in `tests/`; mentioning another plugin in a test name does not make it a cross-plugin test. `panelviewer_kobo_bluetooth_spec.lua` loads Panels+ with KOReader mocks and supplies representative action arguments itself. It neither loads Kobo's action definitions nor exercises Kobo dispatch, so it does not establish compatibility with any pinned Kobo release. Keep it in the general unit suite. When requested, add actual reference-backed coexistence/integration tests under the corresponding versioned directories, labeling the kind of evidence accurately.

Keep reusable scenarios, target-module loaders and fixtures in `tests/plugin-compatibility/shared/`. Version-specific `_spec.lua` files remain under `<plugin>__v<version>/` or `<plugin>__rollingrelease/` and pass the selected reference into shared code, for example:

```lua
require("tests.plugin-compatibility.shared.inkaway_surface")(
    assert(os.getenv("PANELSPLUS_COMPATIBILITY_REFERENCE"))
)
```

The shared directory is not an independent suite. The runner discovers versioned directories only. A target loader may use `loadfile(reference .. "/" .. name .. ".lua", "t", environment)` and a scoped `require` to load the selected counterpart while keeping fixture dependencies isolated.

The Bash selector exports these variables for each suite:

- `PANELSPLUS_COMPATIBILITY_PLUGIN`: canonical directory identifier.
- `PANELSPLUS_COMPATIBILITY_VERSION`: dotted stable version or `rollingrelease`.
- `PANELSPLUS_COMPATIBILITY_REFERENCE`: absolute pinned/rolling source path.
- `PANELSPLUS_COMPATIBILITY_COMMIT`: rolling SHA, empty for stable pins.

The test process loads `tests.helper`, executes each selected `_spec.lua` with `loadfile` (so version directories and hyphens work), and reports through `tests.PanelsPlusTestFramework`. Assertions should read/exercise the actual referenced counterpart, with appropriate KOReader fixtures. Create tests for the requested feature rather than a vacuous suite that only checks metadata. Laboratory-patched compatibility needs explicit evidence identifying the patch; passing against that copy is not a pass against upstream stable.

To exercise the same exact-version suite against a modified stable copy or rolling branch worktree, add `--compatibility-reference=/absolute/path` alongside `--compatibility-plugin` and `--compatibility-plugin-version`. The reference path is printed and exported to the suite; stable metadata must still match the selected pin. Record that result as laboratory/worktree evidence separately from the original reference result.

## Build and deploy

Run from any working directory; paths are anchored to the script's project root. The project must actually be inside a KOReader `plugins/` directory to install. A KOReader runtime (`reader.lua` plus `frontend/`) or the user's KOReader configuration (`settings.reader.lua` plus `settings/`) must be its parent.

```bash
./tools/plugin-compatibility/deploy.sh --plugin=meguru --mode=stable --version=1.7.1
./tools/plugin-compatibility/deploy.sh --plugin=meguru --mode=laboratory --version=1.7.1 --experiment=bluetooth-fix
./tools/plugin-compatibility/deploy.sh --plugin=meguru --mode=rolling --build-only
./tools/plugin-compatibility/deploy.sh --plugin=meguru --mode=rolling --install
```

Stable/laboratory default to a plan without copying. Rolling without `--build-only` or `--install` previews the checkout; both those flags build. Stable/laboratory versions are mandatory. Laboratory also requires `--experiment=<name>` and selects `references-repos/plugins/<plugin>/laboratory/v<version>/<name>/`; rolling reads `_meta.lua` and records the SHA. For a rolling branch worktree, pass `--source=/absolute/worktree/path`; this is valid only in rolling mode. Build helpers take exactly `SOURCE OUTPUT`, with an empty output directory, and preserve runtime licenses/assets. Meguru follows its release CI file list, Kobo its `package.sh` runtime list, Ink Away its release-script runtime list, and Panels+ its existing build script. No automatic fetch or native-library compilation is implied: Meguru's bundled native libraries must match the test device.

Installed folders use the upstream canonical `<plugin>.koplugin` name (`panelsplus.koplugin` for Panels+) so plugin discovery/updaters do not have to understand our version naming. Pins and build provenance remain in the deployment manifest. The installer recognizes only that canonical folder and tightly formed `<plugin>__v1_2_3[.koplugin]` variants; it stops on other active names sharing the plugin prefix. Disabled folders remain untouched.

Existing copies must either match a local immutable stable pin exactly or have a valid installer manifest and unchanged payload. Unmanaged/changed copies stop installation; inspect and preserve them before deciding how to migrate. The live Panels+ development tree is always protected, even when installing Panels+. No force flag bypasses these checks.

Payloads containing symlinks, Git metadata or unsupported file types are rejected. Installation stages and verifies the payload, takes an exclusive deployment lock, rechecks old contents, and moves known old copies to `KOReader/.panelsplus-plugin-backups/<transaction>/` before renaming the new copy into place. This removes duplicates from plugin discovery without `rm -rf`. On failure, the transaction attempts to restore old folders; backups and staging remain available for recovery. The script prints backup locations. Close KOReader before invoking installation to avoid loading files during replacement; restart it for the developer's live test.

## Design questions to revisit for each integration

- Is absence of a known hook really No relationship, or merely untested behavior? State the scope of that conclusion.
- Can recognition be asymmetric by version, load order or UI direction? Do not force one visibility label onto both directions.
- Are plugin settings/data persistent across reinstalls? Backups of code do not restore KOReader settings or books; inspect migrations separately when relevant.
- Does the pinned artifact contain all runtime assets, and are native dependencies suitable for the device? Folder/version agreement alone does not prove an artifact is complete.
- Are we testing the actual counterpart or a stub that reproduces our assumptions? Record KOReader version, device and manual results.
