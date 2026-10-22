---
id: functional-demo-plan
category: protocols
tags: [protocol, demo, compose, home-assistant, emulator, localtuya]
aliases: ["Functional Demo Plan"]
related: [bring-up-the-hub, add-a-tuya-device, mobile-app-design, home-assistant-hub, hosting-architecture, security-and-privacy, adr-0005-control-plane-authority, adr-0006-tuya-bulb-widget-role]
version: 1.8
status: active
---

# Functional Demo Plan

## Problem

The corpus rests on one claim: the golden path works end to end — the app
connects, a bulb turns on, a slider changes its brightness, a wall switch's
channel moves the bulbs it drives, and the app only mirrors that. The claim is
only credible when it runs against the hub the owner actually uses.

The first iteration of this demo proved the app's plumbing against **synthetic
template entities**: a template light and a template switch backed by
`input_boolean`/`input_number` helpers, plus a mirror automation. That phase is
**retired**: the fixture and its two template entities are gone, and the demo now
runs on the owner's real Tuya devices, provisioned in Home Assistant through
LocalTuya over the LAN (TCP/6668). The synthetic path was honest about what it
did not cover — a template light has no datapoints, so it proved the app's
plumbing and nothing about the device leg.

The real devices make the demo harder to run and worth far more:

- the golden path now drives **real entity ids** whose rooms and brightness
  attributes have to satisfy the app's parsing rules, not a fixture built to
  satisfy them;
- the mirror has to move **two** bulbs from one wall-switch channel on one side
  of the house and one bulb from another channel on the other, without a second
  writer;
- every failure now includes hardware failures — a device off the LAN, a rotated
  local key, a guessed datapoint — not just a stopped container.

This procedure is the sequenced plan for that demo. It is a demo, not a
production bring-up: the systemd unit and the scripted backup stay out of scope
and are named as deviations below rather than quietly skipped. LocalTuya device
configuration is now **in** scope, because without it there are no entities to
demo — but it is executed by `[[bring-up-the-hub]]` and
`[[add-a-tuya-device]]`, not re-specified here.

## Solution

The demo has four moving parts: the `deploy/` stack (already real, and owned by
`[[bring-up-the-hub]]`), the owner's Tuya devices as Home Assistant entities, the
addressing seam between the emulator and the host, and the app itself (which
needs exactly two build-side changes, one of them one line).

### Retired: the synthetic phase

An earlier revision of this plan stood the demo up on a synthetic fixture — a
template light, a template switch over `input_boolean`/`input_number` helpers,
and a mirror automation — in
`deploy/config/homeassistant/packages/demo_synthetic.yaml`. That fixture is
**retired and removed**: the package file is gone from `deploy/`, the two
template entities no longer exist on the hub, and **nothing in this procedure
asks anyone to create them**. It is recorded here for one reason only: a reader
who finds an old checkout, or an old note quoting those entity ids, should know
why they do not resolve and should not restore them.

A synthetic stand-in is not an acceptable substitute any more. The demo's value
is that the entities are the real ones — the same objects the phone will drive
tomorrow — so the substitute would re-open exactly the gap the retirement
closed.

### Two decisions this plan fixes

**1. Emulator → host networking — build-time `--dart-define`, primary host `10.0.2.2`.**

`app/lib/hub/http_hub_client.dart` declares it as:

```dart
/// The compile-time default hub base URL, per the design doc.
///
/// This one constant is two things: the default address when nothing else says
/// otherwise, and the demo/device override (`--dart-define=HUB_BASE_URL=…`).
/// The static fallback the mDNS search falls back to when it finds no hub (a
/// network that blocks multicast) is the documented default (`defaultHubHost`),
/// which this constant carries when no override is supplied — so an override
/// that is present but empty can never leave the app without an address.
const String defaultHubBaseUrl = String.fromEnvironment(
  'HUB_BASE_URL',
  defaultValue: defaultHubHost,
);
```

One const, now **one seed**: `main.dart` builds the shared `HubAddress` from it and hands `address.read` to `HttpHubClient`, `HttpLightCommandClient` and `WsLiveStateClient`, so each client reads the address at use time — once per REST request, once per WebSocket connection attempt — instead of caching a string. The emulator is run as:

