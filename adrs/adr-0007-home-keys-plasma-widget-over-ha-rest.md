---
id: adr-0007-home-keys-plasma-widget-over-ha-rest
category: adrs
tags: [adr, desktop-widget, plasma, rest, home-assistant, kwallet, switch-linking]
aliases: ["ADR-0007"]
related: [adr-index, adr-0005-control-plane-authority, adr-0006-tuya-bulb-widget-role, desktop-widget-surface]
version: 1.0
status: active
supersedes: adr-0006-tuya-bulb-widget-role
---

# ADR-0007: Home Keys Plasma widget — the wall-switch desktop surface over Home Assistant REST

## Problem

The owner presses the two wall switches ("teclas") every day — Sala key 1 and
Comedor key 2 — and wants the same keys on the desktop. The obvious source for
that surface is the upstream `tuya-bulb-widget` applet, but it writes the bulbs
directly over the Tuya LAN protocol (TCP/6668), which Home Assistant never
observes: its entity state goes stale, and the applet is therefore not a hub
control path. ADR-0006 rejected a thin adapter in this repository for exactly
that reason — the direct LAN writes would still bypass Home Assistant's state.
That left the desktop surface with no legitimate home once the owner deletes the
upstream repository, which is the plan.

The trade is explicit: the desktop surface must become a **client of the
authority** rather than a second writer. It may hold the wall-switch channel,
because that channel is what the Home Assistant automations already treat as
authoritative; it must never hold a bulb.

## Solution

**The wall-switch desktop surface is re-implemented inside this repository as
`widget/`, a KDE Plasma 6 applet that is a thin Home Assistant REST client: it
writes only the switch channel entities, polls state over REST every ~2 s, and
holds its token in KWallet; the bulbs are display-only and follow from the Home
Assistant automations; Home Assistant stays the single state authority.**

### The key surface (1 → N)

Two keys, each a wall-switch channel that drives one or more bulbs:

| Key | Switch entity (the only write target) | Bulb entities (display-only) |
|---|---|---|
| Key 1 | `switch.sala_tecla_canal_1` | `light.sala_luz_izquierda`, `light.sala_luz_derecha` |
| Key 2 | `switch.comedor_tecla_canal_2` | `light.comedor_luz_sola` |

The mapping is configuration (`widget/io.github.daver-ui.homekeys/contents/config/main.xml`),
not hardcoded QML, and the popup renders it instead of hiding it. Key 1 is
one-to-two and key 2 is one-to-one, so a single claimed state for key 1 would
lie when its bulbs disagree: the aggregate line reads **Mixed** instead
(`aggregateStates()` in `contents/ui/homekeys.js`).

### The write path

A press issues exactly one call:

```http
POST {hub}/api/services/switch/{turn_on|turn_off|toggle}
Authorization: Bearer <token>
Content-Type: application/json

{"entity_id":"<switch entity>"}
```

The **channel is the arbiter**. The Home Assistant automations in
`deploy/config/homeassistant/packages/real_devices.yaml` are
channel-authoritative and write-on-delta, so the widget's job ends at the switch
entity. Bulbs are never written by the widget. The write domain is enforced
structurally: `pressKey()` refuses a target whose entity id is not in the
`switch` domain (`isSwitchChannel()` in `homekeys.js`, covered by the Node test
suite) **before any request is built**, and records a typed `service-failed`
error on that key.

The widget is **refuse-not-queue**: an unreachable or rejecting hub becomes a
typed `hub-unreachable` / `service-failed` error on the key, never a command
held for later. On a 2xx reply the key's switch and bulb entities are re-read
immediately, so the confirmation is the authority's answer rather than the
widget's optimism.

### The hub address

The applet's default hub URL is the literal loopback address
`http://127.0.0.1:8123`: the hub runs on the same PC as the desktop. It is not
`localhost`, which may resolve to `::1` while the hub binds IPv4 only, and not
a `.local` name, which does not resolve here at all.

