---
id: adr-0004-hosting-substrate
category: adrs
tags: [adr, hosting, docker, compose, deployment]
aliases: ["ADR-0004"]
related: [adr-index, adr-0003-tuya-lan-protocol-over-mqtt-device-leg, hosting-architecture, bring-up-the-hub]
version: 1.0
status: active
---

# ADR-0004: Hosting substrate — Home Assistant Container via Docker Compose

## Problem

The hub needs a host: Home Assistant, Eclipse Mosquitto, and the tuya-local-key
harvester have to run continuously on the owner's PC, which is already doing
other work and is not a dedicated appliance. The device leg is settled — the
Tuya hardware speaks the Tuya LAN protocol over Wi-Fi, not MQTT
(`[[adr-0003-tuya-lan-protocol-over-mqtt-device-leg]]`) — so the substrate only
has to host the hub's own containers, never the devices' transport. The
candidates differ in how much of the machine they claim, how isolated their
dependency trees are, and how reproducible the install is from this repository.

## Solution

**Run Home Assistant Container, Eclipse Mosquitto, and tuya-local-key as Docker
Compose services on the owner's existing PC** (decision `ha-container-docker`,
panel confidence 0.82).

The PC does other work, which rules out the HAOS appliance model. Between the two
non-OS paths, Docker beats a Core virtualenv because dependency trees stay
isolated, the update blast radius is bounded per container, the install
materialises as compose manifests in this repository, and LocalTuya installs
through HACS inside the Home Assistant container.

Hosting details:

- **Home Assistant runs with `network_mode: host`.** LocalTuya discovers and
  drives devices on the LAN: it needs UDP 6666/6667 broadcast, TCP 6668, and
  mDNS. Docker bridge NAT breaks device discovery, so the HA container shares the
  host network namespace. This also places the HA REST/WebSocket API on host port
  **8123** directly.
- **Mosquitto listens on 1883** as the hub-internal MQTT bus for MQTT-native
  devices and future extensions — never the Tuya bulbs.
- **tuya-local-key listens on 8000**, bound to loopback (`127.0.0.1:8000`) or
  given `AUTH_USERNAME`/`AUTH_PASSWORD`, since its web UI can expose device local
  keys to anyone who reaches the port.
- **A systemd unit wraps `docker compose up -d`** and every service carries
  `restart: unless-stopped`, so a reboot or network change restores the hub
  without a login.
- **Static DHCP leases** for the hub and for every device, so IPs do not drift
  under LocalTuya.

### Rejected alternatives

- **`home-assistant-os`** — the HAOS appliance image. Rejected: it takes over the
  daily-driver machine, effectively demanding a dedicated box; its headline
  advantage (the add-on store) is already recovered here through first-party and
  third-party container images.
- **`ha-core-venv`** — Home Assistant Core in a virtualenv on the host. Rejected:
  fragile dependency entanglement with the host OS, no isolation from the
  owner's other work, and the highest update blast radius of the three.

What would change this decision: the owner dedicating the machine to the hub (or
running HAOS in a VM on it), or a Supervisor-only add-on with no standalone
container image.

## When to use

Reading back why the hub is containerised, and reviewing any proposal to change
the substrate — HAOS, a native venv, or moving the hub to another machine.

## When not to use

For the app-to-hub interface — that is `[[adr-0005-control-plane-authority]]`;
for the desktop widget's role — that is `[[adr-0006-tuya-bulb-widget-role]]`; to
provision devices — that is `[[add-a-tuya-device]]`. Do not edit this record "for
clarity"; supersede it with a new ADR or append an addendum.

## Examples

The intended service set for `deploy/docker-compose.yml` (no compose file exists
in the repository yet — see `[[bring-up-the-hub]]`):

```yaml
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    network_mode: host          # LocalTuya: UDP 6666/6667, TCP 6668, mDNS
    volumes:
      - ./config/homeassistant:/config
    environment:
      TZ: <timezone>
    restart: unless-stopped

  mosquitto:
    image: eclipse-mosquitto:2
    ports:
      - "1883:1883"
    volumes:
      - ./config/mosquitto:/mosquitto/config
    restart: unless-stopped

  tuya-local-key:
    image: ghcr.io/vineetchoudhary/tuya-local-key:latest
    ports:
      - "127.0.0.1:8000:8000"   # loopback only, or set AUTH_USERNAME/AUTH_PASSWORD
    volumes:
      - tuya-session:/data
    restart: unless-stopped

volumes:
  tuya-session:
```

| Port | Service | Purpose |
| --- | --- | --- |
| 8123 | Home Assistant (host network) | REST snapshot/commands + WebSocket live state |
| 1883 | Mosquitto | hub-internal MQTT bus |
| 8000 | tuya-local-key | key harvest UI/API — loopback or authenticated |

## Common mistakes

- **No Supervisor means no snapshot UI.** Backups are not a button; they are a
  scripted copy of the HA config volume, the Mosquitto config, and the compose
  file. Treat the backup routine in `[[bring-up-the-hub]]` as part of the install.
- **The Docker daemon is shared with the owner's other work.** A daemon restart,
  disk exhaustion, or image prune for another project can take the hub with it.
- **A future Zigbee/Z-Wave USB coordinator needs device passthrough and udev
  handling**, with no add-on store to abstract it — the host-side configuration
  is manual.
- Assuming bridge networking is enough for LocalTuya — it is not; device
  discovery fails without the host network.

## References

- [adr-0003-tuya-lan-protocol-over-mqtt-device-leg.md](adr-0003-tuya-lan-protocol-over-mqtt-device-leg.md) — the device leg this substrate hosts.
- [adr-index.md](adr-index.md)
- [Hosting architecture](../docs/context/hosting-architecture.md)
- [Bring up the hub](../docs/protocols/bring-up-the-hub.md)
