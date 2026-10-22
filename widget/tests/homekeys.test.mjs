import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

/*
 * Runs the exact shipped homekeys.js inside a bare V8 context.
 *
 * QML's ".pragma library" directive is not valid JavaScript, so the pragma line
 * is stripped before evaluation. Everything else is the real file, byte for
 * byte, so these tests exercise what actually ships in the plasmoid.
 *
 * SCOPE: this suite covers the pure homekeys.js layer only. The QML
 * orchestration in main.qml is NOT covered by automated tests and is verified
 * on-device -- in particular the per-key in-flight disable, the stale-reply
 * ordering inside finishPress(), the failure -> unknown adoption, the
 * isSwitchChannel gate in pressKey() and the 10-second wallet timeout.
 */
const sourceUrl = new URL(
    "../io.github.daver-ui.homekeys/contents/ui/homekeys.js",
    import.meta.url,
);

const source = readFileSync(sourceUrl, "utf8").replace(/^\s*\.pragma\b.*$/gm, "");

const sandbox = {};
runInContext(source, createContext(sandbox));

/*
 * Objects built inside the vm context belong to a different realm, so their
 * prototypes are not reference-equal to this realm's Object.prototype and
 * deepStrictEqual rejects them even when the values match. Round-tripping
 * through JSON moves them into this realm so the comparison is meaningful.
 */
const plain = (value) => JSON.parse(JSON.stringify(value));

const {
    STATE_ON,
    STATE_OFF,
    STATE_MIXED,
    STATE_UNKNOWN,
    STATE_UNAVAILABLE,
    ACTION_ON,
    ACTION_OFF,
    ACTION_TOGGLE,
    SEVERITY_POSITIVE,
    SEVERITY_NEGATIVE,
    SEVERITY_NEUTRAL,
    SEVERITY_MUTED,
    SEVERITY_WARNING,
    ERROR_HUB_UNREACHABLE,
    ERROR_UNAUTHORIZED,
    ERROR_NOT_FOUND,
    ERROR_HTTP_ERROR,
    ERROR_TOKEN_MISSING,
    ERROR_WALLET_ERROR,
    ERROR_SERVICE_FAILED,
    MESSAGE_NOT_A_SWITCH_CHANNEL,
    DEFAULT_HUB_BASE_URL,
    LEGACY_HUB_BASE_URL,
    DEFAULT_WALLET_NAME,
    DEFAULT_WALLET_FOLDER,
    DEFAULT_WALLET_KEY,
    DEFAULT_ICON_ON,
    DEFAULT_ICON_OFF,
    DEFAULT_ICON_UNKNOWN,
    RUN_TOKEN_PREFIX,
    normalizeText,
    normalizeBaseUrl,
    splitEntityList,
    roomLabel,
    entityLabel,
    parseEntityPayload,
    entityState,
    aggregateStates,
    severityForState,
    interpretHttpStatus,
    entityNotFoundMessage,
    interpretServiceResponse,
    interpretWalletOutput,
    shellQuote,
    buildWalletReadCommand,
    withRunToken,
    runTokenFromSource,
    isStaleReply,
    copyMap,
    withMapEntry,
    withoutMapKey,
    mapLookup,
    buildStatesUrl,
    buildServiceUrl,
    isSwitchChannel,
    serviceForAction,
    serviceCallBody,
    iconForState,
} = sandbox;

/* --- Constants ----------------------------------------------------------- */

test("the shipped module exposes the documented state vocabulary", () => {
    assert.equal(STATE_ON, "on");
    assert.equal(STATE_OFF, "off");
    assert.equal(STATE_MIXED, "mixed");
    assert.equal(STATE_UNKNOWN, "unknown");
    assert.equal(STATE_UNAVAILABLE, "unavailable");
    assert.equal(new Set([STATE_ON, STATE_OFF, STATE_MIXED, STATE_UNKNOWN, STATE_UNAVAILABLE]).size, 5);
});

