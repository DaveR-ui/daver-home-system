---
last_updated: 2026-10-20
status: active
description: Phone-as-controller app — a thin Home Assistant client over REST plus WebSocket, its screens, token custody, discovery, and offline semantics.
tags: [app, mobile, flutter, rest, websocket, ha-api, design]
version: 1.9
related: [home-assistant-hub, security-and-privacy, provisioning-flow, hosting-architecture]
---

# Mobile App Design

## Problem

The phone is the ecosystem's central controller, but the devices do not talk to it: Tuya hardware is written over the LAN by Home Assistant, and Home Assistant owns every entity and automation. An app that spoke to the bulbs, or to MQTT, would add a second writer with no state owner — the exact failure ADR-0005 forbids. The app must be a **thin client of the single state authority**, and nothing else.

## Solution

The app is a **Home Assistant client**: REST for commands and the initial snapshot, WebSocket for live state. It is not an MQTT client and not a device-level client. Increments 1, 2, 3, and 4 are in `app/`: the HTTP client probes the hub at `GET /api/`, caches the `GET /api/states` snapshot, and keeps the long-lived token in the OS keystore; live state arrives over the WebSocket (`state_changed` into a render cache, with reconnect and a re-read of the tracked entities); mDNS discovers the hub on the LAN, with the static host as fallback; and the control surfaces carry the light-command write path — **no `mqtt_client`**.

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

