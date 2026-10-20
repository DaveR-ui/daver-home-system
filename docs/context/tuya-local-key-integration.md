---
last_updated: 2026-10-20
status: active
description: Component C3 — tuya-local-key as the hub's credential harvester and rotation-surveillance tool, its Docker deployment, exposure, storage, config table, and Bluetooth exclusion.
tags: [tuya-local-key, integration, component, local-key, rotation, docker]
version: 1.1
related: [provisioning-flow, security-and-privacy, hosting-architecture, troubleshooting]
---

# tuya-local-key Integration

## Problem

LocalTuya needs each device's local key, and Tuya never hands it out from the device itself. The key is available only from Tuya's cloud through a device-sharing login, and it silently changes (re-pair, sometimes a firmware update) without notifying anyone. The hub needs one bounded tool that harvests keys and keeps watching for rotation — without becoming a permanent cloud dependency and without exposing a page full of keys.

## Solution

**C3 — tuya-local-key** runs as a **Docker container on the hub PC** (the always-on server, see [[hosting-architecture]]). It is used occasionally, only when provisioning or when the maintenance loop requires it. It is **not** in the control path: it never controls a device.

The project also ships a Home Assistant **app/add-on** variant, but that path requires Home Assistant OS or Supervised. This design runs Home Assistant as **Container**, so the add-on variant is out of scope here; the standalone container is what is deployed.

### What it produces

An account enumeration: per device — name, device id, uuid, **local key**, IP address, category, product id/name, model, online status, local-control support, and **every data point with its local dp id**. The dp-to-local-id mapping is what makes LocalTuya configuration correct rather than guessed; the values feed step 3 of [[provisioning-flow]].

### Exposure

- Listens on port **8000**. The default UI has **no authentication**: anyone who can reach the port sees every local key in the account.
- Bind it to **loopback** (or the container's host-only interface), or set **both** `AUTH_USERNAME` and `AUTH_PASSWORD`. Login is required only when both are set.
- Basic Auth over plain HTTP sends credentials unencrypted, so it still belongs on the trusted LAN. Never expose it beyond the LAN; see [[security-and-privacy]].

### Credential storage

| File | Contents |
|---|---|
| `session.json` | Cached login session (account tokens) from the QR sharing login. |
| `devices.cache` | The encrypted device list — every local key in the account. |
| `cache.key` | The key that decrypts `devices.cache`. |

- All are written readable only by the app's user (`0600`).
- `DEVICE_CACHE=off` keeps the device list in memory only — nothing is written to disk, and the list is re-fetched from Tuya after every restart.
- **Caveat:** the cache key sits next to the file it unlocks, so the encryption protects a `devices.cache` that leaks on its own — not a reader of the whole directory. The directory already holds `session.json`, whose tokens can fetch the same keys. **Treat the data directory itself as the secret.** Back it up accordingly, or don't back it up at all; see [[security-and-privacy]].

### Change detection — the reason it stays installed

Every refresh is compared against the previous list; anything that moved is summarised:

- **Local key changed** — the one that matters. Nothing announces it, and LocalTuya simply stops decrypting that device until the key is updated.
- Devices **added or removed**.
- Devices **renamed**, with the previous name.

Key values never appear in the summary itself, only the fact that one changed. This summary is the detection half of the maintenance loop (step 6 of [[provisioning-flow]]); the fix is re-entering the rotated key into LocalTuya.

### Configuration worth knowing

| Variable | Default | Notes |
|---|---|---|
| `SESSION_FILE` | `/data/session.json` | Where the cached login session lives. |
| `QR_SCHEME` | `smartlife` | Use `tuyaSmart` if scanning or confirmation fails for the account. |
| `PORT` | `8000` | Server port. |
| `AUTH_USERNAME` | _(unset)_ | Required with `AUTH_PASSWORD` to enable Basic Auth. |
| `AUTH_PASSWORD` | _(unset)_ | Required with `AUTH_USERNAME` to enable Basic Auth. |
| `DEVICE_CACHE` | `on` | `off` keeps the device list in memory only. |
| `DEVICE_CACHE_FILE` | `devices.cache` beside `SESSION_FILE` | Encrypted device-list cache path. |
| `DEVICE_CACHE_KEY_FILE` | `cache.key` beside `SESSION_FILE` | Cache key path. |

### Bluetooth exclusion

Bluetooth-only devices show no `local_key` at all — Tuya's sharing API does not return one, because a Bluetooth-only device has no LAN presence. That is not a tool failure. A Bluetooth device behind a Tuya gateway exposes the **gateway's** key, not its own. Bluetooth-only hardware is **out of scope** for this LAN-only design; see symptom 6 in [[troubleshooting]].

## When to use

- Harvesting the id / uuid / local key / IP / dp mapping needed to configure LocalTuya.
- Rotation surveillance: a refresh on a schedule (or after any suspected firmware update) to catch a silently rotated key.
- Inspecting a device's data points and their local dp ids before writing config.

## When not to use

- **As a control surface.** It enumerates; it never turns a bulb on. Control is Home Assistant's job — see [[home-assistant-hub]].
- **Exposed beyond the LAN.** The default page is unauthenticated and lists every key in the account.
- **On this hub as the HA add-on.** That variant needs HAOS/Supervised; this design runs HA Container.
- For continuous cloud polling — a cached session and an occasional refresh are enough.

## Examples

```yaml
# docker compose (hub PC) — loopback-only exposure, cache off
services:
  tuya-local-key:
    # tag: latest — pinned by digest, like the rest of the stack
    image: ghcr.io/vineetchoudhary/tuya-local-key@sha256:95d50ec31f38f81d3161e0f9f36855e240171f2bdf6bd2891319ca18e6dc54b2
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"
    environment:
      DEVICE_CACHE: "off"
      AUTH_USERNAME: "<user>"
      AUTH_PASSWORD: "<password>"
    volumes:
      - tuya-session:/data
```

```text
Login: Smart Life app → Me → Settings → Account and Security → User Code
Then:  Scan the QR → Confirm login (the app names "Home Assistant" — expected)
Then:  Refresh → read the change summary → copy the key that moved
```

## Common mistakes

- **Leaving port 8000 open on the LAN with no auth.** The UI shows every local key; bind loopback or set both auth variables.
- **Assuming the 0600 encrypted cache makes the directory safe to back up.** The key sits beside the file — the data directory is the secret.
- **Letting the cache grow stale forever.** The saved list stays readable when Tuya is unreachable, but rotation detection needs a real refresh; a snapshot nobody refreshes hides the very change it exists to surface.
- **Expecting a key for a Bluetooth-only device.** There is none; the device is out of scope.
- **Treating it as a device controller.** It has no write path to any device.

## References

- [provisioning-flow](provisioning-flow.md) — where steps 2 and 6 fit.
- [security-and-privacy](security-and-privacy.md) — exposure, key custody, backup policy.
- [hosting-architecture](hosting-architecture.md) — where the container runs.
- [troubleshooting](troubleshooting.md) — "a device shows no local key in tuya-local-key".
- [add-a-tuya-device](../protocols/add-a-tuya-device.md) — the by-device procedure.
- [adr-0004-hosting-substrate](../../adrs/adr-0004-hosting-substrate.md) — why the container variant, not the add-on.
