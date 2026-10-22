.pragma library

/*
 * Pure helpers for the Home Keys plasmoid.
 *
 * No QML types and no I/O live here: nothing in this file runs a process,
 * reads a file or talks to the network. That is what lets a plain JavaScript
 * engine execute these exact bytes -- tests/homekeys.test.mjs evaluates them in
 * a bare V8 context -- so URL assembly, Home Assistant state interpretation,
 * shell quoting and the wallet vocabulary are unit tested without a desktop
 * session.
 *
 * Processes belong in main.qml. The QML layer reaches a shell only through
 * buildWalletReadCommand() and the Home Assistant URL/body builders below.
 */

/* --- Entity state -------------------------------------------------------- */

var STATE_ON = "on";
var STATE_OFF = "off";
var STATE_MIXED = "mixed";
var STATE_UNKNOWN = "unknown";
/*
 * Home Assistant's own word for an entity it cannot currently reach. Kept
 * distinct from unknown: the entity exists, the device behind it does not
 * answer. Both are unreadable, but only unavailable renders as a warning.
 */
var STATE_UNAVAILABLE = "unavailable";

/* --- Actions ------------------------------------------------------------- */

var ACTION_ON = "on";
var ACTION_OFF = "off";
var ACTION_TOGGLE = "toggle";

/* --- Severity ------------------------------------------------------------ */

var SEVERITY_POSITIVE = "positive";
var SEVERITY_NEGATIVE = "negative";
var SEVERITY_NEUTRAL = "neutral";
var SEVERITY_MUTED = "muted";
var SEVERITY_WARNING = "warning";

/* --- Typed error kinds --------------------------------------------------- */

var ERROR_HUB_UNREACHABLE = "hub-unreachable";
var ERROR_UNAUTHORIZED = "unauthorized";
var ERROR_NOT_FOUND = "not-found";
var ERROR_HTTP_ERROR = "http-error";
var ERROR_TOKEN_MISSING = "token-missing";
var ERROR_WALLET_ERROR = "wallet-error";
var ERROR_SERVICE_FAILED = "service-failed";

var MESSAGE_HUB_UNREACHABLE = "Home Assistant is unreachable.";
var MESSAGE_UNAUTHORIZED = "Home Assistant rejected the token. Check the KWallet entry.";
var MESSAGE_NOT_FOUND = "The entity does not exist in Home Assistant.";
var MESSAGE_SERVICE_FAILED = "Home Assistant refused the command.";
var MESSAGE_NOT_A_SWITCH_CHANNEL = "The configured entity is not a switch channel; the widget writes only switch entities.";
var MESSAGE_WALLET_ERROR = "The KWallet entry could not be read.";

/* --- Defaults ------------------------------------------------------------ */

var DEFAULT_HUB_BASE_URL = "http://127.0.0.1:8123";
/*
 * The hub address this widget shipped with before the default was corrected to
 * the hub's loopback address on this PC. Plasma copies an applet's configured
 * default into its configuration when the applet is added to a panel, so an
 * install created before the correction still stores the retired address and
 * would keep failing to resolve it.
 *
 * The value is assembled from parts on purpose: the migration below must
 * RECOGNISE the retired endpoint, but the retired address must not be written
 * verbatim in the shipped sources. Keep the host and the port separate.
 */
var LEGACY_HUB_HOST = "homeassistant" + ".local";
var LEGACY_HUB_PORT = 8123;
var LEGACY_HUB_BASE_URL = "http://" + LEGACY_HUB_HOST + ":" + LEGACY_HUB_PORT;
var DEFAULT_WALLET_NAME = "kdewallet";
var DEFAULT_WALLET_FOLDER = "DaverHomeSystem";
var DEFAULT_WALLET_KEY = "ha-token";
var DEFAULT_ICON_ON = "flashlight-on-symbolic";
var DEFAULT_ICON_OFF = "flashlight-off-symbolic";
/*
 * The panel glyph for a state that is neither on nor off. It must never be the
 * off icon: a failed read rendered as "off" is a fake state.
 */
var DEFAULT_ICON_UNKNOWN = "dialog-information-symbolic";
var RUN_TOKEN_PREFIX = "plasma-run-";

/* --- Text helpers -------------------------------------------------------- */

/**
 * Normalises a raw string: nullish -> "", CR removed, surrounding space trimmed.
 */
function normalizeText(raw) {
    if (raw === undefined || raw === null) {
        return "";
    }
    return String(raw).replace(/\r/g, "").trim();
}

