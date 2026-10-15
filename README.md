---
last_updated: 2026-10-14
status: active
description: Single entry point for the daver-home-system documentation corpus — a self-hosted home-IoT hub design and how to navigate its docs.
tags: [entry-point, index, navigation]
version: 1.0
doc_language: en
related: [project-overview]
---

# daver-home-system

A self-hosted, private home-IoT system: the owner's always-on PC runs the hub
(**Home Assistant Container** as the single state authority + **Eclipse Mosquitto**
as the hub-internal MQTT bus), the phone is the central controller, and everyday
control never leaves the LAN. The devices are existing **Tuya** bulbs and switches,
already paired in the Smart Life app and driven locally over the Tuya LAN protocol
(TCP/6668, dps) through the **LocalTuya** integration. Two existing local projects
are reused as components, unmodified: [`tuya-local-key`](docs/context/tuya-local-key-integration.md)
(harvest and maintain Tuya local keys) and
[`tuya-bulb-widget`](docs/context/tuya-bulb-widget-integration.md) (an existing KDE
Plasma desktop control surface).

Today this repository holds the **architecture design, the documentation corpus, and
the first increment of the Flutter phone app** — `app/`, a thin Home Assistant client
(a REST probe and snapshot plus keystore token custody, with a reactive hub-status
banner). The hub itself is still design and docs only: the `deploy/` tree (Compose
manifests, `mosquitto.conf`, `.env` template) is the next phase.

## How to navigate this corpus

**Start with [`docs/project.md`](docs/project.md)** — the canonical agent-facing
entry point (overview, technology stack, the Slices routing table, commands,
conventions, domain entities, context index, common lookups). This README is the
single human entry point; there is no second "start here".

| File | Purpose | When to read |
|---|---|---|
| [docs/project.md](docs/project.md) | Canonical entry point: overview, technology stack, Slices routing table, commands, conventions, domain entities, context index, common lookups. | First, if you are an agent; whenever you need to know where a task lands. |
| [docs/context/context-index.md](docs/context/context-index.md) | Hub for the strategic context docs — the architecture, the hub, the contracts, the components, security, troubleshooting. | To find the detail behind a slice or topic. |
| [app/](app/) | The Flutter phone app's first increment: `pubspec.yaml`, `lib/hub/` (HA REST probe/snapshot + keystore token custody), `lib/ui/`, and `lib/main.dart` with the reactive hub-status banner ("cartel"). **FVM** 4.3.1 pins Flutter 3.47.7 (Dart 3.13.5) via `.fvmrc`; `fvm flutter analyze` is clean and `fvm flutter test` is green. | To see how the first increment of the app is shaped, or to continue building it (implementation plan in [mobile-app-design](docs/context/mobile-app-design.md)). |
| [docs/context/hosting-architecture.md](docs/context/hosting-architecture.md) | The architecture itself: corrected layer model, component inventory, topology, state ownership, stack rationale, risk register. | When you need the design in one place. |
| [docs/protocols/bring-up-the-hub.md](docs/protocols/bring-up-the-hub.md) | Procedure: bring the hub up (Home Assistant, Mosquitto, tuya-local-key) as Compose services on the PC. | When standing the hub up. |
| [docs/protocols/add-a-tuya-device.md](docs/protocols/add-a-tuya-device.md) | Procedure: add an existing Tuya device — Smart Life pairing, key harvest, LocalTuya, verification. | When adding or re-keying a device. |
| [docs/protocols/new-note-protocol.md](docs/protocols/new-note-protocol.md) | Procedure: add a document to this corpus and keep validation green. | Before writing any documentation here. |
| [adrs/adr-index.md](adrs/adr-index.md) | Hub for the append-only decision records. | When questioning *why* the design is shaped this way. |
| [index.md](index.md) | Generated tree and stats of the whole corpus (region `index`). | To see everything the corpus holds. |
| [tag-index.md](tag-index.md) | Generated tag → docs surface (region `tags`). | When the vocabulary is unknown — search by tag. |
| [validate.js](validate.js) | Zero-dependency corpus validator. Run `node validate.js` (read-only) or `node validate.js --write` (regenerate the two indexes). | Before every change; after adding or moving docs. |

## Conventions

- Documentation is English (`doc_language: en`).
- Docs filenames and folders are lowercase kebab-case; the root `README.md` is the single exemption.
- One topic per file; every topic folder has exactly one hub — procedures under
  `docs/protocols/` have no hub and register in the table above instead.
- Generated content lives between `<!-- BEGIN GENERATED: … -->` / `<!-- END GENERATED: … -->`
  markers and is rebuilt with `node validate.js --write`, never hand-edited.
- Local keys and tokens are never logged, printed, or committed; the validator's
  `secret-in-prose` check blocks them from the corpus.
- `tuya-local-key` and `tuya-bulb-widget` are read-only sources: this repo documents
  them as components and never modifies them.
- `validate.js` is a consumer-adapted copy of the framework validator (see
  [ADR-0002](adrs/adr-0002-validate-js-consumer-layout.md)).
