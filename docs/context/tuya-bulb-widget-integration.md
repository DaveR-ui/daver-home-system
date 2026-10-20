---
last_updated: 2026-10-20
status: active
description: Component C4 — tuya-bulb-widget's role boundary in the hub (dp-inspection evidence, interim desktop fallback, not a writer), its retired link-watch job, and the out-of-band-writer risk.
tags: [tuya-bulb-widget, integration, component, plasma, dp-inspection, mirror]
version: 1.1
related: [home-assistant-hub, provisioning-flow, troubleshooting, security-and-privacy]
---

# tuya-bulb-widget Integration

## Problem

An existing, working KDE Plasma tool already controls Tuya bulbs over the LAN and already mirrors a wall switch to them. In the new hub it must not become a second writer: hub-managed bulbs have exactly one authority (Home Assistant/LocalTuya), and two writers with no state owner produce stale state and write fights. Yet the widget holds knowledge the hub still needs — the local dp ids that make LocalTuya configuration correct.

## Solution

**C4 — tuya-bulb-widget** is an existing project reused **unmodified**. It speaks neither MQTT nor HTTP: it drives Tuya devices directly with `tinytuya` over LAN **TCP/6668**, writes dps `1`/`20`, keeps its config `0600`, and returns exit codes `0–10`. Its role here is bounded by ADR-0006:

1. **dp-inspection evidence source.** `link dps` (and the config/doctor surfaces) enumerates a device's datapoints — the local dp id mapping that step 3 of [[provisioning-flow]] needs. This is what makes LocalTuya configuration correct instead of guessed.
2. **Interim desktop fallback surface.** Until LocalTuya bring-up passes for a device, the Plasma applet remains a quick local toggle.
3. **Not a hub writer.** Hub-managed bulbs are written only by Home Assistant/LocalTuya. The applet is never advertised as a hub control path.

### What the owner keeps using it for

| Use | Surface |
|---|---|
| Quick local toggle from the desktop | Plasma applet (applet shells out to the CLI) |
| Inspecting a device | `doctor`, status, dp listing |
| dp discovery for a new device | dp enumeration (cloud metadata primary, `--from-live` fallback) |

### What stops

- The **`link watch`** systemd user service — the loop that mirrors a switch channel to one or more bulbs — moves to a **Home Assistant automation**. The automation inherits the widget's semantics exactly, because they are the requirements source:
  - **channel-authoritative** — the switch channel dp is the arbiter; the bulb is written to match it,
  - **write-on-delta** — write only when the target differs, so concurrent actors never fight a permanent write storm,
  - **dp never guessed** — the channel dp id comes from enumeration evidence, not from assuming `1`/`2`.
- The widget is not extended, not forked, and not modified to speak MQTT or HTTP.

### Residual out-of-band-writer risk

If the owner **opens and uses the Plasma applet**, it still writes the bulb directly over TCP/6668. Home Assistant's entity state then goes **stale until its next poll**, because HA did not observe that write. The hub does not detect it immediately; it recovers on the next poll. Mitigations: never advertise the applet as a hub path, prefer the app once LocalTuya bring-up passes, and re-read the entity if a mismatch is suspected — see symptom 4 in [[troubleshooting]].

### Retirement path

Once LocalTuya bring-up passes for a device (entities appear, commands land, state stays fresh), the widget becomes **optional** for that device. Retirement is per device, not a switch-day: keep it as dp evidence and desktop fallback where it still earns its keep, and stop treating it as a writer where the hub owns the device.

## When to use

- Confirming a device's dp mapping before writing LocalTuya config.
- A quick local toggle while a device is not yet brought up under the hub.
- Understanding why a bulb's HA state looks stale after someone used the desktop.

## When not to use

- As the hub's control surface for a device LocalTuya already owns — that is Home Assistant's job.
- As an MQTT or HTTP integration — it can neither speak MQTT nor be modified to.
- As the long-term home of switch mirroring — that is the automation.

## Examples

```text
# dp evidence for LocalTuya config (unmodified widget)
tuya-bulb link dps Hallway
tuya-bulb link dps Hallway --from-live   # LAN fallback, no session

# interim fallback toggle
tuya-bulb toggle Kitchen
```

```yaml
# the replaced link watch, now an HA automation (semantics preserved)
trigger:
  - platform: state
    entity_id: switch.sala_tecla_canal_1
action:
  - service: light.turn_on          # or turn_off, on the delta only
    target:
      entity_id: light.sala_luz_derecha
```

## Common mistakes

- **Advertising the Plasma applet as part of the hub.** It is an out-of-band writer; calling it a hub surface makes stale state look like a bug in HA.
- **Letting two writers drive one bulb with no state owner.** HA must own hub-managed devices; the applet is fallback, not peer.
- **Assuming the widget can be extended to speak MQTT.** It is reused unmodified — no MQTT client, no HTTP, no plugin seam.
- **Porting `link watch` semantics loosely.** The automation must keep channel-authoritative, write-on-delta, and dp-never-guessed behavior, or it reintroduces the write storms the widget deliberately avoids.

## References

- [home-assistant-hub](home-assistant-hub.md) — the authority that replaces the widget's writer role.
- [provisioning-flow](provisioning-flow.md) — where dp inspection feeds LocalTuya config.
- [troubleshooting](troubleshooting.md) — stale state after the applet was used; mirror stopped.
- [adr-0006-tuya-bulb-widget-role](../../adrs/adr-0006-tuya-bulb-widget-role.md) — the role boundary decision.
- [adr-0003-tuya-lan-protocol-over-mqtt-device-leg](../../adrs/adr-0003-tuya-lan-protocol-over-mqtt-device-leg.md) — the device leg is LAN, not MQTT.
- [project.md](../project.md) — entry point and slices.