/**
 * True when a configured value is the retired hub default.
 *
 * Surrounding whitespace and trailing slashes are ignored and the comparison is
 * case-insensitive, so every spelling Plasma could have stored matches. A path
 * after the host:port makes it a different, user-configured address and is
 * therefore NOT the retired default.
 */
function isLegacyHubBaseUrl(raw) {
    var value = normalizeText(raw).replace(/\/+$/, "");
    return value.toLowerCase() === LEGACY_HUB_BASE_URL.toLowerCase();
}

/**
 * Normalises a hub base URL.
 *
 * Empty input falls back to `fallback` and then to DEFAULT_HUB_BASE_URL, so the
 * widget always has an address. The retired default is treated exactly like an
 * empty value, in `raw` and in `fallback` alike: an install created before the
 * hub moved onto this PC still stores it, and it does not resolve any more.
 * Trailing slashes are removed (the URL builders add their own) and a missing
 * scheme becomes http://, because Home Assistant on the LAN is normally plain
 * HTTP.
 */
function normalizeBaseUrl(raw, fallback) {
    var value = normalizeText(raw);
    if (value === "" || isLegacyHubBaseUrl(value)) {
        value = normalizeText(fallback);
    }
    if (value === "" || isLegacyHubBaseUrl(value)) {
        value = DEFAULT_HUB_BASE_URL;
    }
    value = value.replace(/\/+$/, "");
    if (value === "" || /^[a-zA-Z][a-zA-Z0-9+.-]*:$/.test(value)) {
        value = DEFAULT_HUB_BASE_URL;
    } else if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(value)) {
        value = "http://" + value;
    }
    return value;
}

/**
 * Splits the comma-separated entity list from configuration.
 *
 * Every entry is trimmed and empty entries are dropped, so a trailing comma or
 * an empty field never creates a phantom entity.
 */
function splitEntityList(raw) {
    var text = normalizeText(raw);
    if (text === "") {
        return [];
    }
    var parts = text.split(",");
    var result = [];
    for (var i = 0; i < parts.length; i += 1) {
        var item = normalizeText(parts[i]);
        if (item !== "") {
            result.push(item);
        }
    }
    return result;
}

/**
 * The room name carried by a `*_tecla_canal_<n>` switch entity id.
 *
 * "switch.sala_tecla_canal_1" -> "Sala". Ids that do not follow the convention
 * fall back to the raw id, so an unusual configuration is still labelled
 * truthfully instead of being given an invented room.
 */
function roomLabel(switchEntityId) {
    var id = normalizeText(switchEntityId);
    if (id === "") {
        return "";
    }
    var dot = id.indexOf(".");
    var bare = dot >= 0 ? id.substring(dot + 1) : id;
    var match = /^(.+)_tecla_canal_\d+$/.exec(bare);
    if (match === null) {
        return id;
    }
    var words = match[1].split("_");
    var label = [];
    for (var i = 0; i < words.length; i += 1) {
        var word = words[i];
        if (word === "") {
            continue;
        }
        label.push(word.charAt(0).toUpperCase() + word.substring(1));
    }
    return label.length === 0 ? id : label.join(" ");
}

/**
 * A short display label for an entity id: "light.sala_luz_izquierda" ->
 * "Sala luz izquierda". Falls back to the raw id for anything unusual.
 */
function entityLabel(entityId) {
    var id = normalizeText(entityId);
    if (id === "") {
        return "";
    }
    var dot = id.indexOf(".");
    var bare = dot >= 0 ? id.substring(dot + 1) : id;
    var words = bare.split("_");
    var label = [];
    for (var i = 0; i < words.length; i += 1) {
        var word = words[i];
        if (word === "") {
            continue;
        }
        label.push(word.charAt(0).toUpperCase() + word.substring(1));
    }
    return label.length === 0 ? id : label.join(" ");
}

/* --- Home Assistant payloads -------------------------------------------- */

/**
 * Parses one `GET /api/states/<entity_id>` response body.
 *
 * Returns {state, attributes} for a non-null, non-array object, and null for
 * malformed JSON or any other JSON value. Never throws.
 */
function parseEntityPayload(text) {
    var normalized = normalizeText(text);
    if (normalized === "") {
        return null;
    }

    var parsed;
    try {
        parsed = JSON.parse(normalized);
    } catch (error) {
        return null;
    }

    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
        return null;
    }

    var attributes = parsed.attributes;
    if (attributes === null || typeof attributes !== "object" || Array.isArray(attributes)) {
        attributes = {};
    }

    return {
        state: typeof parsed.state === "string" ? normalizeText(parsed.state) : "",
        attributes: attributes
    };
}

