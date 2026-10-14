---
last_updated: 2026-10-14
status: active
description: The MQTT topic taxonomy and JSON payload contract for MQTT-native devices and extensions - explicitly not the Tuya bulbs.
tags: [mqtt, contract, topics, payloads, home-assistant]
version: 1.0
related: [home-assistant-hub, hosting-architecture, project-overview]
---

# MQTT Topic Map

## Problem

MQTT-native devices and future extensions need one shared contract for topics and payloads, or every device invents its own names and every consumer parses differently. At the same time, the Tuya bulbs must stay out of MQTT entirely - wiring them here would contradict the corrected layer model, because they speak the Tuya LAN protocol and are reached through LocalTuya.

## Solution

This is the MQTT contract for **MQTT-native devices and extensions only**. The Tuya bulbs are LocalTuya/LAN and never appear on these topics - see [[adr-0003-tuya-lan-protocol-over-mqtt-device-leg]]. Every topic below is bridged into a Home Assistant entity by the MQTT integration, so the app still sees only HA entities ([[home-assistant-hub]]).

### Topic scheme

Root namespace `casa/` is fixed from the owner's sketch. Below it, segments are English kebab-case so any device firmware and the app share the same constants.

| Topic | Direction | Purpose |
| --- | --- | --- |
| `casa/<room>/<device>/state` | device -> broker | Published current state |
| `casa/<room>/<device>/set` | broker -> device | Commands to the device |
| `casa/<room>/<device>/available` | device -> broker | LWT online/offline |
| `casa/<room>/<device>/config` | operator -> broker | Retained discovery/identity metadata |

Example with the sketch's vocabulary kept at the root only: `casa/living/foco-1/state`.

### Vocabulary: sketch (Spanish) to English constants

| Sketch | Constant | Notes |
| --- | --- | --- |
| `casa/<habitacion>/` | `casa/<room>/` | `casa` root is fixed; `<room>` is an English kebab slug (`living`, `kitchen`) |
| `<dispositivo>` | `<device>` | Stable kebab slug (`foco-1`, `sensor-temp-1`) |
| `/estado` | `/state` | Retained, device-published |
| `/set` | `/set` | Not retained, device-subscribed |
| `/disponible` | `/available` | Retained, LWT |
| `/config` | `/config` | Retained, operator-published |

The English form is canonical; the Spanish sketch is the origin, not an implementation detail. Consumers never read `estado`/`brillo`/`actualizado`.

### State payload

Canonical (English):

```json
{"state":"ON","brightness":80,"updated_at":"2026-10-14T18:30:00Z"}
```

The Spanish sketch equivalent, kept only for traceability:

```json
{"estado":"ON","brillo":80,"actualizado":"2026-10-14T18:30:00Z"}
```

`updated_at` is ISO-8601 UTC. Fields present are limited to what a device supports; a payload is a full snapshot of the device's known state, not a delta.

### Command payloads per domain

- **light** on `set` - any subset of:

```json
{"state":"ON","brightness":80,"color":{"r":255,"g":180,"b":64}}
```

- **sensor** - read-only telemetry published on `state`, never commanded:

```json
{"temperature":21.5,"humidity":48,"updated_at":"2026-10-14T18:30:00Z"}
```

### Retained messages and LWT

| Topic | Retained | Why |
| --- | --- | --- |
| `state` | Yes | A late subscriber gets the last known value instead of waiting for the next update |
| `available` | Yes | Carries the device's LWT so consumers detect offline |
| `set` | No | A stale command must never replay on reconnect |
| `config` | Yes | Identity/discovery must survive a broker restart |

### QoS

| Traffic | QoS | Why |
| --- | --- | --- |
| `state` | 1 | At-least-once; state is idempotent, and a missed transition matters |
| `set` | 1 | Commands must arrive; device handlers are idempotent |
| high-frequency telemetry | 0 | Loss is acceptable; do not queue a flood |

### Home Assistant mapping

| Topic role | HA MQTT entity key |
| --- | --- |
| `.../state` | `state_topic` |
| `.../set` | `command_topic` |
| `.../available` | `availability_topic` (`online` / `offline`) |
| `.../config` | retained discovery/identity metadata |

Because each topic becomes an entity, the contract stays invisible to the app: it reads and writes HA entities over REST + WebSocket.

## When to use

- When adding an MQTT-native device or an extension that genuinely speaks MQTT.
- When configuring an HA MQTT entity for a topic.
- When changing the payload shape that devices and automations both consume.

## When not to use

- For Tuya bulbs or anything reached through LocalTuya - those are LAN topics on TCP/6668, not MQTT.
- For the hub's internals - see [[home-assistant-hub]].
- For app-side state and reconnection - see [[mobile-app-design]].

## Examples

1. **A light.** The device publishes `casa/living/foco-1/state` retained at QoS 1; a consumer or automation sends a command to `casa/living/foco-1/set`. HA maps `state_topic` and `command_topic` to a light entity.

2. **A sensor.** `casa/kitchen/sensor-temp-1/state` publishes telemetry at QoS 0, retained, so a viewer that connects late still sees the last reading.

3. **An HA automation consuming a topic.** Trigger on `casa/kitchen/sensor-temp-1/state`, compare the JSON value, and act on a Home Assistant entity - the app-side effect is an entity change, not an MQTT call.

## Common mistakes

- Publishing Tuya bulb state to MQTT as if the bulbs listened - they do not; they are LocalTuya/LAN ([[adr-0003-tuya-lan-protocol-over-mqtt-device-leg]]).
- Sending non-JSON payloads, forcing brittle string parsing on every consumer.
- Leaving `state` unretained, so subscribers must wait for the next update to know anything.
- Letting topic names drift between the Spanish sketch (`/estado`, `/brillo`) and the English implementation (`/state`, `/brightness`).
- Publishing `set` as retained and replaying a stale command on reconnect.

## References

- [home-assistant-hub](home-assistant-hub.md)
- [hosting-architecture](hosting-architecture.md)
- [adr-0003-tuya-lan-protocol-over-mqtt-device-leg](../../adrs/adr-0003-tuya-lan-protocol-over-mqtt-device-leg.md)
- [project-overview](project-overview.md)