test("the shipped module exposes the documented severity vocabulary", () => {
    assert.equal(SEVERITY_POSITIVE, "positive");
    assert.equal(SEVERITY_NEGATIVE, "negative");
    assert.equal(SEVERITY_NEUTRAL, "neutral");
    assert.equal(SEVERITY_MUTED, "muted");
    assert.equal(SEVERITY_WARNING, "warning");
});

test("the shipped module exposes the documented action and error kinds", () => {
    assert.equal(ACTION_ON, "on");
    assert.equal(ACTION_OFF, "off");
    assert.equal(ACTION_TOGGLE, "toggle");

    assert.equal(ERROR_HUB_UNREACHABLE, "hub-unreachable");
    assert.equal(ERROR_UNAUTHORIZED, "unauthorized");
    assert.equal(ERROR_NOT_FOUND, "not-found");
    assert.equal(ERROR_HTTP_ERROR, "http-error");
    assert.equal(ERROR_TOKEN_MISSING, "token-missing");
    assert.equal(ERROR_WALLET_ERROR, "wallet-error");
    assert.equal(ERROR_SERVICE_FAILED, "service-failed");
});

test("the shipped module exposes the documented defaults", () => {
    assert.equal(DEFAULT_HUB_BASE_URL, "http://127.0.0.1:8123");
    assert.equal(DEFAULT_WALLET_NAME, "kdewallet");
    assert.equal(DEFAULT_WALLET_FOLDER, "DaverHomeSystem");
    assert.equal(DEFAULT_WALLET_KEY, "ha-token");
    assert.equal(DEFAULT_ICON_ON, "flashlight-on-symbolic");
    assert.equal(DEFAULT_ICON_OFF, "flashlight-off-symbolic");
    assert.equal(DEFAULT_ICON_UNKNOWN, "dialog-information-symbolic");
    assert.equal(RUN_TOKEN_PREFIX, "plasma-run-");
});

/* --- Text helpers -------------------------------------------------------- */

test("normalizeText trims, strips CR, and maps nullish to empty", () => {
    assert.equal(normalizeText(undefined), "");
    assert.equal(normalizeText(null), "");
    assert.equal(normalizeText("  x \r\n"), "x");
    assert.equal(normalizeText(0), "0");
});

test("normalizeBaseUrl fills an empty value from the fallback or the default", () => {
    assert.equal(normalizeBaseUrl("", "http://hub.local:8123"), "http://hub.local:8123");
    assert.equal(normalizeBaseUrl("   ", "http://hub.local:8123/"), "http://hub.local:8123");
    assert.equal(normalizeBaseUrl("", ""), DEFAULT_HUB_BASE_URL);
    assert.equal(normalizeBaseUrl(null, undefined), DEFAULT_HUB_BASE_URL);
    // A value that collapses to nothing or to a bare scheme still leaves a
    // usable address instead of "http:///api/...".
    assert.equal(normalizeBaseUrl("/", ""), DEFAULT_HUB_BASE_URL);
    assert.equal(normalizeBaseUrl("https://", ""), DEFAULT_HUB_BASE_URL);
});

test("normalizeBaseUrl removes trailing slashes and adds a missing scheme", () => {
    assert.equal(normalizeBaseUrl("http://hub.local:8123/", ""), "http://hub.local:8123");
    assert.equal(normalizeBaseUrl("http://hub.local:8123///", ""), "http://hub.local:8123");
    assert.equal(normalizeBaseUrl("hub.local:8123", ""), "http://hub.local:8123");
    assert.equal(normalizeBaseUrl(" https://hub.local ", ""), "https://hub.local");
});

/* --- Retired hub default (legacy migration) ------------------------------ */

test("the shipped module exposes the retired hub default as a sentinel", () => {
    assert.equal(typeof LEGACY_HUB_BASE_URL, "string");
    assert.notEqual(LEGACY_HUB_BASE_URL, "");
    assert.notEqual(LEGACY_HUB_BASE_URL, DEFAULT_HUB_BASE_URL);
    assert.ok(LEGACY_HUB_BASE_URL.startsWith("http://"), LEGACY_HUB_BASE_URL);
});

