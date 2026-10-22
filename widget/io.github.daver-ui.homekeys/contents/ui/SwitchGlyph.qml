import QtQuick

import org.kde.kirigami as Kirigami

/*
 * A two-gang wall switch drawn from rectangles: a plate, a centre divider and two
 * rockers. The proportions follow the sketch's 24-unit glyph, so the same shape
 * serves the panel strip and the popup hero.
 */
Item {
    id: glyph

    property real glyphSize: Kirigami.Units.iconSizes.small
    property color color: Kirigami.Theme.textColor
    readonly property real stroke: Math.max(1, Math.round(glyph.glyphSize / 12))

    implicitWidth: glyph.glyphSize
    implicitHeight: glyph.glyphSize

    Rectangle {
        x: glyph.width * 4 / 24
        y: glyph.height * 2.5 / 24
        width: glyph.width * 16 / 24
        height: glyph.height * 19 / 24
        radius: glyph.width * 2.5 / 24
        color: "transparent"
        border.color: glyph.color
        border.width: glyph.stroke
    }

    Rectangle {
        x: glyph.width * 12 / 24 - glyph.stroke / 2
        y: glyph.height * 3 / 24
        width: glyph.stroke
        height: glyph.height * 18 / 24
        color: glyph.color
    }

    Rectangle {
        x: glyph.width * 6.5 / 24
        y: glyph.height * 5.5 / 24
        width: glyph.width * 2.6 / 24
        height: glyph.height * 4.5 / 24
        radius: glyph.width * 1 / 24
        color: glyph.color
    }

    Rectangle {
        x: glyph.width * 14.9 / 24
        y: glyph.height * 5.5 / 24
        width: glyph.width * 2.6 / 24
        height: glyph.height * 4.5 / 24
        radius: glyph.width * 1 / 24
        color: glyph.color
    }
}