Plasma copies an applet's configured default into its stored configuration when
the applet is added to a panel, so an install created before this change still
holds the retired default. A stored URL equal to that retired value is
therefore **treated as unset** and resolves to the current default
(`normalizeBaseUrl()` in `homekeys.js`, covered by the Node test suite), so an
existing install recovers with no manual action. The manual path is the
Configure page: clear the "Home Assistant URL" field and apply — an empty
value resolves to the default — or type the address outright, which is what a
user does when the hub runs on another host.

### The read path

Every `pollIntervalSeconds` (default **2**, configurable 1–60), the widget issues
one request per tracked entity — two switches plus three bulbs, five requests
per tick:

```http
GET {hub}/api/states/<entity_id>
Authorization: Bearer <token>
Accept: application/json
```

There is no WebSocket. Each `XMLHttpRequest` has an 8-second timeout. A
successful read replaces only that entity's state and clears only that entity's
error; a failed read marks the entity **Unknown** and disables its key. State is
never fabricated: a bulb the hub reports as `unavailable` renders **Unavailable**,
never **Off**.

### Token custody: KWallet

The Home Assistant long-lived token lives in **KWallet** — wallet `kdewallet`,
folder `DaverHomeSystem`, entry `ha-token` — and nowhere else. At startup the
applet runs `kwallet-query --folder … --read-password … <wallet>` **once** through
Plasma's `org.kde.plasma.plasma5support` `DataSource` with `engine: "executable"`,
and caches the secret in a QML property. No compiled helper, no plaintext file, no
environment variable, never logged, never echoed, never appended to a URL.

`widget/install.sh token` is the only writer: it reads the token from stdin
without echo and pipes it to `kwallet-query`, so the secret never reaches a
command line or a file. A 10-second guard turns a locked or hung wallet into a
typed `wallet-error` with a Retry action rather than an endless spinner.

### Relationship to ADR-0006

ADR-0006 remains the record of the upstream project's role. This ADR supersedes
it **in part**:

- **Void:** the role paragraph's "It speaks neither MQTT nor HTTP … it is never
  advertised as a hub control path" (for this repo's desktop surface); "The
  widget cannot be a hub component: it is read-only (never modified)"; the
  Solution's "Interim desktop fallback. Until LocalTuya bring-up passes for a
  given device, the widget's desktop applet remains a working surface for that
  device" — the desktop surface role moved to `widget/` (this ADR), and the
  upstream applet must not be kept installed as a second control surface; and
  the Rejected-alternatives bullet "A thin adapter in this repository …
  Rejected because the widget is read-only and its direct LAN writes would
  still bypass HA's state".
- **Stand:** "LAN control of hub-managed bulbs belongs exclusively to Home
  Assistant via LocalTuya"; the link-watch semantics as the requirements source
  for the automations (channel-authoritative, write-on-delta, dp never guessed);
  and the fallout that an HA outage stops the switch-driven mirror.

The upstream project is still never modified by this repository: the desktop
surface here is a **copy**, not a modification. Its dp-inspection role is not
copied — the widget carries no Tuya protocol code.

### Rejected alternatives

- **(a) Keep the upstream applet as an external read-only component and add a
  second widget here.** Two desktop surfaces, one of which still writes
  TCP/6668 and leaves Home Assistant stale. Keeping both keeps the
  out-of-band-writer hazard on the panel; only one of them can be *the* surface.
- **(b) The widget writing the bulbs directly over TCP/6668.** A second writer
  with no state owner: Home Assistant never observes the write, its entity goes
  stale, and the two writers fight. This is the alternative ADR-0005 forbids.
- **(c) The widget writing the bulbs through `POST /api/services/light/*`.** It
  goes through Home Assistant, so it looks compliant, but the channel is the
  arbiter (channel-authoritative / write-on-delta — the semantics the retired
  `link watch` used and the automations still use). A bulb-only write
  desynchronises the pair, and the next channel delta puts the bulbs back.
- **(d) A compiled helper binary to reach KWallet.** Unnecessary: `kwallet-query`
  is reachable from pure QML through the `plasma5support` executable engine, so a
  helper would add a build step and a binary for no capability.