```sh
fvm flutter run -d <android-device> --dart-define=HUB_BASE_URL=http://10.0.2.2:8123
```

`10.0.2.2` is the emulator's fixed alias for the host's loopback interface, and
the hub's HA service runs `network_mode: host`, so it answers there directly.
The default stays byte-identical, so the 205 fake-based tests are unaffected
(the discovery port is faked in every test, and none reaches the real network).
Rejected: `adb reverse tcp:8123 tcp:8123` — it needs the *same* code change (to
reach `localhost`) **plus** a per-session step that must be re-run after every
emulator restart, so it is kept only as the documented fallback; a runtime
host-setting UI would add a surface, a controller path and new tests for no demo
value. Increment 3 ships the **compile-time static fallback** (the documented
default `defaultHubHost` = `http://homeassistant.local:8123`, re-pointable with
`--dart-define`) as its fallback and adds **no runtime host-setting UI**.

**Discovery is now a runtime concern that ships (increment 3).** The override is
still a *build-time* seam and it still wins over discovery: when
`--dart-define=HUB_BASE_URL=…` is supplied, the mDNS search is **skipped
entirely**. Otherwise the mDNS search decides the runtime source of the base
URL, and the documented default (`defaultHubHost` =
`http://homeassistant.local:8123`) is the static fallback when the search finds
no hub — an override that is present but *empty* falls through to the search and
still leaves the app with that documented default, never with no address at all.
A real phone is addressed with the same define and the hub's LAN IP, or with the
`adb reverse` fallback over USB.

**2. Real entities — the owner's devices, and one authority per mirror.**

The app's own rendering rules constrain what the demo can use
(`app/lib/surfaces/light_entity.dart`): only `light.*` and `switch.*` survive;
the room is the object-id text before the first `_` and the device is the
remainder, both title-cased for display; `linkedBulbsFor` links a switch to
every light whose room matches; a light must report `brightness` for the slider
to appear; the switch-mirror screen is status-only. The owner's real devices
already satisfy that convention, so no fixture is needed — and none is
available.

| Entity id | Device | LAN host | Protocol | dps in use |
|---|---|---|---|---|
| `light.sala_luz_derecha` | A60 RGBCW bulb ("Luz derecha") | `192.168.0.201` | 3.4 | on/off **20**, brightness **22**, colour temp 23, colour 24, mode 21 |
| `light.sala_luz_izquierda` | A60 RGBCW bulb ("luz izquierda") | `192.168.0.229` | 3.4 | same map as the other A60 |
| `light.comedor_luz_sola` | 5-channel interface ("Luz sola") | `192.168.0.226` | 3.5 | same map |
| `switch.sala_tecla_canal_1` | 2-channel module ("TECLA"), channel 1 | `192.168.0.100` | — | channel 1 on dp **1** |
| `switch.comedor_tecla_canal_2` | same module, channel 2 | `192.168.0.100` | — | channel 2 on dp **2** |

The room in an entity id is the text before the first `_`, so the demo renders
two rooms — **Sala** (`Luz Derecha`, `Luz Izquierda`, `Tecla Canal 1`) and
**Comedor** (`Luz Sola`, `Tecla Canal 2`). The wiring and the grouping agree by
construction: canal 1's room holds the two sala bulbs, canal 2's room holds the
comedor bulb, so the app's room-scoped switch mirror lists exactly the bulbs the
automations drive.

| Channel — the authority | Bulbs written, only on a delta |
|---|---|
| `switch.sala_tecla_canal_1` | `light.sala_luz_derecha` **and** `light.sala_luz_izquierda` |
| `switch.comedor_tecla_canal_2` | `light.comedor_luz_sola` |

The mirror automations live in
`deploy/config/homeassistant/packages/real_devices.yaml` and keep the semantics
the corpus mandates (`[[adr-0006-tuya-bulb-widget-role]]`):
**channel-authoritative** (the wall switch is the arbiter; the bulb is written to
match it), **write-on-delta** (the
bulb is written only when its state actually differs from the channel's new
state), and **dp never guessed** (the channel's datapoint comes from observed
evidence — dp 1 and dp 2 on this module, dp 20 on the Type B bulbs, which
report no dp 1 at all). One writer only: with the automation live, the retired
legacy link-watch loop stays stopped (`[[home-assistant-hub]]`).

