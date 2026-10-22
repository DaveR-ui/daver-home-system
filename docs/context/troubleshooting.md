---
last_updated: 2026-10-22
status: active
description: Quick-ref hub troubleshooting sheet — the twelve recurring symptoms keyed by their exact strings, each with context, root cause, fix, and reference.
tags: [troubleshooting, symptoms, hub, quick-ref]
version: 1.2
related: [mobile-app-design, provisioning-flow, tuya-local-key-integration, desktop-widget-surface]
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

## the app shows a stale bulb state after the old Plasma applet was used
**Context:** the app shows a bulb as on (or off) right after someone toggled it from a KDE Plasma applet.
**Root cause:** a **stale install of the retired legacy applet** is still on a panel and wrote the bulb directly over TCP/6668, which Home Assistant never observed, so the HA entity is stale until its next poll. The in-repo `widget/` cannot cause this — it writes only the switch channel, through Home Assistant.
**Fix:** remove the legacy applet, install `widget/` as the desktop surface, then re-read the entity to resync.
**Reference:** [[desktop-widget-surface]], [[adr-0006-tuya-bulb-widget-role]].

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
**Context:** after the hub replaced the legacy link-watch loop, pressing the wall switch no longer moves the bulb.
**Root cause:** the legacy link-watch loop was retired and either the switch entity is missing from HA or the replacing automation is disabled.
**Fix:** confirm the switch entity exists and the mirror automation is enabled.
**Reference:** [[adr-0006-tuya-bulb-widget-role]], [[home-assistant-hub]].

## the desktop widget says the hub is unreachable
**Context:** the Home Keys applet shows `hub-unreachable` and its key cards stay disabled.
**Root cause:** Home Assistant is down, the configured `hubBaseUrl` is wrong, or port 8123 is blocked. The applet's default is now the **loopback address** `http://127.0.0.1:8123`, because the widget runs on the same PC as the hub.
**Fix:** check `GET /api/` from the same machine, then fix the widget's configuration (hub URL) or the hub itself. An install created before the default changed may still hold the retired default `http://homeassistant.local:8123` in its stored configuration; the widget treats that stored value as unset and resolves the current default, so no manual action is required. If Home Assistant is **not** on the same machine, type its LAN address in **Configure Home Keys… → "Home Assistant URL"** (clearing the field and applying also resolves the default).
**Reference:** [[desktop-widget-surface]], [[home-assistant-hub]].

## the desktop widget says the token was rejected
**Context:** the Home Keys applet reports `unauthorized` — Home Assistant answered 401/403 — and invalidates its cached token.
**Root cause:** the HA long-lived access token was revoked or rotated.
**Fix:** re-store it with `widget/install.sh token`, then press **Retry** in the widget; Retry re-reads KWallet, so the new token is picked up. No plasmashell restart is needed.
**Reference:** [[desktop-widget-surface]], [[security-and-privacy]].

## the desktop widget says there is no token
**Context:** the Home Keys applet reports `token-missing` or `wallet-error` and offers Retry.
**Root cause:** the KWallet folder or entry is missing, the wallet is locked, or `kwallet-query` is not installed.
**Fix:** unlock the wallet, install the KWallet command-line tools, or re-run `widget/install.sh token`.
**Reference:** [[desktop-widget-surface]], [[security-and-privacy]].

## the desktop widget shows a bulb as unavailable
**Context:** one bulb card in the Home Keys applet reads **Unavailable** while the rest of the card works.
**Root cause:** Home Assistant cannot reach that bulb, or the entity id in the widget's configuration no longer exists.
**Fix:** check `deploy/config/homeassistant/packages/real_devices.yaml` and the entity ids configured in the widget.
**Reference:** [[desktop-widget-surface]], [[home-assistant-hub]], [[provisioning-flow]].