/**
 * Maps a parsed entity payload onto the widget's state vocabulary.
 *
 * Only Home Assistant's own readable words are trusted. Anything else --
 * a missing state, a malformed payload, a word the widget does not know --
 * degrades to unknown, never to a guessed "off".
 */
function entityState(payload) {
    if (payload === null || payload === undefined || typeof payload !== "object") {
        return STATE_UNKNOWN;
    }
    var state = normalizeText(payload.state).toLowerCase();
    if (state === STATE_ON || state === STATE_OFF || state === STATE_UNAVAILABLE || state === STATE_UNKNOWN) {
        return state;
    }
    return STATE_UNKNOWN;
}

/**
 * Aggregates several entity states.
 *
 * Only readable on/off states vote; unavailable and unknown abstain. Nothing
 * readable is `unknown` (not `off`), and disagreement is `mixed` -- a single
 * claimed state would lie about the bulbs the key drives.
 */
function aggregateStates(states) {
    if (!Array.isArray(states)) {
        return STATE_UNKNOWN;
    }
    var readable = 0;
    var sawOn = false;
    var sawOff = false;
    for (var i = 0; i < states.length; i += 1) {
        var value = states[i];
        if (value !== null && typeof value === "object") {
            value = value.state;
        }
        var state = normalizeText(value).toLowerCase();
        if (state === STATE_ON) {
            readable += 1;
            sawOn = true;
        } else if (state === STATE_OFF) {
            readable += 1;
            sawOff = true;
        }
    }
    if (readable === 0) {
        return STATE_UNKNOWN;
    }
    if (sawOn && sawOff) {
        return STATE_MIXED;
    }
    return sawOn ? STATE_ON : STATE_OFF;
}

/** The severity of one state. Unknown is muted, never neutral. */
function severityForState(state) {
    if (state === STATE_ON) {
        return SEVERITY_POSITIVE;
    }
    if (state === STATE_OFF) {
        return SEVERITY_NEUTRAL;
    }
    if (state === STATE_MIXED) {
        return SEVERITY_NEUTRAL;
    }
    if (state === STATE_UNAVAILABLE) {
        return SEVERITY_WARNING;
    }
    return SEVERITY_MUTED;
}

/* --- HTTP interpretation ------------------------------------------------- */

/**
 * Maps an XMLHttpRequest outcome to a typed error.
 *
 * `networkError` is truthy for status 0 (connection refused, DNS failure,
 * timeout); an http(s) status wins when it is readable. A 2xx answer yields
 * `{kind: "", message: ""}` -- no error. `url` is optional and only used to
 * make the unreachable sentence name the address the user configured.
 */
function interpretHttpStatus(status, networkError, url) {
    var code;
    try {
        code = Number(status);
    } catch (error) {
        code = NaN;
    }

    if (networkError || !isFinite(code) || code === 0) {
        var address = normalizeText(url);
        return {
            kind: ERROR_HUB_UNREACHABLE,
            message: address === ""
                ? MESSAGE_HUB_UNREACHABLE
                : "Home Assistant is unreachable at " + address + "."
        };
    }
    if (code >= 200 && code < 300) {
        return { kind: "", message: "" };
    }
    if (code === 401 || code === 403) {
        return { kind: ERROR_UNAUTHORIZED, message: MESSAGE_UNAUTHORIZED };
    }
    if (code === 404) {
        return { kind: ERROR_NOT_FOUND, message: MESSAGE_NOT_FOUND };
    }
    return {
        kind: ERROR_HTTP_ERROR,
        message: "Home Assistant answered with HTTP " + code + "."
    };
}

/** The entity-specific 404 sentence used when the failing id is known. */
function entityNotFoundMessage(entityId) {
    var id = normalizeText(entityId);
    if (id === "") {
        return MESSAGE_NOT_FOUND;
    }
    return "The entity " + id + " does not exist in Home Assistant.";
}

/**
 * Interprets the reply to a switch service call.
 *
 * A 2xx is the only success. A rejected or unreachable command is never
 * swallowed: it becomes a typed failure the key card can name.
 */
