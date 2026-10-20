---
id: bring-up-the-hub
category: protocols
tags: [protocol, hosting, docker, compose, systemd, backup]
aliases: ["Bring Up the Hub"]
related: [adr-0004-hosting-substrate, hosting-architecture, home-assistant-hub, add-a-tuya-device]
version: 1.4
status: active
---

# Bring Up the Hub

## Problem

The hub — Home Assistant, Mosquitto, and tuya-local-key — has to come up on the
owner's PC as a set of services that survive a reboot and a network change, and
that `deploy/` holds as compose manifests. This procedure is the contract for
the shipped `deploy/` tree (`docker-compose.yml` plus
`config/{homeassistant,mosquitto}`) and the runbook for re-standing it on a bare
machine. The substrate decision it implements is
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
   - **Pin every image by digest** (`image: <repo>@sha256:<digest>`), keeping the
     readable tag next to the pin as a comment. A tag moves under you — `:stable`
     is a rolling tag — and a silent Home Assistant upgrade changes the hub's
     behaviour with nobody deciding it. Pinning freezes the version; moving it
     is the deliberate act in step 8.
3. **Start the stack** from `deploy/`:

   ```sh
   docker compose up -d
   ```

4. **Wrap it in a systemd unit** so a reboot restores the hub without a login.
   The unit ships in the repository as `deploy/systemd/daver-hub.service`; it
   carries a `@DEPLOY_DIR@` placeholder because an absolute path belongs to the
   machine, not to the repository:

   ```sh
   sudo sed "s|@DEPLOY_DIR@|$PWD/deploy|g" deploy/systemd/daver-hub.service \
     | sudo tee /etc/systemd/system/daver-hub.service >/dev/null
   sudo systemctl daemon-reload
   sudo systemctl enable --now daver-hub.service
   systemctl status daver-hub.service
   ```

   The unit is a **system** unit: it starts after `docker.service` and
   `network-online.target`, brings the stack up, retries on failure, and takes it
   down on stop. The repository ships it; installing and enabling it on the host
   is the owner's decision.

   It also **requires the data disk to be mounted** (`RequiresMountsFor=` on the
   volume that holds the repository): the compose file and the whole Home
   Assistant config volume live there, so starting before the mount would find
   no compose file and come up half-configured. With the dependency, **the unit
   does not start while the disk is absent** — deliberately: a hub that is down
   is visible, a hub running against the wrong config is not. Adjust the path in
   the unit if the disk is mounted elsewhere.
5. **First checks.**
   - Home Assistant answers on **8123**.
   - Mosquitto is listening on **1883**.
   - LocalTuya is present in HA. The log then reports `We found a custom
     integration localtuya`.
6. **Install LocalTuya.** Two routes, same result — a custom integration in
   `custom_components/localtuya/`:
   - **With HACS** (where the install supports it): install the `LocalTuya`
     integration from the HACS store.
   - **On a Container install** (no Supervisor, no HACS UI): unpack the
     integration release into
     `deploy/config/homeassistant/custom_components/localtuya/` and restart HA.
   - The directory is **gitignored**: third-party integration code is installed
     state, not repo source.
   - Create the integration in **local-only** mode (`no_cloud: true`). The hub
     then needs no Tuya cloud account at all — the per-device local key is
     still required, and it is what a rotation breaks.
7. **Set up backups** — this replaces the Supervisor snapshots the container
   install does not have. The script ships in the repository as
   `deploy/scripts/backup.sh`:

   ```sh
   deploy/scripts/backup.sh /path/to/backup/dir
   ```

   It writes one tarball per run containing the Home Assistant config
   (**including `.storage/`**, which holds the owner account, the access tokens
   and the LocalTuya local keys), the Mosquitto config and the compose file.
   The archive is created `0600`, the destination must be **outside** the
   repository (the script refuses to write inside it), and it says out loud what
   it left out: the recorder database (Home Assistant writes it while running,
   so a copy would be torn — it is history, not configuration), the HA logs and
   the brand-icon cache. `.storage/` is owned by the container's root, so the
   script streams it out of the running `homeassistant` container instead of
   needing `sudo`; run it with `sudo` when the stack is down.

   **Restore:** stop the stack, untar the archive into an empty directory, copy
   the `deploy/` tree it contains back over the repository's `deploy/`
   directory, and start the stack again. The recorder database is not in the
   archive — history starts empty and the hub rebuilds it.

   Schedule it (e.g. a nightly systemd timer or cron) once the destination
   directory exists.
8. **Bump a pinned image.** The pins in `deploy/docker-compose.yml` freeze the
   stack; moving one is deliberate:

   ```sh
   # find the digest of the tag you want to move to
   docker buildx imagetools inspect ghcr.io/home-assistant/home-assistant:stable
   # then edit the image: line, keep the tag next to it as a comment, and
   docker compose pull && docker compose up -d
   ```

   Record the new digest in the comment beside the pin, and check the hub
   afterwards: HA answers on 8123, the devices are back, and the mirror
   automations still fire.

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
  scripted backup in step 7 is the replacement.
- Using Docker bridge networking for Home Assistant — LocalTuya discovery then
  fails; HA needs `network_mode: host`.
- Exposing tuya-local-key on all interfaces without `AUTH_USERNAME`/`AUTH_PASSWORD`
  — anyone reaching port 8000 can see device local keys.
- Forgetting `restart: unless-stopped` or the systemd unit, so the hub stays down
  after a reboot.
- Editing the unit but skipping `systemctl daemon-reload`.
- **Leaving the images on a moving tag.** `:stable` is a rolling tag: the hub
  can change version without anyone deciding it, and a broken upgrade is
  discovered when the devices stop answering. Pin by digest and move the pin
  deliberately (step 8).
- **Backing up without `.storage/`.** The HA config alone is not the hub: the
  owner account, the access tokens and the LocalTuya local keys live in
  `.storage/`. A restore without it hands back a hub nobody can log into.
- **Backing up the recorder database while Home Assistant runs.** The copy is
  torn; it is history, and the hub rebuilds it.
- **Ignoring that the repository lives on a mounted disk.** A unit without the
  mount dependency can start before the disk is mounted and bring the stack up
  against no compose file; with it, the unit simply stays down until the disk
  is there.

## References

- [adr-0004-hosting-substrate.md](../../adrs/adr-0004-hosting-substrate.md) — the substrate decision.
- [Hosting architecture](../context/hosting-architecture.md)
- [Home Assistant hub](../context/home-assistant-hub.md)
- [Add a Tuya device](add-a-tuya-device.md)
