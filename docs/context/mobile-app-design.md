---
last_updated: 2026-10-14
status: active
description: Phone-as-controller app — a thin Home Assistant client over REST plus WebSocket, its screens, token custody, discovery, and offline semantics.
tags: [app, mobile, flutter, rest, websocket, ha-api, design]
version: 1.0
related: [home-assistant-hub, security-and-privacy, provisioning-flow, hosting-architecture]
---

# Mobile App Design

## Problem

The phone is the ecosystem's central controller, but the devices do not talk to it: Tuya hardware is written over the LAN by Home Assistant, and Home Assistant owns every entity and automation. An app that spoke to the bulbs, or to MQTT, would add a second writer with no state owner — the exact failure ADR-0005 forbids. The app must be a **thin client of the single state authority**, and nothing else.

## Solution

The app is a **Home Assistant client**: REST for commands and the initial snapshot, WebSocket for live state. It is not an MQTT client and not a device-level client. Design only (Flutter); dependency plan is an HTTP client, a WebSocket client, and `nsd`/mDNS discovery — **no `mqtt_client`**.

### Surface

| Purpose | Call |
|---|---|
| Health / hub reachable | `GET /api/` |
| Initial snapshot | `GET /api/states`, `GET /api/states/<entity_id>` |
| Command | `POST /api/services/light/turn_on`, `turn_off`, `toggle` with `{"entity_id":"light.<room>_<device>"}` (optional brightness / colour attributes) |
| Live state | `ws://<host>:8123/api/websocket` |

Every request carries `Authorization: Bearer <long-lived-access-token>`.

### Live-state sequence

1. Connect `ws://<host>:8123/api/websocket` → server sends `auth_required`.
2. Send `{"type":"auth","access_token":"<long-lived-access-token>"}` → server replies `auth_ok`.
3. Send `{"id":1,"type":"subscribe_events","event_type":"state_changed"}`.
4. Apply `state_changed` events to the rooms/devices list and the open detail screen.
5. On close: reconnect, re-authenticate, **resubscribe**, then re-read `GET /api/states/<entity_id>` to close the gap left by the disconnect.

### Authentication and token custody

- One long-lived access token per install, minted in Home Assistant's user profile.
- Stored in the **OS keystore** (Android Keystore / iOS Keychain); never bundled in the app, never in a config file the user might sync.
- Rotation: revoke the token in HA and mint a new one; the app prompts and re-stores. A rejected token shows a re-auth state, not a crash loop.
- Custody and transport caveats belong to [[security-and-privacy]].

### Discovery and addressing

- Primary: mDNS via the platform API (`nsd` on Android, Bonjour/`NWBrowser` on iOS) to find the HA instance on the LAN.
- Fallback: a static host saved by the user (`http://<hub-host>:8123`), for networks that block multicast.
- The app discovers the **hub**, never the devices. Tuya bulbs are not mDNS-advertised and are not reachable by the app; they are entities, not peers.

### Screens

| Screen | Content |
|---|---|
| Rooms / devices | Grouped entity list from `GET /api/states` (filtered to the hub's bulb/switch entities), live-toggled by `state_changed` |
| Bulb detail | On/off/toggle, brightness, optional colour; each command is a `POST /api/services/light/*` |
| Switch-mirror status | The switch entity and the bulb entities its automation drives — status only, never a second write path |
| Hub health | `GET /api/` probe result plus WebSocket connection state (connected / reconnecting / hub unavailable) |

### Reconnect and offline semantics

- WebSocket closed → "reconnecting", exponential backoff, resubscribe, re-read affected entity states.
- HA unreachable → the UI says **hub unavailable** and marks state stale. Commands are **not** silently queued: while the authority is down, the app cannot confirm that a command took effect, and a queued command could fire hours later against a changed world.
- Commands are optimistic only when the write is accepted; the next `state_changed` (or a re-read) confirms it.

### Deliberate non-goals

No MQTT client. No `tinytuya` or any Tuya protocol code. No direct TCP/6668 write. No Tuya cloud account. No device-pairing UI — pairing is Smart Life plus [[tuya-local-key-integration]], see [[provisioning-flow]].

## When to use

- Designing or reviewing any feature of the phone app.
- Deciding how the app learns hub address, token, and state.

## When not to use

- For the hub side (entities, recorder, automations) — see [[home-assistant-hub]].
- For the hub-internal MQTT bus — see [[mqtt-topic-map]]; the app never touches it.
- For the LAN boundary and token exposure — see [[security-and-privacy]].

## Examples

```http
GET /api/
Authorization: Bearer <long-lived-access-token>

POST /api/services/light/turn_on
Authorization: Bearer <long-lived-access-token>
Content-Type: application/json

{"entity_id": "light.kitchen_ceiling", "brightness": 180}
```

```json
{"type": "auth", "access_token": "<long-lived-access-token>"}
{"id": 1, "type": "subscribe_events", "event_type": "state_changed"}
```

## Common mistakes

- **Caching entity state as the app's own source of truth.** HA is the authority; a local mirror drifts the moment the Plasma applet or an automation writes. Hold a cache for render, never for decisions.
- **Embedding the token in the app or a synced config.** It lives in the OS keystore, per install, and is revocable in HA.
- **Expecting the app to work while HA is down.** With the authority down there is no state to confirm; show "hub unavailable" and refuse to fake it.
- **Designing a device-pairing flow.** Hardware is already paired in Smart Life; the app never enrols a device.

## References

- [home-assistant-hub](home-assistant-hub.md) — the authority the app talks to.
- [security-and-privacy](security-and-privacy.md) — token custody and the LAN-only boundary.
- [provisioning-flow](provisioning-flow.md) — how a device becomes an entity before the app ever sees it.
- [adr-0005-control-plane-authority](../../adrs/adr-0005-control-plane-authority.md) — why the app is HA-facing, not device-facing.
- [project.md](../project.md) — entry point and slices.