function interpretServiceResponse(status, body) {
    var code;
    try {
        code = Number(status);
    } catch (error) {
        code = NaN;
    }

    if (isFinite(code) && code >= 200 && code < 300) {
        return { ok: true, kind: "", message: "" };
    }

    var http = interpretHttpStatus(status, false);
    if (http.kind === ERROR_UNAUTHORIZED) {
        return { ok: false, kind: http.kind, message: http.message };
    }
    if (http.kind === ERROR_HUB_UNREACHABLE) {
        return { ok: false, kind: http.kind, message: http.message };
    }
    return { ok: false, kind: ERROR_SERVICE_FAILED, message: MESSAGE_SERVICE_FAILED };
}

/**
 * Interprets one `kwallet-query` run.
 *
 * Verified behaviour on this machine:
 *   - exit 0: the secret is on stdout;
 *   - exit 4 + "The folder ... does not exist!": folder missing;
 *   - exit 4 + "Failed to read entry ...": entry missing.
 *
 * The secret is returned in `token` for the QML layer to keep in a property,
 * and is NEVER placed in `message`, which is what the popup renders (and what
 * a user may copy into a bug report).
 */
function interpretWalletOutput(exitCode, stdout, folder, key) {
    var code;
    try {
        code = Number(exitCode);
    } catch (error) {
        code = NaN;
    }

    var text = normalizeText(stdout);
    var where = normalizeText(folder) !== "" || normalizeText(key) !== ""
        ? " (" + normalizeText(folder) + "/" + normalizeText(key) + ")"
        : "";

    if (code === 0) {
        if (text === "") {
            return {
                ok: false,
                kind: ERROR_TOKEN_MISSING,
                message: "No token in KWallet" + where + ".",
                token: ""
            };
        }
        return { ok: true, kind: "", message: "", token: text };
    }

    if (code === 4 && (/does not exist/i.test(text) || /Failed to read entry/i.test(text))) {
        return {
            ok: false,
            kind: ERROR_TOKEN_MISSING,
            message: "No token in KWallet" + where + ".",
            token: ""
        };
    }

    return { ok: false, kind: ERROR_WALLET_ERROR, message: MESSAGE_WALLET_ERROR, token: "" };
}

/* --- Shell command assembly ---------------------------------------------- */

/**
 * Wraps a value in single quotes for /bin/sh. An embedded single quote is
 * closed, escaped and reopened ('it'\''s') so the value can never end the
 * quoting itself. Folder, key and wallet come from configuration.
 */