The app has **no write path for switches**, so the channel is flipped on the hub
side: HA **Developer Tools → Actions → `switch.turn_on` / `switch.turn_off`**
targeting `switch.sala_tecla_canal_1`, the physical wall switch itself, or the
`POST /api/services/switch/turn_on` curl in `## Examples`. That is the point — a
foreign writer flips the channel, the automation moves the bulbs, and the app
can only mirror it.

### Phase 0 — Preconditions (verify only; change nothing)

Working directory: repository root, except where noted.

| Check | Command | Observable |
|---|---|---|
| Docker daemon reachable | `docker version --format '{{.Server.Version}}'` | prints `29.x` |
| Compose v2 present | `docker compose version` | prints `v2.x` |
| Node present | `node --version` | prints `v26.x` |
| Emulator exists | `fvm flutter emulators` (cwd `app/`) | lists the `pixel` AVD |
| Flutter pin intact | `fvm flutter --version` (cwd `app/`) | `Flutter 3.47.7` / `Dart 3.13.5` |
| JDK 17 for the build | `JAVA_HOME=/path/to/jdk-17 java -version` | prints `17.x` (the **default** `java` may be newer — that is the failure this row catches) |
| Devices reachable on the LAN | `nc -z 192.168.0.201 6668 && nc -z 192.168.0.100 6668 && echo tuya-listening` | prints `tuya-listening` |

**Verify:** all seven commands succeed. **Gate:** no later phase starts until
Phase 0 passes; the pinned toolchain is `fvm flutter`, only from `app/`.
**Repo green:** untouched — `node validate.js` still exits 0 and
`fvm flutter test` is still the 205 baseline.

**The JDK 17 row is not decoration.** The Android Gradle build targets Java 17
(`sourceCompatibility`/`targetCompatibility` = `VERSION_17`,
`jvmTarget` = `JVM_17`, Gradle wrapper 9.3.1), but the Gradle/Groovy compiler
reads the *running* JDK's class files. On a machine whose default JDK is 27 the
build dies before compiling anything, with `Unsupported class file major version
71` (71 = Java 27) inside `BUG! exception in phase 'semantic analysis' in source
unit '_BuildScript_'`. Point the build at a JDK 17 instead of upgrading the
wrapper:

```sh
JAVA_HOME=/path/to/jdk-17 fvm flutter build apk --debug \
  --dart-define=HUB_BASE_URL=http://10.0.2.2:8123
```

**The device row is the new one.** The demo no longer has a hardware-free
fallback: if the bulbs do not answer on TCP/6668 from the hub's host, every
later phase fails at the entity census in Phase 2, not at the app.

### Phase 1 — Confirm the `deploy/` hub (the real artifact)

The stack is not written by this procedure. It exists in `deploy/` in the shape
`[[bring-up-the-hub]]` fixes, with the configuration and runtime state that
document and its deployment own; this phase confirms it, so that a broken stack
is caught before the app is blamed.

| Service | Image | Why it matters to the demo |
|---|---|---|
| `homeassistant` | `ghcr.io/home-assistant/home-assistant` (pinned by digest, tag `stable`) | the state authority; `network_mode: host` so LocalTuya keeps UDP 6666/6667, TCP/6668 and mDNS, and so the emulator's `10.0.2.2:8123` lands on it |
| `eclipse-mosquitto` | `eclipse-mosquitto` (pinned by digest, tag `2`) | hub-internal MQTT bus; the app never speaks it, so it can be down without touching the golden path |
| `tuya-local-key` | `ghcr.io/vineetchoudhary/tuya-local-key` (pinned by digest), `127.0.0.1:8000` | provisioning capability only; the hub holds the local keys of the real devices, in a gitignored config entry |