test("normalizeBaseUrl treats the retired default as unset", () => {
    assert.equal(normalizeBaseUrl(LEGACY_HUB_BASE_URL, ""), DEFAULT_HUB_BASE_URL);
    assert.equal(normalizeBaseUrl(LEGACY_HUB_BASE_URL + "/", ""), DEFAULT_HUB_BASE_URL);
    assert.equal(
        normalizeBaseUrl("  " + LEGACY_HUB_BASE_URL.toUpperCase() + "  ", ""),
        DEFAULT_HUB_BASE_URL,
    );
    assert.equal(normalizeBaseUrl(LEGACY_HUB_BASE_URL, "   "), DEFAULT_HUB_BASE_URL);
});

test("normalizeBaseUrl falls through a retired fallback to the default", () => {
    assert.equal(normalizeBaseUrl("", LEGACY_HUB_BASE_URL), DEFAULT_HUB_BASE_URL);
    assert.equal(normalizeBaseUrl("   ", LEGACY_HUB_BASE_URL + "/"), DEFAULT_HUB_BASE_URL);
    assert.equal(
        normalizeBaseUrl(LEGACY_HUB_BASE_URL, LEGACY_HUB_BASE_URL),
        DEFAULT_HUB_BASE_URL,
    );
});

test("normalizeBaseUrl keeps a retired host that carries a path as configured", () => {
    assert.equal(normalizeBaseUrl(LEGACY_HUB_BASE_URL + "/api", ""), LEGACY_HUB_BASE_URL + "/api");
    assert.equal(normalizeBaseUrl(LEGACY_HUB_BASE_URL + "/api/", ""), LEGACY_HUB_BASE_URL + "/api");
});

test("normalizeBaseUrl keeps a normal configured hub address", () => {
    assert.equal(normalizeBaseUrl("http://127.0.0.1:8123", ""), "http://127.0.0.1:8123");
    assert.equal(normalizeBaseUrl("http://hub.local:8123/", ""), "http://hub.local:8123");
    assert.equal(normalizeBaseUrl("", "http://hub.local:8123"), "http://hub.local:8123");
});

/* --- Configuration lists and labels -------------------------------------- */

test("splitEntityList splits on commas, trims and drops empty entries", () => {
    assert.deepEqual(plain(splitEntityList("light.a, light.b")), ["light.a", "light.b"]);
    assert.deepEqual(plain(splitEntityList(" light.a ,, light.b, ")), ["light.a", "light.b"]);
    assert.deepEqual(plain(splitEntityList("light.a")), ["light.a"]);
    assert.deepEqual(plain(splitEntityList("")), []);
    assert.deepEqual(plain(splitEntityList("   ")), []);
    assert.deepEqual(plain(splitEntityList(null)), []);
    assert.deepEqual(plain(splitEntityList(" , , ")), []);
});

test("roomLabel derives the room from the tecla convention", () => {
    assert.equal(roomLabel("switch.sala_tecla_canal_1"), "Sala");
    assert.equal(roomLabel("switch.comedor_tecla_canal_2"), "Comedor");
    assert.equal(roomLabel("switch.pasillo_norte_tecla_canal_12"), "Pasillo Norte");
    assert.equal(roomLabel("  switch.sala_tecla_canal_1  "), "Sala");
});

test("roomLabel falls back to the raw id when the convention does not match", () => {
    assert.equal(roomLabel("switch.kitchen"), "switch.kitchen");
    assert.equal(roomLabel("switch.sala_tecla_canal_x"), "switch.sala_tecla_canal_x");
    assert.equal(roomLabel(""), "");
    assert.equal(roomLabel(null), "");
});

