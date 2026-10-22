import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "homekeys.js" as Homekeys

/*
 * Popup / desktop representation.
 *
 * This file never reads configuration and never performs I/O: main.qml owns
 * both, and hands down the computed cards, the overall severity and the
 * blocking error (a rejected token or a wallet failure). Buttons only emit
 * intents.
 *
 * The 1-to-N mapping is visible: each key card renders every bulb the key
 * drives (two for key 1, one for key 2), and every bulb card shows its own live
 * state. The aggregate line above the bulbs says "mixed" when they disagree.
 */
ColumnLayout {
    id: fullRoot

    // One entry per key, built by main.qml:
    // { id, keyNumber, room, switchEntity, switchState, bulbs: [{entity, label, state}],
    //   bulbAggregate, actionKind, errorKind, errorMessage, enabled }
    property var cards: []
    property string overallState: Homekeys.STATE_UNKNOWN
    property string severity: Homekeys.SEVERITY_MUTED
    property string blockingErrorText: ""
    property bool tokenLoading: false
    property bool tokenReady: false
    property bool anyBusy: false

    signal pressRequested(string keyId, string action)
    signal retryRequested()
    signal refreshRequested()

    spacing: Kirigami.Units.smallSpacing

    Layout.preferredWidth: Kirigami.Units.gridUnit * 20

    // --- Header --------------------------------------------------------------
    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Kirigami.Units.gridUnit * 2.75
            Layout.preferredHeight: Kirigami.Units.gridUnit * 2.75
            radius: Kirigami.Units.smallSpacing * 2
            color: Kirigami.Theme.alternateBackgroundColor
            border.color: Qt.alpha(Kirigami.Theme.textColor, 0.2)
            border.width: 1

            SwitchGlyph {
                anchors.centerIn: parent
                glyphSize: Kirigami.Units.iconSizes.medium
                color: Kirigami.Theme.highlightColor
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: i18n("Home Keys")
                    font.bold: true
                    elide: Text.ElideRight
                }

                SeverityDot {
                    Layout.alignment: Qt.AlignVCenter
                    severity: fullRoot.severity
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: fullRoot.tokenLoading
                    ? i18n("Reading the token from KWallet…")
                    : (fullRoot.tokenReady
                        ? i18ncp("@info", "%1 wall-switch key · Home Assistant", "%1 wall-switch keys · Home Assistant", fullRoot.cards.length)
                        : i18n("Home Assistant token unavailable"))
                opacity: 0.7
                font: Kirigami.Theme.smallFont
                wrapMode: Text.WordWrap
            }
        }

        PlasmaComponents3.ToolButton {
            icon.name: "view-refresh"
            display: PlasmaComponents3.AbstractButton.IconOnly
            enabled: fullRoot.tokenReady && !fullRoot.anyBusy
            onClicked: fullRoot.refreshRequested()

            PlasmaComponents3.ToolTip {
                text: i18n("Refresh now")
            }
        }
    }

    // --- Blocking error (rejected token or wallet failure) ------------------
    Rectangle {
        Layout.fillWidth: true
        visible: fullRoot.blockingErrorText !== ""
        implicitHeight: walletRow.implicitHeight + 2 * Kirigami.Units.smallSpacing
        color: Qt.alpha(Kirigami.Theme.negativeTextColor, 0.12)
        border.color: Qt.alpha(Kirigami.Theme.negativeTextColor, 0.5)
        border.width: 1
        radius: Kirigami.Units.smallSpacing * 2

        RowLayout {
            id: walletRow

            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                Layout.alignment: Qt.AlignVCenter
                source: "data-error"
                color: Kirigami.Theme.negativeTextColor
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: fullRoot.blockingErrorText
                color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.WordWrap
            }

            PlasmaComponents3.Button {
                text: fullRoot.tokenLoading ? i18n("Retrying…") : i18n("Retry")
                enabled: !fullRoot.tokenLoading
                onClicked: fullRoot.retryRequested()
            }
        }
    }

    // --- Key cards -----------------------------------------------------------
    Repeater {
        model: fullRoot.cards

        TeclaBlock {
            Layout.fillWidth: true
            card: modelData

            onPressRequested: (keyId, action) => fullRoot.pressRequested(keyId, action)
        }
    }

    PlasmaComponents3.BusyIndicator {
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredWidth: Kirigami.Units.iconSizes.small
        Layout.preferredHeight: Kirigami.Units.iconSizes.small
        running: fullRoot.anyBusy
        visible: fullRoot.anyBusy
    }

    // --- Legend --------------------------------------------------------------
    ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Qt.alpha(Kirigami.Theme.textColor, 0.2)
        }

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: i18n("How to read this widget")
            font.bold: true
            font.capitalization: Font.AllUppercase
        }

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: i18n("The key is the authoritative object: it writes the wall-switch channel, and Home Assistant's automations drive its bulbs. The bulb cards are display-only.")
            wrapMode: Text.WordWrap
            opacity: 0.8
            font: Kirigami.Theme.smallFont
        }

        Flow {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            SeverityLine {
                severity: Homekeys.SEVERITY_POSITIVE
                text: i18n("On")
            }

            SeverityLine {
                severity: Homekeys.SEVERITY_NEUTRAL
                text: i18n("Off")
            }

            SeverityLine {
                severity: Homekeys.SEVERITY_NEUTRAL
                text: i18n("Mixed")
            }

            SeverityLine {
                severity: Homekeys.SEVERITY_WARNING
                text: i18n("Unavailable")
            }

            SeverityLine {
                severity: Homekeys.SEVERITY_MUTED
                text: i18n("Unknown")
            }
        }
    }
}
