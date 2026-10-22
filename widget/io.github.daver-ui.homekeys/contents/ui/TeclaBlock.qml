import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "homekeys.js" as Homekeys

/*
 * One tecla card: a switch key on the left and the bulbs it drives on the
 * right, joined by a dashed divider and a "Linked to" connector per bulb.
 *
 * The left zone is the authoritative key channel; its On / Off / Toggle
 * buttons only emit a pressRequested intent, which main.qml turns into a Home
 * Assistant switch service call. The right zone is render-only: each bulb card
 * shows the bulb's own live state, and the aggregate line says "Mixed" when
 * the bulbs disagree.
 *
 * `card` is built once by main.qml, so this file never reads configuration and
 * never maps a state onto a colour itself.
 */
Rectangle {
    id: teclaCard

    property var card: ({})

    signal pressRequested(string keyId, string action)

    readonly property string keyId: teclaCard.card && teclaCard.card.id
        ? String(teclaCard.card.id) : ""
    readonly property int keyNumber: teclaCard.card && teclaCard.card.keyNumber
        ? Number(teclaCard.card.keyNumber) : 1
    readonly property string room: teclaCard.card && teclaCard.card.room
        ? String(teclaCard.card.room) : ""
    readonly property string switchEntity: teclaCard.card && teclaCard.card.switchEntity
        ? String(teclaCard.card.switchEntity) : ""
    readonly property string channelState: teclaCard.card && teclaCard.card.switchState
        ? String(teclaCard.card.switchState) : Homekeys.STATE_UNKNOWN
    readonly property var bulbs: teclaCard.card && teclaCard.card.bulbs
        ? teclaCard.card.bulbs : []
    readonly property string bulbAggregate: teclaCard.card && teclaCard.card.bulbAggregate
        ? String(teclaCard.card.bulbAggregate) : Homekeys.STATE_UNKNOWN
    readonly property string actionKind: teclaCard.card && teclaCard.card.actionKind
        ? String(teclaCard.card.actionKind) : ""
    readonly property string errorMessage: teclaCard.card && teclaCard.card.errorMessage
        ? String(teclaCard.card.errorMessage) : ""
    readonly property bool cardEnabled: teclaCard.card && teclaCard.card.enabled === true
    readonly property bool pressable: teclaCard.cardEnabled && teclaCard.actionKind === ""
    readonly property bool stacked: teclaCard.width < Kirigami.Units.gridUnit * 24
    readonly property real pad: Kirigami.Units.largeSpacing

    function pressingAs(action) {
        return teclaCard.actionKind !== "" && teclaCard.actionKind === action;
    }

    function channelStateText() {
        if (teclaCard.channelState === Homekeys.STATE_ON) {
            return i18n("On");
        }
        if (teclaCard.channelState === Homekeys.STATE_OFF) {
            return i18n("Off");
        }
        if (teclaCard.channelState === Homekeys.STATE_UNAVAILABLE) {
            return i18n("Unavailable");
        }
        return i18n("Unknown");
    }

    function bulbAggregateText() {
        if (teclaCard.bulbAggregate === Homekeys.STATE_MIXED) {
            return i18n("Bulbs disagree — mixed");
        }
        if (teclaCard.bulbAggregate === Homekeys.STATE_ON) {
            return i18n("Bulbs are on");
        }
        if (teclaCard.bulbAggregate === Homekeys.STATE_OFF) {
            return i18n("Bulbs are off");
        }
        return i18n("Bulb state is unknown");
    }

    color: Kirigami.Theme.alternateBackgroundColor
    border.color: Qt.alpha(Kirigami.Theme.textColor, 0.2)
    border.width: 1
    radius: Kirigami.Units.smallSpacing * 2
    implicitHeight: body.implicitHeight + 2 * teclaCard.pad

    GridLayout {
        id: body

        anchors.fill: parent
        anchors.margins: teclaCard.pad
        columns: teclaCard.stacked ? 1 : 3
        columnSpacing: Kirigami.Units.largeSpacing
        rowSpacing: Kirigami.Units.largeSpacing

        // --- Left zone: the authoritative key channel ------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    text: i18nc("@title", "Key %1", teclaCard.keyNumber)
                    font.bold: true
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: teclaCard.room
                    font.bold: true
                    elide: Text.ElideRight
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: teclaCard.switchEntity
                opacity: 0.6
                elide: Text.ElideRight
                font: Kirigami.Theme.smallFont
            }

            SeverityLine {
                Layout.fillWidth: true
                severity: Homekeys.severityForState(teclaCard.channelState)
                text: teclaCard.channelStateText()
                bold: true
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: i18n("Key state (authoritative)")
                wrapMode: Text.WordWrap
                opacity: 0.7
                font: Kirigami.Theme.smallFont
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Button {
                    Layout.fillWidth: true
                    text: teclaCard.pressingAs(Homekeys.ACTION_ON) ? "…" : i18n("On")
                    enabled: teclaCard.pressable
                    onClicked: teclaCard.pressRequested(teclaCard.keyId, Homekeys.ACTION_ON)
                }

                PlasmaComponents3.Button {
                    Layout.fillWidth: true
                    text: teclaCard.pressingAs(Homekeys.ACTION_OFF) ? "…" : i18n("Off")
                    enabled: teclaCard.pressable
                    onClicked: teclaCard.pressRequested(teclaCard.keyId, Homekeys.ACTION_OFF)
                }

                PlasmaComponents3.Button {
                    Layout.fillWidth: true
                    text: teclaCard.pressingAs(Homekeys.ACTION_TOGGLE) ? "…" : i18n("Toggle")
                    enabled: teclaCard.pressable
                    onClicked: teclaCard.pressRequested(teclaCard.keyId, Homekeys.ACTION_TOGGLE)
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: teclaCard.errorMessage !== ""
                text: teclaCard.errorMessage
                color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
            }
        }

        // --- Divider between the key and its bulbs ---------------------------
        DashedLine {
            vertical: !teclaCard.stacked
            color: Qt.alpha(Kirigami.Theme.textColor, 0.25)
            Layout.fillHeight: !teclaCard.stacked
            Layout.fillWidth: teclaCard.stacked
        }

        // --- Right column: one card per bulb --------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Kirigami.Units.smallSpacing

            SeverityLine {
                Layout.fillWidth: true
                severity: Homekeys.severityForState(teclaCard.bulbAggregate)
                small: true
                text: teclaCard.bulbAggregateText()
            }

            Repeater {
                model: teclaCard.bulbs

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        PlasmaComponents3.Label {
                            Layout.alignment: Qt.AlignHCenter
                            text: i18n("Linked to")
                            font.capitalization: Font.AllUppercase
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            color: Kirigami.Theme.highlightColor
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 2
                                color: Kirigami.Theme.highlightColor
                            }

                            Kirigami.Icon {
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                source: "arrow-right"
                                color: Kirigami.Theme.highlightColor
                            }
                        }
                    }

                    BulbCard {
                        Layout.fillWidth: true
                        bulbName: modelData.label
                        entityId: modelData.entity
                        bulbState: modelData.state
                    }
                }
            }
        }
    }
}
