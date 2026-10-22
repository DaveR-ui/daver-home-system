---
id: home-keys-widget
category: widget
tags: [plasma, widget, home-assistant, rest, kwallet, wall-switch]
aliases: ["Home Keys", "homekeys", "home-keys"]
related: [desktop-widget-surface, adr-0007-home-keys-plasma-widget-over-ha-rest, mobile-app-design, adr-0005-control-plane-authority]
version: 1.0
status: active
---

# Home Keys Plasma Widget

A KDE Plasma 6 applet for the two wall-switch ("tecla") channels in the Sala and
the Comedor. It is a **thin Home Assistant REST client**: it reads five entities
every poll and writes **only** the switch channel entities. The bulbs are
display-only; Home Assistant's existing automations move them. Home Assistant
stays the single state authority (ADR-0005), so the widget is never a second
writer. This is the desktop widget surface of the hub, sharing the REST contract
described in [Mobile App Design](../docs/context/mobile-app-design.md).

## Requirements and install

KDE Plasma 6, `kwallet-query` (with a running `kwalletd6`), and a Home Assistant
long-lived access token. `kpackagetool6` is optional; `install.sh` falls back to
copying the package into the user's plasmoids directory.

```sh
cd widget
./install.sh            # install (the default subcommand)
./install.sh upgrade    # upgrade an installed copy
./install.sh status     # report whether it is installed
./install.sh remove     # remove it
```

Then right-click the panel or desktop, choose **Add Widgets…**, and add
**Home Keys**. If it does not appear, restart plasmashell:
`kquitapp6 plasmashell && kstart plasmashell`. There is no Python package,
virtualenv, systemd service or scheduled task.

## Provision the token

The token lives in KWallet, never in the widget configuration and never in a
file. Store it once with `./install.sh token`: the command reads the token from
stdin without echoing it and pipes it to `kwallet-query`, so only the wallet,
folder and entry key appear on the command line. Defaults (overridable with
`--wallet`, `--folder`, `--key`): wallet `kdewallet`, folder `DaverHomeSystem`,
entry key `ha-token`.

At startup the widget runs
`kwallet-query --folder <folder> --read-password <key> <wallet>` once through
Plasma's `executable` data engine, caches the token in a QML property, and never
logs or echoes it. A 10-second guard turns a locked/hung wallet into a typed
`wallet-error` instead of an endless spinner. After rotating the token,
**Retry** re-reads the KWallet entry, so the new token is picked up without
restarting plasmashell.

## Configure

Open **Configure Home Keys…**:

| Entry | Default |
|---|---|
| `hubBaseUrl` | `http://127.0.0.1:8123` |
| `pollIntervalSeconds` | `2` (1–60) |
| `tecla1SwitchEntity` | `switch.sala_tecla_canal_1` |
| `tecla1BulbEntities` | `light.sala_luz_izquierda, light.sala_luz_derecha` |
| `tecla2SwitchEntity` | `switch.comedor_tecla_canal_2` |
| `tecla2BulbEntities` | `light.comedor_luz_sola` |
| `iconOn` | `flashlight-on-symbolic` |
| `iconOff` | `flashlight-off-symbolic` |
| `iconUnknown` | `dialog-information-symbolic` (shown for unknown, unavailable and mixed — never the off icon) |

The token is **not** entered on that page. The hub address and every entity id
come from configuration, not from hardcoded QML.

## Hub URL and the retired default

The widget runs on the same PC as the hub, so its default address is the loopback
address `http://127.0.0.1:8123`. It is the literal loopback address, not
`localhost`, because `localhost` may resolve to `::1` while the hub binds IPv4
only — the name would look right and still fail to connect.

An install created before this change still holds the retired `*.local` default
in its panel configuration. Plasma copies the configured default into an applet's
configuration when the applet is added to a panel, so that stored value would
otherwise keep pointing at a name that does not resolve. The widget treats the
retired value as unset and resolves it to the current default, so an existing
install recovers with no manual action.

The manual reset path is also there if you want to be explicit: open
**Configure Home Keys…**, clear the **Home Assistant URL** field and apply — an
empty value resolves to the default — or type the address outright. Typing it is
what you do when Home Assistant runs on another host, for example
`http://192.168.1.20:8123`.

## The 1-to-N mapping

| Key | Switch entity (the only write target) | Bulb entities (display-only) |
|---|---|---|
| Key 1 | `switch.sala_tecla_canal_1` | `light.sala_luz_izquierda`, `light.sala_luz_derecha` |
| Key 2 | `switch.comedor_tecla_canal_2` | `light.comedor_luz_sola` |

Each key card renders every bulb it drives, and each bulb card shows that bulb's
own live state. When the two key-1 bulbs disagree, the card's aggregate line
reads **Mixed**; it never claims one state for the pair. A bulb whose state
cannot be read shows **Unknown** (or **Unavailable** when Home Assistant says
so), never a fake **Off**.

## Reads, writes and errors

Every `pollIntervalSeconds`, the widget issues one
`GET /api/states/<entity_id>` per tracked entity (two switches plus three
bulbs), each with `Authorization: Bearer <token>`. Commands are
`POST /api/services/switch/{turn_on|turn_off|toggle}` with
`{"entity_id":"<switch entity>"}`; the bulbs are never written. A successful
press immediately re-reads that key's switch and bulb entities instead of
waiting for the next tick.

Failures are typed and rendered in the popup, the tooltip and the panel icon:

| Kind | Meaning |
|---|---|
| `hub-unreachable` | The hub did not answer (status 0 / network error). |
| `unauthorized` | HTTP 401/403; check the KWallet entry. |
| `not-found` | HTTP 404 on a configured entity id. |
| `http-error` | Any other non-2xx status. |
| `token-missing` | The KWallet folder or entry does not exist. |
| `wallet-error` | The wallet read failed or timed out. |
| `service-failed` | Home Assistant refused the switch command. |

A failed read marks the affected entity **Unknown**, disables that key's
buttons and leaves the other key usable. Per-key in-flight guards ensure a press
disables only its own key, and a later press always wins over a slow reply for
the same key.

## Authority and tests

The widget follows [ADR-0005](../adrs/adr-0005-control-plane-authority.md):
Home Assistant owns state and the bulb automations, and the widget's only write
is the wall-switch channel. It supersedes the `link watch` writer role of the
retired upstream applet, whose status and fate this surface records in
[ADR-0006](../adrs/adr-0006-tuya-bulb-widget-role.md) and
[ADR-0007](../adrs/adr-0007-home-keys-plasma-widget-over-ha-rest.md); that
project stays read-only and unmodified.

Pure logic lives in `contents/ui/homekeys.js` and is covered by Node's built-in
test runner (no npm dependencies): `cd widget && node --test`. That suite
exercises the pure `homekeys.js` layer only; the QML orchestration in
`contents/ui/main.qml` is not covered by automated tests and is verified
on-device. QML syntax is checked with
`qmllint -I /usr/lib/qt6/qml widget/io.github.daver-ui.homekeys/contents/ui/*.qml widget/io.github.daver-ui.homekeys/contents/ui/config/*.qml`
from the repo root.
