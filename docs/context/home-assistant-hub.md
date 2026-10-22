---
last_updated: 2026-10-22
status: active
description: The hub's internals and operations - Compose services, LocalTuya, recorder, MQTT integration, automations, restart and backup.
tags: [home-assistant, operations, localtuya, recorder, automation]
version: 1.9
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

LocalTuya is installed as a custom integration - not the core Tuya integration, which would route through the cloud. It reaches the hub through HACS where the install supports it, or by unpacking the release into `deploy/config/homeassistant/custom_components/localtuya/` on a Container install (no Supervisor, no HACS UI); the directory is gitignored, because third-party integration code is installed state, not repo source. It can run in local-only mode (`no_cloud: true`), so the hub needs no Tuya cloud account. Each hub-managed device is configured with its `id`, `host` (static-leased IP), `<local_key>`, and `protocol_version`, then mapped to the datapoints that actually exist:

- on/off on **dp 1** on some devices, **dp 20** on many bulbs - this must be discovered, never assumed;
- brightness and colour on their own dps where supported.

The `id`, `local_key`, and dp map come from tuya-local-key at provisioning time - see [[tuya-local-key-integration]] and [[provisioning-flow]].

The hub's Tuya devices, as provisioned:

| Entity id | Device | LAN host | Protocol | dps used |
|---|---|---|---|---|
| `light.sala_luz_derecha` | A60 RGBCW ("Luz derecha") | 192.168.0.201 | 3.4 | on/off 20, brightness 22, colour temp 23, colour 24, mode 21 |
| `light.sala_luz_izquierda` | A60 RGBCW ("luz izquierda") | 192.168.0.229 | 3.4 | on/off 20, brightness 22, colour temp 23, colour 24, mode 21 |
| `light.comedor_luz_sola` | 5-channel interface ("Luz sola") | 192.168.0.226 | 3.5 | on/off 20, brightness 22, colour temp 23, colour 24, mode 21 |
| `switch.sala_tecla_canal_1` | 2-channel module ("TECLA") | 192.168.0.100 | 3.4 | channel 1 on dp 1 |
| `switch.comedor_tecla_canal_2` | 2-channel module ("TECLA") | 192.168.0.100 | 3.4 | channel 2 on dp 2 |

**Canal 1 drives both sala bulbs.** The wall switch's channel 1 is the authority
for `light.sala_luz_derecha` *and* `light.sala_luz_izquierda` - the retired legacy
applet's own link config had one channel driving both bulbs of the sala - and channel 2
drives `light.comedor_luz_sola`. There is no bulb-to-bulb follower and no light
group: the switch is the single authority, and Home Assistant writes the bulbs
that follow it (ADR-0005).

All three bulbs are **Type B**: their live dp table reports no dp `1` at all and
carries the power boolean on dp `20`, with brightness on dp `22` (the value that
tracks the cloud's `bright_value_v2`) and colour temp on dp `23`. That is
observed evidence, not a model assumption - a different bulb must be read again.

The channel entities are polled (`scan_interval: 2`) because the two-channel module has no push, and their entity ids carry the room of the bulb each channel drives, so the app's room-scoped switch mirror lists the right bulb.

A device that is online in the cloud but on a network segment the hub cannot
reach (a guest or isolated SSID) stays invisible to the hub: it answers on no
subnet and announces nothing on the Tuya broadcast. The hub can only add it
once it answers on TCP/6668.

### One writer only

Once Home Assistant owns a bulb, any legacy direct-to-device writer is a **second writer** and must stay stopped. The retired legacy applet's link-watch service failed silently while its cached keys were stale, and it would have started fighting the hub's automation the moment the keys were refreshed. That project is gone, but an install left behind on a machine is not: if a legacy link-watch service or a stale applet is still present, it must stay stopped, or it must be removed. The in-repo desktop surface under `widget/` writes nothing but the switch channel, through this API. The hub's own mirror automations live in `deploy/config/homeassistant/packages/real_devices.yaml`.

### Recorder (SQLite)

The recorder writes entity history to SQLite inside the HA config volume. It is the system's history store - there is no separate database. Nothing else queries a history service, and a dropped database is never rebuilt; a fresh DB is the deferred option, not a parallel one.

### MQTT integration

The MQTT integration is the **only** bridge between Mosquitto and Home Assistant entities. MQTT-native devices publish to topics under `casa/...`; the integration turns each into an entity (or is configured by retained discovery). Because every topic surfaces as an entity, the app never sees MQTT - it sees Home Assistant. The topic and payload contract lives in [[mqtt-topic-map]].

### Automations (switch -> bulb mirror)

The switch-mirrors-bulb automation follows the mirror semantics fixed by the decision record:

- **channel-authoritative** - the wall switch's channel is the source; the light follows it;
- **write-on-delta** - only write the light when the mirrored value actually differs, so no command storm;
- **dp never guessed** - if the datapoint is unknown, refuse rather than guess.

These rules are the requirements recorded in [[adr-0006-tuya-bulb-widget-role]]; the implementation is a native Home Assistant automation, not a desktop applet.

### Restart behaviour

On restart, the app reconnects its WebSocket and resubscribes to `state_changed`; entities restore from the registry and recorder; LocalTuya reconnects to devices over the LAN; and MQTT-native entities republish their retained state so they come back without waiting. While HA is down, the app shows "hub unavailable" and never queues commands.

### Backup routine (no Supervisor)

A Container install has no Supervisor snapshots, so a scripted routine replaces them: archive the HA config volume, the mosquitto config, and the compose file, then copy the archive off-host. Verify a restore before trusting the routine; the same script covers the `deploy/` manifests that ship in the repo.

The script (`deploy/scripts/backup.sh`) **deliberately leaves the recorder database out**: Home Assistant writes it while it runs, so a copy taken now would be a torn database. It is history, not configuration, and the hub rebuilds it — a restored hub starts with an empty history rather than a corrupt one. The archive does include `.storage/` (the owner account, the access tokens and the LocalTuya local keys), which is why it is written `0600` to a mounted volume and why the recorder DB is the one thing that is deliberately absent.

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
- Running a stale install of the retired legacy applet while HA thinks otherwise - it writes the bulb directly over TCP/6668. The in-repo `widget/` cannot cause that, because it writes only the switch channel through Home Assistant.

## References

- [hosting-architecture](hosting-architecture.md)
- [mqtt-topic-map](mqtt-topic-map.md)
- [tuya-local-key-integration](tuya-local-key-integration.md)
- [troubleshooting](troubleshooting.md)
