---
last_updated: 2026-10-14
status: active
description: Phone-as-controller app — a thin Home Assistant client over REST plus WebSocket, its screens, token custody, discovery, and offline semantics.
tags: [app, mobile, flutter, rest, websocket, ha-api, design]
version: 1.3
related: [home-assistant-hub, security-and-privacy, provisioning-flow, hosting-architecture]
---

# Mobile App Design

## Problem

The phone is the ecosystem's central controller, but the devices do not talk to it: Tuya hardware is written over the LAN by Home Assistant, and Home Assistant owns every entity and automation. An app that spoke to the bulbs, or to MQTT, would add a second writer with no state owner — the exact failure ADR-0005 forbids. The app must be a **thin client of the single state authority**, and nothing else.

## Solution

The app is a **Home Assistant client**: REST for commands and the initial snapshot, WebSocket for live state. It is not an MQTT client and not a device-level client. Currently the design plus increment 1 in `app/`: the HTTP client is in place (it probes the hub at `GET /api/`, caches the `GET /api/states` snapshot, and keeps the long-lived token in the OS keystore). The dependency plan for the remaining increments is a WebSocket client and `nsd`/mDNS discovery — **no `mqtt_client`**.

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

### Build status and project structure

| Path | Purpose |
|---|---|
| `app/.fvmrc` | Committed FVM pin: `{"flutter": "3.47.7"}` |
| `app/.fvm/` | Gitignored FVM cache — the `flutter_sdk` symlink into the registered 3.47.7 SDK |
| `app/pubspec.yaml` | Package identity, Dart SDK constraint `^3.6.0`, Flutter + lints, and the runtime deps `http` + `flutter_secure_storage`; resolved versions live in `pubspec.lock` |
| `app/analysis_options.yaml` | Lint baseline `package:flutter_lints` |
| `app/lib/main.dart` | `main()`, `DaverApp` Material 3 theme, `HomeScreen` wired to the hub client; `DaverApp(hubClient:, tokenStore:)` are the test seams |
| `app/lib/hub_status.dart` | `HubStatus` = `connecting` / `hubUnavailable` / `offline` |
| `app/lib/hub/hub_client.dart` | The `HubClient` port over the HA REST surface, `EntitySnapshot`, and the typed exceptions |
| `app/lib/hub/http_hub_client.dart` | `GET /api/` probe and `GET /api/states` snapshot, each with `Authorization: Bearer <token>`; maps every failure onto the typed exceptions |
| `app/lib/hub/token_store.dart` | The `TokenStore` port for token custody |
| `app/lib/hub/secure_token_store.dart` | OS-keystore custody via `flutter_secure_storage` (Android encrypted prefs) |
| `app/lib/hub/hub_status_controller.dart` | Reactive status: null = connected; `offline` vs `hubUnavailable`; `needsToken` on a missing or rejected token |
| `app/lib/ui/hub_banner.dart` | `HubBanner`, the reactive status banner the owner calls the "cartel" |
| `app/lib/ui/token_entry.dart` | Token entry / re-auth surface |
| `app/test/` | `widget_test.dart` (title + banner render) plus the `test/hub/` and `test/ui/` suites; fakes only — no test touches the network or the keystore |
| `app/android/`, `app/ios/` | Platform folders generated by `fvm flutter create . --platforms=android,ios` |
| `app/.gitignore` | Keeps `.dart_tool/`, build output, and `.fvm/` out of the repo |

**FVM** (4.3.1) is the machine's Flutter SDK manager, and **Flutter 3.47.7 (Dart 3.13.5)** is now installed and pinned — registered as a local SDK into FVM's cache and recorded in `app/.fvmrc`, with the `android/` / `ios/` platform folders generated. `fvm flutter analyze` is clean and `fvm flutter test` is green; see `### Implementation plan` for the pin mechanics.

### First screen

The first screen is a `Scaffold` with an app bar titled `Daver Home`, a short line naming the surface, and a **reactive** `HubBanner` driven by `HubStatusController`. The banner is hidden when connected and otherwise shows `connecting`, `hubUnavailable`, or `offline`. When no token is stored — or the hub rejects the stored one (HTTP 401/403) — the screen surfaces a token entry / re-auth field. It does not render entities yet.

The banner is the seam the hub client lands on: the same enum drives label, colour, and icon from the real `GET /api/` probe — exactly the "hub unavailable" rule stated in the reconnect section above.

### Next increments

1. **Hub client** (done) — `GET /api/` probe plus `GET /api/states` snapshot and token custody in the OS keystore via `http` and `flutter_secure_storage`; see `### Implementation plan`.
2. **Live state** — `web_socket_channel` to `ws://<host>:8123/api/websocket`: `auth` → `auth_ok` → `subscribe_events`, with reconnect, exponential backoff, resubscribe, and a re-read of the affected entities.
3. **Discovery** — mDNS via the platform API, with a static saved host as fallback.
4. **Surfaces** — rooms/devices list, bulb detail, switch-mirror status, and hub health.

Still **no `mqtt_client`**.

### Implementation plan

Order, gates, packages, toolchain, and test shape for the increments listed in `### Next increments` above. **Increment 1 is done** (its gate is met); 2–4 stay gated.

