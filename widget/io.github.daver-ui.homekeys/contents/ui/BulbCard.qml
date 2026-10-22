import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "homekeys.js" as Homekeys

/*
 * One bulb that a switch key drives, as a bordered card. The state arrives
 * already interpreted; this file neither polls nor writes.
 *
 * An unreadable bulb (unknown or unavailable) gets a dashed border and reads
 * "Unknown" / "Unavailable" -- never "Off". The bulb is display-only: the
 * widget never writes it, the Home Assistant automation does.
 */
Rectangle {
    id: card

    property string bulbName: ""
    property string entityId: ""
    property string bulbState: Homekeys.STATE_UNKNOWN

    readonly property bool unreadable: card.bulbState === Homekeys.STATE_UNKNOWN
        || card.bulbState === Homekeys.STATE_UNAVAILABLE
    readonly property string severity: Homekeys.severityForState(card.bulbState)
    // On/off use the shipped flashlight icons; an unreadable bulb gets a
    // question mark so it never looks like a settled "off".
    readonly property string bulbIcon: card.bulbState === Homekeys.STATE_ON
        ? Homekeys.DEFAULT_ICON_ON
        : (card.bulbState === Homekeys.STATE_OFF
            ? Homekeys.DEFAULT_ICON_OFF
            : "question-symbolic")

    function stateText() {
        if (card.bulbState === Homekeys.STATE_ON) {
            return i18n("On");
        }
        if (card.bulbState === Homekeys.STATE_OFF) {
            return i18n("Off");
        }
        if (card.bulbState === Homekeys.STATE_UNAVAILABLE) {
            return i18n("Unavailable");
        }
        return i18n("Unknown");
    }

    implicitHeight: contents.implicitHeight + 2 * Kirigami.Units.smallSpacing

    color: Kirigami.Theme.backgroundColor
    border.color: card.unreadable ? "transparent" : Qt.alpha(Kirigami.Theme.textColor, 0.2)
    border.width: 1
    radius: Kirigami.Units.smallSpacing * 2

    RowLayout {
        id: contents

        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
            Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            source: card.bulbIcon
            color: stateLine.tone
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: card.bulbName
                font.bold: true
                elide: Text.ElideRight
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: card.entityId !== ""
                text: card.entityId
                opacity: 0.6
                elide: Text.ElideRight
                font: Kirigami.Theme.smallFont
            }

            SeverityLine {
                id: stateLine

                Layout.fillWidth: true
                severity: card.severity
                small: true
                text: card.stateText()
            }
        }
    }

    DashedLine {
        visible: card.unreadable
        color: stateLine.tone
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
    }

    DashedLine {
        visible: card.unreadable
        color: stateLine.tone
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
    }

    DashedLine {
        visible: card.unreadable
        vertical: true
        color: stateLine.tone
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
    }

    DashedLine {
        visible: card.unreadable
        vertical: true
        color: stateLine.tone
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
    }
}
