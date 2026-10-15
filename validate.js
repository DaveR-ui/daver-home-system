#!/usr/bin/env node
/*
 * validate.js — C1 minimum-viable validator for a DocumentationAsAService corpus.
 *
 * Plain, zero-dependency Node.js (CommonJS). No package.json, no npm install.
 *
 *   node validate.js          -> check mode: STRICTLY read-only, never writes.
 *   node validate.js --write  -> regenerate the two generated regions IN EXISTING
 *                                FILES ONLY (never creates index.md / tag-index.md),
 *                                write-if-diff, then run the full check.
 *
 * Output: one finding per line `path:line — check-name: message` (POSIX relative
 * paths), then `N error(s), M warning(s) — files scanned: K`. Exit 1 iff N > 0.
 * --write's `wrote: <path>` notices go to STDERR so STDOUT keeps exactly the
 * documented findings + summary shape.
 *
 * Link-scan exemptions: ``` fenced blocks are exempt from wikilink scanning,
 * and wikilinks inside inline code spans (`[[stem]]`) are skipped too — the
 * justification is "a citation is not a link; mirrors editor rendering". The
 * inline-code exemption applies to WIKILINKS ONLY: markdown links stay live
 * even when backticked (the anti-smuggling rule), and secret scanning keeps
 * the fenced-blocks-only exemption (inline code can still hide a secret).
 *
 * This script is the MACHINE IMPLEMENTATION of the catalog in
 * guidelines/04-validation.md, under the contract of guidelines/02-document-contract.md.
 * Repo precedence (guidelines/00): contract 02 > guideline 04 > this tool.
 * Where this file disagrees with the 02/04 prose, the PROSE WINS and this
 * file carries the bug.
 *
 * ---------------------------------------------------------------------------
 * CONSUMER ADAPTATION (documentation-onrails v1.4 -> tuya-bulb-widget).
 *
 * This is a faithful copy of the reference validator, adapted ONLY for the
 * consumer layout prescribed by the playbook (docs/project.md + docs/context/ +
 * docs/protocols/ at the repo root). The reference copy was written for the
 * methodology repo itself (guidelines/, templates/, protocols/, adrs/ at root)
 * and would misclassify every file in a consumer tree. Exactly three changes:
 *
 *   1. collectMarkdown() skips dot-directories (.git, .venv, .pytest_cache, …)
 *      and common build/vendor directories, so a consumer repo's virtualenv and
 *      cache never pollute the corpus scan.
 *   2. classify() maps the consumer folders onto the same doc classes:
 *      docs/project.md -> context-entry, docs/ and docs/context/ -> context-doc,
 *      docs/protocols/ -> protocol, adrs/ -> adr. The class -> contract mapping
 *      is untouched.
 *   3. checkCategory() compares against the folder's final path segment, so the
 *      nested docs/protocols/ folder still matches category "protocols".
 *
 * Every check, the severity model, the generated-region renderer, the secret
 * catalog and the output format are byte-identical in behaviour to the
 * reference. See adrs/adr-0002-validate-js-consumer-layout.md.
 * ---------------------------------------------------------------------------
 *
 * Catalog (see guidelines/04 for the normative text):
 *   ERRORS    metadata-outside-contract, non-kebab-case-name, duplicate-ids,
 *             dangling-related-target, dangling-link, orphan-note, missing-from-hub,
 *             stale-generated-index, secret-in-prose
 *   WARNINGS  no-h1, category-mismatch-folder, near-duplicate-body
 *
 * Reference implementation: small, readable, commented. No cleverness.
 */
'use strict';

const fs = require('fs');
const path = require('path');

// ----------------------------- Configuration ------------------------------

const ROOT = __dirname; // repo root = directory containing validate.js
const WRITE_MODE = process.argv.slice(2).includes('--write');
const DASH = '\u2014';  // — in output; written as an escape so the source is pure ASCII
const ELL = '\u2026';   // … in secret redaction sketches

// Lifecycle enum for `status` (both contracts). "archived" notes live outside
// the served root, so it is NOT a valid status value here (guidelines/03 §1).
const STATUS_ENUM = new Set(['draft', 'active', 'superseded', 'expired']);

// Note-family contract: 7 required + 3 optional (guidelines/02 §1).
const NOTE_REQUIRED = ['id', 'category', 'tags', 'aliases', 'related', 'version', 'status'];
const NOTE_OPTIONAL = ['supersedes', 'expires_at', 'moved_from'];
// Context-doc contract: 5 required + 2 optional (guidelines/02 §4).
const CTX_REQUIRED = ['last_updated', 'status', 'description', 'tags', 'version'];
const CTX_OPTIONAL = ['related', 'moved_from'];
// Root README.md = context-doc entry point + one extra required key.
const ENTRY_EXTRA = 'doc_language';

