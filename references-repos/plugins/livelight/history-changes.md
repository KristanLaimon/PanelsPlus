# LiveLight compatibility history

## Current state

2026-11-15: Registered stable 1.2.0 and canonical rolling submodule, clean
`main` at `af2c6bac7a81a2e175319fb57af70d0cb10c31ed` (exact v1.2.0 tag).
Both pass 18 reference-backed integration cases using the existing Panels+
adapter without runtime changes. Rolling's runtime is nested at
`rolling.koplugin/livelight.koplugin/`. No installation/commit/publication;
registration staged `.gitmodules` and its pointer, leaving other changes
unstaged. Physical light/input and level-box rendering remain unverified.

## 2026-11-15 — 01: Register existing LiveLight gesture support

User requested registering https://github.com/ironicsans/livelight.koplugin
and verifying the existing manual compatibility fix. Source: Panels+ 1.6.0,
`main-nightly`, base `38022f41209497efcd1ac4e58e456c7d45c1f7e0`. Ongoing
formatter/lint and Meguru reference/fixture changes are preserved. Host pin:
`035e00b21d0286325ef2e8a7e3b6326f340e2ded`; physical device/runtime unverified.

Existing `src/plugins-support/livelight.lua` lets LiveLight's complete edge
slide reach the reader, including when the image is pannable. Classify the
intended relation as Panels+ → LiveLight, Not visual: Panels+ adds no new UI.
LiveLight's own brightness/warmth feedback is its existing UI. Prior tests
use invented touch-zone handlers and are unit coverage only; they do not
establish counterpart integration. New tests will load the actual selected
target's registration and gesture handling, with host/device services mocked.
No target runtime changes, build, installation or publication requested.

GitHub reports latest release v1.2.0, published 2026-10-18. Initial submodule
registration was blocked by read-only Git metadata; retried with escalation.
Stable artifact digest and exact rolling revision/results are recorded below
when verified. Live reader/input/lighting validation remains pending.

### Registration and tests

Canonical source: upstream main/tag v1.2.0 at the SHA above, no local edits.
Stable release ZIP SHA-256:
`fbaff3639981b61d6b26242007d5351214d45cc67c4ab17b6c1e26d314dd9ee8`,
verified against GitHub's API digest. Its `_meta.lua` and `main.lua` are byte
identical to rolling's nested runtime. Upstream omits metadata version and
ZIP license; stable identity is recorded in `releases.md` and enforced using
the adjacent `stable/v1_2_0.sha256`. The unmodified upstream root AGPL license
is retained at `LICENSE`. Stable payload files are not patched.

Registered selector aliases and nested runtime path in compatibility tooling,
and a runtime builder retaining the root license. Existing deployment version
inference requires a metadata version and is not extended here: no deploy
support or live installation is claimed for this unversioned target.

`./run-tests.sh --compatibility-plugin=livelight` runs stable before rolling,
**18 passed / 0 failed / 0 skipped per reference**, from the Panels+ root using
desktop Lua. The fixture loads actual target `main.lua`, calls actual `init`
and captures its four registered touch zones; Panels+'s real dispatch reaches
actual handlers. Tests assert brightness/warmth values and resume-state saves,
pan/release/swipe/multiswipe while pannable and unzoomed, movement off-edge,
quick flicks, disabled/unused/horizontal/center gestures, missing warmth,
suspend timer cleanup, and absent frontlight/touch capabilities. No failures
were observed before a fix; no runtime fix was needed. UI registration,
gesture-range matching, screen, power hardware and timers are fixtures;
`show_level=false` intentionally leaves actual level-box rendering untested.
These are gesture integration checks, not full plugin lifecycle/load-order or
physical-device certification. Existing Panels+ absence/unit tests remain.

User-facing defaults are unchanged: LiveLight's settings choose enabled edges
and controls; Panels+ only passes claimed gestures through. Next action is
optional live reader confirmation of lighting while zoomed. No builds or
installation requested; a recipe smoke-check may create only a `/tmp` payload.

### Final verification of the combined reference update

After formatting the new fixture/specs, all four plugin selectors passed:
Meguru 14/14/14 (1.7.1, 1.8.7, rolling); Ink Away 5/44/44 (4.4.0,
4.5.0, rolling); LiveLight 18/18; existing Kobo 2/2. Kobo's newer upstream
rolling remains deliberately untested/unmodified, as recorded in its history.

`PANELSPLUS_LUA='luajit -l ffi' UV_CACHE_DIR=/tmp/panelsplus-uv-cache
./run-tests.sh --quick --strict` passed Python 101 (one skip), Go worker tests,
and all 13 Lua/dataset jobs: **645 passed, zero failed, five skipped** for
pending Safe mappings. `./check.sh` passed **151 files, zero warnings/errors**;
`bash tests/plugin_workflow_spec.sh` passed **26 checks**, including accepted
unversioned pins, rejection of a tampered pin, and scoped LiveLight syncing.
Shell syntax and whitespace checks passed. A `/tmp` builder smoke-check
confirmed exact copies of both runtime files and the upstream license; it did
not install a plugin or retain a project build artifact. All three newly pinned
release payloads (Meguru, Ink Away and LiveLight) were compared byte-for-byte
and by complete file set to their original ZIPs after `check.sh`: unchanged.
Old stable references and all target runtime working trees remain unchanged.
