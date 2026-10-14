---
id: context-index
category: context
tags: [hub, index, navigation]
aliases: ["Context Index"]
related: [project-overview]
version: 1.0
status: active
---

# Context Index

Navigation hub for the strategic docs in `docs/context/`. Each file covers exactly one topic; start at the [project entry point](../project.md) for routing, then open the doc that matches your change.

## Contents

- [project-overview](project-overview.md) — what the system is, its goals and anti-goals, and how the pieces fit together.
- [hosting-architecture](hosting-architecture.md) — the hub's layer model, containers, networking, and hosting substrate.
- [home-assistant-hub](home-assistant-hub.md) — Home Assistant as authority: entities, LocalTuya, recorder, automations, backup.
- [mqtt-topic-map](mqtt-topic-map.md) — the MQTT topic taxonomy and JSON payload contract for MQTT-native devices.
- [mobile-app-design](mobile-app-design.md) — the planned Flutter app: HA REST + WebSocket client, token, reconnect.
- [provisioning-flow](provisioning-flow.md) — end-to-end flow from a paired Tuya device to an HA entity.
- [tuya-local-key-integration](tuya-local-key-integration.md) — the `tuya-local-key` component: harvesting, output fields, rotation.
- [tuya-bulb-widget-integration](tuya-bulb-widget-integration.md) — the `tuya-bulb-widget` boundary: evidence, fallback surface, link-mirror semantics.
- [security-and-privacy](security-and-privacy.md) — LAN-only boundary, exposed ports, token and local-key posture.
- [troubleshooting](troubleshooting.md) — symptom→cause table for common failures.

## Elsewhere

- [Project entry point](../project.md) — metadata, stack, commands, slices, and common lookups.
- Project procedures live under `../protocols/`; this hub links only the strategic context docs above.