test("entityLabel turns an entity id into a short display label", () => {
    assert.equal(entityLabel("light.sala_luz_izquierda"), "Sala Luz Izquierda");
    assert.equal(entityLabel("light.comedor_luz_sola"), "Comedor Luz Sola");
    assert.equal(entityLabel(""), "");
});

/* --- Home Assistant payloads --------------------------------------------- */

test("parseEntityPayload returns state and attributes for a real payload", () => {
    const raw = JSON.stringify({
        entity_id: "light.sala_luz_izquierda",
        state: "on",
        attributes: { friendly_name: "Sala luz izquierda", brightness: 120 },
    });
    const payload = plain(parseEntityPayload(raw));
    assert.equal(payload.state, "on");
    assert.deepEqual(payload.attributes, { friendly_name: "Sala luz izquierda", brightness: 120 });
});

test("parseEntityPayload defaults missing or damaged attributes to an object", () => {
    assert.deepEqual(plain(parseEntityPayload('{"state":"off"}').attributes), {});
    assert.deepEqual(plain(parseEntityPayload('{"state":"off","attributes":null}').attributes), {});
    assert.deepEqual(plain(parseEntityPayload('{"state":"off","attributes":[1]}').attributes), {});
});

test("parseEntityPayload refuses malformed JSON and non-object JSON", () => {
    for (const raw of [
        "",
        "   ",
        "not json",
        "null",
        "[]",
        "[1,2]",
        "42",
        '"text"',
        '{"state": "on"',
    ]) {
        assert.equal(parseEntityPayload(raw), null, JSON.stringify(raw));
    }
    assert.equal(parseEntityPayload(undefined), null);
    assert.equal(parseEntityPayload(null), null);
});

test("parseEntityPayload never throws on garbage", () => {
    assert.doesNotThrow(() => {
        for (const value of [undefined, null, 0, 1, {}, [], true, Symbol("x"), () => {}]) {
            parseEntityPayload(value);
        }
    });
});

test("entityState trusts only Home Assistant's readable words", () => {
    assert.equal(entityState({ state: "on" }), STATE_ON);
    assert.equal(entityState({ state: "off" }), STATE_OFF);
    assert.equal(entityState({ state: "unavailable" }), STATE_UNAVAILABLE);
    assert.equal(entityState({ state: "unknown" }), STATE_UNKNOWN);
    assert.equal(entityState({ state: "ON" }), STATE_ON);
    assert.equal(entityState({ state: "purple" }), STATE_UNKNOWN);
    assert.equal(entityState({ state: "" }), STATE_UNKNOWN);
});

test("entityState degrades null, malformed and non-object payloads to unknown", () => {
    for (const value of [null, undefined, "on", 42, [], {}, { state: 7 }]) {
        assert.equal(entityState(value), STATE_UNKNOWN, JSON.stringify(value));
    }
});

test("aggregateStates lets only readable on/off states vote", () => {
    assert.equal(aggregateStates([STATE_ON, STATE_ON]), STATE_ON);
    assert.equal(aggregateStates([STATE_OFF, STATE_OFF]), STATE_OFF);
    assert.equal(aggregateStates([STATE_ON, STATE_OFF]), STATE_MIXED);
});

test("aggregateStates abstains on unknown and unavailable", () => {
    assert.equal(aggregateStates([STATE_UNKNOWN, STATE_UNKNOWN]), STATE_UNKNOWN);
    assert.equal(aggregateStates([STATE_UNAVAILABLE, STATE_UNAVAILABLE]), STATE_UNKNOWN);
    assert.equal(aggregateStates([]), STATE_UNKNOWN);
    assert.equal(aggregateStates([STATE_ON, STATE_UNKNOWN]), STATE_ON);
    assert.equal(aggregateStates([STATE_OFF, STATE_UNAVAILABLE]), STATE_OFF);
    // Mixed with one unreadable entity still reads mixed, not a claimed state.
    assert.equal(aggregateStates([STATE_ON, STATE_OFF, STATE_UNKNOWN]), STATE_MIXED);
});