- Precedence, in order: an explicit `--dart-define=HUB_BASE_URL=…` **wins outright** and the mDNS search is **skipped entirely**; otherwise the mDNS search decides; otherwise the **static fallback** is used.
- Primary: mDNS via the platform API (`nsd` on Android, Bonjour/`NWBrowser` on iOS), looking for Home Assistant's `_home-assistant._tcp` advertisement on port **8123**.
- Build-time override: `--dart-define=HUB_BASE_URL=…` re-points the compile-time default (`defaultHubBaseUrl`) at a demo or device address — the emulator's `http://10.0.2.2:8123`, or a real phone's LAN IP — without a code change. See [functional-demo-plan](../protocols/functional-demo-plan.md).
- Fallback: the **static host** the search falls back to when multicast is blocked or no advertisement is seen — the documented default `defaultHubHost` = `http://homeassistant.local:8123`, which `defaultHubBaseUrl` carries when no override is supplied. An override that is present but *empty* (`--dart-define=HUB_BASE_URL=`) falls through to the search and still leaves the app with that documented default, never with no address at all. There is no runtime host-setting UI.
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
| `app/pubspec.yaml` | Package identity, Dart SDK constraint `^3.11.0`, Flutter + lints, and the runtime deps `http` + `flutter_secure_storage` + `web_socket_channel` (live state) + `nsd` (mDNS discovery); resolved versions live in `pubspec.lock` |
| `app/analysis_options.yaml` | Lint baseline `package:flutter_lints` |
| `app/lib/main.dart` | `main()`, `DaverApp` Material 3 theme, `HomeScreen` wired to the hub client; `DaverApp(hubClient:, tokenStore:)` are the test seams |
| `app/lib/hub_status.dart` | `HubStatus` = `connecting` / `hubUnavailable` / `offline` |
| `app/lib/hub/hub_client.dart` | The `HubClient` port over the HA REST surface — probe, snapshot, and `fetchEntity` for the reconnect re-read — plus `EntitySnapshot`, and the typed exceptions |
| `app/lib/hub/http_hub_client.dart` | `GET /api/` probe, `GET /api/states` snapshot, and `GET /api/states/<entity_id>` re-read, each with `Authorization: Bearer <token>`; maps every failure onto the typed exceptions |
| `app/lib/hub/hub_rest_transport.dart` | Increment 4: the shared REST transport both HTTP clients sit on — bearer-token read, request build, per-request timeout, and the mapping of every failure onto the typed exceptions |
| `app/lib/hub/live_state_client.dart` | The `LiveStateClient` port over the HA WebSocket surface: an events stream, a status stream, `setTrackedEntities`, `start`, and `stop` |
| `app/lib/hub/ws_live_state_client.dart` | The `LiveStateClient` implementation over `web_socket_channel` to `ws(s)://<host>:8123/api/websocket`; injected channel factory / delay / jitter seams keep every test fake-based |
| `app/lib/hub/hub_discovery.dart` | Increment 3: the `HubDiscovery` port, `HubDiscovered`, the sealed `HubDiscoveryResult` (`HubDiscoveryFound` / `HubDiscoveryNotFound`), and `HubNotFoundReason` (`timeout` / `noAdvertisement` / `pluginUnavailable`) — typed failures, never exceptions |
| `app/lib/hub/hub_address.dart` | Increment 3: the shared mutable `HubAddress` (with a `generation` counter), its `HubAddressReader` seam, `HubAddressSource` / `HubResolution`, `normalizeHubBaseUrl`, and the pure `HubAddressResolver` that encodes the precedence rule |
| `app/lib/hub/hub_discovery_nsd.dart` | Increment 3: the `nsd`-backed `HubDiscovery` (`NsdHubDiscovery`), with the plugin behind `NsdRunner`, plus the public `hubDiscoveredFromNsdService` mapping; searches `_home-assistant._tcp`, port 8123 |
| `app/lib/hub/token_store.dart` | The `TokenStore` port for token custody |
| `app/lib/hub/secure_token_store.dart` | OS-keystore custody via `flutter_secure_storage` (Android encrypted prefs) |
| `app/lib/hub/hub_status_controller.dart` | Reactive status: null = connected; `offline` vs `hubUnavailable`; `needsToken` on a missing or rejected token; increment 4 adds the light-command write path (`sendLightCommand`: optimistic-when-accepted, refuse-not-queue, a per-entity in-flight guard so a second command is `busy`, and a 5-second confirmation timeout that falls back to a render-only re-read) |
| `app/lib/hub/light_command.dart` | Increment 4: `LightService` + `LightCommand` — the light-command model |
| `app/lib/hub/light_command_client.dart` | Increment 4: the `LightCommandClient` write port over HA's light services |
| `app/lib/hub/http_light_command_client.dart` | Increment 4: `POST /api/services/light/*` implementation with the shared token/error mapping |
| `app/lib/surfaces/light_entity.dart` | Increment 4: pure-Dart `LightEntity` / `RoomSection` parsing + grouping for the surfaces (render-only) |
| `app/lib/ui/hub_banner.dart` | `HubBanner`, the reactive status banner the owner calls the "cartel" |
| `app/lib/ui/token_entry.dart` | Token entry / re-auth surface |
| `app/lib/ui/rooms_devices_screen.dart` | Increment 4: grouped rooms/devices list + hub-health card kept to the connected affirmation only (render-only) |
| `app/lib/ui/bulb_detail_screen.dart` | Increment 4: bulb detail — on/off/toggle, brightness, colour presets (the only write surface) |
| `app/lib/ui/switch_mirror_screen.dart` | Increment 4: switch-mirror status — status only, no write path |
| `app/test/` | `widget_test.dart` (title + banner render) plus the `test/hub/`, `test/surfaces/`, and `test/ui/` suites — 205 fake-based cases (32 increment 1, 25 increment 2, 54 increment 4, 15 review fixes, 1 with the `HUB_BASE_URL` addressing change, 78 increment 3); the increment-3 suites are `test/hub/hub_address_test.dart` (34), `test/hub/hub_discovery_test.dart` (24), and `test/hub/hub_status_controller_discovery_test.dart` (18). No test touches the real hub, the network, the OS keystore, or real mDNS — the discovery port is faked in every test |
| `app/android/`, `app/ios/` | Platform folders generated by `fvm flutter create . --platforms=android,ios`; the Android manifest declares `INTERNET` + `CHANGE_WIFI_MULTICAST_STATE`, and the iOS `Info.plist` declares `NSLocalNetworkUsageDescription` + `NSBonjourServices` = `_home-assistant._tcp` |
| `app/.gitignore` | Keeps `.dart_tool/`, build output, and `.fvm/` out of the repo |

**FVM** (4.3.2) is the machine's Flutter SDK manager, and **Flutter 3.47.7 (Dart 3.13.5)** is now installed and pinned — registered as a local SDK into FVM's cache and recorded in `app/.fvmrc`, with the `android/` / `ios/` platform folders generated. `fvm flutter analyze` is clean and `fvm flutter test` is green; see `### Implementation plan` for the pin mechanics.

### First screen