function shellQuote(value) {
    var text = value === undefined || value === null ? "" : String(value);
    return "'" + text.replace(/'/g, "'\\''") + "'";
}

/**
 * The KWallet read command:
 *
 *   kwallet-query --folder <folder> --read-password <key> <wallet>
 *
 * Only non-secret values are interpolated; the secret is printed by
 * kwallet-query on stdout and never appears on a command line.
 */
function buildWalletReadCommand(wallet, folder, key) {
    var walletName = normalizeText(wallet);
    var folderName = normalizeText(folder);
    var entryKey = normalizeText(key);
    if (walletName === "") {
        walletName = DEFAULT_WALLET_NAME;
    }
    if (folderName === "") {
        folderName = DEFAULT_WALLET_FOLDER;
    }
    if (entryKey === "") {
        entryKey = DEFAULT_WALLET_KEY;
    }
    return "kwallet-query --folder " + shellQuote(folderName)
        + " --read-password " + shellQuote(entryKey)
        + " " + shellQuote(walletName);
}

/*
 * The "executable" data engine treats connectedSources as a SET: assigning the
 * same command string twice is a no-op and the command is NOT re-executed.
 * Appending a unique trailing shell comment makes each assignment distinct.
 * Every command this file builds ends its own logic before the comment.
 */
function withRunToken(command, token) {
    var safeToken = String(token).replace(/[\r\n]/g, "");
    return command + " # " + RUN_TOKEN_PREFIX + safeToken;
}

/**
 * The run token a command string carries, or null when it carries none.
 *
 * The engine echoes the full source string back on a reply, token comment
 * included, so the token is recovered from that string rather than guessed.
 */
function runTokenFromSource(source) {
    var text = normalizeText(source);
    if (text === "") {
        return null;
    }
    var match = new RegExp("#\\s*" + RUN_TOKEN_PREFIX + "(\\d+)\\s*$").exec(text);
    if (match === null) {
        return null;
    }
    return Number(match[1]);
}

/**
 * True when a reply carrying `replyToken` is older than the newest dispatch for
 * its target. A reply whose token cannot be read is stale by default.
 */
function isStaleReply(latestToken, replyToken) {
    var reply = Number(replyToken);
    if (replyToken === null || replyToken === undefined || !isFinite(reply)) {
        return true;
    }
    var latest = Number(latestToken);
    if (latestToken === null || latestToken === undefined || !isFinite(latest)) {
        return false;
    }
    return latest > reply;
}

/* --- Target bookkeeping --------------------------------------------------- */

/*
 * QML only re-evaluates a binding when a property's VALUE changes, so every
 * map mutation REPLACES the map with a copy. These helpers are the only place
 * that copies, which keeps the rule in one tested spot.
 */

/** A shallow copy of a plain object's own properties, {} for anything else. */
function copyMap(source) {
    var copy = {};
    if (source === null || typeof source !== "object" || Array.isArray(source)) {
        return copy;
    }
    for (var key in source) {
        if (Object.prototype.hasOwnProperty.call(source, key)) {
            copy[key] = source[key];
        }
    }
    return copy;
}

/** A copy of a map with one key set, leaving the original untouched. */
function withMapEntry(source, key, value) {
    var copy = copyMap(source);
    copy[String(key)] = value;
    return copy;
}

/** A copy of a map without one key, leaving the original untouched. */
function withoutMapKey(source, key) {
    var copy = copyMap(source);
    delete copy[String(key)];
    return copy;
}

/**
 * The own value stored at `key`, or `fallback` when the key is not there.
 * hasOwnProperty is deliberate: a key named "constructor" or "toString" must
 * not answer with a function from the prototype.
 */
function mapLookup(source, key, fallback) {
    if (source === null || typeof source !== "object") {
        return fallback;
    }
    if (!Object.prototype.hasOwnProperty.call(source, String(key))) {
        return fallback;
    }
    var value = source[String(key)];
    return value === undefined ? fallback : value;
}

/* --- Home Assistant endpoints -------------------------------------------- */

/** `GET /api/states/<entity_id>` on the configured hub. */
function buildStatesUrl(baseUrl, entityId) {
    return normalizeBaseUrl(baseUrl, DEFAULT_HUB_BASE_URL)
        + "/api/states/" + encodeURIComponent(normalizeText(entityId));
}

/** `POST /api/services/<domain>/<service>` on the configured hub. */
function buildServiceUrl(baseUrl, domain, service) {
    return normalizeBaseUrl(baseUrl, DEFAULT_HUB_BASE_URL)
        + "/api/services/" + encodeURIComponent(normalizeText(domain))
        + "/" + encodeURIComponent(normalizeText(service));
}

/**
 * True only for a non-empty entity id whose domain is exactly `switch`.
 *
 * The widget's write domain is the wall-switch channel, so a misconfigured
 * entity id must be refused before a request is built rather than left for
 * Home Assistant to reject. Home Assistant entity ids are
 * `<domain>.<object_id>` and case-sensitive, so "light.sala_luz_izquierda",
 * "switch" and "switch." all fail.
 */
function isSwitchChannel(entityId) {
    var id = normalizeText(entityId);
    if (id === "") {
        return false;
    }
    var dot = id.indexOf(".");
    if (dot <= 0 || dot === id.length - 1) {
        return false;
    }
    return id.substring(0, dot) === "switch";
}

/** The service name for an action, or "" for anything else. */
function serviceForAction(action) {
    if (action === ACTION_ON) {
        return "turn_on";
    }
    if (action === ACTION_OFF) {
        return "turn_off";
    }
    if (action === ACTION_TOGGLE) {
        return "toggle";
    }
    return "";
}

/** The JSON body of a switch service call. */
function serviceCallBody(entityId) {
    return JSON.stringify({ entity_id: normalizeText(entityId) });
}

/* --- Presentation helpers ------------------------------------------------ */

/**
 * The panel icon name for a state, using the configured names when set.
 *
 * Only a readable off state gets the off glyph. Mixed, unknown, unavailable and
 * anything unexpected get the unknown glyph, so an unreadable state never
 * reads as "off".
 */
function iconForState(state, iconOn, iconOff, iconUnknown) {
    var onName = normalizeText(iconOn) === "" ? DEFAULT_ICON_ON : normalizeText(iconOn);
    var offName = normalizeText(iconOff) === "" ? DEFAULT_ICON_OFF : normalizeText(iconOff);
    var unknownName = normalizeText(iconUnknown) === "" ? DEFAULT_ICON_UNKNOWN : normalizeText(iconUnknown);
    if (state === STATE_ON) {
        return onName;
    }
    if (state === STATE_OFF) {
        return offName;
    }
    return unknownName;
}