test("aggregateStates also accepts parsed entity payloads", () => {
    assert.equal(aggregateStates([{ state: STATE_ON }, { state: STATE_ON }]), STATE_ON);
    assert.equal(aggregateStates([{ state: STATE_ON }, { state: STATE_OFF }]), STATE_MIXED);
    assert.equal(aggregateStates([{ state: STATE_UNKNOWN }, null]), STATE_UNKNOWN);
});

test("aggregateStates never throws on non-array input", () => {
    for (const value of [null, undefined, "on", 42, {}]) {
        assert.equal(aggregateStates(value), STATE_UNKNOWN, String(value));
    }
});

test("severityForState maps every state explicitly", () => {
    assert.equal(severityForState(STATE_ON), SEVERITY_POSITIVE);
    assert.equal(severityForState(STATE_OFF), SEVERITY_NEUTRAL);
    assert.equal(severityForState(STATE_MIXED), SEVERITY_NEUTRAL);
    assert.equal(severityForState(STATE_UNAVAILABLE), SEVERITY_WARNING);
    assert.equal(severityForState(STATE_UNKNOWN), SEVERITY_MUTED);
    // Unknown must never read as neutral ("off, and therefore fine").
    assert.notEqual(severityForState(STATE_UNKNOWN), SEVERITY_NEUTRAL);
    assert.equal(severityForState("garbage"), SEVERITY_MUTED);
});

/* --- HTTP interpretation ------------------------------------------------- */

test("interpretHttpStatus maps status 0 / a network error to hub-unreachable", () => {
    assert.equal(interpretHttpStatus(0, false).kind, ERROR_HUB_UNREACHABLE);
    assert.equal(interpretHttpStatus(0, true).kind, ERROR_HUB_UNREACHABLE);
    assert.equal(interpretHttpStatus(200, true).kind, ERROR_HUB_UNREACHABLE);
    assert.equal(interpretHttpStatus(undefined, false).kind, ERROR_HUB_UNREACHABLE);
});

test("interpretHttpStatus names the configured URL only when it is given", () => {
    assert.equal(interpretHttpStatus(0, true, "http://hub.local:8123").message,
        "Home Assistant is unreachable at http://hub.local:8123.");
    assert.ok(!interpretHttpStatus(0, true).message.includes("<"));
});

test("interpretHttpStatus maps 401 and 403 to unauthorized", () => {
    assert.equal(interpretHttpStatus(401, false).kind, ERROR_UNAUTHORIZED);
    assert.equal(interpretHttpStatus(403, false).kind, ERROR_UNAUTHORIZED);
    assert.ok(interpretHttpStatus(401, false).message.includes("token"));
});

test("interpretHttpStatus maps 404 to not-found", () => {
    assert.equal(interpretHttpStatus(404, false).kind, ERROR_NOT_FOUND);
    assert.ok(interpretHttpStatus(404, false).message.includes("does not exist"));
    assert.ok(entityNotFoundMessage("light.hall").includes("light.hall"));
});

test("interpretHttpStatus maps other non-2xx statuses to http-error", () => {
    for (const status of [400, 418, 429, 500, 502, 503]) {
        assert.equal(interpretHttpStatus(status, false).kind, ERROR_HTTP_ERROR, String(status));
        assert.ok(interpretHttpStatus(status, false).message.includes(String(status)));
    }
});

test("interpretHttpStatus treats 200 as no error", () => {
    assert.deepEqual(plain(interpretHttpStatus(200, false)), { kind: "", message: "" });
});

test("interpretServiceResponse accepts only a 2xx", () => {
    assert.deepEqual(plain(interpretServiceResponse(200, "")), { ok: true, kind: "", message: "" });
    assert.equal(interpretServiceResponse(201, "").ok, true);
});

