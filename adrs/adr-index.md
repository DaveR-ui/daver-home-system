---
id: adr-index
category: adrs
tags: [hub, adr, index]
aliases: ["ADR Index"]
related: [adr-0001-adopt-documentation-onrails]
version: 1.0
status: active
---

# ADR Index

Navigation hub for the append-only decision records in `adrs/`. Each record is one
decision with its forces and accepted fallout; the text of a record is never edited
(corrections arrive as a new ADR carrying `supersedes`).

## Contents

- [adr-0001-adopt-documentation-onrails](adr-0001-adopt-documentation-onrails.md) — adopt the documentation-onrails framework and its consumer corpus layout for this repo.
- [adr-0002-validate-js-consumer-layout](adr-0002-validate-js-consumer-layout.md) — ship a consumer-adapted copy of `validate.js` (three path-mapping changes only).
- [adr-0003-tuya-lan-protocol-over-mqtt-device-leg](adr-0003-tuya-lan-protocol-over-mqtt-device-leg.md) — the device leg is the Tuya LAN protocol (TCP/6668), not MQTT; Mosquitto stays hub-internal.
- [adr-0004-hosting-substrate](adr-0004-hosting-substrate.md) — host the hub as Docker Compose services on the existing PC (HA Container + Mosquitto + tuya-local-key).
- [adr-0005-control-plane-authority](adr-0005-control-plane-authority.md) — Home Assistant is the single state authority; the app speaks REST + WebSocket only; no separate Node backend or database.
- [adr-0006-tuya-bulb-widget-role](adr-0006-tuya-bulb-widget-role.md) — `tuya-bulb-widget` is provisioning evidence plus an interim fallback surface, never a hub writer.

## Elsewhere

- [hosting-architecture](../docs/context/hosting-architecture.md) — the design these decisions are drawn from.
- [Project entry point](../docs/project.md) — routing, conventions, and common lookups.