// Which keys must be scalars per contract (everything else present is a list).
const NOTE_SCALARS = new Set(['id', 'category', 'version', 'status', 'supersedes', 'expires_at']);
const CTX_SCALARS = new Set(['last_updated', 'status', 'description', 'version', ENTRY_EXTRA]);

// Root generated artifacts: relative path -> region marker name.
const GENERATED_ARTIFACTS = [
  { rel: 'index.md', marker: 'index' },
  { rel: 'tag-index.md', marker: 'tags' },
];

const NOTE_CLASSES = new Set(['note', 'hub', 'adr', 'template', 'protocol']);

// The lowercase kebab-case naming rule (guidelines/02 §3) is enforced from the
// same shape as the `id` slug (§1) — hence SLUG_RE below. Conventional all-caps
// root filenames are the one documented exemption; README.md is the only file it
// covers among the scanned .md set (LICENSE and friends are never collected).
const NAME_EXEMPT = new Set(['README.md']);

// Consumer adaptation (2/3a): directories never walked by the corpus scan. Dot
// directories (.git, .venv, .pytest_cache, .mypy_cache, …) cover a consumer
// repo's tooling; the rest are common build/vendor outputs. `app` is the
// application source tree (Flutter): it is not part of the documentation corpus
// and ships its own generated README.md files.
const SKIP_DIRS = new Set(['app', 'diagrams', 'node_modules', '__pycache__', 'dist', 'build', 'site-packages']);

// ----------------------------- File collection & classification ------------------------------

/** Recursively collect all .md files under dir as sorted POSIX relative paths.
 *  `.git` and any folder named `diagrams` are skipped entirely; every non-.md
 *  file (LICENSE, .gitignore, validate.js, html, …) is never collected.
 *  Consumer adaptation: dot-directories and SKIP_DIRS are skipped too, so a
 *  consumer virtualenv / cache never joins the corpus. */
function collectMarkdown(dir, out) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    if (ent.name.startsWith('.') || SKIP_DIRS.has(ent.name)) continue;
    const abs = path.join(dir, ent.name);
    if (ent.isDirectory()) collectMarkdown(abs, out);
    else if (ent.isFile() && ent.name.toLowerCase().endsWith('.md')) {
      out.push(path.relative(ROOT, abs).split(path.sep).join('/'));
    }
  }
  out.sort();
}

/** File classification, path-based (per guidelines/01 + 02). Order matters: README.md ->
 *  context-entry; root index.md/tag-index.md -> generated artifact (BEFORE the
 *  hub rule, else tag-index.md looks like a hub by name); any `*-index.md` ->
 *  hub (note contract, body not validated); consumer folders -> context-doc;
 *  adrs/ | templates/ | protocols/ -> adr | template | protocol; rest -> note.
 *  Consumer adaptation: docs/project.md is the second context-entry, docs/ and
 *  docs/context/ are context-docs, docs/protocols/ is the protocol class. */
function classify(rel) {
  if (rel === 'README.md' || rel === 'docs/project.md') return 'context-entry';
  if (rel === 'index.md' || rel === 'tag-index.md') return 'generated';
  if (rel.slice(rel.lastIndexOf('/') + 1).endsWith('-index.md')) return 'hub';
  const dir = rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : '';
  if (dir === 'guidelines' || dir === 'docs' || dir === 'docs/context') return 'context-doc';
  if (dir === 'adrs') return 'adr';
  if (dir === 'templates') return 'template';
  if (dir === 'protocols' || dir === 'docs/protocols') return 'protocol';
  return 'note';
}

// ----------------------------- Minimal YAML-subset frontmatter parser ------------------------------

function unquote(s) {
  if (s.length >= 2 && ((s[0] === '"' && s.endsWith('"')) || (s[0] === "'" && s.endsWith("'")))) {
    return s.slice(1, -1);
  }
  return s;
}

/** Parse frontmatter between the FIRST pair of `---` lines. Returns
 *  { entries: Map<key, entry>, end } or null. entry.kind: 'scalar' (.value) |
 *  'list' (.items) | 'blank'; each entry carries its key line (1-based).
 *  Rules: split at the FIRST colon (values may contain colons); `key: [a, b]`
 *  inline list; `key:` + following `- item` lines block list (column 0 allowed);
 *  lines whose first non-space char is `#` are COMMENTS and skipped — the
 *  shipped template's commented `# supersedes:` / `# expires_at:` /
 *  `# moved_from:` examples must NOT parse as blanks; quoted scalars unquoted. */