test("interpretServiceResponse keeps a rejected command typed", () => {
    const rejected = plain(interpretServiceResponse(500, ""));
    assert.equal(rejected.ok, false);
    assert.equal(rejected.kind, ERROR_SERVICE_FAILED);
    assert.ok(rejected.message.length > 0);

    assert.equal(interpretServiceResponse(401, "").kind, ERROR_UNAUTHORIZED);
    assert.equal(interpretServiceResponse(0, "").kind, ERROR_HUB_UNREACHABLE);
});

/* --- Wallet interpretation ----------------------------------------------- */

const FAKE_SECRET = "eyJhbGciOiJIUzI1NiJ9.fake-token-value.signature";

test("interpretWalletOutput returns the secret only in token, never in message", () => {
    const result = plain(interpretWalletOutput(0, FAKE_SECRET + "\n", "DaverHomeSystem", "ha-token"));
    assert.equal(result.ok, true);
    assert.equal(result.kind, "");
    assert.equal(result.message, "");
    assert.equal(result.token, FAKE_SECRET);
    assert.ok(!result.message.includes(FAKE_SECRET));
});

test("interpretWalletOutput maps a missing folder to token-missing", () => {
    const result = plain(interpretWalletOutput(
        4,
        "The folder DaverHomeSystem does not exist!\n",
        "DaverHomeSystem",
        "ha-token",
    ));
    assert.equal(result.ok, false);
    assert.equal(result.kind, ERROR_TOKEN_MISSING);
    assert.ok(result.message.includes("DaverHomeSystem/ha-token"));
    assert.equal(result.token, "");
});

test("interpretWalletOutput maps a missing entry to token-missing", () => {
    const result = plain(interpretWalletOutput(
        4,
        "Failed to read entry ha-token value from the kdewallet wallet.\n",
        "DaverHomeSystem",
        "ha-token",
    ));
    assert.equal(result.ok, false);
    assert.equal(result.kind, ERROR_TOKEN_MISSING);
    assert.equal(result.token, "");
});

test("interpretWalletOutput maps any other failure to wallet-error", () => {
    for (const [code, stdout] of [
        [1, "boom"],
        [4, "something else"],
        [127, "kwallet-query: not found"],
        [undefined, ""],
    ]) {
        const result = plain(interpretWalletOutput(code, stdout, "DaverHomeSystem", "ha-token"));
        assert.equal(result.ok, false, String(code));
        assert.equal(result.kind, ERROR_WALLET_ERROR, String(code));
        assert.equal(result.token, "", String(code));
    }
});

test("interpretWalletOutput treats an empty successful read as token-missing", () => {
    const result = plain(interpretWalletOutput(0, "   \n", "F", "K"));
    assert.equal(result.ok, false);
    assert.equal(result.kind, ERROR_TOKEN_MISSING);
});

test("interpretWalletOutput never leaks the secret in a failure message", () => {
    const result = plain(interpretWalletOutput(4, FAKE_SECRET, "F", "K"));
    assert.equal(result.ok, false);
    assert.ok(!result.message.includes(FAKE_SECRET));
});

/* --- Shell assembly ------------------------------------------------------ */

test("buildWalletReadCommand uses the documented argument order", () => {
    assert.equal(
        buildWalletReadCommand("kdewallet", "DaverHomeSystem", "ha-token"),
        "kwallet-query --folder 'DaverHomeSystem' --read-password 'ha-token' 'kdewallet'",
    );
});

test("buildWalletReadCommand shell-quotes a folder with a space", () => {
    const command = buildWalletReadCommand("kdewallet", "Daver Home System", "ha-token");
    assert.ok(command.includes("--folder 'Daver Home System'"), command);
    assert.ok(command.includes("--read-password 'ha-token'"), command);
    assert.ok(command.endsWith("'kdewallet'"), command);
});

test("buildWalletReadCommand falls back to the configured defaults", () => {
    assert.equal(
        buildWalletReadCommand("", "", ""),
        "kwallet-query --folder 'DaverHomeSystem' --read-password 'ha-token' 'kdewallet'",
    );
});

