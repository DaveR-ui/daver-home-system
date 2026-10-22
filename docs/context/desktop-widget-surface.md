---
last_updated: 2026-10-22
status: active
description: The in-repo KDE Plasma 6 wall-switch applet — a thin Home Assistant REST client that writes only switch channel entities and keeps its token in KWallet.
tags: [desktop, plasma, widget, homeassistant, rest, kwallet, switch, tecla, polling]
version: 1.3
related: [mobile-app-design, home-assistant-hub, security-and-privacy, troubleshooting]
---

# Desktop Widget Surface (Home Keys)

## Problem

Everyday light control already happens at two physical wall switches ("teclas") in the Sala and the Comedor, and the owner expects the same control from the desktop. The obvious shortcut — a desktop applet that talks to the bulbs directly over the Tuya LAN protocol — adds a second writer with no state owner: Home Assistant never observes the write, its entity goes stale, and two writers end up fighting over the same bulb. That is exactly the failure [[adr-0005-control-plane-authority]] forbids.

The desktop surface therefore needs a client that is authoritative only where it is allowed to be: the wall-switch channel. It must read bulb state without ever writing it, survive a locked wallet and an unreachable hub without crashing, and never guess a state it could not read.

## Solution

The desktop surface is the **Home Keys** applet, maintained in this repository under `widget/`. It is a KDE Plasma 6 / Qt 6 QML plasmoid that speaks **only** Home Assistant's REST API: it polls five entities (two switch channels plus the three bulbs their automations drive) and writes the two switch entities. Home Assistant remains the single state authority; its automations own the bulb writes. The earlier upstream project that inspired this applet is **retired** and is no longer a dependency (the history is in [[adr-0006-tuya-bulb-widget-role]] and [[adr-0007-home-keys-plasma-widget-over-ha-rest]]).

### The key surface (1 → N)

Two keys, each a wall-switch channel that drives one or more bulbs:

| Key | Switch entity (the only write target) | Bulb entities (display-only) |
|---|---|---|
| Key 1 | `switch.sala_tecla_canal_1` | `light.sala_luz_izquierda`, `light.sala_luz_derecha` |
| Key 2 | `switch.comedor_tecla_canal_2` | `light.comedor_luz_sola` |

The mapping is rendered, not hidden. Each key card lists every bulb it drives, every bulb card carries that bulb's own live state, and the card's aggregate line reads **Mixed** when the key-1 bulbs disagree. The aggregate is computed by `aggregateStates()` in `contents/ui/homekeys.js`: only readable `on`/`off` states vote, `unknown` and `unavailable` abstain, no readable vote yields **Unknown**, and disagreement yields **Mixed**. A single claimed state for the pair would be a lie, so the widget never invents one.

A bulb that cannot be read renders **Unknown**; a bulb Home Assistant reports as `unavailable` renders **Unavailable** — never a fabricated **Off**.

### The write path

A press issues exactly one call:

```http
POST {hub}/api/services/switch/{turn_on|turn_off|toggle}
Authorization: Bearer <token>
Content-Type: application/json

{"entity_id": "<switch entity>"}
```

The service name is derived by `serviceForAction()` and the body by `serviceCallBody()`; both are pure functions covered by the Node test suite. The write domain is structural, not implied: `isSwitchChannel()` refuses a target whose entity id is not in the `switch` domain before any request is built, and the popup shows the refusal as a typed `service-failed` error on that key. The bulbs are **never** written by the widget — they follow from the Home Assistant automations in `deploy/config/homeassistant/packages/real_devices.yaml` (channel-authoritative, write-on-delta).

The applet is not optimistic. On a 2xx reply it immediately re-reads that key's switch and bulb entities instead of waiting for the next poll tick, so the displayed state is the authority's answer, not the applet's hope. A rejected or unreachable command becomes a typed `service-failed` / `hub-unreachable` state on that key.

### The read path

Every `pollIntervalSeconds` (default **2**, configurable 1–60), the widget issues one request per tracked entity:

```http
GET {hub}/api/states/<entity_id>
Authorization: Bearer <token>
Accept: application/json
```

That is five requests per tick: two switches plus three bulbs. Each `XMLHttpRequest` has an 8-second timeout, so a connected-but-silent hub becomes `hub-unreachable` rather than a hung card. A successful read replaces that entity's state and clears only that entity's error; a sibling's success never hides a still-broken entity.

### Hub address: loopback default

The applet's hub URL default is the literal **`http://127.0.0.1:8123`** (`hubBaseUrl` in `contents/config/main.xml`): the widget runs on the same PC as the hub, so the loopback address is the correct one. `localhost` is deliberately **not** used — it can resolve to `::1` while Home Assistant binds IPv4 only. The retired default **`http://homeassistant.local:8123`** does not resolve on the owner's machine and is no longer shipped.

**Legacy-default normalization.** Plasma writes the config default into an applet's stored configuration when the widget is added to a panel, so an install created before this change still holds the retired default. The widget treats a stored `hubBaseUrl` equal to the retired default as **unset** and resolves it to the current default, so **no manual action is required for an existing install**.

