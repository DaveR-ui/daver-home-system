---
id: bring-up-the-hub
category: protocols
tags: [protocol, hosting, docker, compose, systemd, backup]
aliases: ["Bring Up the Hub"]
related: [adr-0004-hosting-substrate, hosting-architecture, home-assistant-hub, add-a-tuya-device]
version: 1.0
status: active
---

# Bring Up the Hub

## Problem

The hub — Home Assistant, Mosquitto, and tuya-local-key — has to come up on the
owner's PC as a set of services that survive a reboot and a network change, and
that the next phase can write into `deploy/` as compose manifests. **No compose
file exists in this repository yet:** this procedure is the design-time contract
for the `deploy/` tree the next phase writes, not a description of shipped
tooling. The substrate decision it implements is
`[[adr-0004-hosting-substrate]]`.

## Solution

Ordered, checkable steps:

1. **Confirm prerequisites.**
   - Docker Engine and the Compose v2 plugin are installed and the daemon runs.
   - The PC has a static DHCP lease or a fixed IP; **the PC must not be suspended**
     (a sleeping hub is an unavailable hub).
   - Static DHCP leases are reserved for the hub and for every device.
2. **Write the three service definitions** under `deploy/`:
   - `homeassistant` — Home Assistant Container, `network_mode: host` (LocalTuya
     needs UDP 6666/6667, TCP 6668, and mDNS), config volume mounted at
     `./config/homeassistant`.
   - `eclipse-mosquitto` — Mosquitto v2 on port 1883 with its config mounted at
     `./config/mosquitto`.
   - `tuya-local-key` — the harvester, port 8000 either bound to loopback
     (`127.0.0.1:8000`) or protected by setting `AUTH_USERNAME` and
     `AUTH_PASSWORD`.
   - Give every service `restart: unless-stopped`.
3. **Start the stack** from `deploy/`:

   ```sh
   docker compose up -d
   ```

4. **Wrap it in a systemd unit** so a reboot restores the hub without a login:

   ```ini
   [Unit]
   Description=Daver home hub (docker compose)
   After=docker.service network-online.target
   Requires=docker.service

   [Service]
   Type=oneshot
   RemainAfterExit=yes
   WorkingDirectory=/absolute/path/to/deploy
   ExecStart=/usr/bin/docker compose up -d
   ExecStop=/usr/bin/docker compose down

   [Install]
   WantedBy=multi-user.target
   ```

   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now daver-hub.service
   ```

5. **First checks.**
   - Home Assistant answers on **8123**.
   - Mosquitto is listening on **1883**.
   - LocalTuya is installed in HA via HACS.
6. **Set up backups** — this replaces the Supervisor snapshots the container
   install does not have:

   ```sh
   # scripted, e.g. a nightly cron/systemd-timer job
   tar czf <backup-dir>/ha-config-$(date +%F).tar.gz deploy/config/homeassistant
   tar czf <backup-dir>/mosquitto-$(date +%F).tar.gz   deploy/config/mosquitto
   cp       deploy/docker-compose.yml <backup-dir>/docker-compose-$(date +%F).yml
   ```

## When to use

Bringing the hub up on the owner's PC, or re-standing it after a rebuild or a
move to another machine.

## When not to use

- Do **not** use this procedure to run the hub on a machine dedicated to other
  work that cannot host Docker — that is a substrate change
  (`[[adr-0004-hosting-substrate]]`).
- Do **not** use it to provision devices — that is `[[add-a-tuya-device]]`.

## Examples

The intended invocation, from the `deploy/` directory:

```sh
docker compose up -d
docker compose ps
```

Health checks:

```sh
curl -sI http://<host>:8123/                 # HA web/API reachable
nc -z <host> 1883                            # Mosquitto listening
curl -s  http://127.0.0.1:8000/              # tuya-local-key (loopback)
```

## Common mistakes

- Expecting Supervisor snapshots — a container install has no snapshot UI; the
  scripted backup in step 6 is the replacement.
- Using Docker bridge networking for Home Assistant — LocalTuya discovery then
  fails; HA needs `network_mode: host`.
- Exposing tuya-local-key on all interfaces without `AUTH_USERNAME`/`AUTH_PASSWORD`
  — anyone reaching port 8000 can see device local keys.
- Forgetting `restart: unless-stopped` or the systemd unit, so the hub stays down
  after a reboot.
- Editing the unit but skipping `systemctl daemon-reload`.

## References

- [adr-0004-hosting-substrate.md](../../adrs/adr-0004-hosting-substrate.md) — the substrate decision.
- [Hosting architecture](../context/hosting-architecture.md)
- [Home Assistant hub](../context/home-assistant-hub.md)
- [Add a Tuya device](add-a-tuya-device.md)