function parseFrontmatter(lines) {
  if (lines.length === 0 || lines[0].trim() !== '---') return null;
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trim() === '---') { end = i; break; }
  }
  if (end < 0) return null;

  const entries = new Map();
  let i = 1;
  while (i < end) {
    const raw = lines[i];
    const t = raw.trim();
    if (t === '' || t.startsWith('#')) { i++; continue; }
    const m = /^([^:\s][^:]*):\s*(.*)$/.exec(raw);
    if (!m) { i++; continue; } // outside the subset — ignore silently
    const key = m[1];
    const rest = m[2].trim();
    if (rest === '') {
      const items = [];
      let j = i + 1;
      while (j < end) {
        const s = lines[j].trim();
        if (!s.startsWith('-') || s.startsWith('#')) break;
        items.push(unquote(s.replace(/^-\s*/, '').trim()));
        j++;
      }
      entries.set(key, items.length ? { kind: 'list', items, line: i + 1 } : { kind: 'blank', line: i + 1 });
      i = j;
    } else if (rest.startsWith('[') && rest.endsWith(']')) {
      const inner = rest.slice(1, -1).trim();
      entries.set(key, { kind: 'list', items: inner === '' ? [] : inner.split(',').map((x) => unquote(x.trim())), line: i + 1 });
      i++;
    } else {
      entries.set(key, { kind: 'scalar', value: unquote(rest), line: i + 1 });
      i++;
    }
  }
  return { entries, end };
}

// ----------------------------- Small helpers ------------------------------

function isValidDate(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(s));
  if (!m) return false;
  return m[2] >= 1 && m[2] <= 12 && m[3] >= 1 && m[3] <= 31;
}
function isValidVersion(s) { return /^\d+(\.\d+){0,2}$/.test(String(s).trim()); } // MAJOR[.MINOR[.PATCH]]
// `id` slug format (guidelines/02 §1: present, unique, slug format):
// lowercase alphanumeric segments joined by single hyphens.
const SLUG_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
function todayISO() {
  const d = new Date(), p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}
function ciCompare(a, b) { // case-insensitive alphabetical, code-point tie-break
  const la = a.toLowerCase(), lb = b.toLowerCase();
  return la < lb ? -1 : la > lb ? 1 : a < b ? -1 : a > b ? 1 : 0;
}

/** Boolean mask, true = line is inside a ```/~~~ fenced block. Fence content
 *  is EXEMPT from wikilink and secret scanning (the guidelines are full of
 *  example fences). The fence-toggle line itself counts as inside. */
function fenceMask(lines) {
  const mask = new Array(lines.length).fill(false);
  let open = false;
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith('```') || t.startsWith('~~~')) { open = !open; mask[i] = true; continue; }
    mask[i] = open;
  }
  return mask;
}

/** [start, end) spans of inline code (backtick spans) on a SINGLE, already
 *  known-non-fenced line. A wikilink written inside such a span — `[[stem]]` —
 *  is a CITATION of the syntax, not a live link (mirroring how editors render
 *  it), so wikilink scanning skips it.
 *  SIMPLIFICATION (documented, acceptable for a reference impl): spans are
 *  matched as a pair of backtick runs with no backtick inside, non-greedy, on
 *  one line. Doubled-backtick spans (``code``) degrade to their inner single-
 *  backtick span (still exempting what they contain) and multi-line spans are
 *  not recognized — both fail toward the safe side of this check. */