test("shellQuote escapes an embedded single quote instead of ending the quote", () => {
    assert.equal(shellQuote("abc"), "'abc'");
    assert.equal(shellQuote("it's"), "'it'\\''s'");
    assert.equal(shellQuote(undefined), "''");
    assert.equal(shellQuote(null), "''");
});

test("withRunToken makes each assignment distinct and strips CR/LF", () => {
    const a = withRunToken("kwallet-query --folder 'F' -w 'K' 'W'", 1);
    const b = withRunToken("kwallet-query --folder 'F' -w 'K' 'W'", 2);
    assert.notEqual(a, b);
    assert.ok(a.endsWith("# plasma-run-1"), a);
    assert.equal(withRunToken("cmd", "a\nb"), "cmd # plasma-run-ab");
    assert.ok(!withRunToken("cmd", "a\r\nb").includes("\n"));
});

test("runTokenFromSource round-trips the token", () => {
    const command = withRunToken("kwallet-query --folder 'F' -w 'K' 'W'", 42);
    assert.equal(runTokenFromSource(command), 42);
});

test("runTokenFromSource returns null without a trailing token comment", () => {
    for (const raw of [
        "",
        "   ",
        undefined,
        null,
        "kwallet-query --folder 'F' -w 'K' 'W'",
        "cmd # plasma-run-",
        "cmd # plasma-run-abc",
        "cmd --x='has # plasma-run-9 inside'",
    ]) {
        assert.equal(runTokenFromSource(raw), null, JSON.stringify(raw));
    }
});

test("isStaleReply lets the newest dispatch win", () => {
    assert.equal(isStaleReply(9, 9), false);
    assert.equal(isStaleReply(10, 9), true);
    assert.equal(isStaleReply(100, 1), true);
    assert.equal(isStaleReply(3, 12), false);
    for (const bad of [null, undefined, "", "abc", NaN, {}]) {
        assert.equal(isStaleReply(7, bad), true, String(bad));
    }
    for (const none of [null, undefined, ""]) {
        assert.equal(isStaleReply(none, 7), false, String(none));
    }
});

/* --- Map helpers --------------------------------------------------------- */

test("map helpers replace the map instead of mutating it", () => {
    const source = { a: 1 };
    const added = withMapEntry(source, "b", 2);
    assert.deepEqual(plain(added), { a: 1, b: 2 });
    assert.deepEqual(plain(source), { a: 1 });
    assert.notEqual(added, source);

    assert.deepEqual(plain(withoutMapKey(added, "a")), { b: 2 });
    assert.deepEqual(plain(added), { a: 1, b: 2 });
});

test("mapLookup reads own values only, so a constructor key is not present", () => {
    assert.equal(mapLookup({ kitchen: "on" }, "kitchen", ""), "on");
    assert.equal(mapLookup({}, "constructor", ""), "");
    assert.equal(mapLookup({}, "toString", ""), "");
    assert.equal(mapLookup({}, "hasOwnProperty", ""), "");
    assert.equal(mapLookup({}, "__proto__", ""), "");
    assert.equal(mapLookup(null, "a", "fallback"), "fallback");
    assert.equal(mapLookup("nope", "a", "fallback"), "fallback");
    assert.equal(mapLookup({ a: undefined }, "a", "fallback"), "fallback");
    assert.equal(mapLookup({ a: 0 }, "a", "fallback"), 0);
});

test("copyMap copies own properties and drops non-objects", () => {
    assert.deepEqual(plain(copyMap({ a: 1, b: "two" })), { a: 1, b: "two" });
    assert.deepEqual(plain(copyMap(Object.create({ inherited: 1 }))), {});
    for (const bad of [null, undefined, "text", 7, [1, 2], true]) {
        assert.deepEqual(plain(copyMap(bad)), {}, String(bad));
    }
});

/* --- Home Assistant endpoints -------------------------------------------- */

