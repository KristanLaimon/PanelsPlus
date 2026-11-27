# Kobo release references

- [GitHub repository](https://github.com/OGKevin/kobo.koplugin)
- [Latest upstream release](https://github.com/OGKevin/kobo.koplugin/releases/latest) — moving discovery link.
- [Pinned release v0.4.1](https://github.com/OGKevin/kobo.koplugin/releases/tag/v0.4.1) — local reference: [`stable/v0_4_1/`](stable/v0_4_1/).

The pinned release URL was reachable during initial setup.

On 2026-11-27, GitHub still reports v0.4.1 as latest stable (2026-02-20).
Canonical rolling now follows `origin/main` at
`607691b84f93831111980f1537c84d4ca695e643`, including Bluetooth connection
handling changes. Each reference passed both Bluetooth page-turn action
integration cases. See [history](history-changes.md).

`rolling.koplugin/` is the local development Git submodule, pinned by the parent repository. It is not automatically today's upstream HEAD.

Release-tag links are provenance candidates, not evidence of completed compatibility testing. Verify artifact provenance/checksums when refreshing pins; do not silently replace a local pin with today's latest release. Version directory names use underscores.

See [relationships](../../relationships.md) for declarations and exact tested tuples, and [licenses and attribution](../../LICENSES.md) for retained notices. A local reference alone does not establish a passing coexistence or integration test.
