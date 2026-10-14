---
id: adr-0006-tuya-bulb-widget-role
category: adrs
tags: [adr, tuya-bulb-widget, superseded, localtuya, switch-linking]
aliases: ["ADR-0006"]
related: [adr-index, adr-0003-tuya-lan-protocol-over-mqtt-device-leg, adr-0005-control-plane-authority, tuya-bulb-widget-integration]
version: 1.0
status: active
---

# ADR-0006: tuya-bulb-widget role — superseded by Home Assistant + LocalTuya

## Problem

`tuya-bulb-widget` already controls bulbs over the Tuya LAN protocol (TCP/6668,
dps) and, through its `link watch`, mirrors a wall-switch channel onto a bulb.
Once the hub exists, what does the widget become: a hub component, a parallel
control surface beside it, or a tool that steps aside? Two writers of the same
bulb drive HA's authoritative state stale, so the role has to be named rather
than left implicit. Confidence here is **0.6, the lowest of the three hub
decisions**, because the honest answer depends on how much the owner values the
existing desktop surface.

## Solution

**LAN control of hub-managed bulbs belongs exclusively to Home Assistant via
LocalTuya; `tuya-bulb-widget` is superseded in the authoritative path** (decision
`superseded-by-ha-local-tuya`, panel confidence 0.6).

The widget cannot be a hub component: it is read-only (never modified), and it
speaks neither MQTT nor HTTP — it writes the bulb directly over TCP/6668. Its
documented role is therefore narrower than control:

- **(a) Provisioning / inspection evidence.** Its dp discovery and the local dp
  id mapping it surfaces are the evidence used to configure LocalTuya correctly
  — see `[[add-a-tuya-device]]`.
- **(b) Interim desktop fallback.** Until LocalTuya bring-up passes for a given
  device, the widget's desktop applet remains a working surface for that device.

The widget's `link watch` switch-channel mirror — channel-authoritative,
write-on-delta, dp never guessed — is **retired from the authoritative path** and
re-expressed as a Home Assistant automation over LocalTuya switch-channel and
bulb entities. The widget's link semantics are the **requirements source** for
that automation: the channel is authoritative, the target is written on delta,
and the dp is taken from evidence, never assumed.

### Rejected alternatives

- **`standalone-parallel-surface`** — accept the widget as a fixed,
  HA-independent control surface. Rejected, but not decisively: if the owner
  wants LAN resilience when HA is down, or treats the desktop applet as the
  primary UX, this becomes the honest choice and supersedes this record.
- **A thin adapter in this repository** — wrap the widget as a hub component.
  Rejected because the widget is read-only and its direct LAN writes would still
  bypass HA's state; only warranted if LocalTuya cannot expose the switch's
  channel dps.

What would change this decision: the owner treating the desktop applet plus
`link watch` as a fixed, HA-independent control surface (→
`standalone-parallel-surface`); or LocalTuya being unable to expose the switch
dps (→ a thin adapter becomes warranted).

## When to use

When deciding whether the desktop widget may be advertised as a control path,
and when expressing its link semantics as a Home Assistant automation.

## When not to use

For the step-by-step provisioning of a device — that is `[[add-a-tuya-device]]`;
for the substrate — that is `[[adr-0004-hosting-substrate]]`. Do not edit this
record "for clarity"; supersede it or append an addendum.

## Examples

The widget's dp evidence feeding LocalTuya (conceptual; the widget is used
unmodified):

```sh
tuya-bulb link dps Hallway              # cloud metadata: enumerate dps + codes
tuya-bulb link dps Hallway --from-live  # LAN fallback
```

The retired mirror, re-expressed as a Home Assistant automation (channel
authoritative, write-on-delta — the widget's `link watch` semantics as the
requirement):

```yaml
automation:
  - alias: Hall channel 1 -> Kitchen (mirror on delta)
    trigger:
      - platform: state
        entity_id: switch.hall_channel_1
    condition:
      - condition: template
        value_template: "{{ trigger.from_state.state != trigger.to_state.state }}"
    action:
      - service: "light.turn_{{ trigger.to_state.state }}"
        target:
          entity_id: light.kitchen_ceiling
```

## Common mistakes

Accepted fallout, stated honestly:

- **The Plasma applet remains a residual out-of-band writer.** If the owner opens
  it, it writes the bulb directly and HA's entity state goes stale until the next
  poll. The applet must **never** be advertised as a hub control path.
- **With `link watch` retired, an HA outage stops the switch-driven mirror** until
  HA returns. There is no longer a widget-side loop to fall back on.
- **If LocalTuya cannot expose the wall switch's channel dps, the mirror stops.**
  That is the trigger to revisit this decision, not to guess a dp.

## References

- [adr-0003-tuya-lan-protocol-over-mqtt-device-leg.md](adr-0003-tuya-lan-protocol-over-mqtt-device-leg.md) — the device leg both surfaces write.
- [adr-0005-control-plane-authority.md](adr-0005-control-plane-authority.md) — who owns state.
- [adr-index.md](adr-index.md)
- [tuya-bulb-widget integration](../docs/context/tuya-bulb-widget-integration.md)
- [Add a Tuya device](../docs/protocols/add-a-tuya-device.md)
