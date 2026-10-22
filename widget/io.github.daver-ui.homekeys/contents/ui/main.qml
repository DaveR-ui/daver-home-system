/*
 * Home Keys plasmoid.
 *
 * A thin Home Assistant REST client for two wall-switch ("tecla") channels.
 * The widget reads five entities every poll -- two switch channels and the
 * three bulbs their automations drive -- and writes ONLY the switch channel
 * entities. The bulbs are display-only: Home Assistant stays the single state
 * authority (ADR-0005), and its automations move the bulbs when a channel
 * changes. The widget is never a second writer.
 *
 * Boundaries:
 *
 *  1. This is the only file that reads Plasmoid.configuration and the only
 *     file that performs I/O. Command strings and URL/body assembly live in
 *     homekeys.js, which is pure and unit tested.
 *
 *  2. The token is read from KWallet once at startup through the
 *     plasma5support "executable" engine and cached in a QML property. It is
 *     never logged, echoed, put on a command line, written to a file or
 *     appended to a URL.
 *
 *  3. Every failure is typed (homekeys.ERROR_*). A failed read makes the
 *     affected entity unknown, never "off"; a failed wallet read disables the
 *     controls and offers Retry instead of faking a state. A rejected token
 *     (401/403) invalidates the cached secret, so Retry performs a fresh
 *     KWallet read instead of re-polling with the same rejected token.
 *
 *  4. Writes are per key. While a press is in flight that key's buttons are
 *     disabled and the other key stays live. Each dispatch carries a monotonic
 *     run token; a slower reply that has been overtaken by a newer press for
 *     the same key is dropped and does not clear the newer run's marker.
 */

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

import "homekeys.js" as Homekeys