The package directory holds exactly what the demo needs:
`deploy/config/homeassistant/packages/real_devices.yaml` — three mirror
automations (canal 1 → the two sala bulbs, canal 2 → the comedor bulb). The
synthetic package that used to sit beside it is retired and removed; do not
re-create it (see *Retired: the synthetic phase*).

Start it and probe it (cwd `deploy/`):

```sh
docker compose config -q
docker compose up -d
docker compose ps
```

First start takes 30–60 s while Home Assistant initialises. Then:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8123/api/   # 401
nc -z 127.0.0.1 1883 && echo mosquitto-listening                       # mosquitto-listening
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/        # 200
```

**Verify:** `docker compose config -q` exits 0; `docker compose ps` shows all
three services `Up`; the three probes print `401`, `mosquitto-listening`,
`200`. The `401` is the point — HA is up **and** token-gated.
**Deviations, stated deliberately:** the systemd unit and the scripted backup
are out of scope for a workstation demo, and the broker is closed rather than
authenticated (no password file). LocalTuya is **not** a deviation any more: the
demo depends on it, and Phase 2 proves the devices it exposes.
**Repo green:** `node validate.js` exits 0 (no `.md` is created under `deploy/`).

### Phase 2 — Onboard HA, mint the token, prove the real entities

Home Assistant is host-networked, so onboarding happens in the **PC's** browser
at `http://127.0.0.1:8123` (the emulator's browser at `http://10.0.2.2:8123`
works too): create the owner account, then
**Profile → Security → Long-lived access tokens → Create** and copy the value.
It is a credential — keep it in an environment variable for the session, never
in a file, a doc, or a commit:

```sh
export HA_TOKEN=<long-lived-token>
```

(The same token can be minted programmatically over the WebSocket command
`auth/long_lived_access_token` once an owner exists — see the live-state
sequence in [[mobile-app-design]] — but the profile page is the documented
path.)

Then take the entity census — exactly the five ids of the entity table above,
and no synthetic leftovers (cwd: repository root):

```sh
curl -s -H "Authorization: Bearer $HA_TOKEN" http://127.0.0.1:8123/api/states | node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  const ids = JSON.parse(s).map(e => e.entity_id)
    .filter(i => /^(light|switch)\.(sala|comedor)_/.test(i)).sort();
  console.log(ids.join("\n"));
});'
```

**Verify:** five lines, one per row of the entity table. A missing
`light.sala_luz_*` is a provisioning or LAN problem — see `[[add-a-tuya-device]]`
and `[[troubleshooting]]`, not an app problem. An entity id that does not follow
`<domain>.<room>_<device>` will group into the wrong room in the app.

Then prove the light leg and the mirror without the app. Record the baseline
first — these are physical bulbs, whatever they are doing now is the baseline:

```sh
curl -s -H "Authorization: Bearer $HA_TOKEN" http://127.0.0.1:8123/api/states/light.sala_luz_derecha
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" -H 'Content-Type: application/json' \
     -d '{"entity_id":"light.sala_luz_derecha","brightness":64}' \
     http://127.0.0.1:8123/api/services/light/turn_on
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" -H 'Content-Type: application/json' \
     -d '{"entity_id":"switch.sala_tecla_canal_1"}' \
     http://127.0.0.1:8123/api/services/switch/turn_off
curl -s -H "Authorization: Bearer $HA_TOKEN" http://127.0.0.1:8123/api/states/light.sala_luz_derecha
```

**Verify:** after the light service call the read returns `"state":"on"` with
`"brightness":64`; after `switch.turn_off` on canal 1 the bulb reads
`"state":"off"` — that hop is the automation, proven before the app is involved.
Turn canal 1 back on (`switch.turn_on`) to leave the room as you found it, and
confirm both sala bulbs follow. A bulb whose state moves for the light call but
not for the switch call is an automation problem, not a LocalTuya problem.
**Repo green:** unchanged; nothing in the repo was touched.

### Phase 3 — Close the emulator → host gap in the app

Two files (cwd `app/` for the commands).

**`app/lib/hub/http_hub_client.dart`** (change) — the const from "Two decisions
this plan fixes" above.
**`app/android/app/src/main/AndroidManifest.xml`** (change) — add the cleartext
allowance to the application element:

```xml
<application
    android:label="daver_home"
    android:name="${applicationName}"
    android:icon="@mipmap/ic_launcher"
    android:usesCleartextTraffic="true">
```

Without it, `http://10.0.2.2:8123` is refused by the platform's cleartext
policy and the app reads as permanently *hub unavailable* no matter how correct
the host and token are. The design already accepts plain HTTP on the trusted
LAN (`[[security-and-privacy]]`), so the allowance belongs in the main
manifest; a network-security-config scoped to the hub host is the documented
hardening follow-up.

Launch the emulator, then prove the toolchain is still green:

```sh
fvm flutter emulators --launch pixel
adb devices                                  # emulator-5554   device
fvm flutter devices                          # use the id it reports in Phase 4
fvm flutter analyze
fvm flutter test
```

**Verify:** `fvm flutter analyze` prints `No issues found!`; `fvm flutter test`
reports all 205 cases green; `adb devices` shows `emulator-5554  device`. The
default base URL is unchanged, so the suites are untouched by the override.
**Repo green:** analyze clean and tests green, both from `app/` only.

### Phase 4 — Golden path on the emulator

Run (cwd `app/`), replacing the device id with the one `fvm flutter devices`
reported:

```sh
fvm flutter run -d emulator-5554 --dart-define=HUB_BASE_URL=http://10.0.2.2:8123
```

**(a) Connected.** The app opens with the token field (nothing is stored yet,
so the controller short-circuits to *hub unavailable* before any network call).
Paste the token — emulator clipboard sharing is the clean route; `adb shell
input text` works but puts the secret in the shell's history — then tap
**Save token**. **Verify:** the banner disappears (`HubStatus` null) and the
hub-health card shows **Hub connected / Live state on.**

**(b) Light toggle + brightness.** Tap **Sala → Luz Derecha**. **Verify:**
*Turn on* flips `State: on`, the row subtitle shows `on · <brightness>`, the
brightness slider appears (LocalTuya exposes dp 22 as the `brightness`
attribute), and a slider release shows `Brightness: <n>`; cross-check with
`curl -s -H "Authorization: Bearer $HA_TOKEN"
http://127.0.0.1:8123/api/states/light.sala_luz_derecha` showing the same
`"brightness"`. *Toggle* and *Turn off* are the other two writes; each is
confirmed over REST and echoed back over the WebSocket.

**(c) Switch mirror.** Back out, tap the **Sala** switch row (**Tecla Canal
1**). **Verify:** the mirror screen shows `State: on|off (read-only)` and lists
the bulbs it drives — *Luz Derecha* and *Luz Izquierda* — read-only. Flip the
channel from the wall switch, or from HA **Developer Tools → Actions →
`switch.turn_on`** targeting `switch.sala_tecla_canal_1` (or the Phase 2 curl),
and watch the row update live over the WebSocket, with the bulbs following
because the automation moved them. The module has no push, so the hub polls its
channels every couple of seconds — allow one poll cycle before calling it
broken. The screen never writes anything.

### Phase 5 — Failure-mode drills

| Scenario | How to force it | `HubStatus` | What the app shows |
|---|---|---|---|
| Absent token | first launch, or **Android settings → Apps → daver_home → Clear storage** | `hubUnavailable` + `needsToken` | banner **Hub unavailable** *and* the *Home Assistant access token* card; `connect()` returns before any network call, so a perfectly reachable hub is never contacted |
| Wrong or revoked token | mint a second token, enter it, then delete it in HA **Profile → Security**; or store a token, revoke it, and hot-restart | `hubUnavailable` + `needsToken` | banner **Hub unavailable** plus the token field (HTTP 401/403 is re-auth, not a retry loop); a tap on a bulb returns `needsToken` → snackbar *Re-enter your token* |
| HA container down | `docker compose stop homeassistant` (cwd `deploy/`) | `hubUnavailable` | banner **Hub unavailable** ("Home Assistant cannot be reached; state may be stale."); the bulb detail controls are disabled with the refused-commands card; a tap is refused → *Hub unavailable — command not sent*; the WebSocket reconnects with backoff (1 s → 2 s → … → 30 s cap) |
| HA not reachable at all (wrong host, 8123 blocked) | run with `--dart-define=HUB_BASE_URL=http://10.0.2.2:9999` | `hubUnavailable` | same banner; nothing is queued and nothing is faked |
| Phone offline | `adb shell cmd connectivity airplane-mode enable` | `offline` | banner **Phone offline** ("This device has no network, so the hub is unreachable.") — reached **only** by a no-route errno (ENETDOWN/ENETUNREACH/EHOSTUNREACH); any other failure is *hub unavailable*, which is the honest distinction |
| A bulb off the LAN | power the bulb off, or drop its static lease | unchanged — HA holds the entity | the room list still shows the bulb; commands fail at the device and its state goes stale. This is the hub's problem (`[[troubleshooting]]`), not a banner: the app is talking to a healthy hub about an unhealthy device |
| HA restarted while connected | `docker compose restart homeassistant` (cwd `deploy/`) | `connecting` | banner **Connecting to the hub**; on recovery the app resubscribes and re-reads the tracked entities, so the list is authoritative again |