The first screen is a `Scaffold` with an app bar titled `Daver Home`, a short line naming the surface, and a **reactive** `HubBanner` driven by `HubStatusController`. The banner is hidden when connected and otherwise shows `connecting`, `hubUnavailable`, or `offline`. When no token is stored — or the hub rejects the stored one (HTTP 401/403) — the screen surfaces a token entry / re-auth field. `HomeScreen` now renders the rooms/devices list below that header — the grouped bulbs and switches from the render cache — with the banner and the hub-health row reporting reachability.

The banner is the seam the hub client lands on: the same enum drives label, colour, and icon from the real `GET /api/` probe — exactly the "hub unavailable" rule stated in the reconnect section above.

### Next increments

1. **Hub client** (done) — `GET /api/` probe plus `GET /api/states` snapshot and token custody in the OS keystore via `http` and `flutter_secure_storage`; see `### Implementation plan`.
2. **Live state** (done) — `web_socket_channel` to `ws://<host>:8123/api/websocket`: `auth` → `auth_ok` → `subscribe_events`, with reconnect, exponential backoff, resubscribe, and a re-read of the affected entities; see `### Implementation plan`.
3. **Discovery** (done) — mDNS via the platform API for the hub's `_home-assistant._tcp` advertisement, with the static host as fallback; see `### Implementation plan`.
4. **Surfaces** (done) — rooms/devices list, bulb detail, switch-mirror status, and hub health.

Still **no `mqtt_client`**.

### Implementation plan

Order, gates, packages, toolchain, and test shape for the increments listed in `### Next increments` above. **Increments 1, 2, 3, and 4 are done.**

| # | Increment | Scope | Gate to start |
|---|---|---|---|
| 1 | **Hub client** (done) | `GET /api/` availability probe + `GET /api/states` snapshot, both with `Authorization: Bearer <token>`; token in the OS keystore via `flutter_secure_storage`; reactive `HubBanner` | — (first) |
| 2 | **Live state** (done) | `web_socket_channel` to `ws://<host>:8123/api/websocket`: `auth` → `auth_ok` → `subscribe_events`; reconnect with exponential backoff, resubscribe, re-read affected entities | increment 1 green |
| 3 | **Discovery** (done) | mDNS via the platform API for the hub's `_home-assistant._tcp` advertisement, with the static host as fallback; the address is resolved before the probe | increment 2 green |
| 4 | **Surfaces** (done) | Rooms/devices list, bulb detail, switch-mirror status, hub health | increment 3 green — started without it, by owner decision |

Gate: the current increment merged, `fvm flutter test` green from `app/`, and its hub-facing code behind a port covered by fakes. Because **no test talks to the real hub**, behaviour against a live HA is confirmed by the human on-device, not in CI.

**Gate deviation (increment 4).** Increment 4 was started **without** its documented gate (`increment 3 green`) — by the owner's explicit decision. With increment 2 (live state) already green, the owner redirected from Discovery to Surfaces, so increment 3 (mDNS) was deferred **at the time** and the **static host fallback** (`defaultHubBaseUrl = http://homeassistant.local:8123`) was the interim addressing. That deviation is recorded here truthfully and not back-dated: increment 4 really was started before its gate. The deferral it describes is now **lifted** — increment 3 is implemented, so there **is** mDNS now; the static host is the fallback the search falls back to when multicast is blocked or no advertisement is seen.

**Increment 1 — hub client.** The probe (`GET /api/`) and the snapshot (`GET /api/states`) each carry `Authorization: Bearer <token>`. The long-lived token persists in the **OS keystore** (Android Keystore / iOS Keychain) via `flutter_secure_storage`; it is never bundled and never written to a config file. `HubBanner` becomes **reactive** — it renders `HubStatus` from the probe/connection state instead of the hard-coded `hubUnavailable` of the first screen:

| Client / probe state | `HubStatus` | `HubBanner` shows |
|---|---|---|
| Probe in flight, no result yet | `connecting` | "Connecting to the hub" |
| Connection refused / timeout / non-`200` | `hubUnavailable` | "Hub unavailable" |
| `GET /api/` → `200 {"message":"API running."}` | *(none — success)* | hidden: the app is connected |
| Device offline, no usable device route (e.g. `ENETUNREACH`) | `offline` | "Phone offline" |

