---
id: adr-0002-validate-js-consumer-layout
category: adrs
tags: [adr, validation, tooling]
aliases: ["ADR-0002"]
related: [adr-0001-adopt-documentation-onrails, adr-index]
version: 1.1
status: active
---

# ADR-0002: Adapt the reference validator to the consumer `docs/` layout

## Problem

The reference `validate.js` is written for the methodology repository itself.
Its `classify()` maps root `guidelines/` to context-doc and root `templates/` /
`protocols/` / `adrs/` to their classes, and `collectMarkdown()` walks every
`.md` under the root except `.git/` and `diagrams/`. A consumer repo keeps its
content under `docs/` (`docs/project.md`, `docs/context/`, `docs/protocols/`)
and may contain tooling directories full of third-party `.md` files. Run
verbatim, the validator misclassifies every consumer file and scans vendored /
cache markdown, producing thousands of false errors.

## Solution

Ship a faithful local copy of `validate.js`, adapted in **exactly three** path
mapping points, with every check, severity and the output format untouched:

1. **`collectMarkdown()`** skips dot-directories (`.git`, `.venv`,
   `.pytest_cache`, …) and common build/vendor directories (`SKIP_DIRS`), so
   only the corpus is scanned.
2. **`classify()`** maps the consumer layout onto the same doc classes:
   `docs/project.md` → context-entry; `docs/` and `docs/context/` →
   context-doc; `docs/protocols/` → protocol; `adrs/` → adr. The class →
   contract mapping is unchanged.
3. **`checkCategory()`** compares against the folder's final path segment, so
   the nested `docs/protocols/` folder still matches `category: protocols`.

The copy carries an added header comment documenting this adaptation; this ADR
is its normative record. The copy came from the sibling repository
`tuya-bulb-widget`, which solved the same problem first. Install it by copying
that file to the repository root (byte-for-byte), then confirm with `diff`
against the reference that only the three points above differ.

## When to use

When updating the validator, or when a reviewer asks why the local copy differs
from the upstream reference.

## When not to use

Do not extend the adaptation to weaken or remove a check — any behavioural
change beyond the three points above needs its own ADR.

## Examples

- `node validate.js` from the repo root — strictly read-only; exit 1 when there
  are errors.
- `node validate.js --write` — regenerate the `index.md` / `tag-index.md`
  regions in place (write-if-diff; never creates files).

## Common mistakes

- **Replacing the adapted copy wholesale** with the upstream file —
  reintroduces the misclassification and the vendored-markdown scan.
- **Adapting the checks instead of only the path mapping** — silently changes
  what the corpus enforces.

## References

- [adr-0001-adopt-documentation-onrails.md](adr-0001-adopt-documentation-onrails.md) — the adoption this adaptation serves.
- [adr-index.md](adr-index.md) — the hub these records are registered in.
- [../validate.js](../validate.js) — the adapted copy.
- [../README.md](../README.md) — the corpus entry point that documents the conventions.

## Addendum (2026-10-22) — the sibling repository is retired

The sibling repository this validator was copied from is retired and its source
repository is being deleted, so the "copy that file to the repository root"
instruction in the body above can no longer be followed. The copy in this
repository (`validate.js`) is complete and self-contained: it differs from the
reference validator in the three path-mapping changes recorded above and needs
no external file. The body above is kept as it was written.