function inlineCodeSpans(line) {
  const spans = [];
  for (const m of line.matchAll(/`([^`]*)`/g)) spans.push([m.index, m.index + m[0].length]);
  return spans;
}

// ----------------------------- Loading & the ONE resolver ------------------------------

/** One resolver, case-insensitive (guidelines/02 §3): a target string resolves to a file
 *  if it matches its id OR filename stem OR any alias OR (for markdown paths)
 *  relative path. First-wins over rel-sorted files keeps it deterministic. */
function buildResolver(docs) {
  const byToken = new Map(); // lowercase token -> rel
  const norm = (x) => String(x).trim().toLowerCase().replace(/\.md$/, '').replace(/\/$/, '');
  for (const d of docs) {
    const add = (tok) => { const k = norm(tok); if (k && !byToken.has(k)) byToken.set(k, d.rel); };
    add(d.rel); add(d.stem);
    if (d.id) add(d.id);
    for (const a of d.aliases) add(a);
  }
  return {
    resolve(token) {
      const rel = byToken.get(norm(token));
      return rel === undefined ? null : rel;
    },
  };
}

function loadDocs() {
  const rels = [];
  collectMarkdown(ROOT, rels);
  return rels.map((rel) => {
    const content = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    const lines = content.split(/\r?\n/);
    const doc = {
      rel,
      name: rel.slice(rel.lastIndexOf('/') + 1),
      dir: rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : '',
      stem: rel.slice(rel.lastIndexOf('/') + 1).replace(/\.md$/i, ''),
      content, lines, mask: fenceMask(lines), cls: classify(rel),
    };
    const fm = parseFrontmatter(doc.lines);
    doc.fm = fm;
    doc.entries = fm ? fm.entries : new Map();
    const idE = doc.entries.get('id');
    doc.id = idE && idE.kind === 'scalar' && idE.value ? idE.value.trim() : null;
    const alE = doc.entries.get('aliases');
    doc.aliases = alE && alE.kind === 'list' ? alE.items.filter((x) => x !== '') : [];
    return doc;
  });
}

// ----------------------------- Findings machinery ------------------------------

const findings = []; // {severity, path, line, name, msg}
function err(p, l, name, msg) { findings.push({ severity: 'error', path: p, line: l, name, msg }); }
function warn(p, l, name, msg) { findings.push({ severity: 'warning', path: p, line: l, name, msg }); }

// ----------------------------- ERROR 1: metadata-outside-contract ------------------------------

/** Per file class: required keys present + well-typed, status in enum, dates
 *  YYYY-MM-DD, optional keys valid-or-absent, NEVER blank. Present-but-blank
 *  optional key = error (guidelines/02 iron rules). Unknown keys are flagged
 *  too — the check name literally reads "metadata OUTSIDE contract"
 *  (interpretation; see report). */
function checkMetadata(d) {
  if (d.cls === 'generated') return; // artifacts carry no frontmatter contract
  const isNote = NOTE_CLASSES.has(d.cls);
  const required = isNote ? NOTE_REQUIRED
    : d.cls === 'context-entry' ? [...CTX_REQUIRED, ENTRY_EXTRA] : CTX_REQUIRED;
  const optional = isNote ? NOTE_OPTIONAL : CTX_OPTIONAL;
  const scalars = isNote ? NOTE_SCALARS : CTX_SCALARS;
  const e = d.entries;

  const typeError = (k, ent, msg) => err(d.rel, ent.line, 'metadata-outside-contract', msg);
  const checkOne = (k, ent, label) => {
    if (ent.kind === 'blank') return typeError(k, ent, `${label} key '${k}' is present but blank${label === 'optional' ? ' — omit it entirely' : ''}`);
    const mustBeScalar = scalars.has(k) || k === 'description';
    if (mustBeScalar && ent.kind !== 'scalar') return typeError(k, ent, `key '${k}' must be a scalar`);
    if (!mustBeScalar && ent.kind !== 'list') return typeError(k, ent, `key '${k}' must be a list`);
    if (ent.kind !== 'scalar') return;
    const v = ent.value;
    if (k === 'version' && !isValidVersion(v)) typeError(k, ent, `version '${v}' is not a number`);
    // Note-class only: id must be a slug (context-docs carry no id).
    if (k === 'id' && isNote && !SLUG_RE.test(String(v).trim())) typeError(k, ent, `id '${v}' is not a slug (expected lowercase alphanumerics joined by single hyphens)`);
    if ((k === 'last_updated' || k === 'expires_at') && !isValidDate(v)) typeError(k, ent, `${k} '${v}' is not YYYY-MM-DD`);
    if (k === 'status' && !STATUS_ENUM.has(String(v).trim())) typeError(k, ent, `status '${v}' not in {draft, active, superseded, expired}`);
  };

  for (const k of required) {
    const ent = e.get(k);
    if (!ent) err(d.rel, 1, 'metadata-outside-contract', `required key '${k}' is missing for ${d.cls}`);
    else checkOne(k, ent, 'required');
  }
  for (const k of optional) {
    const ent = e.get(k);
    if (ent) checkOne(k, ent, 'optional');
  }
  for (const [k, ent] of e) {
    if (!required.includes(k) && !optional.includes(k)) {
      err(d.rel, ent.line, 'metadata-outside-contract', `key '${k}' is not part of the ${d.cls} contract`);
    }
  }
}

// ----------------------------- ERROR 2: duplicate-ids ------------------------------

function checkDuplicateIds(docs) {
  const seen = new Map(); // id -> first doc claiming it
  for (const d of docs) {
    if (!NOTE_CLASSES.has(d.cls) || !d.id) continue;
    const ent = d.entries.get('id');
    if (seen.has(d.id)) {
      err(d.rel, ent.line, 'duplicate-ids', `id '${d.id}' already claimed by ${seen.get(d.id)}`);
    } else {
      seen.set(d.id, d.rel);
    }
  }
}

// ----------------------------- Graph edges + ERROR 3 (dangling-related-target) + ERROR 4 (dangling-link) ------------------------------

/** Builds out/inn edge sets (related + wikilinks + resolvable markdown links,
 *  self-edges dropped) and mdOut (markdown-link-only, for the hub check), while
 *  reporting dangling-related-target and dangling-link errors. Ignored:
 *  http(s)/mailto/data/ftp, pure #fragments; #fragment stripped before the
 *  existence check; directory targets OK; paths resolve to the containing file. */
function collectEdges(docs, resolver) {
  const out = new Map(), inn = new Map(), mdOut = new Map();
  for (const d of docs) { out.set(d.rel, new Set()); inn.set(d.rel, new Set()); mdOut.set(d.rel, new Set()); }
  const link = (from, to) => { if (to && to !== from) { out.get(from).add(to); inn.get(to).add(from); } };
  const relSet = new Set(docs.map((d) => d.rel));

  for (const d of docs) {
    // related: semantic vocabulary, resolved through the ONE resolver.
    const rel = d.entries.get('related');
    if (rel && rel.kind === 'list') {
      for (const item of rel.items) {
        if (!item) continue;
        const hit = resolver.resolve(item);
        if (!hit) err(d.rel, rel.line, 'dangling-related-target', `related entry '${item}' resolves to no document (ids, stems and aliases all missed)`);
        else link(d.rel, hit);
      }
    }
    if (d.cls === 'generated') continue; // artifact preambles are not link sources

    const start = d.fm ? d.fm.end + 1 : 0;
    for (let i = start; i < d.lines.length; i++) {
      if (d.mask[i]) continue; // EXEMPT inside fences
      const line = d.lines[i];

      // (a) wikilinks [[stem]] or [[stem|display]] — additionally skipped when
      // fully inside an inline code span: `[[stem]]` cites the syntax, it does
      // not link it. (Markdown links in (b) are NOT inline-code-exempt, and
      // secret scanning keeps fenced-blocks-only exemption — see header.)
      const spans = inlineCodeSpans(line);
      for (const m of line.matchAll(/\[\[([^\[\]|\n]+)(?:\|[^\[\]\n]*)?\]\]/g)) {
        if (spans.some(([s, e]) => s <= m.index && m.index + m[0].length <= e)) continue;
        const token = m[1].trim();
        const hit = resolver.resolve(token);
        if (!hit) err(d.rel, i + 1, 'dangling-link', `wikilink [[${token}]] resolves to no document`);
        else link(d.rel, hit);
      }

      // (b) relative markdown links [t](path)
      for (const m of line.matchAll(/\[[^\]]*\]\(([^)\s]+)\)/g)) {
        let target = m[1].trim();
        if (!target || target.startsWith('#')) continue;
        if (/^(?:https?:|mailto:|data:|ftp:)/i.test(target)) continue;
        target = target.split('#')[0];
        if (!target) continue;
        const abs = path.resolve(ROOT, d.dir, target);
        if (!fs.existsSync(abs)) {
          err(d.rel, i + 1, 'dangling-link', `markdown link target '${m[1].trim()}' does not exist`);
          continue;
        }
        const relT = path.relative(ROOT, abs).split(path.sep).join('/');
        const hit = relSet.has(relT) ? relT : resolver.resolve(target);
        if (hit) { link(d.rel, hit); mdOut.get(d.rel).add(hit); }
      }
    }
  }
  return { out, inn, mdOut };
}

// ----------------------------- ERROR 5: orphan-note ------------------------------

/** A note-class file (note/hub/adr/template/protocol) with ZERO non-self
 *  edges in both directions. EXEMPTION: context-docs (README +
 *  guidelines/) are exempt — they are entry furniture reached through the
 *  entry-point navigation table, not graph content. Generated artifacts and
 *  skipped files are exempt too. */
function checkOrphans(docs, out, inn) {
  for (const d of docs) {
    if (!NOTE_CLASSES.has(d.cls)) continue;
    if (out.get(d.rel).size === 0 && inn.get(d.rel).size === 0) {
      err(d.rel, 1, 'orphan-note', 'note has zero resolved non-self edges in both directions');
    }
  }
}

// ----------------------------- ERROR 6: missing-from-hub ------------------------------

/** - note in a folder containing a hub -> must be referenced BY THE HUB
 *    (wikilink or markdown link to its stem/id/path, i.e. any resolvable edge).
 *  - note in a hub-less folder (templates/, protocols/, root-level notes)
 *    -> must be referenced by a resolvable MARKDOWN link in README.md.
 *  - hubs themselves must also be referenced by a resolvable markdown link in
 *    README.md. */
function checkHubMembership(docs, out, mdOut) {
  const readmeLinks = mdOut.get('README.md') || new Set();
  const hubByDir = new Map();
  for (const d of docs) if (d.cls === 'hub') hubByDir.set(d.dir, d);
  for (const d of docs) {
    if (!NOTE_CLASSES.has(d.cls)) continue;
    if (d.cls === 'hub') {
      if (!readmeLinks.has(d.rel)) {
        err(d.rel, 1, 'missing-from-hub', 'hub is not referenced by a resolvable markdown link in README.md');
      }
      continue;
    }
    const hub = hubByDir.get(d.dir);
    if (hub) {
      if (!out.get(hub.rel).has(d.rel)) {
        err(d.rel, 1, 'missing-from-hub', `note is not referenced by hub ${hub.rel} (wikilink or markdown link)`);
      }
    } else if (!readmeLinks.has(d.rel)) {
      err(d.rel, 1, 'missing-from-hub',
        'note sits in a hub-less folder and is not referenced by a resolvable markdown link in README.md');
    }
  }
}

// ----------------------------- ERROR 9: non-kebab-case-name ------------------------------

/** Every scanned file and every folder that holds one must be lowercase
 *  kebab-case (guidelines/02 §3). README.md is the single documented
 *  conventional exemption (NAME_EXEMPT). The `id` slug (§1) shares the same
 *  shape, so both use SLUG_RE. Folders are reported once, on the folder path. */
function checkNames(docs) {
  const dirs = new Set();
  for (const d of docs) {
    if (d.dir) dirs.add(d.dir);
    if (!NAME_EXEMPT.has(d.name) && !SLUG_RE.test(d.stem)) {
      err(d.rel, 1, 'non-kebab-case-name', `filename '${d.name}' is not lowercase kebab-case (guidelines/02 §3)`);
    }
  }
  for (const dir of [...dirs].sort()) {
    const bad = dir.split('/').find((seg) => !SLUG_RE.test(seg));
    if (bad) err(dir, 1, 'non-kebab-case-name', `folder '${bad}/' is not lowercase kebab-case (guidelines/02 §3)`);
  }
}

// ----------------------------- Generated region rendering (deterministic — byte-stable for unchanged input) ------------------------------

function classCounts(docs) {
  const c = { ctx: 0, note: 0, hub: 0, adr: 0, tmpl: 0, proto: 0 };
  for (const d of docs) {
    if (d.cls === 'context-entry' || d.cls === 'context-doc') c.ctx++;
    else if (d.cls === 'hub') c.hub++;
    else if (d.cls === 'adr') c.adr++;
    else if (d.cls === 'template') c.tmpl++;
    else if (d.cls === 'protocol') c.proto++;
    else if (d.cls === 'note') c.note++;
  }
  return c;
}
function treeLabel(d) {
  return { 'context-entry': 'context-doc (entry)', 'context-doc': 'context-doc', generated: 'generated',
    hub: 'hub', adr: 'adr', template: 'template', protocol: 'protocol' }[d.cls] || 'note';
}
function idSuffix(d) { return NOTE_CLASSES.has(d.cls) && d.id ? `, id: \`${d.id}\`` : ''; }