Drill commands and their observables are in `## Examples`.

### Phase 6 — Keep the corpus truthful

- **`docs/protocols/functional-demo-plan.md`** (this document, v1.6) — golden
  path on the real devices; the synthetic phase recorded as retired.
- **`README.md`** — update the navigation row and the intro sentence so they
  describe the demo as running on the real Tuya devices, not on synthetic
  entities.
- **`docs/project.md`** — same correction in the overview and the *Procedures*
  list.
- **`docs/context/project-overview.md`** — same correction in the
  common-mistakes note about what the hub actually is.
- **`index.md`**, **`tag-index.md`** (regenerated, never hand-edited).

```sh
node validate.js --write   # cwd: repository root — refreshes the two generated regions
node validate.js           # cwd: repository root — must exit 0
```

**Verify:** `node validate.js --write` reports `wrote: index.md` /
`wrote: tag-index.md` on stderr when the tag or file set moved, and then
`0 error(s), 0 warning(s)`; a following `node validate.js` prints the same and
exits 0. Final gate, both directories: `node validate.js` (root) exits 0, and
`fvm flutter analyze` clean + `fvm flutter test` green (cwd `app/`).

## When to use

- Re-running the golden path on the real hub, on this machine or on a rebuilt
  one, before showing the app to anyone.
- Showing the design's golden path with the owner's actual bulbs and wall
  switch — no Tuya cloud account and no Smart Life app in the loop.
- Regression-testing the app's hub client against a real Home Assistant and real
  devices that are safe to toggle.
- Proving the switch mirror end to end after a LocalTuya or automation change.

## When not to use

- **For a device bring-up.** Pairing, key harvest, LocalTuya entries and the dp
  map are `[[add-a-tuya-device]]` plus `[[bring-up-the-hub]]`; this plan assumes
  them and only proves the result.
- **As a production bring-up.** No systemd unit, no backup routine, and the
  broker is closed rather than authenticated.
- **As a hardware-free demo.** There is no synthetic fallback any more: without
  the real devices reachable on TCP/6668 there is nothing to demo.
- **As an architecture decision.** The mirror semantics come from
  `[[adr-0006-tuya-bulb-widget-role]]` and the single-writer rule from
  `[[adr-0005-control-plane-authority]]`; this plan exercises them, it does not
  decide them.

## Examples

### Run the demo

```sh
# 1. the hub (cwd: deploy/)
docker compose up -d
docker compose ps

# 2. the app on the emulator (cwd: app/)
fvm flutter emulators --launch pixel
fvm flutter devices
fvm flutter run -d emulator-5554 --dart-define=HUB_BASE_URL=http://10.0.2.2:8123
```

### Golden-path script (say this while you tap)

