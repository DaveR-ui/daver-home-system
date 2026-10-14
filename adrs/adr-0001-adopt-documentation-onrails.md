---
id: adr-0001-adopt-documentation-onrails
category: adrs
tags: [adr, documentation, methodology]
aliases: ["ADR-0001"]
related: [adr-0002-validate-js-consumer-layout, adr-index]
version: 1.0
status: active
---

# ADR-0001: Adopt documentation-onrails as the documentation corpus

## Problem

This repository starts greenfield: the design of the home system exists as a
frozen digest, but there is no documentation structure — no frontmatter
contracts, no navigation index, no slice routing and no validator. A reader
(human or agent) has no fixed entry point, no way to tell a current fact from a
stale one, and no machine check that a new file is registered. The owner asked
for an architecture design plus a documentation corpus, so the corpus shape is
itself a decision to record.

## Solution

Adopt the **documentation-onrails** framework (v1.4) as this repository's
documentation corpus, instantiated in its consumer layout:

- **Root entry**: `README.md` is the single entry point and declares
  `doc_language: en`. `index.md` and `tag-index.md` are generated
  marker-region artifacts; `validate.js` is the zero-dependency check.
- **Content layout**: `docs/project.md` is the agent entry point (nine fixed
  sections); `docs/context/` holds the strategic docs, one topic per file;
  `docs/protocols/` holds the procedures; `adrs/` holds the append-only
  decision records behind `adrs/adr-index.md`.
- **Contracts**: note-class files (`docs/protocols/`, `adrs/`) carry
  `id`, `category`, `tags`, `aliases`, `related`, `version`, `status`;
  context-docs (`README.md`, `docs/project.md`, `docs/context/`) carry
  `last_updated`, `status`, `description`, `tags`, `version`. `category`
  belongs only to note-class files.
- **Generated regions**: `index.md` / `tag-index.md` are refreshed by
  `node validate.js --write`; the check mode is strictly read-only.
- **Machine walk**: `validate.js` is the machine implementation of the review
  catalog (see [adr-0002-validate-js-consumer-layout.md](adr-0002-validate-js-consumer-layout.md)).
- **Language**: `doc_language: en`. The owner speaks Spanish, but the framework
  mandates one language per corpus; the corpus is written in English.

This decision adapts the precedent set by the sibling repository
`tuya-bulb-widget`, which adopted the same framework and consumer layout first.

## When to use

When reading back why this corpus is shaped this way, or when deciding where a
new document belongs.

## When not to use

Do not edit this record to "clarify" it — an ADR is append-only; append an
addendum or supersede it with a successor ADR.

## Examples

- **Added**: `README.md`; `index.md`; `tag-index.md`; `validate.js`;
  `docs/project.md`; the `docs/context/` strategic docs; the `docs/protocols/`
  procedures; `adrs/adr-index.md` plus the ADR series.

## Common mistakes

- **Two entry points.** `README.md` and `docs/project.md` must not both open
  with "start here": README is the human entry, `docs/project.md` is the
  canonical agent-facing file.
- **Writing the corpus in Spanish.** The owner's language is Spanish, but the
  one-language rule fixes the corpus to `en`; the `doc_language` declaration is
  the single place that decides it.

## References

- [adr-0002-validate-js-consumer-layout.md](adr-0002-validate-js-consumer-layout.md) — the validator adaptation this adoption requires.
- [adr-index.md](adr-index.md) — the hub these records are registered in.
- [../docs/project.md](../docs/project.md) — the agent entry point.
- [../validate.js](../validate.js) — the checker this corpus runs.
