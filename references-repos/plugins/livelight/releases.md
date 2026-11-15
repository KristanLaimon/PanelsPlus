# LiveLight release references

- [Upstream repository](https://github.com/ironicsans/livelight.koplugin).
- [Pinned stable v1.2.0](https://github.com/ironicsans/livelight.koplugin/releases/tag/v1.2.0),
  published 2026-10-18; unchanged payload in [`stable/v1_2_0/`](stable/v1_2_0/).
- [Release ZIP](https://github.com/ironicsans/livelight.koplugin/releases/download/v1.2.0/livelight.koplugin.zip):
  SHA-256 `fbaff3639981b61d6b26242007d5351214d45cc67c4ab17b6c1e26d314dd9ee8`,
  verified against GitHub's release API digest on 2026-11-15.

Canonical rolling submodule: [`rolling.koplugin/`](rolling.koplugin/), clean
`main` at `af2c6bac7a81a2e175319fb57af70d0cb10c31ed`, exactly tag v1.2.0.
Its plugin runtime lives in the nested `livelight.koplugin/` directory.
Stable and rolling runtime files are byte identical.

Upstream `_meta.lua` has no version field. Stable identity comes from the
verified release archive and adjacent [`stable/v1_2_0.sha256`](stable/v1_2_0.sha256),
checked before its compatibility tests; metadata is not patched to invent a
version. The ZIP has only `_meta.lua` and `main.lua`; the upstream repository's
[AGPL-3.0 license](LICENSE) is retained alongside the pins. The runtime build
recipe copies that license from the repository root. Existing deployment
version inference still requires versioned metadata; this task registers
reference tests, not unversioned deployment support.

See [history](history-changes.md) and [relationships](../../relationships.md)
for actual reference-backed results and physical-device limitations.
