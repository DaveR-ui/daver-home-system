import QtQuick

import org.kde.kirigami as Kirigami

/*
 * A dashed rule drawn from short rectangles, because a QML Rectangle has no dashed
 * border. It fills its own length: width for a horizontal rule, height for a
 * vertical one. Used for the tecla divider and the offline bulb border.
 */
Item {
    id: line

    property bool vertical: false
    property color color: Kirigami.Theme.textColor
    property real dash: Kirigami.Units.smallSpacing
    property real thickness: 1

    readonly property real span: line.vertical ? line.height : line.width
    readonly property int dashCount: Math.max(0, Math.floor((line.span + line.dash) / (line.dash * 2)))

    implicitWidth: line.vertical ? line.thickness : 0
    implicitHeight: line.vertical ? 0 : line.thickness

    Repeater {
        model: line.dashCount

        Rectangle {
            x: line.vertical ? 0 : index * line.dash * 2
            y: line.vertical ? index * line.dash * 2 : 0
            width: line.vertical ? line.thickness : line.dash
            height: line.vertical ? line.dash : line.thickness
            color: line.color
        }
    }
}
