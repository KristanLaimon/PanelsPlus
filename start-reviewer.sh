#!/bin/sh

# This tool is brand-new, I'll document its usage in CONTRIBUTING.md soon.  | Atte: KristanLaimon

cd -- "$(dirname -- "$0")" || exit 1
exec bun tools/panels_revision/revision.ts