test("buildStatesUrl addresses one entity without hardcoding the hub", () => {
    assert.equal(
        buildStatesUrl("http://hub.local:8123", "light.sala_luz_izquierda"),
        "http://hub.local:8123/api/states/light.sala_luz_izquierda",
    );
    assert.equal(
        buildStatesUrl("http://hub.local:8123/", "switch.sala_tecla_canal_1"),
        "http://hub.local:8123/api/states/switch.sala_tecla_canal_1",
    );
    assert.equal(
        buildStatesUrl("", "light.x"),
        DEFAULT_HUB_BASE_URL + "/api/states/light.x",
    );
});

test("buildServiceUrl addresses the switch service", () => {
    assert.equal(
        buildServiceUrl("http://hub.local:8123", "switch", "turn_on"),
        "http://hub.local:8123/api/services/switch/turn_on",
    );
    assert.equal(
        buildServiceUrl("http://hub.local:8123", "switch", "toggle"),
        "http://hub.local:8123/api/services/switch/toggle",
    );
});

test("isSwitchChannel accepts only the switch domain", () => {
    assert.equal(isSwitchChannel("switch.sala_tecla_canal_1"), true);
    assert.equal(isSwitchChannel("switch.comedor_tecla_canal_2"), true);
    assert.equal(isSwitchChannel("  switch.hall  "), true);
});

test("isSwitchChannel refuses bulbs, empty and malformed ids", () => {
    for (const raw of [
        "",
        "   ",
        null,
        undefined,
        "light.sala_luz_izquierda",
        "sensor.switch",
        "switchy.hall",
        "Switch.sala_tecla_canal_1",
        "switch",
        ".switch",
        "switch.",
    ]) {
        assert.equal(isSwitchChannel(raw), false, JSON.stringify(raw));
    }
});

test("the refused write target has a typed message of its own", () => {
    assert.notEqual(MESSAGE_NOT_A_SWITCH_CHANNEL, "");
    assert.ok(MESSAGE_NOT_A_SWITCH_CHANNEL.includes("switch"));
});

test("serviceForAction maps only the three documented actions", () => {
    assert.equal(serviceForAction(ACTION_ON), "turn_on");
    assert.equal(serviceForAction(ACTION_OFF), "turn_off");
    assert.equal(serviceForAction(ACTION_TOGGLE), "toggle");
    assert.equal(serviceForAction("status"), "");
    assert.equal(serviceForAction(""), "");
    assert.equal(serviceForAction(undefined), "");
});

test("serviceCallBody sends exactly the switch entity id", () => {
    assert.equal(
        serviceCallBody("switch.sala_tecla_canal_1"),
        '{"entity_id":"switch.sala_tecla_canal_1"}',
    );
    assert.deepEqual(JSON.parse(serviceCallBody("switch.x")), { entity_id: "switch.x" });
});

test("iconForState uses the configured names and their defaults", () => {
    assert.equal(iconForState(STATE_ON, "my-on", "my-off", "my-unknown"), "my-on");
    assert.equal(iconForState(STATE_OFF, "my-on", "my-off", "my-unknown"), "my-off");
    assert.equal(iconForState(STATE_ON, "", "", ""), DEFAULT_ICON_ON);
    assert.equal(iconForState(STATE_OFF, "", "", ""), DEFAULT_ICON_OFF);
    assert.equal(iconForState("garbage", "", "", ""), DEFAULT_ICON_UNKNOWN);
});

test("iconForState never renders an unreadable state as off", () => {
    for (const state of [STATE_MIXED, STATE_UNKNOWN, STATE_UNAVAILABLE, "", "garbage"]) {
        assert.equal(
            iconForState(state, "my-on", "my-off", "my-unknown"),
            "my-unknown",
            String(state),
        );
        assert.notEqual(iconForState(state, "my-on", "my-off", "my-unknown"), "my-off");
    }
    assert.equal(iconForState(STATE_MIXED, "", "", ""), DEFAULT_ICON_UNKNOWN);
    assert.equal(iconForState(STATE_UNAVAILABLE, "", "", ""), DEFAULT_ICON_UNKNOWN);
});
