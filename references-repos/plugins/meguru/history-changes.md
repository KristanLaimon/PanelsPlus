# Meguru compatibility history

## Current state

2026-11-15 test rerun: all retained stable and current local rolling suites passed; see the test-suite rerun entry below. No runtime changes or installation.

2026-11-15: Stable 1.8.7 added from the verified upstream release ZIP; stable
1.7.1 retained unchanged. Canonical rolling is clean detached HEAD
`7a6e9b8033c228c187855af8fcd4c4580018ac4b`, metadata 1.8.7; sync staged
only its parent pointer. All 14 geometry integration cases pass against each
of the three references. Panels+ runtime is unchanged. Fixture now simulates
screen dimensions consistently with rotation. Complete general suite and lint
also pass after the update (details below). No build/install/commit/push.
Physical reader validation remains pending; no future-version range claimed.

## 2026-11-15 — 01: Refresh stable and rolling compatibility references

Panels+ metadata 1.6.0, `main-nightly` at
`38022f41209497efcd1ac4e58e456c7d45c1f7e0`; initial working changes are the
three formatter/linter exclusion files (`check.sh`, `.styluaignore`,
`.luacheckrc`), preserved. Canonical target
`references-repos/plugins/meguru/rolling.koplugin/` initially has metadata 1.7.1,
branch `main`, clean working tree, base
`8f98bd28f89ce0e769fd71a9218a320577c81618`. Host source pin:
`035e00b21d0286325ef2e8a7e3b6326f340e2ded`. Running KOReader/device version
has not been verified.

The user authorized updating only Meguru rolling and the stable 1.8.7 reference,
then repeating existing compatibility tests. The sync helper stages its selected
submodule pointer; no commit, push or installation is authorized. Source runtime
changes will be limited to those needed by an observed compatibility failure.

Before the update, `./run-tests.sh --compatibility-plugin=meguru` passes 14 tests
against stable 1.7.1 and 14 against the old rolling commit. These load real
Meguru document/spread modules and exercise Panels+ panel selection and bounds;
network, rendering and KOReader UI are fixtures. They do not establish complete
plugin load-order, lifecycle or physical-device coexistence. Earlier evidence
is retained in `../../relationships.md` (2026-10-31 and 2026-11-07 entries).

The complete Panels+ suite before this reference update passed: Python 101 tests
(one skip), Go OCR worker tests, and 13 LuaJIT/native-FFI jobs with zero failures.
Five Lua cases were skipped for pending Safe mappings (EPUB/KEPUB/MOBI,
Horimiya and SHY). `./check.sh` passes with zero warnings/errors in 146 owned
Lua files after excluding external references from formatting/lint.

Release metadata was downloaded from the GitHub release API for tag `v1.8.7`;
artifact provenance, final revisions and post-update results will be recorded
below. Physical reader validation remains pending.

### Update and verification

`./run-sync-submodules.sh --meguru` initially failed because the sandbox makes
Git metadata read-only; the escalated retry updated only Meguru, adding 62
commits from the base above. The helper left detached HEAD and staged the
new parent pointer. Upstream tag v1.8.7 resolves to
`c4d623b1b53583b2178046ba0f85b463c57baa27`; rolling differs only in
`manifest.json`'s version bump. No target source edits or feature branch
were needed for this reference-only update.

Stable release asset `meguru.koplugin.zip` SHA-256:
`877757d520d31b3fd8a2021f85b01268c984e37ab23c96549fe7221faee307ac`,
verified against the GitHub release API digest before extraction. Notices and
bundled libraries were retained unchanged. The actual spread module is byte
identical to 1.7.1 (`80fc2aabd81ba4001151051c3ee271b80a78a6171d2ecea1ffa3d026577357d7`).

The first stable/rolling runs each passed 12 tests and failed the two Auto
landscape cases with `attempt to index a nil value (local 'pair')`. Upstream
now checks `Screen:getWidth() > Screen:getHeight()` instead of rotation parity.
The fixture had updated rotation but inherited portrait dimensions. Added
fixture width/height methods consistent with its rotation; no production
behavior, assertions or accuracy gates were changed.

`./run-tests.sh --compatibility-plugin=meguru` then passed **14 tests each**
for stable 1.7.1, stable 1.8.7 and rolling. Existing scenarios retain both
orders/halves, Always/Auto, crop modes, fallbacks and off-page input.
`PANELSPLUS_LUA='luajit -l ffi' UV_CACHE_DIR=/tmp/panelsplus-uv-cache
./run-tests.sh --quick --strict` passed Python 101 (one skip), Go OCR worker
tests and all 13 Lua/dataset jobs, with the same five pending-mapping skips.
`./check.sh` passed zero warnings/errors in 147 owned Lua files. Commands ran
from the Panels+ root on desktop Linux. Live pixels/input/network/lifecycle
validation remains outside these geometry fixtures; next step is live reader
confirmation if requested. No runtime fix or deployment was necessary.

Final combined reference-update run after registering LiveLight and stable
Ink Away 4.5.0 also passed: Python 101 (one skip), Go worker tests, LuaJIT
645 passed / 0 failed / 5 pending-mapping skips across 13 jobs, all plugin
selectors, 26 workflow checks, and lint 151 owned files. Meguru release payload
was reverified against every ZIP member after formatting: unchanged. Final
details and commands are also recorded in LiveLight history entry 01.

## 2026-11-15 — Test-suite rerun — Panels+ 1.6.0 / meguru 1.8.7

User requested running all tests and checking green. Source: Panels+ 1.6.0,
`main-nightly`, HEAD `b966904dd0ce1937549a57ab5e02e1657a256f85`;
initial working tree clean. Dataset metadata changed during the broader run;
those changes were preserved. Target canonical `rolling.koplugin/`:
`7a6e9b8033c228c187855af8fcd4c4580018ac4b`, detached HEAD, clean working tree and index.
Host source pin: `035e00b21d0286325ef2e8a7e3b6326f340e2ded`;
installed reader/device version was not inspected.

From the Panels+ root, `./run-tests.sh --compatibility-plugin=meguru`
ran retained immutable stable references first, then the existing local rolling
checkout. Passed counts: 1.7.1: 14; 1.8.7: 14; rolling: 14; zero failures or skips in each suite.
These are the existing reference-backed desktop Lua tests with mocked KOReader
services; their established scenario scope and physical-device limits remain
as documented above. No counterpart source changes, updates, builds, deployment,
commits or publication. User-facing defaults unchanged. Live reader validation
was not rerun; further device validation remains separate from this test rerun.

Broader validation completed: `./run-tests.sh --strict --quick` passed all 13
Lua/dataset jobs (plain Lua); Python ran 101 tests with one skip and Go passed.
Separate read-only StyLua and gofmt checks passed; Luacheck reported zero
warnings/errors in 150 files. Workflow shell checks: 26 passed.