PlasmoidItem {
    id: root

    // --- Configuration -------------------------------------------------------
    readonly property string hubBaseUrl: Homekeys.normalizeBaseUrl(
        Plasmoid.configuration.hubBaseUrl,
        Homekeys.DEFAULT_HUB_BASE_URL
    )
    readonly property int pollIntervalMs: Math.max(
        1000,
        Number(Plasmoid.configuration.pollIntervalSeconds || 2) * 1000
    )
    readonly property string walletName: Homekeys.normalizeText(Plasmoid.configuration.walletName)
    readonly property string walletFolder: Homekeys.normalizeText(Plasmoid.configuration.walletFolder)
    readonly property string walletKey: Homekeys.normalizeText(Plasmoid.configuration.walletKey)

    // The two configured keys. Nothing about the hub or the entity ids is
    // hardcoded below: every value is read from Plasmoid.configuration.
    readonly property var keys: [
        {
            id: "tecla1",
            switchEntity: Homekeys.normalizeText(Plasmoid.configuration.tecla1SwitchEntity),
            bulbEntities: Homekeys.splitEntityList(Plasmoid.configuration.tecla1BulbEntities)
        },
        {
            id: "tecla2",
            switchEntity: Homekeys.normalizeText(Plasmoid.configuration.tecla2SwitchEntity),
            bulbEntities: Homekeys.splitEntityList(Plasmoid.configuration.tecla2BulbEntities)
        }
    ]

    // --- Token custody -------------------------------------------------------
    property string token: ""
    property bool tokenReady: false
    property bool tokenLoading: true
    property string walletErrorKind: ""
    property string walletErrorText: ""
    // Set when Home Assistant rejected the cached token (401/403). It is the
    // only state in which Retry re-reads KWallet, so it must survive until the
    // next wallet read succeeds.
    property string authErrorText: ""
    // The run token of the wallet read currently in flight. A slow reply from
    // an earlier read must not overwrite the result of a newer Retry.
    property int walletRunToken: 0

    // --- Live entity state ---------------------------------------------------
    // entity id -> Homekeys.STATE_*; the value is REPLACED on every mutation so
    // QML re-evaluates every binding that reads it.
    property var switchStates: ({})
    property var bulbStates: ({})
    // entity id -> {kind, message}: a read failure belongs to the entity that
    // failed, so a successful read of a sibling cannot erase it.
    property var entityErrors: ({})
    // key id -> {kind, message}: a service-call failure belongs to the key.
    property var serviceErrors: ({})

    // --- Per-key concurrency -------------------------------------------------
    // key id -> ACTION_* in flight; replaced, never mutated in place.
    property var actionTargets: ({})
    // key id -> newest run token ever dispatched for it; never pruned. This map
    // is the single source of truth for the staleness decision in
    // finishPress(): no other run bookkeeping may override it.
    property var actionLatestRun: ({})
    property int runToken: 0

    // --- Derived view --------------------------------------------------------
    readonly property var cards: root.buildCards()

    // The single banner message: a rejected token first, then a wallet
    // failure. The two causes stay distinguishable in the source properties.
    readonly property string blockingErrorText: root.authErrorText !== ""
        ? root.authErrorText
        : root.walletErrorText

    readonly property bool errorActive: root.walletErrorKind !== ""
        || root.authErrorText !== ""
        || Object.keys(root.entityErrors).length > 0
        || Object.keys(root.serviceErrors).length > 0
    readonly property bool anyBusy: Object.keys(root.actionTargets).length > 0

    readonly property var overallState: {
        var states = [];
        for (var i = 0; i < root.cards.length; i += 1) {
            states.push(root.cards[i].switchState);
        }
        return Homekeys.aggregateStates(states);
    }
    readonly property string severity: root.errorActive
        ? Homekeys.SEVERITY_NEGATIVE
        : Homekeys.severityForState(root.overallState)
    readonly property string iconName: Homekeys.iconForState(
        root.overallState,
        Plasmoid.configuration.iconOn,
        Plasmoid.configuration.iconOff,
        Plasmoid.configuration.iconUnknown
    )

    Plasmoid.title: i18n("Home Keys")
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground

    preferredRepresentation: Plasmoid.formFactor === PlasmaCore.Types.Planar ? fullRepresentation : null

    toolTipMainText: i18n("Home Keys")
    toolTipSubText: root.errorText !== "" ? root.errorText : root.summaryText

    // --- Helpers -------------------------------------------------------------

    function nextRunToken() {
        root.runToken += 1;
        return root.runToken;
    }

    function keyById(keyId) {
        for (var i = 0; i < root.keys.length; i += 1) {
            if (root.keys[i].id === keyId) {
                return root.keys[i];
            }
        }
        return null;
    }

    function switchStateFor(keyId) {
        return Homekeys.mapLookup(root.switchStates, keyId, Homekeys.STATE_UNKNOWN);
    }

    function bulbStateFor(entityId) {
        return Homekeys.mapLookup(root.bulbStates, entityId, Homekeys.STATE_UNKNOWN);
    }

    function asError(value) {
        return value === null || typeof value !== "object" ? null : value;
    }

    function serviceErrorFor(keyId) {
        return root.asError(Homekeys.mapLookup(root.serviceErrors, keyId, null));
    }

    function readErrorFor(key) {
        if (key === null || key === undefined) {
            return null;
        }
        var switchError = root.asError(Homekeys.mapLookup(root.entityErrors, key.switchEntity, null));
        if (switchError !== null) {
            return switchError;
        }
        for (var i = 0; i < key.bulbEntities.length; i += 1) {
            var bulbError = root.asError(Homekeys.mapLookup(root.entityErrors, key.bulbEntities[i], null));
            if (bulbError !== null) {
                return bulbError;
            }
        }
        return null;
    }

    function errorFor(key) {
        var serviceError = root.serviceErrorFor(key.id);
        return serviceError !== null ? serviceError : root.readErrorFor(key);
    }

    function actionKindFor(keyId) {
        return Homekeys.mapLookup(root.actionTargets, keyId, "");
    }

    function stateWord(state) {
        if (state === Homekeys.STATE_ON) {
            return i18n("On");
        }
        if (state === Homekeys.STATE_OFF) {
            return i18n("Off");
        }
        if (state === Homekeys.STATE_MIXED) {
            return i18n("Mixed");
        }
        if (state === Homekeys.STATE_UNAVAILABLE) {
            return i18n("Unavailable");
        }
        return i18n("Unknown");
    }

    function buildCards() {
        var result = [];
        for (var i = 0; i < root.keys.length; i += 1) {
            var key = root.keys[i];
            var bulbs = [];
            var bulbStates = [];
            for (var j = 0; j < key.bulbEntities.length; j += 1) {
                var entity = key.bulbEntities[j];
                var state = root.bulbStateFor(entity);
                bulbs.push({
                    entity: entity,
                    label: Homekeys.entityLabel(entity),
                    state: state
                });
                bulbStates.push(state);
            }

            var error = root.errorFor(key);
            var readError = root.readErrorFor(key);
            result.push({
                id: key.id,
                keyNumber: i + 1,
                room: Homekeys.roomLabel(key.switchEntity),
                switchEntity: key.switchEntity,
                switchState: root.switchStateFor(key.id),
                bulbs: bulbs,
                bulbAggregate: Homekeys.aggregateStates(bulbStates),
                actionKind: root.actionKindFor(key.id),
                errorKind: error === null ? "" : Homekeys.normalizeText(error.kind),
                errorMessage: error === null ? "" : Homekeys.normalizeText(error.message),
                // A read failure disables the key (it cannot trust state); a
                // service refusal leaves the buttons live so the user can retry.
                enabled: root.tokenReady && readError === null
            });
        }
        return result;
    }

    readonly property string summaryText: {
        var parts = [];
        for (var i = 0; i < root.cards.length; i += 1) {
            var card = root.cards[i];
            parts.push(card.room + ": " + root.stateWord(card.switchState)
                + " · " + i18ncp("@info", "%1 bulb", "%1 bulbs", card.bulbs.length)
                + " " + root.stateWord(card.bulbAggregate).toLowerCase());
        }
        return parts.join(" — ");
    }

    readonly property string errorText: {
        if (root.blockingErrorText !== "") {
            return root.blockingErrorText;
        }
        for (var i = 0; i < root.cards.length; i += 1) {
            if (root.cards[i].errorMessage !== "") {
                return root.cards[i].room + ": " + root.cards[i].errorMessage;
            }
        }
        return "";
    }

    // --- Token read ----------------------------------------------------------

    function readToken() {
        root.token = "";
        root.tokenReady = false;
        root.tokenLoading = true;
        root.walletErrorKind = "";
        root.walletErrorText = "";
        root.authErrorText = "";

        var walletToken = root.nextRunToken();
        var command = Homekeys.withRunToken(
            Homekeys.buildWalletReadCommand(root.walletName, root.walletFolder, root.walletKey),
            walletToken
        );
        root.walletRunToken = walletToken;
        walletSource.connectedSources = [command];
        walletTimeout.restart();
    }

    function retry() {
        // A rejected token is not retried as-is: re-read KWallet so a token
        // re-stored with `install.sh token` is picked up without a restart.
        if (root.walletErrorKind !== "" || root.authErrorText !== "" || !root.tokenReady) {
            root.readToken();
            return;
        }
        root.pollAll();
    }

    P5Support.DataSource {
        id: walletSource
        engine: "executable"
        interval: 0
        connectedSources: []

        onNewData: (sourceName, data) => {
            if (data["exit code"] === undefined) {
                return;
            }
            // A reply from an earlier read must not override a newer Retry.
            if (Homekeys.runTokenFromSource(sourceName) !== root.walletRunToken) {
                return;
            }
            walletTimeout.stop();

            const result = Homekeys.interpretWalletOutput(
                data["exit code"],
                data["stdout"],
                root.walletFolder,
                root.walletKey
            );
            if (result.ok) {
                root.token = result.token;
                root.tokenReady = true;
                root.tokenLoading = false;
                root.walletErrorKind = "";
                root.walletErrorText = "";
                // A fresh token clears the rejection: the next 401/403 will
                // invalidate it again rather than being swallowed.
                root.authErrorText = "";
                root.pollAll();
                return;
            }

            root.token = "";
            root.tokenReady = false;
            root.tokenLoading = false;
            root.walletErrorKind = result.kind;
            root.walletErrorText = result.message;
        }
    }

    // A locked wallet can leave kwallet-query waiting forever. The guard turns
    // that into a typed wallet-error instead of an endless spinner.
    Timer {
        id: walletTimeout
        interval: 10000
        repeat: false

        onTriggered: {
            walletSource.connectedSources = [];
            root.token = "";
            root.tokenReady = false;
            root.tokenLoading = false;
            root.walletErrorKind = Homekeys.ERROR_WALLET_ERROR;
            root.walletErrorText = i18n("The KWallet entry could not be read (the wallet did not answer).");
        }
    }

    // --- Polling -------------------------------------------------------------

    Timer {
        id: pollTimer
        interval: root.pollIntervalMs
        repeat: true
        running: root.tokenReady

        onTriggered: root.pollAll()
    }

    function pollAll() {
        if (!root.tokenReady) {
            return;
        }
        for (var i = 0; i < root.keys.length; i += 1) {
            root.readKey(root.keys[i]);
        }
    }

    // Re-reads one key's channel and bulbs immediately, without waiting for the
    // next poll tick.
    function readKey(key) {
        if (key === null || key === undefined) {
            return;
        }
        root.readEntity(key.switchEntity, key.id, true);
        for (var i = 0; i < key.bulbEntities.length; i += 1) {
            root.readEntity(key.bulbEntities[i], key.id, false);
        }
    }

    function readEntity(entityId, keyId, isSwitch) {
        if (!root.tokenReady || Homekeys.normalizeText(entityId) === "") {
            return;
        }

        const xhr = new XMLHttpRequest();
        xhr.timeout = 8000;
        try {
            xhr.open("GET", Homekeys.buildStatesUrl(root.hubBaseUrl, entityId), true);
            xhr.setRequestHeader("Authorization", "Bearer " + root.token);
            xhr.setRequestHeader("Accept", "application/json");
        } catch (error) {
            // A malformed configured URL must not crash the widget.
            root.adoptReadFailure(
                entityId,
                keyId,
                isSwitch,
                Homekeys.ERROR_HUB_UNREACHABLE,
                Homekeys.interpretHttpStatus(0, true, root.hubBaseUrl).message
            );
            return;
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) {
                return;
            }

            const status = xhr.status;
            const error = Homekeys.interpretHttpStatus(
                status,
                status === 0,
                root.hubBaseUrl
            );
            if (error.kind !== "") {
                const message = error.kind === Homekeys.ERROR_NOT_FOUND
                    ? Homekeys.entityNotFoundMessage(entityId)
                    : error.message;
                root.adoptReadFailure(entityId, keyId, isSwitch, error.kind, message);
                return;
            }

            const payload = Homekeys.parseEntityPayload(xhr.responseText);
            if (payload === null) {
                root.adoptReadFailure(
                    entityId,
                    keyId,
                    isSwitch,
                    Homekeys.ERROR_HTTP_ERROR,
                    i18n("Home Assistant answered with an unreadable state payload.")
                );
                return;
            }

            root.adoptRead(entityId, keyId, isSwitch, Homekeys.entityState(payload));
        };

        // A connected-but-silent hub must not hang the read forever.
        xhr.ontimeout = function() {
            root.adoptReadFailure(
                entityId,
                keyId,
                isSwitch,
                Homekeys.ERROR_HUB_UNREACHABLE,
                Homekeys.interpretHttpStatus(0, true, root.hubBaseUrl).message
            );
        };

        try {
            xhr.send();
        } catch (error) {
            root.adoptReadFailure(
                entityId,
                keyId,
                isSwitch,
                Homekeys.ERROR_HUB_UNREACHABLE,
                Homekeys.interpretHttpStatus(0, true, root.hubBaseUrl).message
            );
        }
    }

    function adoptRead(entityId, keyId, isSwitch, state) {
        if (isSwitch) {
            root.switchStates = Homekeys.withMapEntry(root.switchStates, keyId, state);
        } else {
            root.bulbStates = Homekeys.withMapEntry(root.bulbStates, entityId, state);
        }
        // Only THIS entity's failure is cleared: a sibling's success must not
        // hide a 404 or an auth failure on the entity that is still broken.
        root.entityErrors = Homekeys.withoutMapKey(root.entityErrors, entityId);
    }

    function adoptReadFailure(entityId, keyId, isSwitch, kind, message) {
        if (isSwitch) {
            root.switchStates = Homekeys.withMapEntry(root.switchStates, keyId, Homekeys.STATE_UNKNOWN);
        } else {
            root.bulbStates = Homekeys.withMapEntry(root.bulbStates, entityId, Homekeys.STATE_UNKNOWN);
        }
        root.entityErrors = Homekeys.withMapEntry(root.entityErrors, entityId, {
            kind: kind,
            message: message
        });

        // A rejected token is not an entity problem: the cached secret is dead,
        // so drop it. The poll timer stops on its own (`running:
        // root.tokenReady`) and Retry re-reads KWallet. The `tokenReady` guard
        // makes this fire once, when the first 401/403 arrives; a 404 or any
        // other status leaves the token untouched.
        if (kind === Homekeys.ERROR_UNAUTHORIZED && root.tokenReady) {
            root.token = "";
            root.tokenReady = false;
            root.authErrorText = i18n("Home Assistant rejected the token. Re-store it with 'widget/install.sh token' and press Retry.");
        }
    }

    // --- Writes --------------------------------------------------------------

    function latestRunFor(target) {
        return Homekeys.mapLookup(root.actionLatestRun, target, null);
    }

    // Records the newest run token per key. The in-flight action itself is
    // carried by actionTargets, so no per-run object is kept.
    function noteRun(run) {
        root.actionLatestRun = Homekeys.withMapEntry(root.actionLatestRun, run.target, run.token);
    }

    function pressKey(keyId, action) {
        if (!root.tokenReady) {
            return;
        }
        if (root.actionKindFor(keyId) !== "") {
            return;
        }

        const key = root.keyById(keyId);
        if (key === null) {
            return;
        }

        // The write domain is the wall-switch channel. Refuse a misconfigured
        // target before any request is built, so a bulb or an empty entity id
        // can never reach Home Assistant at all.
        if (!Homekeys.isSwitchChannel(key.switchEntity)) {
            root.serviceErrors = Homekeys.withMapEntry(root.serviceErrors, keyId, {
                kind: Homekeys.ERROR_SERVICE_FAILED,
                message: Homekeys.MESSAGE_NOT_A_SWITCH_CHANNEL
            });
            return;
        }

        const service = Homekeys.serviceForAction(action);
        if (service === "") {
            return;
        }

        const run = {
            token: root.nextRunToken(),
            target: keyId
        };
        root.noteRun(run);
        root.actionTargets = Homekeys.withMapEntry(root.actionTargets, keyId, action);

        const xhr = new XMLHttpRequest();
        xhr.timeout = 8000;
        try {
            xhr.open("POST", Homekeys.buildServiceUrl(root.hubBaseUrl, "switch", service), true);
            xhr.setRequestHeader("Authorization", "Bearer " + root.token);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.setRequestHeader("Accept", "application/json");
        } catch (error) {
            root.finishPress(key, run, 0);
            return;
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) {
                return;
            }
            root.finishPress(key, run, xhr.status);
        };

        // A connected-but-silent hub must not leave the key busy forever.
        xhr.ontimeout = function() {
            root.finishPress(key, run, 0);
        };

        try {
            xhr.send(Homekeys.serviceCallBody(key.switchEntity));
        } catch (error) {
            root.finishPress(key, run, 0);
        }
    }

    function finishPress(key, run, status) {
        // A newer press for the same key owns the marker and the state now:
        // actionLatestRun is the only source for this decision.
        if (Homekeys.isStaleReply(root.latestRunFor(run.target), run.token)) {
            return;
        }

        root.actionTargets = Homekeys.withoutMapKey(root.actionTargets, run.target);

        const result = Homekeys.interpretServiceResponse(status, "");
        if (result.ok) {
            root.serviceErrors = Homekeys.withoutMapKey(root.serviceErrors, run.target);
            // Read the switch and its bulbs immediately: do not wait for the
            // next poll tick to show the result.
            root.readKey(key);
            return;
        }

        root.serviceErrors = Homekeys.withMapEntry(root.serviceErrors, run.target, {
            kind: result.kind,
            message: result.message
        });
    }

    // --- Lifecycle -----------------------------------------------------------

    Component.onCompleted: root.readToken()

    // --- Representations -----------------------------------------------------

    compactRepresentation: CompactRepresentation {
        overallState: root.overallState
        severity: root.severity
        iconName: root.iconName
        errorActive: root.errorActive
        loading: root.tokenLoading
    }

    fullRepresentation: FullRepresentation {
        cards: root.cards
        overallState: root.overallState
        severity: root.severity
        blockingErrorText: root.blockingErrorText
        tokenLoading: root.tokenLoading
        tokenReady: root.tokenReady
        anyBusy: root.anyBusy

        onPressRequested: (keyId, action) => root.pressKey(keyId, action)
        onRetryRequested: root.retry()
        onRefreshRequested: root.pollAll()
    }
}
