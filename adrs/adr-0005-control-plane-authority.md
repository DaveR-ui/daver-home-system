---
id: adr-0005-control-plane-authority
category: adrs
tags: [adr, control-plane, authority, home-assistant, rest, websocket]
aliases: ["ADR-0005"]
related: [adr-index, adr-0004-hosting-substrate, home-assistant-hub, mobile-app-design]
version: 1.0
status: active
---

# ADR-0005: Control-plane authority — Home Assistant as the single state authority

## Problem

Every control surface — phone app, desktop, automations — reads and writes the
same device state. If two components each keep their own model of a bulb, they
diverge the moment either writes out of band, and the user is shown a lie. The
question is where authoritative state lives and how the app reaches it: make the
MQTT broker the authority, stand up a purpose-built Node.js backend with its own
database, or adopt Home Assistant's state model directly. The decisive fact:
**only Home Assistant can actually actuate these devices** — it drives them over
LocalTuya. Any other nominated authority would be a facade: topics nothing
enforces.

## Solution

**Home Assistant is the single source of truth; the app speaks only to Home
Assistant through its REST and WebSocket API** (decision
`ha-authority-app-via-ha-api`, panel confidence 0.85). HA owns entity state, the
recorder SQLite database, and the event bus; nothing else keeps a competing model
of device state.

The app authenticates with a long-lived access token sent as
`Authorization: Bearer <long-lived-access-token>`. Exact surface:

| Method + path | Purpose |
| --- | --- |
| `GET /api/` | health / API presence check |
| `GET /api/states` | full snapshot of every entity |
| `GET /api/states/<entity_id>` | one entity's current state |
| `POST /api/services/light/turn_on` | turn on, optionally with brightness/colour attributes |
| `POST /api/services/light/turn_off` | turn off |
| `POST /api/services/light/toggle` | toggle |

Service calls carry `{"entity_id": "light.<room>_<device>"}` plus optional
attributes. Live state comes over WebSocket at `ws://<host>:8123/api/websocket`:

1. server sends `auth_required`;
2. client sends `{"type":"auth","access_token":"…"}`;
3. server replies `auth_ok`;
4. client sends `{"id":1,"type":"subscribe_events","event_type":"state_changed"}`;
5. on close, reconnect and resubscribe.

**Mosquitto is not app-facing.** It stays the hub-internal bus for MQTT-native
devices and future extensions; the app has no broker credentials and no topic
contract.

**A separate Node.js backend and a separate database are deferred, not rebuilt.**
HA already provides the entity model, persistence, and event stream those would
have duplicated; standing one up now buys nothing and adds a second authority to
reconcile.

### Rejected alternatives

- **Broker-as-authority** — treat Mosquitto topics as the canonical state.
  Rejected: nothing enforces the topics, and the devices are not on the broker,
  so the "authority" would be a projection of state HA already owns.
- **Separate Node.js backend + database** — a bespoke app server mediating
  control. Rejected for now: it duplicates HA's state, persistence, and event
  stream, and adds a second authority to keep in sync.

## When to use

When designing or changing the app-to-hub interface, adding a control surface, or
when a proposal introduces a second state store.

## When not to use

For the substrate the hub runs on — that is `[[adr-0004-hosting-substrate]]`; for
the desktop widget's role — that is `[[adr-0006-tuya-bulb-widget-role]]`; for
topic design among hub-internal MQTT devices — see `[[mqtt-topic-map]]`. Do not
edit this record "for clarity"; supersede it or append an addendum.

## Examples

Snapshot and command over REST:

```sh
curl -H "Authorization: Bearer <long-lived-access-token>" \
     http://<host>:8123/api/states

curl -X POST -H "Authorization: Bearer <long-lived-access-token>" \
     -H "Content-Type: application/json" \
     -d '{"entity_id": "light.kitchen_ceiling"}' \
     http://<host>:8123/api/services/light/turn_on
```

Live updates over WebSocket (messages in wire order):

```json
{"type": "auth", "access_token": "<long-lived-access-token>"}
{"id": 1, "type": "subscribe_events", "event_type": "state_changed"}
```

The Flutter app's design consumes exactly this surface — see
`[[mobile-app-design]]`.

## Common mistakes

Accepted fallout recorded at decision time:

- **HA restarts.** The app must show "hub unavailable" and resubscribe on
  reconnect — it must **not** silently queue commands against a dead socket.
- **A leaked long-lived token is full LAN control.** Store it in the OS keystore;
  never ship it in the app bundle.
- **Plain HTTP plus a bearer token is sniffable on a hostile LAN.** The
  trusted-LAN assumption is documented explicitly rather than implied.
- **Non-HA MQTT devices later re-open the question.** If MQTT-native devices are
  added, the broker-authority temptation returns and this ADR must be revisited
  deliberately, not drifted into.

## References

- [adr-0004-hosting-substrate.md](adr-0004-hosting-substrate.md) — where HA runs.
- [adr-index.md](adr-index.md)
- [Home Assistant hub](../docs/context/home-assistant-hub.md)
- [Mobile app design](../docs/context/mobile-app-design.md)
- [MQTT topic map](../docs/context/mqtt-topic-map.md)