/** Body of the index.md "index" region (snapshot line added at write time).
 *  Root files first: README.md then tag-index.md (index.md never lists itself;
 *  validate.js is not scanned so never appears), rest of the root sorted; then
 *  folders sorted alphabetically, files sorted inside. Folders without any
 *  scanned .md (e.g. diagrams/) are not listed. */
function renderIndexRegion(docs) {
  const L = [];
  const c = classCounts(docs);
  L.push('## Generated index', '', '### Overview', '');
  L.push(`- Markdown files: ${docs.length}`); // total scanned = every walked .md incl. artifacts
  L.push(`- Context docs: ${c.ctx} | Notes: ${c.note} | Hubs: ${c.hub} | adrs: ${c.adr} | templates: ${c.tmpl} | protocols: ${c.proto}`);
  L.push('', '### Tree', '');
  const fmt = (d, indent) => `${indent}- ${d.name} ${DASH} ${treeLabel(d)}${idSuffix(d)}`;
  for (const rel of ['README.md', 'tag-index.md']) {
    const d = docs.find((x) => x.rel === rel);
    if (d) L.push(fmt(d, ''));
  }
  const rootRest = docs.filter((d) => d.dir === '' && d.rel !== 'index.md' && d.rel !== 'README.md' && d.rel !== 'tag-index.md')
    .sort((a, b) => ciCompare(a.name, b.name));
  for (const d of rootRest) L.push(fmt(d, ''));
  const dirs = [...new Set(docs.filter((d) => d.dir !== '').map((d) => d.dir))].sort(ciCompare);
  for (const dir of dirs) {
    L.push(`- ${dir}/`);
    for (const d of docs.filter((x) => x.dir === dir).sort((a, b) => ciCompare(a.name, b.name))) {
      L.push(fmt(d, '  '));
    }
  }
  return L;
}

