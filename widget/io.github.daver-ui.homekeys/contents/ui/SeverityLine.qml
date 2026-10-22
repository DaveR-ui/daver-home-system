import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "homekeys.js" as Homekeys

/*
 * A severity dot followed by a line of text in the same colour. The colour is
 * read from SeverityDot, the one severity -> colour mapping, so the text and its
 * dot can never disagree. `tone` exposes that colour for icons beside the line.
 */
RowLayout {
    id: line

    property string severity: Homekeys.SEVERITY_MUTED
    property string text: ""
    property bool small: false
    property bool bold: false
    readonly property color tone: dot.severityColor

    spacing: Kirigami.Units.smallSpacing

    SeverityDot {
        id: dot

        Layout.alignment: Qt.AlignVCenter
        severity: line.severity
    }

    PlasmaComponents3.Label {
        Layout.fillWidth: true
        text: line.text
        color: line.tone
        wrapMode: Text.WordWrap
        font.pointSize: line.small ? Kirigami.Theme.smallFont.pointSize : Kirigami.Theme.defaultFont.pointSize
        font.bold: line.bold
    }
}
