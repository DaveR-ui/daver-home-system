---
last_updated: 2026-10-15
status: active
description: Agent entry point for daver-home-system — self-hosted home-IoT hub design (Home Assistant + Mosquitto + Tuya LAN), slices, and doc routing.
tags: [project, entry-point]
version: 1.3
doc_language: en
related: [project-overview]
---

# Project Entry Point — daver-home-system

## Overview

`daver-home-system` is a self-hosted, private home-IoT system in which the owner's always-on PC runs the hub and the phone is the central controller, with everyday control staying on the LAN. The hub is **Home Assistant Container** (the single state authority) plus an **Eclipse Mosquitto** broker (the hub-internal MQTT bus); the devices are existing **Tuya** bulbs and switches, already paired in the Smart Life app, spoken to locally over Wi-Fi via the Tuya LAN protocol (TCP/6668, dps) through the **LocalTuya** integration. Today the hub side is an **architecture design plus a documentation corpus** — no compose manifests and no runnable hub deployment; the only code in the repo is the Flutter app under `app/` — a first hub client (a Home Assistant REST probe and snapshot, plus keystore token custody, plus live state over the Home Assistant WebSocket with reconnect and re-read), with no hub deployment and no platform build. Two existing local projects are reused as components, unmodified: `tuya-local-key` (harvest and maintain Tuya local keys) and `tuya-bulb-widget` (an existing KDE Plasma desktop control surface). **Anti-goals:** no corporate-cloud control path, no new firmware and no re-pairing of devices, no runnable hub deployment and no Dart or Node backend (the phone app is a thin Home Assistant client, not a backend service), and the referenced repos are never modified by this one.

## Technology Stack

- **Home Assistant Container** — the hub and the single state authority: entities, automations, and history in the recorder SQLite database. LocalTuya is installed via HACS.
- **Eclipse Mosquitto** — the hub-internal MQTT broker (port 1883) for MQTT-native devices and future extensions; never the Tuya bulbs.
- **LocalTuya / tinytuya** — drives Tuya devices over the LAN protocol **TCP/6668** with dps payloads (on/off on dp 1 or dp 20).
- **HA recorder SQLite** — history storage; no separate database is introduced.
- **Docker Compose** — the hosting substrate: HA, Mosquitto, and `tuya-local-key` as services on the existing PC (HA uses `network_mode: host`).
- **`tuya-local-key`** — a container that harvests and maintains Tuya local keys (occasional, cloud-touching).
- **Flutter** — the phone app under `app/`: a thin Home Assistant REST + WebSocket client. Increments 1 and 2 are in place (REST probe/snapshot plus keystore token custody, plus live state over the WebSocket with reconnect/backoff); **FVM** 4.3.1 pins Flutter **3.47.7** (Dart 3.13.5) via `app/.fvmrc`.
- **Pattern:** a single-authority hub with an internal MQTT bus; the app is a thin HA client. There is **no separate Node backend and no separate database**.

## Slices