/** Body of the tag-index.md "tags" region: one line per distinct tag, tags
 *  sorted; refs sorted; ref = filename stem for context-docs, id (fallback
 *  stem) for note-class files; source = `tags` frontmatter of every scanned
 *  md that has frontmatter. */
function renderTagsRegion(docs) {
  const tagMap = new Map();
  for (const d of docs) {
    const ent = d.entries.get('tags');
    if (!ent || ent.kind !== 'list') continue;
    const ref = NOTE_CLASSES.has(d.cls) && d.id ? d.id : d.stem;
    for (const t of ent.items) {
      const k = String(t).trim().toLowerCase();
      if (!k) continue;
      if (!tagMap.has(k)) tagMap.set(k, new Set());
      tagMap.get(k).add(ref);
    }
  }
  const L = ['## Generated tag index', ''];
  for (const tag of [...tagMap.keys()].sort()) {
    L.push(`- **${tag}** ${DASH} ${[...tagMap.get(tag)].sort().join(', ')}`);
  }
  return L;
}

const SNAPSHOT_RE = /^<!-- snapshot: \d{4}-\d{2}-\d{2} -->$/;
function extractRegion(lines, marker) {
  const b = lines.findIndex((l) => l.trim() === `<!-- BEGIN GENERATED: ${marker} -->`);
  const e = lines.findIndex((l) => l.trim() === `<!-- END GENERATED: ${marker} -->`);
  if (b < 0 || e <= b) return null;
  return { beginLine: b, endLine: e, body: lines.slice(b + 1, e) };
}
const stripSnapshots = (body) => body.filter((l) => !SNAPSHOT_RE.test(l.trim()));

