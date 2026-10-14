---
id: new-note-protocol
category: protocols
tags: [protocol, contract, documentation]
aliases: ["New Note Protocol"]
related: [context-index, adr-index]
version: 1.0
status: active
---

# New Note Protocol

## Problem

An unregistered or mis-frontmattered document joins the corpus invisibly: the
navigation hub never links it, the generated indexes omit it, and the checker
cannot resolve its `related` targets or its links. Adding files ad hoc makes the
corpus drift and fails `node validate.js` from the first commit.

## Solution

Before writing, pick the right contract; after writing, register and validate in
the same change.

1. **Pick the document class by folder.**
   - A context doc lives under `docs/context/` (`docs/project.md` is the entry
     point).
   - A procedure lives under `docs/protocols/`.
   - A decision record lives under `adrs/`.
2. **Use that class's frontmatter keys exactly — never mix them.**
   - Context doc: `last_updated`, `status`, `description`, `tags`, `version`
     (optional `related`, `moved_from`).
   - Note/ADR/procedure: `id`, `category`, `tags`, `aliases`, `related`,
     `version`, `status` (optional `supersedes`, `expires_at`, `moved_from`).
   - `category` belongs only to note-class files; context docs must not carry
     it, and note-class files must not carry `last_updated` or `description`.
   - Never leave a key blank; if an optional key has no value, omit it.
3. **Write one H1 plus the seven verbatim sections**, in order: `Problem`,
   `Solution`, `When to use`, `When not to use`, `Examples`, `Common mistakes`,
   `References`. Every heading must contain real content.
4. **Name the file lowercase kebab-case, with `id` equal to the filename stem**
   (`new-note-protocol.md` → `id: new-note-protocol`).
5. **Register the new file in the same change.**
   - A context doc goes in its hub, `docs/context/context-index.md`.
   - An ADR goes in its hub, `adrs/adr-index.md`.
   - A procedure has no hub, so link it from the `README.md` navigation table.
6. **Validate before declaring done**, from the repo root:

```sh
node validate.js
```

Errors block. When files were added or moved, refresh the generated regions:

```sh
node validate.js --write
```

`--write` refreshes the `index.md` / `tag-index.md` regions in existing files; it
never creates a file or fixes metadata.

## When to use

- Adding, renaming, or restructuring any document in the corpus.

## When not to use

- Editing prose inside an already-registered file (validate, but no new
  registration is needed).
- Content that is not part of the corpus (throwaway notes, code comments).

## Examples

Frontmatter for a new procedure:

```yaml
---
id: new-note-protocol
category: protocols
tags: [protocol, contract, documentation]
aliases: ["New Note Protocol"]
related: [context-index]
version: 1.0
status: active
---
```

Register and validate:

```sh
# add the file, then link it from the relevant hub or the README nav table
node validate.js
node validate.js --write   # only if the generated index regions are stale
```

## Common mistakes

- Forgetting to register the note, leaving an orphan or `missing-from-hub`
  error.
- Using a class's keys in the wrong folder — e.g. context-doc keys inside
  `docs/protocols/`, or `category` on a context doc.
- A filename that is not kebab-case, or an `id` that does not equal the stem.
- A `related` target that matches no id, stem, or alias.
- Linking to a file that does not exist yet.
- Leaving any frontmatter key blank instead of omitting it.

## References

- [../project.md](../project.md) — the agent entry point.
- [../context/context-index.md](../context/context-index.md) — the context-doc hub.
- [../../adrs/adr-index.md](../../adrs/adr-index.md) — the ADR hub.
- Adapted from the sibling repository's `new-note-protocol.md` and the framework's
  `protocols/new-note-protocol.md` (external to this corpus, so named, not linked).