**Manual reset path.** To point the applet somewhere else — for example when Home Assistant runs on another host — use **Configure Home Keys… → "Home Assistant URL"**: clear the field and apply (an empty value resolves to the default), or type the address explicitly. The value lives in the applet configuration, never in a file.

### Token custody: KWallet only

The Home Assistant long-lived token lives in **KWallet**, never in the widget configuration, never in a file, never in a URL, and never on a command line.

- At startup the applet runs `kwallet-query --folder <folder> --read-password <key> <wallet>` **once** through Plasma's `org.kde.plasma.plasma5support` `DataSource` with `engine: "executable"`.
- The command string is assembled by `buildWalletReadCommand()`, which shell-quotes wallet, folder and key. The secret is printed by `kwallet-query` on stdout and cached in a QML property.
- The token is never logged or echoed, and the wallet-parse result carries it only in a `token` field — never in the user-facing `message`.
- Defaults: wallet `kdewallet`, folder `DaverHomeSystem`, entry key `ha-token`.
- A 10-second guard converts a locked or hung wallet into a typed `wallet-error` instead of an endless spinner.
- A 401/403 from Home Assistant invalidates the cached token and stops polling; **Retry** then re-reads KWallet, so a rotated token is picked up without restarting plasmashell.
- `widget/install.sh token` is the **only** writer of that entry: it reads the token from stdin without echo and pipes it to `kwallet-query`, so the secret never reaches a command line or a file.

The same custody rule as the phone app applies — see [[security-and-privacy]].

### Typed error states

Every failure is classified; none is swallowed and none becomes a fake state.

| Kind | Meaning |
|---|---|
| `hub-unreachable` | Network error, HTTP status 0, or request timeout — the hub did not answer. |
| `unauthorized` | HTTP 401/403 — the token was rejected; check the KWallet entry. |
| `not-found` | HTTP 404 on a configured entity id. |
| `http-error` | Any other non-2xx status, or an unreadable state payload. |
| `token-missing` | The KWallet folder or entry does not exist (or the read returned an empty secret). |
| `wallet-error` | The wallet read failed for another reason, or the 10-second guard fired. |
| `service-failed` | Home Assistant refused the switch command. |

A failed read marks that entity **Unknown**, disables the affected key's buttons, and leaves the other key usable. A service refusal leaves the buttons live so the user can retry. The widget never crashes on a malformed URL, malformed JSON, or a hub that stops answering.

### Per-key in-flight and stale replies

Concurrency is scoped to the key, not to the widget:

- While a press for a key is in flight, only that key's On/Off/Toggle buttons are disabled; the other key stays live.
- Each dispatch carries a monotonic run token (`nextRunToken()`). The newest token per key is recorded in `actionLatestRun`.
- When a reply arrives, `isStaleReply()` compares its token with the key's latest. A slower reply overtaken by a newer press for the same key is dropped and does **not** clear the newer run's in-flight marker — later press wins.
- A reply whose token cannot be recovered is treated as stale by default.
- The same guard protects a `Retry` of the wallet read: an older `kwallet-query` reply cannot overwrite a newer attempt.

### Display-only bulbs

The bulb zone exists to make the 1-to-N mapping legible, not to offer a second write path. Each `BulbCard` receives `bulbName`, `entityId` and `bulbState` and renders them; there is no click handler and no service call. The bulbs are read because the owner needs to see what the key actually did — not because the widget may drive them.

This is the visible form of the authority rule: one writer per bulb (Home Assistant), one write target per key (the switch channel), and an honest display of the result.

### Package layout and module boundary

```text
widget/
├── install.sh                          # install / upgrade / remove / status / token
├── README.md                           # note-class doc for this directory
├── tests/homekeys.test.mjs             # 61 zero-dependency node:test cases
└── io.github.daver-ui.homekeys/
    ├── metadata.json
    ├── contents/
    │   ├── config/
    │   │   ├── main.xml                # KConfig schema + defaults
    │   │   └── config.qml              # configuration category
    │   ├── icons/homekeys.svg
    │   └── ui/
    │       ├── main.qml                # only state owner and only I/O
    │       ├── homekeys.js             # pure, I/O-free, unit-tested logic
    │       ├── FullRepresentation.qml  # popup / desktop, render-only
    │       ├── CompactRepresentation.qml
    │       ├── TeclaBlock.qml
    │       ├── BulbCard.qml
    │       ├── SeverityDot.qml
    │       ├── SeverityLine.qml
    │       ├── SwitchGlyph.qml
    │       ├── DashedLine.qml
    │       └── config/ConfigGeneral.qml
    └── ...
```

The boundary is strict:

- `contents/ui/homekeys.js` is pure: no QML types, no process, no file, no network. It owns URL/body assembly, state interpretation, error classification, shell quoting, wallet-output parsing and the map-copy helpers. That purity is what lets a plain V8 context execute the shipped bytes in `tests/homekeys.test.mjs`.
- `main.qml` is the only file that reads `Plasmoid.configuration` and the only file that performs I/O (`XMLHttpRequest` for Home Assistant, the `executable` `DataSource` for KWallet).
- Every other QML file is render-only: it receives computed values and emits intents; it never reads configuration, never performs I/O and never maps a state onto a colour by itself.
- `contents/config/main.xml` is the KConfig contract. Nothing about the hub or the entity ids is hardcoded in QML — all of it comes from configuration with the documented defaults.

### Install and run

```sh
cd widget
./install.sh            # install (default); uses kpackagetool6 --type Plasma/Applet --install
./install.sh upgrade    # upgrade an installed copy
./install.sh status     # report whether it is installed
./install.sh remove     # remove it
./install.sh token      # read the HA token from stdin (no echo) into KWallet
```

Then right-click the panel or desktop, choose **Add Widgets…**, and add **Home Keys**. If it does not appear, restart plasmashell: `kquitapp6 plasmashell && kstart plasmashell`. `kpackagetool6` install was verified on this machine with Plasma 6.8; without `kpackagetool6` the script copies the package into the user's plasmoids directory instead.

Verification:

```sh
cd widget && node --test                                     # 61 logic cases, no npm dependencies
qmllint -I /usr/lib/qt6/qml widget/io.github.daver-ui.homekeys/contents/ui/*.qml widget/io.github.daver-ui.homekeys/contents/ui/config/*.qml # QML syntax
```

### What the widget is not

No TCP/6668. No Tuya protocol code. No `tinytuya`. No Python, no CLI, no virtualenv. No MQTT. No Home Assistant WebSocket. No systemd user service. No link-watch loop. No scheduled task. No compiled helper binary. No per-device, group or all-lights surfaces. No brightness or colour control. No CLI configuration page.

It is a small REST client with two key cards, not a replacement for the phone app's full surface.

### Accepted trade-offs

- **Staleness.** REST polling means state can be up to one poll interval old (default ~2 s). A press is confirmed by the following read, not optimistically.
- **No queueing.** An HA outage stops the desktop surface. Commands are refused, never queued — the same rule as the phone app, because a queued command could fire later against a changed world.
- **Wallet dependency.** The widget depends on an unlocked, running KWallet. A locked wallet yields `wallet-error` and a Retry action, not a cached token in the widget config.
- **Plain transport.** The hub is addressed over plain HTTP with a bearer token on the trusted LAN. No TLS is terminated by the applet.

## When to use

- Changing or reviewing the desktop wall-switch surface (`widget/`).
- Understanding why the applet writes only the switch channel and never a bulb.
- Debugging a widget error state, a stale card, a wallet read failure, or a hub URL that is wrong or still holds the retired default.
- Adding another key card or another display-only bulb to the mapping.

## When not to use

- For the phone app's screens, discovery or WebSocket live state — see [[mobile-app-design]].
- For the hub's entities, recorder or automations — see [[home-assistant-hub]].
- For the history of the retired upstream project this applet descends from — see [[adr-0006-tuya-bulb-widget-role]].
- For the LAN boundary and secret-handling posture — see [[security-and-privacy]].

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

Configure a second key and its bulbs in `contents/config/main.xml`:

```xml
<entry name="tecla2SwitchEntity" type="String">
  <label>Home Assistant switch entity for key 2. This is the only entity the key writes.</label>
  <default>switch.comedor_tecla_canal_2</default>
</entry>
<entry name="tecla2BulbEntities" type="String">
  <label>Comma-separated light entities that key 2 drives. Display-only: the Home Assistant automation writes them.</label>
  <default>light.comedor_luz_sola</default>
</entry>
```

## Common mistakes

- **Writing a bulb from the applet.** The bulbs are display-only; the automations own them. A second writer reintroduces stale state and write fights.
- **Treating a failed read as Off.** Unknown and Unavailable are truthful; Off is a claim the widget cannot make without evidence.
- **Collapsing key 1's two bulbs into one state.** When they disagree the answer is Mixed, not the state of whichever bulb answered last.
- **Putting the token in the configuration page or a file.** It belongs in KWallet; `install.sh token` is the only writer.
- **Waiting for the next poll after a press.** The write path re-reads the key immediately, so the card confirms the command.
- **Sharing one in-flight guard across both keys.** Concurrency is per key; a press on one key must not freeze the other.

## References

- [mobile-app-design](mobile-app-design.md) — the other thin HA REST client; same single-authority rule, different custody.
- [home-assistant-hub](home-assistant-hub.md) — the authority the applet reads and writes through.
- [security-and-privacy](security-and-privacy.md) — token custody and the LAN-only boundary.
- [troubleshooting](troubleshooting.md) — hub-unreachable and token-rejected symptoms.
- [[adr-0007-home-keys-plasma-widget-over-ha-rest]] — the decision to build the surface on HA REST.
- [adr-0005-control-plane-authority](../../adrs/adr-0005-control-plane-authority.md) — why Home Assistant is the only writer.
- `widget/README.md` — the directory-level install and configuration note.