// ----------------------------- ERROR 7: stale-generated-index (+ the --write half) ------------------------------

/** Check: artifact missing -> error at file line 1; markers missing -> error;
 *  body mismatch -> error at the BEGIN-marker line. Comparison strips the
 *  snapshot line from BOTH stored and recomputed bodies: identical-except-date
 *  = FRESH. */
function checkGeneratedRegions(docs, bodies) {
  for (const art of GENERATED_ARTIFACTS) {
    const d = docs.find((x) => x.rel === art.rel);
    const body = bodies.get(art.rel);
    if (!d) {
      err(art.rel, 1, 'stale-generated-index',
        `generated artifact ${art.rel} is missing (create file + marker pair, then run: node validate.js --write)`);
      continue;
    }
    const region = extractRegion(d.lines, art.marker);
    if (!region) {
      err(art.rel, 1, 'stale-generated-index', `${art.rel} is missing its BEGIN/END GENERATED: ${art.marker} marker pair`);
      continue;
    }
    if (stripSnapshots(region.body).join('\n') !== body.join('\n')) {
      err(art.rel, region.beginLine + 1, 'stale-generated-index',
        `${art.rel} "${art.marker}" region body is out of sync with the corpus (run: node validate.js --write)`);
    }
  }
}

/** --write: regenerate regions IN EXISTING FILES ONLY (a missing artifact is
 *  never created — it stays an error). Write-if-diff on the FULL new bytes.
 *  First line inside the regenerated region: `<!-- snapshot: YYYY-MM-DD -->`;
 *  body-minus-date unchanged -> PRESERVE the existing date, else today. */
function regenerateRegions(docs, bodies) {
  for (const art of GENERATED_ARTIFACTS) {
    const d = docs.find((x) => x.rel === art.rel);
    if (!d) continue;
    const region = extractRegion(d.lines, art.marker);
    if (!region) continue; // no markers: cannot write safely — the check reports it
    const body = bodies.get(art.rel);
    let snapshot;
    if (stripSnapshots(region.body).join('\n') === body.join('\n')) {
      const old = region.body.find((l) => SNAPSHOT_RE.test(l.trim()));
      snapshot = old ? old.trim() : `<!-- snapshot: ${todayISO()} -->`;
    } else {
      snapshot = `<!-- snapshot: ${todayISO()} -->`;
    }
    const newLines = [
      ...d.lines.slice(0, region.beginLine + 1),
      snapshot,
      ...body,
      ...d.lines.slice(region.endLine),
    ];
    const eol = d.content.includes('\r\n') ? '\r\n' : '\n';
    const next = newLines.join(eol);
    if (next !== d.content) {
      fs.writeFileSync(path.join(ROOT, art.rel), next, 'utf8');
      process.stderr.write(`wrote: ${art.rel}\n`);
    }
  }
}

// ----------------------------- ERROR 8: secret-in-prose  (FINDINGS NEVER ECHO THE VALUE) ------------------------------