```text
a. App opens with a token field and a "Hub unavailable" banner.
b. Paste the long-lived token, tap "Save token".
   -> banner disappears, "Hub connected / Live state on." appears.
c. Sala -> "Luz Derecha" -> "Turn on".
   -> "State: on", row shows "on · <brightness>", the brightness slider appears.
d. Drag the slider and release.
   -> "Brightness: 96"; the Home Assistant state agrees:
      GET /api/states/light.sala_luz_derecha -> "brightness": 96
e. Back -> Sala -> "Tecla Canal 1" (the switch row).
   -> mirror screen: "State: on|off (read-only)" + the bulbs it drives
      ("Luz Derecha", "Luz Izquierda"), listed, not tappable.
f. Flip the channel from the wall or from HA, not from the app:
      Developer Tools -> Actions -> switch.turn_off -> target switch.sala_tecla_canal_1
   -> within a poll cycle the mirror row shows off AND both sala bulbs turn off.
      The app never had a switch write path; the automation did the work.
g. Comedor -> "Tecla Canal 2" -> same shape, one bulb ("Luz Sola").
```

### Hub-side drills

```sh
cd deploy

# HA down -> "Hub unavailable" (banner is immediate; bulb controls disable)
docker compose stop homeassistant
docker compose start homeassistant

# HA restart -> "Connecting to the hub", then reconnected (resubscribe + re-read)
docker compose restart homeassistant

# broker down -> no app impact (the app never speaks MQTT)
docker compose stop eclipse-mosquitto

# whole stack down -> "Hub unavailable" for the rest of the session
docker compose down
docker compose up -d
```

```sh
cd app

# wrong host -> "Hub unavailable" (nothing is queued)
fvm flutter run -d emulator-5554 --dart-define=HUB_BASE_URL=http://10.0.2.2:9999

# phone offline -> "Phone offline" only if the route actually disappears
adb shell cmd connectivity airplane-mode enable
adb shell cmd connectivity airplane-mode disable
```

### Cross-checking the hub without the app

```sh
export HA_TOKEN=<long-lived-token>

curl -s -H "Authorization: Bearer $HA_TOKEN" http://127.0.0.1:8123/api/states/light.sala_luz_derecha
curl -s -H "Authorization: Bearer $HA_TOKEN" http://127.0.0.1:8123/api/states/switch.sala_tecla_canal_1

# flip the channel (what the wall switch and Developer Tools do)
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" -H 'Content-Type: application/json' \
     -d '{"entity_id":"switch.sala_tecla_canal_1"}' \
     http://127.0.0.1:8123/api/services/switch/turn_on

# entity census: exactly the demo's ids under light./switch., rooms sala|comedor
curl -s -H "Authorization: Bearer $HA_TOKEN" http://127.0.0.1:8123/api/states | node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  const ids = JSON.parse(s).map(e => e.entity_id)
    .filter(i => /^(light|switch)\.(sala|comedor)_/.test(i)).sort();
  console.log(ids.join("\n"));
});'
```

## Common mistakes

- **Reaching for the retired synthetic entity ids.** They were removed with the
  fixture; an `entity_id` copied from an old note returns `Entity not found`, and
  a run that "works" against them is not talking to this hub at all. Do not
  restore the fixture.
- **Guessing dp 1 for the bulbs.** Both A60 bulbs are **Type B**: no dp 1 at
  all, on/off on dp 20 and brightness on dp 22. A LocalTuya entry built from a
  generic Tuya template yields a bulb that never turns on while the LAN, the key
  and the app are all fine.
- **Running the demo on unprovisioned hardware.** No LocalTuya entry means no
  entity, and the app shows an empty room — not an error. The entity census in
  Phase 2 is there to catch exactly that.
- **Leaving a retired legacy link-watch loop running.** Two writers on one bulb: the
  automation and the desktop loop fight, and HA's state goes stale after every
  applet toggle. The service stays stopped (`[[home-assistant-hub]]`).
- **Forgetting the cleartext allowance.** Without
  `android:usesCleartextTraffic="true"` (or a network-security-config) every
  request dies in the platform's network policy and the app looks broken while
  the hub is fine — the failure is silent in the UI, which only ever says
  *Hub unavailable*.
- **Typing the URL into the emulator instead of the build.** The app has no
  host-setting UI; the host is fixed at build time by
  `--dart-define=HUB_BASE_URL=…`. Leaving the flag off on the emulator means
  the default `http://homeassistant.local:8123`, which the emulator cannot
  resolve or route to.