| # | Increment | Scope | Gate to start |
|---|---|---|---|
| 1 | **Hub client** (done) | `GET /api/` availability probe + `GET /api/states` snapshot, both with `Authorization: Bearer <token>`; token in the OS keystore via `flutter_secure_storage`; reactive `HubBanner` | — (first) |
| 2 | **Live state** | `web_socket_channel` to `ws://<host>:8123/api/websocket`: `auth` → `auth_ok` → `subscribe_events`; reconnect with exponential backoff, resubscribe, re-read affected entities | increment 1 green |
| 3 | **Discovery** | mDNS via the platform API; static saved host as fallback | increment 2 green |
| 4 | **Surfaces** | Rooms/devices list, bulb detail, switch-mirror status, hub health | increment 3 green |

Gate: the current increment merged, `fvm flutter test` green from `app/`, and its hub-facing code behind a port covered by fakes. Because **no test talks to the real hub**, behaviour against a live HA is confirmed by the human on-device, not in CI.

**Increment 1 — hub client.** The probe (`GET /api/`) and the snapshot (`GET /api/states`) each carry `Authorization: Bearer <token>`. The long-lived token persists in the **OS keystore** (Android Keystore / iOS Keychain) via `flutter_secure_storage`; it is never bundled and never written to a config file. `HubBanner` becomes **reactive** — it renders `HubStatus` from the probe/connection state instead of the hard-coded `hubUnavailable` of the first screen:

| Client / probe state | `HubStatus` | `HubBanner` shows |
|---|---|---|
| Probe in flight, no result yet | `connecting` | "Connecting to the hub" |
| Connection refused / timeout / non-`200` | `hubUnavailable` | "Hub unavailable" |
| `GET /api/` → `200 {"message":"API running."}` | *(none — success)* | hidden: the app is connected |
| Device offline, no usable device route (e.g. `ENETUNREACH`) | `offline` | "Phone offline" |

The enum keeps its three values; success is the absence of a status, so a hidden banner means connected.

**Status (increment 1).** Implemented: the `HubClient` port and its HTTP implementation, keystore token custody, and the reactive banner/controller live in `app/lib/hub/` and `app/lib/ui/`, all hub-facing code behind the port and covered by fakes. `fvm flutter analyze` is clean and the 32 `fvm flutter test` cases are green; a rejected token (HTTP 401/403) surfaces the re-auth state rather than a crash loop. Live behaviour against a real Home Assistant is still confirmed by the human on-device — never in CI.

**Packages (increment 1).** `http` (REST, resolved **1.6.0**) and `flutter_secure_storage` (token custody, resolved **9.2.4**) are declared in `app/pubspec.yaml`, with the resolved versions recorded in `pubspec.lock` by `fvm flutter pub get` — never hand-written into this plan. Dart 3.13.5 satisfies the `^3.6.0` SDK constraint.

**FVM pin.** FVM **4.3.1** is installed at `/usr/bin/fvm` and is the machine's Flutter SDK manager. As of 2026-10-14, **Flutter 3.47.7 (Dart 3.13.5) is installed and pinned**: `app/.fvmrc` records `{"flutter": "3.47.7"}` and the SDK is cached at `/home/admin/fvm/versions/3.47.7/`. It was registered manually as a **local** SDK — the official `flutter_linux_3.47.7-stable.tar.xz` tarball was extracted so the SDK root sits directly at `/home/admin/fvm/versions/3.47.7/`, which is FVM 4.3.1's supported manual registration for a local SDK (the cache dir must contain an executable `bin/flutter` and `bin/cache/dart-sdk`). `fvm install` itself only clones git repositories and accepts no local path, so the human's original network route (`fvm install <version>`) remains the upgrade path for future versions. `.fvmrc` is committed; `app/.fvm/` (the `flutter_sdk` symlink cache) is gitignored.

Pin procedure, in order:

1. Human: `fvm install <version>` (network/git) **or** register a local tarball by extracting its SDK root to `/home/admin/fvm/versions/<version>/`; then inside `app/`, `fvm use <version>`. This writes `.fvmrc` (commit it) and the local `.fvm/` symlink cache (gitignored).
2. `fvm flutter create .` in `app/` adds the `android/` / `ios/` platform folders (already generated here).
3. From `app/` only: `fvm flutter pub get`, `fvm flutter analyze`, `fvm flutter test` — never a bare `flutter`, never from the repo root.

Done for 3.47.7: `fvm flutter pub get` succeeds, `fvm flutter analyze` reports "No issues found!", and `fvm flutter test` runs 32 cases, all green.

**Test shape.** `flutter_test` widget tests for `HubBanner` across every `HubStatus` value; unit tests for the hub client against an injected fake HTTP client (no real network); a fake keystore behind the storage port for token custody. These suites now exist under `app/test/`: `test/ui/hub_banner_test.dart`, `test/hub/` (client, controller, secure store), and `test/widget_test.dart` (title + banner render). **No test ever talks to the real hub** — the hub is a fake in every test. Run with `fvm flutter test` from `app/`.

**Guardrails (unchanged).** No `mqtt_client`. No `tinytuya`. No direct TCP/6668. No Tuya cloud. No device-pairing UI. Home Assistant stays the single state authority ([[adr-0005-control-plane-authority]]); the app holds a cache for rendering only, never for decisions — see `### Deliberate non-goals` below.

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
