---
id: adr-0003-tuya-lan-protocol-over-mqtt-device-leg
category: adrs
tags: [adr, architecture, tuya, mqtt]
aliases: ["ADR-0003"]
related: [adr-index, mqtt-topic-map, home-assistant-hub]
version: 1.0
status: active
---

# ADR-0003: Tuya LAN protocol on the device leg, not MQTT

## Problem

The owner's original sketch drew the device leg as an MQTT/Wi-Fi link:

    [ Dispositivos/Focos ] <---(MQTT/Wi-Fi)---> [ Servidor Central ]

That is wrong for the hardware in this home. The Tuya bulbs and switches do not
speak MQTT. Over Wi-Fi they speak the Tuya LAN protocol on TCP/6668, a
`dps`-based payload (on/off rides dp 1 or dp 20 depending on the device), and
they are driven by Home Assistant through the **LocalTuya** integration
(`tinytuya` underneath). An MQTT device leg would therefore never reach them:
publishing to it would leave the bulbs unresponsive while appearing to be a
valid integration.

## Solution

Fix the device leg to the Tuya LAN protocol over Wi-Fi (TCP/6668, `dps` 1/20),
driven by Home Assistant via LocalTuya / `tinytuya` — **not** MQTT. What stays:

- **Eclipse Mosquitto** remains in the architecture as the **hub-internal** MQTT
  bus. It carries MQTT-native devices and future extensions, and it is the
  integration point this ecosystem keeps for sensors and actuators that do
  speak MQTT.
- **No Tuya bulb traffic crosses MQTT.** The hub-managed bulbs are written only
  by Home Assistant / LocalTuya on the authoritative path (see
  [adr-0005-control-plane-authority.md](adr-0005-control-plane-authority.md)).

The corrected layer model is therefore:

    [ Tuya bulb / switch ] --Wi-Fi LAN, TCP/6668 + dps (LocalTuya)--> [ HUB on the owner's PC ]
    [ HUB ] --MQTT (hub-internal bus)--> [ MQTT-native devices and future extensions ]

## When to use

When reading the architecture's layer model, or when deciding how a new device
attaches to the hub.

## When not to use

Do not use this record as a provisioning tutorial — that procedure is
[../docs/protocols/add-a-tuya-device.md](../docs/protocols/add-a-tuya-device.md).

## Examples

The corrected two-line layer model:

    [ Tuya bulb / switch ] --Wi-Fi LAN, TCP/6668 + dps (LocalTuya)--> [ HUB: HA + Mosquitto ]
    [ HUB ] --MQTT (hub-internal only)--> [ MQTT-native devices ]

## Common mistakes

- **Wiring an MQTT bridge for the bulbs.** It cannot work: the bulbs never
  answer MQTT; LocalTuya speaks the LAN protocol.
- **Publishing the sketch's `casa/habitacion/foco/estado` topics** and
  expecting the bulbs to respond. Those topics belong to the hub-internal bus,
  not to the device leg.
- **Reading Mosquitto's presence as proof of an MQTT device leg.** The broker
  exists for MQTT-native devices; its existence does not move the Tuya bulbs
  onto MQTT.

## References

- [../docs/context/mqtt-topic-map.md](../docs/context/mqtt-topic-map.md) — the hub-internal topic map.
- [../docs/context/home-assistant-hub.md](../docs/context/home-assistant-hub.md) — the hub that runs LocalTuya.
- [adr-0005-control-plane-authority.md](adr-0005-control-plane-authority.md) — who owns device state.
- [adr-index.md](adr-index.md) — the hub these records are registered in.