// Conservative patterns; prose AND frontmatter (frontmatter is NOT exempt);
// fenced blocks are exempt. Assignment key part is case-insensitive.
const SECRET_PATTERNS = [
  { kind: 'aws-access-key-id', re: /AKIA[0-9A-Z]{16}/g, val: (m) => m[0] },
  { kind: 'private-key-block', re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/g, val: (m) => m[0] },
  { kind: 'secret-assignment', re: /(api[_-]?key|token|secret|password|passwd)\s*[:=]\s*["']?([A-Za-z0-9+/=_\-.]{16,})["']?/gi, val: (m) => m[2] },
  { kind: 'hex-token', re: /(?<![0-9a-fA-F])[a-f0-9]{32,}(?![0-9a-fA-F])/g, val: (m) => m[0] },
];

function checkSecrets(docs) {
  for (const d of docs) {
    for (let i = 0; i < d.lines.length; i++) {
      if (d.mask[i]) continue;
      const line = d.lines[i];
      const reported = []; // spans already reported on this line (pattern precedence)
      for (const p of SECRET_PATTERNS) {
        p.re.lastIndex = 0;
        let m;
        while ((m = p.re.exec(line))) {
          const s = m.index, e = m.index + m[0].length;
          if (reported.some((t) => s < t[1] && e > t[0])) continue;
          reported.push([s, e]);
          // Redacted sketch ONLY: first 4 chars + ellipsis. The value itself
          // must never travel in a finding (guidelines/04 design rule 3).
          err(d.rel, i + 1, 'secret-in-prose', `${p.kind} detected (redacted: ${String(p.val(m)).slice(0, 4)}${ELL})`);
        }
      }
    }
  }
}

// ----------------------------- WARNINGS (non-blocking; exit 0 when only warnings) ------------------------------

function checkNoH1(docs) {
  for (const d of docs) {
    if (d.cls === 'generated') continue; // every scanned md EXCEPT artifacts
    const start = d.fm ? d.fm.end + 1 : 0;
    let has = false;
    for (let i = start; i < d.lines.length; i++) {
      if (!d.mask[i] && /^#\s+\S/.test(d.lines[i])) { has = true; break; }
    }
    if (!has) warn(d.rel, 1, 'no-h1', 'document has no H1 heading outside fenced blocks');
  }
}

function checkCategory(docs) {
  for (const d of docs) {
    if (!NOTE_CLASSES.has(d.cls) || d.dir === '') continue; // root-level notes: no folder to compare
    const ent = d.entries.get('category');
    if (!ent || ent.kind !== 'scalar' || !ent.value) continue; // absence/blank owned by check 1
    // Consumer adaptation (3/3): compare against the folder's final segment, so
    // a nested docs/protocols/ folder still matches category "protocols".
    const folder = d.dir.slice(d.dir.lastIndexOf('/') + 1);
    if (ent.value.trim().toLowerCase() !== folder.toLowerCase()) {
      warn(d.rel, ent.line, 'category-mismatch-folder', `category '${ent.value.trim()}' does not match folder '${d.dir}/'`);
    }
  }
}

function checkNearDuplicates(docs) {
  // Word tokens lowercased (\w+), Jaccard >= 0.85, skip docs < 25 tokens, one
  // finding per pair (reported on the later path). Generated artifacts are
  // excluded: their bodies are deterministic boilerplate.
  const pool = docs.filter((d) => d.cls !== 'generated').map((d) => {
    const toks = [];
    const start = d.fm ? d.fm.end + 1 : 0;
    for (let i = start; i < d.lines.length; i++) {
      if (!d.mask[i]) for (const m of d.lines[i].matchAll(/\w+/g)) toks.push(m[0].toLowerCase());
    }
    return { d, toks };
  }).filter((x) => x.toks.length >= 25)
    .map((x) => ({ d: x.d, set: new Set(x.toks) }));
  for (let i = 0; i < pool.length; i++) {
    for (let j = i + 1; j < pool.length; j++) {
      const A = pool[i].set, B = pool[j].set;
      let inter = 0;
      for (const t of A) if (B.has(t)) inter++;
      const union = A.size + B.size - inter;
      const jac = union === 0 ? 0 : inter / union;
      if (jac >= 0.85) {
        warn(pool[j].d.rel, 1, 'near-duplicate-body',
          `body is a near-duplicate of ${pool[i].d.rel} (jaccard=${jac.toFixed(2)})`);
      }
    }
  }
}

// ----------------------------- Main ------------------------------

function main() {
  let docs = loadDocs();
  let resolver = buildResolver(docs);

  // Region bodies are derived from the file set + frontmatter, which --write
  // never changes — compute once, write, then reload for checking.
  const bodies = new Map(GENERATED_ARTIFACTS.map((a) =>
    [a.rel, a.marker === 'index' ? renderIndexRegion(docs) : renderTagsRegion(docs)]));
  if (WRITE_MODE) {
    regenerateRegions(docs, bodies); // strictly read-only below this line
    docs = loadDocs();
    resolver = buildResolver(docs);
  }

  const { out, inn, mdOut } = collectEdges(docs, resolver);

  for (const d of docs) checkMetadata(d);
  checkDuplicateIds(docs);
  checkNames(docs);
  checkSecrets(docs);
  checkOrphans(docs, out, inn);
  checkHubMembership(docs, out, mdOut);
  checkGeneratedRegions(docs, bodies);

  checkNoH1(docs);
  checkCategory(docs);
  checkNearDuplicates(docs);

  findings.sort((a, b) =>
    a.path < b.path ? -1 : a.path > b.path ? 1
      : a.line !== b.line ? a.line - b.line
        : a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  const lines = findings.map((f) => `${f.path}:${f.line} ${DASH} ${f.name}: ${f.msg}`);
  const nErr = findings.filter((f) => f.severity === 'error').length;
  const nWarn = findings.length - nErr;
  lines.push(`${nErr} error(s), ${nWarn} warning(s) ${DASH} files scanned: ${docs.length}`);
  process.stdout.write(lines.join('\n') + '\n');
  process.exitCode = nErr > 0 ? 1 : 0;
}

main();
