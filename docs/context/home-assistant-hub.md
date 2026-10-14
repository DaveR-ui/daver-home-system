---
last_updated: 2026-10-14
status: active
description: The hub's internals and operations - Compose services, LocalTuya, recorder, MQTT integration, automations, restart and backup.
tags: [home-assistant, operations, localtuya, recorder, automation]
version: 1.0
related: [hosting-architecture, mqtt-topic-map, provisioning-flow]
---

# Home Assistant Hub

## Problem

Home Assistant is the system's centre of gravity, but its value depends on internals that are easy to get subtly wrong: which integration reaches the Tuya devices, where history lives, how MQTT-native state becomes an entity, how a switch mirrors a bulb without guessing datapoints, and how the hub recovers after a restart. A Container install also has no Supervisor, so backups and health checks have to be owned explicitly.

## Solution

The hub runs Home Assistant Container, Eclipse Mosquitto, and tuya-local-key as Compose services on the owner's PC. This doc covers what Home Assistant does internally and how it is kept healthy; for the topology, ports, and stack rationale see [[hosting-architecture]].

### The three services

| Service | Job in the hub |
| --- | --- |
| Home Assistant Container | State authority: entities, recorder, automations, REST + WebSocket API |
| Eclipse Mosquitto | MQTT bus for MQTT-native devices; reached by HA's MQTT integration |
| tuya-local-key | Harvests and maintains Tuya local keys; not involved in day-to-day control |

### Why `network_mode: host`

Home Assistant runs on the host network in the container because LocalTuya needs UDP 6666/6667 broadcast, TCP/6668, and mDNS. The Docker bridge NATs that broadcast traffic away, so device discovery and control fail on the bridge. Mosquitto and tuya-local-key only need TCP and stay on published ports.

### LocalTuya: the Tuya device path

LocalTuya is installed through HACS as a custom integration - not the core Tuya integration, which would route through the cloud. Each hub-managed device is configured with its `id`, `host` (static-leased IP), `<local_key>`, and `protocol_version`, then mapped to the datapoints that actually exist:

- on/off on **dp 1** on some devices, **dp 20** on many bulbs - this must be discovered, never assumed;
- brightness and colour on their own dps where supported.

The `id`, `local_key`, and dp map come from tuya-local-key at provisioning time - see [[tuya-local-key-integration]] and [[provisioning-flow]].

### Recorder (SQLite)

The recorder writes entity history to SQLite inside the HA config volume. It is the system's history store - there is no separate database. Nothing else queries a history service, and a dropped database is never rebuilt; a fresh DB is the deferred option, not a parallel one.

### MQTT integration

The MQTT integration is the **only** bridge between Mosquitto and Home Assistant entities. MQTT-native devices publish to topics under `casa/...`; the integration turns each into an entity (or is configured by retained discovery). Because every topic surfaces as an entity, the app never sees MQTT - it sees Home Assistant. The topic and payload contract lives in [[mqtt-topic-map]].

### Automations (switch -> bulb mirror)

The switch-mirrors-bulb automation inherits the widget's link semantics:

- **channel-authoritative** - the wall switch's channel is the source; the light follows it;
- **write-on-delta** - only write the light when the mirrored value actually differs, so no command storm;
- **dp never guessed** - if the datapoint is unknown, refuse rather than guess.

These rules are the requirements carried over from tuya-bulb-widget's `link watch` behaviour; the implementation is a native Home Assistant automation, not the applet. See [[tuya-bulb-widget-integration]].

### Restart behaviour

On restart, the app reconnects its WebSocket and resubscribes to `state_changed`; entities restore from the registry and recorder; LocalTuya reconnects to devices over the LAN; and MQTT-native entities republish their retained state so they come back without waiting. While HA is down, the app shows "hub unavailable" and never queues commands.

### Backup routine (no Supervisor)

A Container install has no Supervisor snapshots, so a scripted routine replaces them: archive the HA config volume (including the recorder DB), the mosquitto config, and the compose file, then copy the archive off-host. Verify a restore before trusting the routine; the same script covers the `deploy/` manifests when they land.

### Health checks

| Check | Healthy signal |
| --- | --- |
| HA API | `GET /api/` returns `200` with `{"message":"API running."}` |
| Broker | Port `1883` accepts connections and MQTT entities are not `unavailable` |
| Entities | Tuya entities update; `unavailable` points at a LAN, key, or broker problem |
| Provisioning | tuya-local-key answers on `8000` (loopback or authenticated) |

## When to use

- When configuring a Tuya device path, an automation, or the MQTT bridge.
- When writing or testing the backup and health routines.
- When diagnosing an entity that will not update.

## When not to use

- For hosting topology, ports, and stack choices - see [[hosting-architecture]].
- For the MQTT topic/payload contract - see [[mqtt-topic-map]].
- For the provisioning login itself - see [[tuya-local-key-integration]].

## Examples

LocalTuya device entry (placeholders, never real secrets):

```yaml
host: 192.0.2.10            # static DHCP lease
device_id: <device_id>
local_key: <local_key>
protocol_version: "3.3"
```

Switch-mirrors-bulb automation:

```yaml
alias: Mirror hallway switch to hallway light
triggers:
  - trigger: state
    entity_id: switch.hallway_switch
actions:
  - action: light.turn_on
    target:
      entity_id: light.hallway
    # write-on-delta: only reached when the mirrored channel differs
```

Health probe (token is a placeholder):

```sh
curl -H "Authorization: Bearer <long-lived-access-token>" http://<host>:8123/api/
```

## Common mistakes

- Installing the core Tuya integration instead of LocalTuya, which parks control back on the cloud.
- Assuming on/off lives on dp 1 - many bulbs use dp 20; discover the dp map instead.
- Running Home Assistant on the Docker bridge and losing device discovery.
- Adding a separate database for history - the recorder's SQLite already covers it.
- Expecting Supervisor snapshots on a Container install; run the scripted backup instead.
- Letting the Plasma applet write the bulb while HA thinks otherwise - the applet is a fallback, not a co-authority.

## References

- [hosting-architecture](hosting-architecture.md)
- [mqtt-topic-map](mqtt-topic-map.md)
- [tuya-local-key-integration](tuya-local-key-integration.md)
- [tuya-bulb-widget-integration](tuya-bulb-widget-integration.md)
- [troubleshooting](troubleshooting.md)
