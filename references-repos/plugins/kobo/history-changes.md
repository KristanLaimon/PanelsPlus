# Kobo compatibility history

## Current state

2026-11-15 test rerun: all retained stable and current local rolling suites passed; see the test-suite rerun entry below. No runtime changes or installation.

2026-11-15: Latest upstream stable remains v0.4.1 (published 2026-02-20).
Upstream HEAD is `cd2f75d9da57c2a4e4cfa6bbe8ab569e4ba29318`, dated
2026-11-14; local rolling stays at
`baa133794c8567a68068c7337d68d2fbf05631c7` (clean detached HEAD).
The user requested checking for updates; no rolling update or installation
was requested/performed. New upstream code is not tested here.

## 2026-11-15 — 01: Check upstream updates

Panels+ 1.6.0, `main-nightly`, base
`38022f41209497efcd1ac4e58e456c7d45c1f7e0`. Host source pin:
`035e00b21d0286325ef2e8a7e3b6326f340e2ded`. Existing in-progress parent
changes and staged Meguru/LiveLight reference registration are preserved.

Queried GitHub `/repos/OGKevin/kobo.koplugin/releases/latest` and
`/repos/OGKevin/kobo.koplugin/commits/HEAD` without fetching/updating local
refs. Stable v0.4.1 is unchanged upstream. New rolling HEAD is titled
`fix(bluetooth): detach spawned daemons from onboard storage (#244)`;
this availability check is not a compatibility result for that code.

Before this check, `./run-tests.sh --compatibility-plugin=kobo` passed two
actual Bluetooth action-dispatch integration cases per existing stable and
local rolling reference. Host Dispatcher/hardware are fixtures; physical
Bluetooth, plugin discovery and full load-order/lifecycle are unverified.
Earlier evidence remains in `../../relationships.md` (2026-11-07 entry).
No build/install/commit/push; next action is updating/testing rolling only
if requested.

After the combined Meguru/Ink Away/LiveLight registration changes, the same
`./run-tests.sh --compatibility-plugin=kobo` selector was rerun: 2 stable and
2 existing-rolling cases pass, with the same real-action/mock-hardware scope.
No local Kobo reference or runtime file changed.

## 2026-11-15 — Test-suite rerun — Panels+ 1.6.0 / kobo 0.4.1

User requested running all tests and checking green. Source: Panels+ 1.6.0,
`main-nightly`, HEAD `b966904dd0ce1937549a57ab5e02e1657a256f85`;
initial working tree clean. Dataset metadata changed during the broader run;
those changes were preserved. Target canonical `rolling.koplugin/`:
`baa133794c8567a68068c7337d68d2fbf05631c7`, detached HEAD, clean working tree and index.
Host source pin: `035e00b21d0286325ef2e8a7e3b6326f340e2ded`;
installed reader/device version was not inspected.

From the Panels+ root, `./run-tests.sh --compatibility-plugin=kobo`
ran retained immutable stable references first, then the existing local rolling
checkout. Passed counts: 0.4.1: 2; rolling: 2; zero failures or skips in each suite.
These are the existing reference-backed desktop Lua tests with mocked KOReader
services; their established scenario scope and physical-device limits remain
as documented above. No counterpart source changes, updates, builds, deployment,
commits or publication. User-facing defaults unchanged. Live reader validation
was not rerun; further device validation remains separate from this test rerun.

Broader validation completed: `./run-tests.sh --strict --quick` passed all 13
Lua/dataset jobs (plain Lua); Python ran 101 tests with one skip and Go passed.
Separate read-only StyLua and gofmt checks passed; Luacheck reported zero
warnings/errors in 150 files. Workflow shell checks: 26 passed.
