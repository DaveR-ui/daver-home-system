---
last_updated: 2026-10-21
status: active
description: The LAN-only trust boundary — exposed ports, token/key custody, the plain-HTTP caveat, the three cloud-touching moments, and the backup policy.
tags: [security, privacy, lan, trust-boundary, tokens, backup]
version: 1.3
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

**Discovery trust assumption.** The app now learns the hub's address from an mDNS advertisement on the LAN: any device on that LAN can advertise `_home-assistant._tcp` and, if the app connects to it, receive the long-lived token. The LAN-only boundary above is the mitigation, and the address is **pinned while the app is connected** (banner hidden) — a later advertisement does not move a connected hub. A successful probe alone is **not** the pin: while the app is in a non-connected display state (live socket handshaking or backing off, hub unavailable, phone offline) a new advertisement may still take over the address, and the next probe carries the token to it. Discovery yields an `http://` address; a hub behind local TLS is reached with the build-time `--dart-define=HUB_BASE_URL` override, not through discovery. See [[mobile-app-design]].

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

**The archive is a secret.** The backup that `deploy/scripts/backup.sh` writes
includes `.storage/` — the owner account, the long-lived access tokens and the
**LocalTuya local keys** — so anyone holding the tarball can drive the owner's
bulbs. It therefore: is written `0600`; refuses to be written inside the
repository; and must live on a **mounted volume the owner trusts** (ideally an
encrypted volume, and ideally not the same physical device as the source disk —
a backup next to the thing it backs up protects nothing). The scheduled unit
(`daver-backup.timer`) enforces the first half of that: it refuses to run
unless the destination is a mount point of its own, so a mistyped path cannot
quietly fill the root filesystem. The recorder database is deliberately **not**
in the archive (it is written while Home Assistant runs and would be torn); it
is history, and the hub rebuilds it.

The archives are never deleted by the script: one per night grows without
bound, so the owner prunes them on their own schedule.

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