The enum keeps its three values; success is the absence of a status, so a hidden banner means connected.

**Status (increment 1).** Implemented: the `HubClient` port and its HTTP implementation, keystore token custody, and the reactive banner/controller live in `app/lib/hub/` and `app/lib/ui/`, all hub-facing code behind the port and covered by fakes. `fvm flutter analyze` is clean and the 32 `fvm flutter test` cases are green; a rejected token (HTTP 401/403) surfaces the re-auth state rather than a crash loop. Live behaviour against a real Home Assistant is still confirmed by the human on-device — never in CI.

**Status (increment 2).** Implemented: the `LiveStateClient` port and its `web_socket_channel` implementation live in `app/lib/hub/live_state_client.dart` and `app/lib/hub/ws_live_state_client.dart`, behind the port pattern of increment 1 and covered by fakes. The documented sequence runs exactly: connect → `auth_required` → `{"type":"auth","access_token":…}` → `auth_ok` → `{"id":<n>,"type":"subscribe_events","event_type":"state_changed"}` (id increments from 1) → apply events; `result`/`pong` acks are ignored and malformed frames are dropped, never thrown. `state_changed` updates a **render cache only** — per [[adr-0005-control-plane-authority]] Home Assistant stays the single state authority and the cache is never a decision input. Reconnect uses exponential backoff — base **1s**, factor **2**, cap **30s**, ±**20%** jitter — accumulating across reconnects and resetting once a live event proves flow; on close it re-authenticates, resubscribes, then re-reads the tracked entities via `GET /api/states/<entity_id>` (the new `HubClient.fetchEntity`) to close the disconnect gap. Edge cases: `auth_invalid` or a revoked token → re-auth state (`needsToken`), never a crash loop; device-offline errno (ENETDOWN/ENETUNREACH/EHOSTUNREACH) → `HubStatus.offline`; duplicate and out-of-order events are dropped by a `last_updated` ordering guard. Live status composes with increment 1's probe-first `HubStatusController`, so `HubBanner` stays coherent (connecting/reconnecting → `connecting`, offline → `offline`, token rejected → re-auth prompt, connected → banner hidden) and the `HubStatus` enum keeps its three values. `fvm flutter analyze` is clean and all 57 `fvm flutter test` cases are green — 32 from increment 1 plus 25 new — all fakes, with no test touching the real hub, the network, or the OS keystore. Live behaviour against a real Home Assistant is still confirmed by the human on-device — never in CI.

**Status (increment 4).** Implemented: the control surfaces and the light-command write path. `LightCommand`/`LightService` (the command model) plus the `LightCommandClient` **port** and its `HttpLightCommandClient` implementation post `POST /api/services/light/{turn_on|turn_off|toggle}` with `{"entity_id": …}` (+ `brightness` / `rgb_color` when set), reusing the same token/error mapping as `HubClient` and mirroring the `HubClient` / `LiveStateClient` port pattern. `HubStatusController.sendLightCommand` gates the write path: when the hub is not connected it returns `refused` and **sends nothing — a command is never silently queued** while the authority is down (ADR-0005); once accepted the write is applied optimistically with the row kept **undated** (`lastUpdated: null`) so the authoritative `state_changed` always wins the ordering guard, and only **one command per entity is ever in flight**: a second command for an entity that is already pending is **refused** (`busy`, never queued) and the bulb detail controls stay disabled while a command is unconfirmed. The accepted command's `brightness`/`rgb_color` are **merged** onto the entity's cached attributes, so a `turn_off` does not wipe the cached brightness/colour and a brightness-only `turn_on` keeps the colour. Confirmation is the next live `state_changed` — or, with no live client, or once the **5-second confirmation timeout** expires, a render-only re-read — so a no-op command that HA accepts but never announces cannot leave the pending indicator spinning. The surfaces are `rooms_devices_screen.dart` (grouped `light.*` / `switch.*` from the render cache, plus a hub-health card that now shows only the connected affirmation — the always-on `HubBanner` directly above the list already owns the connecting / hub-unavailable / phone-offline copy), `bulb_detail_screen.dart` (on/off/toggle, brightness slider, colour presets, disabled and refusing when the hub is down — the only write surface), and `switch_mirror_screen.dart` — **status only, no write path** to the bulbs its automation drives. Because `GET /api/states` exposes no automation→entity edges, the switch→bulbs link is modelled by **room-prefix convention** (`switch.<room>` ↔ `light.<room>_*`), a documented rendering assumption. Home Assistant remains the single state authority and the entity cache stays render-only. `fvm flutter analyze` is clean and `fvm flutter test` is green; see `### Test shape`. Live behaviour against a real Home Assistant is still confirmed by the human on-device — never in CI.

