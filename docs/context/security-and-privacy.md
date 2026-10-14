---
last_updated: 2026-10-14
status: active
description: The LAN-only trust boundary — exposed ports, token/key custody, the plain-HTTP caveat, the three cloud-touching moments, and the backup policy.
tags: [security, privacy, lan, trust-boundary, tokens, backup]
version: 1.0
related: [hosting-architecture, home-assistant-hub, tuya-local-key-integration, mobile-app-design]
---

# Security and Privacy

## Problem

The hub holds the credentials that unlock every device (local keys) and the token that commands the whole home (the Home Assistant long-lived access token). It must be reachable from the phone and the desktop inside the home, and reachable from nowhere else by default. The design also has to be honest about what still leaves the LAN: a handful of provisioning/maintenance moments touch Tuya's cloud even in a "fully local" setup.

## Solution

### Trust boundary

- The **home LAN is trusted**. Everything the hub exposes is exposed to the LAN.
- **Nothing is exposed to the internet by default.** No port forwarding, no reverse proxy, no tunnel as a shipped default.
- Remote access is a **deliberate, separate decision**: the documented alternative is **WireGuard / VPN to the PC**, which puts the phone back on the trusted network without exposing a service. The default is **LAN-only**.

### Exposed ports and who may reach them

| Port | Service | Reachable by | Posture |
|---|---|---|---|
| 8123 | Home Assistant REST + WebSocket | LAN; the app with the long-lived token | Token-authenticated; plain HTTP (see caveat) |
| 1883 | Eclipse Mosquitto MQTT | LAN; hub-internal clients only | **Per-user auth — not anonymous** |
| 8000 | tuya-local-key | loopback only, or LAN behind Basic Auth | Default is **unauthenticated**; never expose it |

Port 8000 is the sharp edge: its page lists every local key in the account. Bind it to loopback, or set both `AUTH_USERNAME` and `AUTH_PASSWORD`, and keep it off any interface the internet can reach. See [[tuya-local-key-integration]].

### Token and key custody

- **App token** — a Home Assistant long-lived access token stored in the **OS keystore** (Android Keystore / iOS Keychain). Never bundled, never in a synced file, rotatable by revoking it in HA. See [[mobile-app-design]].
- **Local keys** — live in three places only: LocalTuya config on the hub, tuya-local-key's encrypted `devices.cache`, and tuya-bulb-widget's `0600` config. They are **never** in docs, logs, issue text, or git.
- **Corpus guard** — the documentation validator's secret check blocks anything resembling a key from being committed to `docs/`; docs use placeholders such as `<local_key>`.
- tuya-local-key's **data directory is itself a secret**: `cache.key` sits beside `devices.cache`, and `session.json` can re-fetch the same keys. `0600` on each file is necessary but not sufficient; the directory as a whole is the unit to protect.

### Plain-HTTP caveat

There is no TLS inside the LAN: HA on 8123 serves plain HTTP, and a `Bearer` token over HTTP is sniffable by anyone already on the network. This is accepted **under the trusted-LAN assumption**. If the LAN is not trusted (shared Wi-Fi, guests, untrusted devices), put Home Assistant behind local TLS — a certificate on the host — rather than sending the token in the clear. Either way, remote access goes through the VPN path, not through a forwarded plain-HTTP port.

### What the cloud still sees

Three moments touch Tuya's cloud (from [[provisioning-flow]]); all are provisioning or maintenance, **never control**:

1. **Smart Life pairing** — the device is enrolled once in the Tuya account.
2. **The sharing login** — tuya-local-key enumerates the account to harvest keys.
3. **Key rotation recovery** — a re-harvest after Tuya silently rotates a key.

Control, state, automations, app traffic, and MQTT stay on the LAN.

### Backup policy

| Back up | Notes |
|---|---|
| Home Assistant config volume | Entities, automations, recorder config |
| Mosquitto config | Broker config and authorised users |
| The compose file | Whole-stack topology |
| tuya-local-key data directory | **Only if the backup medium is itself protected** — it holds the keys' cache and the cache key; otherwise skip it and re-harvest on restore |

### Device-internet policy (documented default)

Default: the hub keeps working with the devices it already has, and Tuya devices' internet access is left as the device/firmware dictates. The documented options, should the owner tighten this later: block the devices from the WAN at the router (local control keeps working; cloud-side device status in Smart Life goes stale), or leave them connected (Smart Life stays usable). This is a documented default with a revert path, not an open question — the ADRs carry the deliberation. See [[adr-0004-hosting-substrate]].

## When to use

- Before exposing any hub port, setting up remote access, or changing where keys/tokens live.
- Before making or restoring a backup of the hub.
- When auditing what leaves the LAN.

## When not to use

- For app-side token handling specifics — see [[mobile-app-design]].
- For the hub-internal MQTT bus and its users — see [[mqtt-topic-map]].
- For per-component deployment — see [[hosting-architecture]].

## Examples

```text
# LAN-only posture
8123  → LAN, token-authenticated
1883  → LAN, per-user auth (no anonymous)
8000  → 127.0.0.1 only, or LAN + Basic Auth

# Remote access (opt-in)
WireGuard/VPN to the PC → phone rejoins the trusted LAN; no public port
```

## Common mistakes

- **Exposing port 8000 for convenience.** It shows every local key in the account, unauthenticated by default.
- **Committing a local key "just for the docs".** Keys belong in config and encrypted caches; the validator blocks them, and a key in git is a key leaked forever.
- **Anonymous MQTT on a shared LAN.** Port 1883 must use per-user auth; an open broker lets anyone read and publish hub traffic.
- **Assuming a "fully offline" hub means no cloud ever.** Rotation recovery needs the sharing login; the cloud is provisioning-only, but it is not zero.
- **Backing up the tuya-local-key data directory to an unprotected medium.** `cache.key` beside `devices.cache` means that backup is the key ring.

## References

- [mobile-app-design](mobile-app-design.md) — token custody and the hub-unavailable posture.
- [tuya-local-key-integration](tuya-local-key-integration.md) — port 8000 and the data directory as secret.
- [mqtt-topic-map](mqtt-topic-map.md) — broker auth and hub-internal topics.
- [provisioning-flow](provisioning-flow.md) — the cloud-touching moments.
- [adr-0004-hosting-substrate](../../adrs/adr-0004-hosting-substrate.md) — hosting, backup, and device-internet defaults.
- [adr-0005-control-plane-authority](../../adrs/adr-0005-control-plane-authority.md) — single-authority rationale.
