---
last_updated: 2026-10-14
status: active
description: Quick-ref hub troubleshooting sheet — the eight recurring symptoms keyed by their exact strings, each with context, root cause, fix, and reference.
tags: [troubleshooting, symptoms, hub, quick-ref]
version: 1.0
related: [mobile-app-design, provisioning-flow, tuya-local-key-integration, tuya-bulb-widget-integration]
---

# Hub Troubleshooting — Quick Ref

## the bulb stopped responding after a Smart Life re-pair
**Context:** right after a device was re-paired in the Smart Life app (and sometimes after a firmware update) and the hub had been controlling it fine before.
**Root cause:** Tuya rotated the device's local key, silently — LocalTuya is still sending the old key, so the device no longer decrypts the command.
**Fix:** refresh the device list in tuya-local-key, read the change summary for "local key changed", and re-enter the new key into the LocalTuya config for that device.
**Reference:** [[tuya-local-key-integration]], [[provisioning-flow]].

## LocalTuya reports the device as unavailable
**Context:** a device that worked is now unavailable in Home Assistant, typically after a network change, a config edit, or a re-pair.
**Root cause:** the configured IP is wrong after a DHCP change, the protocol version is wrong, or the local key rotated — the classic "check key or version" ambiguity.
**Fix:** give the device a static DHCP lease, re-check the protocol version, and re-enter the local key from a fresh enumeration.
**Reference:** [[home-assistant-hub]], [[provisioning-flow]].

## the app cannot reach the hub after a PC reboot
**Context:** the phone app cannot connect right after the hub PC rebooted.
**Root cause:** the systemd unit or the compose `restart: unless-stopped` policy did not bring the stack back, or `network_mode: host` was dropped from a service.
**Fix:** check the systemd unit is enabled and active, and confirm the compose file still sets `network_mode: host` on the services that need it.
**Reference:** [[hosting-architecture]].

## the app shows a stale bulb state after the Plasma widget was used
**Context:** the app shows a bulb as on (or off) right after someone toggled it from the KDE Plasma applet.
**Root cause:** the applet is an out-of-band writer — it wrote the bulb directly over TCP/6668, which Home Assistant never observed, so the HA entity is stale until its next poll.
**Fix:** re-read the entity to resync, and stop treating the applet as a hub control path.
**Reference:** [[tuya-bulb-widget-integration]].

## the Mosquitto container exits on startup
**Context:** the broker container fails to start, or exits shortly after start.
**Root cause:** another service already holds port 1883, or the mosquitto configuration is invalid.
**Fix:** change the broker port, or fix the mosquitto config and restart the container.
**Reference:** [[mqtt-topic-map]], [[hosting-architecture]].

## a device shows no local key in tuya-local-key
**Context:** a device appears in the tuya-local-key device list but its local key column shows no value.
**Root cause:** the Tuya sharing API returns no `local_key` for Bluetooth-only devices — there is no LAN key to hand out.
**Fix:** treat the device as out of scope for LAN control; a Bluetooth device behind a Tuya gateway shows the gateway's key instead.
**Reference:** [[tuya-local-key-integration]].

## Home Assistant is unreachable on port 8123
**Context:** REST or WebSocket calls to the hub on port 8123 fail.
**Root cause:** the HA container is down, something else is bound to 8123, or the firewall blocks the port.
**Fix:** check the systemd unit, list the listener with `ss -ltnp`, and check the firewall.
**Reference:** [[home-assistant-hub]].

## the switch no longer mirrors the bulb after the hub took over
**Context:** after the hub replaced the widget, pressing the wall switch no longer moves the bulb.
**Root cause:** `link watch` was retired and either the switch entity is missing from HA or the replacing automation is disabled.
**Fix:** confirm the switch entity exists and the mirror automation is enabled.
**Reference:** [[tuya-bulb-widget-integration]], [[home-assistant-hub]].
