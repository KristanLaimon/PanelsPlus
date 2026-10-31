# Vendored moiré filter

The native libraries behind the **Derainbow** row on the Tone tab. They are not
Meguru's code and they are not built here — they are taken, unmodified, from
another KOReader plugin, and they are the reason that plugin does not have to be
installed for the row to work.

## Where they came from

| | |
|---|---|
| project | [`derainbowify.koplugin`](https://github.com/Euphoriyy/derainbowify.koplugin) |
| version | **0.0.12** — the `version` in its `_meta.lua` |
| licence | **GPL-3.0** — see `LICENSE` in this directory |
| taken from | the `libs/` of that plugin's own release archive |
| unmodified | yes, byte for byte |

`color_detect-<platform>.so` exports `is_page_colored`; `moire_filter-<platform>.so`
exports `remove_moire`, `init_moire_resources` and `cleanup_moire_resources`. Those
four symbols are the whole of what Meguru calls — see `meguru/derainbow.lua`, which
declares the prototypes and is the only file that touches any of this.

## Why it is here rather than required

Meguru used to find these in an installed `derainbowify.koplugin` and answer
"unavailable" when it was not there. Shipping them means the row works on a
device that has never heard of that plugin — at the cost of freezing the pair,
which is a trade `docs/derainbow.md` sets out in full.

**The version above is the contract.** The four prototypes in `meguru/derainbow.lua`
are written against it, and LuaJIT's FFI does not check a signature against the
library it calls: a changed one is undefined behaviour rather than an error. So
when that plugin releases, these files are not updated by anything — a human
decides, re-copies, and re-tests.

## Licence

These binaries are GPL-3.0 and Meguru is AGPL-3.0. The two are compatible:
GPLv3 §13 expressly permits combining a GPLv3 work with an AGPLv3 one, and the
combined work is conveyed under the AGPL. The corresponding source is the
upstream repository above, at version 0.0.12 — that is where these were built
from, and it is the offer this directory makes.

**Do not delete `LICENSE` from this directory.** It is not decoration; it is the
only copy of the terms that travels with these files.