**Status (increment 3).** Implemented: mDNS discovery of the hub, behind the same port-and-fake discipline. The `HubDiscovery` port, `HubDiscovered`, the sealed `HubDiscoveryResult` (`HubDiscoveryFound` / `HubDiscoveryNotFound`) and `HubNotFoundReason` (`timeout` / `noAdvertisement` / `pluginUnavailable`) live in `app/lib/hub/hub_discovery.dart`; the `nsd` adapter (`NsdHubDiscovery`, with the plugin behind `NsdRunner`) and the public `hubDiscoveredFromNsdService` mapping live in `app/lib/hub/hub_discovery_nsd.dart`; the shared `HubAddress`, its `HubAddressReader` seam, and the pure `HubAddressResolver` live in `app/lib/hub/hub_address.dart`. Precedence is exactly: an explicit `--dart-define=HUB_BASE_URL=…` wins outright and the mDNS search is **skipped entirely**; otherwise the mDNS search decides; otherwise `defaultHubBaseUrl` is the **static fallback**. The base URL reaches the clients through the reader — the REST transport reads it once per request, the WebSocket client once per connection attempt — because the platform's responder only answers a query that is already running, the same seam as `tokenReader`. The address is resolved **before** the probe, so exactly one probe runs per connect attempt and `HubBanner` keeps a single monotone transition; `HubStatus` keeps exactly its three values, and success stays the *absence* of a status. Failures are typed: no advertisement and blocked multicast are `HubDiscoveryNotFound` values, never thrown exceptions; a miss rides on the resolution as an observation and never paints a status, so a blocked multicast search still connects through the static fallback. An advertisement that arrives after the search resolved is deferred while an attempt is running and applied **only when the hub is not connected** — a connected hub keeps the address that probed successfully, because moving REST to another host while the live socket stays on this one would split the app across two hubs. One bounded search runs per controller (3-second default timeout, including the platform start); `refreshAddress()` re-searches only when no resolution is in flight — an in-flight search is the current one, so a second platform start (and a second subscription) is avoided. The platform search is installed exactly once however many `discover` calls overlap, and every waiting call is answered by the first advertisement. On pause or detach the platform search is stopped (on Android `nsd` holds a `WifiManager.MulticastLock`, released only by `stopDiscovery`) and the address is re-resolved on resume. The static fallback is the documented default `defaultHubHost` = `http://homeassistant.local:8123`: an override that is present but empty falls through to the search and still leaves the app with that default, never with no address at all. Platform surface: Android declares `CHANGE_WIFI_MULTICAST_STATE` alongside `INTERNET`; iOS declares `NSLocalNetworkUsageDescription` and `NSBonjourServices` = `_home-assistant._tcp`. Two limitations are stated rather than hidden: discovery yields an `http://` address, so a hub behind local TLS is reached with the `--dart-define=HUB_BASE_URL` override, not through discovery; and any device on the LAN can advertise `_home-assistant._tcp` — the LAN-only boundary is the mitigation, see [[security-and-privacy]]. `fvm flutter analyze` is clean and the 205 `fvm flutter test` cases are green; no test touches the real hub, the network, the OS keystore, or real mDNS. Live behaviour against a real Home Assistant is still confirmed by the human on-device — never in CI.

**Packages (increment 4).** None — increment 4 adds no dependency; it reuses `http` and `web_socket_channel`. Still **no `mqtt_client`**.

**Packages (increment 3).** `nsd` (mDNS discovery) is declared in `app/pubspec.yaml` and resolved to **5.0.1** in `pubspec.lock` by `fvm flutter pub get` — never hand-written into this plan. `nsd` 5.0.1 requires Dart `^3.11.0`, so the app's `environment.sdk` moved from `^3.6.0` to `^3.11.0`; Dart 3.13.5 satisfies it. Still **no `mqtt_client`**.