- **(e) Home Assistant WebSocket live state instead of REST polling.** The owner
  chose REST polling at the old widget's ~2 s cadence. The accepted cost is up to
  ~2 s of staleness and a confirmation that is up to one poll late — this is the
  desktop surface's disadvantage against the phone app, stated honestly rather
  than hidden.
- **(f) A 0600 plaintext token file or an environment variable.** Readable by
  every process of the user, inherited by children, and liable to land in
  backups; neither is a custody boundary.
- **(g) Running the REST calls through `curl` in the executable DataSource.**
  The bearer token would appear in the process list, which is exactly the leak
  the in-process `XMLHttpRequest` avoids.

What would change this decision: a third wall-switch channel needing a
per-device surface (the tecla-only scope would have to grow); a home hub where
the polling load of one request per entity per tick becomes material (one
snapshot request per tick would then be the better shape); or LocalTuya losing
the switch channel dps (then the channel would not exist to write).

## When to use

- Changing or reviewing the desktop wall-switch surface under `widget/`.
- Deciding how a new desktop control talks to the hub: through Home Assistant,
  with the write domain named explicitly.
- Explaining why the applet writes only the switch channel and never a bulb.

## When not to use

- For dp inspection or the retired `link watch` semantics — those are the upstream
  project's, and they are recorded in
  [adr-0006-tuya-bulb-widget-role.md](adr-0006-tuya-bulb-widget-role.md).
- For the phone app's screens, discovery or WebSocket live state — that is
  `[[mobile-app-design]]`.
- For the hub's entities, recorder or automations — that is
  `[[home-assistant-hub]]`.
- Do not edit this record "for clarity"; supersede it or append an addendum.

## Examples

Read one entity:

```http
GET http://127.0.0.1:8123/api/states/switch.sala_tecla_canal_1
Authorization: Bearer <token>
Accept: application/json
```

Write the channel only:

```http
POST http://127.0.0.1:8123/api/services/switch/turn_on
Authorization: Bearer <token>
Content-Type: application/json

{"entity_id":"switch.sala_tecla_canal_1"}
```

Read the token from KWallet (prints the secret on stdout; store it once with
`widget/install.sh token` instead of typing it anywhere):

```sh
kwallet-query --folder 'DaverHomeSystem' --read-password 'ha-token' 'kdewallet'
```

## Common mistakes

Accepted fallout, stated as costs:

1. **The read-only convention changes for this widget.** The upstream repository
   is still never modified, but its Plasma surface is now copied and adapted
   here, so "reused unmodified" no longer describes the desktop surface.
2. **The dp-inspection evidence is not copied.** `doctor` and `link dps` stay in
   the upstream project and disappear with it. The dp evidence inside this
   repository is `tuya-local-key`'s device details; a LAN dp probe would be a new
   decision, not a dp guess.
3. **The widget is now a hub control path *through* Home Assistant.** ADR-0006's
   "never advertise the applet as a hub control path" survives only for a stale
   install of the upstream applet, which still writes TCP/6668 directly.
4. **An HA outage stops the desktop surface.** No widget-side loop, nothing
   queued — the same posture as the phone app.
5. **REST polling is up to ~2 s stale and a write is not painted optimistically.**
   The card confirms on the following read, not on the click.
6. **The widget depends on an unlocked KWallet** and, like the phone app, sends a
   bearer token over plain HTTP on the trusted LAN.

## References

- [adr-0005-control-plane-authority.md](adr-0005-control-plane-authority.md) — Home Assistant as the single state authority.
- [adr-0006-tuya-bulb-widget-role.md](adr-0006-tuya-bulb-widget-role.md) — the upstream project's role, superseded in part by this record.
- [[desktop-widget-surface]] — the surface this decision creates.
- [[mobile-app-design]] — the other thin Home Assistant client; same authority rule, WebSocket instead of polling.
- [adr-index.md](adr-index.md)