| Slice | Description | Keywords | Entry points | Primary agents |
|---|---|---|---|---|
| hub-core | The hub: Home Assistant container, Mosquitto broker, recorder storage, automations, bring-up and backup | home assistant, mosquitto, compose, localtuya, hacs, recorder, automation, 8123, 1883, hub, container, backup | docs/context/home-assistant-hub.md, docs/context/hosting-architecture.md | coder, reviewer |
| app-control-surface | The phone/desktop app design: HA REST + WebSocket client, long-lived token, reconnect semantics | flutter, rest, websocket, token, state_changed, entity, controller, app, reconnect, offline | docs/context/mobile-app-design.md | coder, reviewer |
| mqtt-contracts | The MQTT topic taxonomy and JSON payload contract for MQTT-native devices and extensions (never the Tuya bulbs) | mqtt, topic, payload, json, mosquitto, casa, habitacion, foco, set, state, sensor | docs/context/mqtt-topic-map.md | coder, reviewer |
| tuya-provisioning | Harvesting and maintaining Tuya local keys: the tuya-local-key component, LocalTuya credentials, rotation handling | tuya, local key, localtuya, sharing sdk, qr, rotation, dp, devices.cache, provisioning | docs/context/tuya-local-key-integration.md, docs/context/provisioning-flow.md, docs/protocols/add-a-tuya-device.md | coder, reviewer |
| desktop-widget-component | The existing tuya-bulb-widget component boundary: provisioning evidence, interim fallback surface, link-mirror semantics | tuya-bulb-widget, plasma, applet, tinytuya, 6668, dps, link watch, mirror, fallback | docs/context/tuya-bulb-widget-integration.md | reviewer, explorer |
| security-privacy | LAN-only boundary, exposed ports, token handling, local-key storage posture, remote-access policy | security, privacy, lan, token, tls, wireguard, local key, secrets, 0600, exposure, backup | docs/context/security-and-privacy.md | reviewer, architect |
| docs-tooling | The documentation corpus: entry point, hubs, ADRs, protocols, validator, generated indexes | docs, frontmatter, hub, index, validate, adr, protocol, kebab, tag index | README.md, docs/project.md, adrs/, validate.js, index.md, tag-index.md | documenter, explorer |

## Commands

Run from the repo root.

| Command | Purpose |
|---|---|
| `node validate.js` | documentation corpus check (read-only; exits 1 on errors) |
| `node validate.js --write` | regenerate the `index.md` / `tag-index.md` regions (write-if-diff) |

## Repository Structure

```text
daver-home-system/
├── README.md                   # human entry point + corpus navigation table
├── index.md                    # generated: corpus tree + stats (region `index`)
├── tag-index.md                # generated: tag → docs surface (region `tags`)
├── validate.js                 # zero-dependency corpus validator (consumer-adapted copy)
├── adrs/                       # append-only decision records + adr-index hub
├── app/                        # Flutter phone app — hub-client increments 1+2 (REST probe/snapshot + token custody + live state)
├── docs/
│   ├── project.md              # agent entry point — the nine fixed sections
│   ├── context/                # strategic docs, one topic per file + context-index hub
│   └── protocols/              # project procedures (registered in README, no hub)
└── deploy/                     # PLANNED (not in the repo yet): compose manifests, mosquitto.conf, .env template
```

`app/` (the Flutter phone app) holds increments 1 and 2 of the hub client — the Home Assistant REST probe/snapshot, keystore token custody, the reactive status banner, and live state over the WebSocket with reconnect/backoff; **FVM** 4.3.1 pins Flutter **3.47.7** (Dart 3.13.5) in `app/.fvmrc` and the `android/` / `ios/` platform folders are generated (`fvm flutter analyze` clean, `fvm flutter test` green). `deploy/` likewise holds only intended manifests today.

## Key Conventions

- Documentation is **English** (`doc_language: en`).
- Docs filenames and folders are **lowercase kebab-case**; the root `README.md` is the single exemption.
- **One topic per file**, and every topic folder has exactly one hub — a note missing from its hub is a validation error.
- Generated content lives between the `BEGIN/END GENERATED` markers and is rebuilt with `node validate.js --write`, never hand-edited.
- The Tuya device leg is the **LAN protocol TCP/6668**, not MQTT (ADR-0003); MQTT is the hub-internal bus only.
- **Home Assistant is the single state authority** and MQTT is hub-internal (ADR-0005).
- Local keys and tokens are **never** committed, logged, or written into docs.
- `tuya-local-key` and `tuya-bulb-widget` are **read-only sources** and are never modified by this repo.

## Domain Entities