- **Forgetting `--dart-define` on a later `fvm flutter run`.** Every run needs
  it; a rebuild without it silently reverts to the unresolvable default.
- **Running the app with no token and blaming the network.** With no stored
  token the controller returns `hubUnavailable` + `needsToken` **before any
  network call** — a reachable hub is never contacted.
- **Dropping a `.md` file under `deploy/`.** `validate.js` walks `deploy/`, and
  a `deploy/README.md` fails `non-kebab-case-name` and `missing-from-hub`. The
  demo's documentation lives in this procedure, registered in `README.md`.
- **Starting the stack with `packages/` missing.** `!include_dir_named
  packages` fails configuration validation and Home Assistant refuses to start.
  The folder must exist and hold `real_devices.yaml` before the first
  `docker compose up -d`. Package files are `snake_case` (`real_devices.yaml`),
  not kebab-case like the corpus `.md` files: `!include_dir_named` derives the
  package name from the filename stem and Home Assistant validates that name
  with `cv.slug`, which rejects hyphens — so the config file deliberately breaks
  the corpus's kebab-case filename convention.
- **Pointing `password_file` at a file that does not exist.** Mosquitto exits,
  `restart: unless-stopped` crash-loops it, and the stack never settles. This
  is exactly why the demo config closes the listener with
  `allow_anonymous false` and no password file.
- **Committing the token, a local key, or
  `deploy/config/homeassistant/.storage/`.** The token is a credential: keep it
  in an environment variable, in the OS keystore, or in a `0600` file **outside
  the repository** — never in a tracked file, never in a doc. `.storage/` holds
  the owner account, the LocalTuya keys and the tokens; `.gitignore` is what
  keeps it out of git.
- **Reading the demo as a full hub bring-up.** `tuya-local-key` is the real,
  deployed capability, but the systemd unit and the backup routine are still
  someone else's procedure — `[[bring-up-the-hub]]` — and this plan says so on
  purpose.
- **Flipping the switch from the app.** There is no write path for switches by
  design; the channel is flipped at the wall or on the hub side, and the app
  mirrors it. Adding a switch toggle would create the second writer
  `[[adr-0005-control-plane-authority]]` forbids.

## References

- [bring-up-the-hub.md](bring-up-the-hub.md) — the compose/topology contract
  this `deploy/` tree implements.
- [add-a-tuya-device.md](add-a-tuya-device.md) — how the entities the golden
  path drives were provisioned, and how to re-provision one.
- [new-note-protocol.md](new-note-protocol.md) — the corpus contract this
  document is written to.
- [../context/hosting-architecture.md](../context/hosting-architecture.md) — the
  layer model, ports and service inventory the stack reproduces.
- [../context/home-assistant-hub.md](../context/home-assistant-hub.md) — HA as
  authority, the provisioned device table, and the automation semantics the
  mirror reuses.
- [../context/mobile-app-design.md](../context/mobile-app-design.md) — the app's
  surfaces, addressing and offline semantics.
- [../context/tuya-local-key-integration.md](../context/tuya-local-key-integration.md)
  — the port-8000 posture and why the container is deployed with no devices.
- [../context/security-and-privacy.md](../context/security-and-privacy.md) — the
  trusted-LAN/plain-HTTP assumption, token custody, and the no-anonymous-broker
  rule.
- [../context/troubleshooting.md](../context/troubleshooting.md) — the symptom
  table the drills exercise ("the app cannot reach the hub after a PC reboot",
  "Home Assistant is unreachable on port 8123").
- [../../adrs/adr-0005-control-plane-authority.md](../../adrs/adr-0005-control-plane-authority.md)
  — why the app has no second write path.
- [../../adrs/adr-0006-tuya-bulb-widget-role.md](../../adrs/adr-0006-tuya-bulb-widget-role.md)
  — the mirror automation's requirements source.
- [../project.md](../project.md) — the agent entry point and slice routing.
- [../../README.md](../../README.md) — where this procedure is registered.
- `deploy/config/homeassistant/packages/real_devices.yaml` — the three mirror
  automations the golden path exercises (a repository file, not a corpus doc,
  so named rather than linked).