**Packages (increment 1).** `http` (REST, resolved **1.6.0**) and `flutter_secure_storage` (token custody, resolved **9.2.4**) are declared in `app/pubspec.yaml`, with the resolved versions recorded in `pubspec.lock` by `fvm flutter pub get` — never hand-written into this plan. Dart 3.13.5 satisfies the `^3.6.0` SDK constraint.

**Packages (increment 2).** `web_socket_channel` (live state) is declared in `app/pubspec.yaml` and resolved to **3.0.3** in `pubspec.lock` by `fvm flutter pub get` — never hand-written into this plan. Dart 3.13.5 satisfies the package's `^3.6.0` SDK constraint.

**FVM pin.** FVM **4.3.2** is installed at `/usr/bin/fvm` and is the machine's Flutter SDK manager. As of 2026-10-14, **Flutter 3.47.7 (Dart 3.13.5) is installed and pinned**: `app/.fvmrc` records `{"flutter": "3.47.7"}` and the SDK is cached at `/home/admin/fvm/versions/3.47.7/`. It was registered manually as a **local** SDK — the official `flutter_linux_3.47.7-stable.tar.xz` tarball was extracted so the SDK root sits directly at `/home/admin/fvm/versions/3.47.7/`, which is FVM 4.3.2's supported manual registration for a local SDK (the cache dir must contain an executable `bin/flutter` and `bin/cache/dart-sdk`). `fvm install` itself only clones git repositories and accepts no local path, so the human's original network route (`fvm install <version>`) remains the upgrade path for future versions. `.fvmrc` is committed; `app/.fvm/` (the `flutter_sdk` symlink cache) is gitignored.

Pin procedure, in order:

1. Human: `fvm install <version>` (network/git) **or** register a local tarball by extracting its SDK root to `/home/admin/fvm/versions/<version>/`; then inside `app/`, `fvm use <version>`. This writes `.fvmrc` (commit it) and the local `.fvm/` symlink cache (gitignored).
2. `fvm flutter create .` in `app/` adds the `android/` / `ios/` platform folders (already generated here).
3. From `app/` only: `fvm flutter pub get`, `fvm flutter analyze`, `fvm flutter test` — never a bare `flutter`, never from the repo root.

Done for 3.47.7: `fvm flutter pub get` succeeds, `fvm flutter analyze` reports "No issues found!", and `fvm flutter test` runs **205 cases**, all green.

**Test shape.** `flutter_test` widget tests for `HubBanner` across every `HubStatus` value; unit tests for the hub client against an injected fake HTTP client (no real network), including the four `fetchEntity` HTTP cases; a fake WebSocket channel behind an injected factory — with injected delay and jitter — driving the `LiveStateClient` through a live-controller suite that covers socket lifecycle, backoff, and re-read, plus status mapping and dedupe, with added cases for a token rejected on the reconnect re-read, mixed re-read recovery, backoff reset pinning, and the backoff overflow regression; a fake keystore behind the storage port for token custody; and a faked mDNS port plus a faked address reader for discovery, so no test reaches the platform channel. These suites now exist under `app/test/`: `test/ui/hub_banner_test.dart`, `test/hub/` (client, live-state client, live controller, status controller, secure store, light-command client, controller command state, hub address, hub discovery, controller discovery), `test/surfaces/light_entity_test.dart`, `test/ui/{rooms_devices,bulb_detail,switch_mirror}_test.dart`, and `test/widget_test.dart` (title + banner render) — **205 cases in total** (32 from increment 1, 25 from increment 2, 54 from increment 4, 15 added by the increment-4 review fixes: optimistic-merge, per-command concurrency, confirmation timeout, hub-copy de-duplication, and shared REST transport; 1 added with the `HUB_BASE_URL` addressing change; and 78 from increment 3 — `test/hub/hub_address_test.dart` 34, `test/hub/hub_discovery_test.dart` 24, `test/hub/hub_status_controller_discovery_test.dart` 18, plus 1 in `http_hub_client_test.dart` and 1 in `ws_live_state_client_test.dart`). **No test ever talks to the real hub** — the hub is a fake in every test, and no test touches the network, the OS keystore, or real mDNS. Run with `fvm flutter test` from `app/`.

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

{"entity_id": "light.sala_luz_derecha", "brightness": 180}
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
