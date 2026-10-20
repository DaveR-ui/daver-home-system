---
id: add-a-tuya-device
category: protocols
tags: [protocol, provisioning, localtuya, tuya-local-key, dps]
aliases: ["Add a Tuya Device"]
related: [adr-0006-tuya-bulb-widget-role, tuya-local-key-integration, provisioning-flow, tuya-bulb-widget-integration]
version: 1.2
status: active
---

# Add a Tuya Device

## Problem

An existing Tuya bulb or switch has to be brought under the hub so Home Assistant
— the single state authority — can drive it over the LAN. Tuya devices are not
MQTT, and their local control depends on a per-device local key plus the correct
datapoint (dp) mapping, neither of which can be guessed. The cloud is touched
once to pair and to read the key, and never again for day-to-day control. The
provisioning flow this implements is `[[provisioning-flow]]`.

## Solution

Ordered, checkable steps:

1. **Pair the device in the Smart Life app.** This is the one cloud step: the
   device must exist in the account so its local key can be read. Do not add
   firmware or a hub of Tuya's own.
2. **Read the device row with tuya-local-key** (see
   `[[tuya-local-key-integration]]`) — run its QR sharing login, then open the
   device's details panel and record:
   - `id`, `uuid`, local key, IP address;
   - category and product id/name;
   - **every data point with its local dp id** and reported value.

   The **id and the local key are the identity**; the *name* is not. The owner
   can rename a device in the Smart Life app, and the row then carries the new
   name while the id stays. A **re-pair rotates the local key**: the id
   survives, the key does not, and the old key is rejected with the device
   ("Check device key or version"). Re-harvest after any rename or re-pair
   instead of trusting a stored key.
3. **Note the on/off dp — never guess it.** Type A bulbs use dp `1`; newer Type B
   bulbs use dp `20`. Confirm from the dp evidence in tuya-local-key, or from
   `tuya-bulb-widget`'s inspection commands, before configuring anything.
   The decisive check is the **live dp table** of the device on the LAN: a bulb
   that reports no dp `1` at all and reports its power boolean on dp `20` is
   Type B, and its brightness is the dp whose value tracks the cloud's
   `bright_value_v2`. Read it, do not reason from the product name.
4. **Add the device to LocalTuya** with id, local key, IP, and the right protocol
   version; confirm the entities appear in Home Assistant.
   - LocalTuya 2026.7 dropped YAML import: the device is added through its
     config flow (Settings → Devices & Services → Local Tuya → Configure →
     Add Device Manually), or the same flow over REST
     (`POST /api/config/config_entries/options/flow`). The integration runs
     **local-only** (`no_cloud: true`), so the hub needs no Tuya cloud account.
   - The entity id must be `light.<room>_<device>`: the app parses the room as
     the text before the first `_`, so a device named "sala luz derecha"
     becomes `light.sala_luz_derecha`.
   - The **room comes from the physical layout, not from the device name**:
     a device the owner renamed ("zSalaluces2" → "luz izquierda") no longer
     carries its room in its name. Take it from the widget's group config (the
     `sala` group listed "Luz derecha" and "zSalaluces2" together) and from the
     channel that drives it. When the evidence cannot settle it, provision the
     device and report the entity id as an open question rather than guessing.
   - The local key lives in the config entry inside
     `deploy/config/homeassistant/.storage/` — gitignored, never in the repo.
   - A multi-channel switch becomes one entity per channel; give each channel
     the entity id of the room it drives, so the app's room-scoped switch
     mirror lists the right bulb.
   - The device must be **reachable on the LAN** (TCP/6668) to be added: a
     device that is online in the cloud but on another Wi-Fi segment - a guest
     or isolated SSID - is invisible to the hub until it joins the hub's own
     network.
5. **Verify from the app surface** — the app talks only to HA:

   ```sh
   curl -H "Authorization: Bearer <long-lived-access-token>" \
        http://<host>:8123/api/states/light.<room>_<device>
   ```
6. **If the device is a switch channel meant to drive a bulb, bind the
   automation.** Its semantics come from the widget's link rules: the channel is
   authoritative, the target is written **on delta**, dp never guessed — see
   `[[adr-0006-tuya-bulb-widget-role]]`. Once Home Assistant drives the bulb, the
   widget's own `link watch` is a second writer: stop it
   (`systemctl --user disable --now tuya-bulb-link-watch.service`) or the two
   will fight over the same bulb.

**Maintenance loop (recurring, not optional):**

- Refresh **tuya-local-key** periodically; its change detection reports local key
  rotations.
- On a **rotation alert**, re-enter the new local key into LocalTuya. A rotated
  key otherwise breaks local control **silently** — the device stops decrypting
  with no error at the bulb.

## When to use

Adding one existing, LAN-capable Tuya device to the hub.

## When not to use

- **Bluetooth-only devices** — they have no LAN local key at all; tuya-local-key
  shows `-` for the local key and the device cannot be reached over the LAN.
- **Re-pairing or resetting a device** — that is a device-side reset, not an add;
  a reset usually also rotates the local key.

## Examples

```sh
# 2. read the device row (web UI at http://127.0.0.1:8000, or the CLI)
#    record id, uuid, local key, IP, category, and every dp + local dp id

# 3. confirm the on/off dp from evidence (never assume)
tuya-bulb link dps <switch-name>              # widget inspection, cloud metadata
tuya-bulb link dps <switch-name> --from-live  # LAN fallback

# 5. verify the new entity from HA
curl -H "Authorization: Bearer <long-lived-access-token>" \
     http://<host>:8123/api/states/light.<room>_<device>
```

## Common mistakes

- **Trusting a stale key after a firmware update** — firmware updates can rotate
  the local key; re-check tuya-local-key's change detection.
- **Guessing the dp** — Type A (`1`) vs Type B (`20`) differs by model; take the
  id from the dp evidence.
- **Leaving the device on DHCP without a lease** — its IP drifts and LocalTuya
  loses it; reserve a static lease.
- **Treating this as a one-time bootstrap** — key rotation makes device
  maintenance recurring, not a one-off.

## References

- [adr-0006-tuya-bulb-widget-role.md](../../adrs/adr-0006-tuya-bulb-widget-role.md) — the mirror semantics this automation reuses.
- [tuya-local-key integration](../context/tuya-local-key-integration.md)
- [Provisioning flow](../context/provisioning-flow.md)
- [tuya-bulb-widget integration](../context/tuya-bulb-widget-integration.md)
- [Bring up the hub](bring-up-the-hub.md)
