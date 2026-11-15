# Kobo release references

- [GitHub repository](https://github.com/OGKevin/kobo.koplugin)
- [Latest upstream release](https://github.com/OGKevin/kobo.koplugin/releases/latest) — moving discovery link.
- [Pinned release v0.4.1](https://github.com/OGKevin/kobo.koplugin/releases/tag/v0.4.1) — local reference: [`stable/v0_4_1/`](stable/v0_4_1/).

The pinned release URL was reachable during initial setup.

On 2026-11-15, GitHub still reports v0.4.1 as latest stable (2026-02-20).
Upstream HEAD is `cd2f75d9da57c2a4e4cfa6bbe8ab569e4ba29318` (2026-11-14),
`fix(bluetooth): detach spawned daemons from onboard storage (#244)`;
local rolling remains `baa133794c8567a68068c7337d68d2fbf05631c7`.
This was an availability check only; newer rolling code was not downloaded
or tested. [History](history-changes.md).

`rolling.koplugin/` is the local development Git submodule, pinned by the parent repository. It is not automatically today's upstream HEAD.

Release-tag links are provenance candidates, not evidence of completed compatibility testing. Verify artifact provenance/checksums when refreshing pins; do not silently replace a local pin with today's latest release. Version directory names use underscores.

See [relationships](../../relationships.md) for declarations and exact tested tuples, and [licenses and attribution](../../LICENSES.md) for retained notices. A local reference alone does not establish a passing coexistence or integration test.