- **Hub** — the always-on server (the owner's PC) running Home Assistant, Mosquitto, and `tuya-local-key`.
- **Authority** — Home Assistant, the single owner of device state on the hub.
- **Entity** — a stateful object HA exposes (for example a light) with an `entity_id`.
- **LocalTuya** — the HA integration that drives Tuya devices over the LAN protocol.
- **Local key** — the per-device AES secret required for LAN control; never committed.
- **Data point (dp)** — a numbered Tuya field in a device payload (on/off on dp 1 or dp 20).
- **Broker** — Mosquitto, the hub-internal MQTT server.
- **Topic** — an MQTT address in the hub-internal taxonomy.
- **Long-lived access token** — the HA bearer credential the app presents on REST and WebSocket calls.
- **Provisioning** — pairing/harvesting a device's credentials (id, local key, ip, dps) for the hub.
- **Rotation** — a silent change of a device's local key, detected and re-harvested by `tuya-local-key`.
- **Component** — a reused project (`tuya-local-key`, `tuya-bulb-widget`), never modified here.
- **Slice** — a routing unit in the Slices table binding a change area to its primary doc and agents.
- **Context doc** — a strategic, one-topic file under `docs/context/`.
- **Protocol** — a project procedure under `docs/protocols/`.
- **Generated region** — the `validate.js`-rendered block inside `index.md` / `tag-index.md`.

## Context Index

Context docs (`docs/context/`):

- [project-overview](context/project-overview.md) — what the system is, its goals and anti-goals, and how the pieces fit together.
- [hosting-architecture](context/hosting-architecture.md) — the hub's layer model, containers, networking, and hosting substrate.
- [home-assistant-hub](context/home-assistant-hub.md) — Home Assistant as authority: entities, LocalTuya, recorder, automations, backup.
- [mqtt-topic-map](context/mqtt-topic-map.md) — the MQTT topic taxonomy and JSON payload contract for MQTT-native devices.
- [mobile-app-design](context/mobile-app-design.md) — the Flutter app (design + `app/` scaffold): HA REST + WebSocket client, token, reconnect.
- [provisioning-flow](context/provisioning-flow.md) — end-to-end flow from a paired Tuya device to an HA entity.
- [tuya-local-key-integration](context/tuya-local-key-integration.md) — the `tuya-local-key` component: harvesting, output fields, rotation.
- [tuya-bulb-widget-integration](context/tuya-bulb-widget-integration.md) — the `tuya-bulb-widget` boundary: evidence, fallback surface, link-mirror semantics.
- [security-and-privacy](context/security-and-privacy.md) — LAN-only boundary, exposed ports, token and local-key posture.
- [troubleshooting](context/troubleshooting.md) — symptom→cause table for common failures.

Procedures (`docs/protocols/`):

- [new-note-protocol](protocols/new-note-protocol.md) — add a new note to the corpus and keep validation green.
- [bring-up-the-hub](protocols/bring-up-the-hub.md) — bring the hub up from a bare machine.
- [add-a-tuya-device](protocols/add-a-tuya-device.md) — harvest a local key and add a Tuya device to the hub.

## Common Lookups

| Symptom | Where to look |
|---|---|
| "the bulb stopped responding after a Smart Life re-pair" | docs/context/troubleshooting.md#the-bulb-stopped-responding-after-a-smart-life-re-pair |
| "LocalTuya reports the device as unavailable" | docs/context/troubleshooting.md#localtuya-reports-the-device-as-unavailable |
| "the app cannot reach the hub after a PC reboot" | docs/context/troubleshooting.md#the-app-cannot-reach-the-hub-after-a-pc-reboot |
| "the app shows a stale bulb state after the Plasma widget was used" | docs/context/troubleshooting.md#the-app-shows-a-stale-bulb-state-after-the-plasma-widget-was-used |
| "the Mosquitto container exits on startup" | docs/context/troubleshooting.md#the-mosquitto-container-exits-on-startup |
| "a device shows no local key in tuya-local-key" | docs/context/troubleshooting.md#a-device-shows-no-local-key-in-tuya-local-key |
| "Home Assistant is unreachable on port 8123" | docs/context/troubleshooting.md#home-assistant-is-unreachable-on-port-8123 |
| "the switch no longer mirrors the bulb after the hub took over" | docs/context/troubleshooting.md#the-switch-no-longer-mirrors-the-bulb-after-the-hub-took-over |
