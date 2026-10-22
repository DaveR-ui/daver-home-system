import QtQuick

import org.kde.kirigami as Kirigami

import "homekeys.js" as Homekeys

/*
 * A small coloured dot encoding a severity produced by homekeys.js.
 * Shared by every representation so the severity -> colour mapping exists once.
 * The severity vocabulary itself is imported, not re-spelled, so it lives only in
 * homekeys.js.
 */
Rectangle {
    id: dot

    property string severity: Homekeys.SEVERITY_MUTED
    property int diameter: Math.round(Kirigami.Units.gridUnit / 3)

    readonly property color severityColor: {
        switch (dot.severity) {
        case Homekeys.SEVERITY_POSITIVE:
            return Kirigami.Theme.positiveTextColor;
        case Homekeys.SEVERITY_NEGATIVE:
            return Kirigami.Theme.negativeTextColor;
        case Homekeys.SEVERITY_WARNING:
            return Kirigami.Theme.neutralTextColor;
        case Homekeys.SEVERITY_NEUTRAL:
            // Grey rather than the bright text colour: an off state must not read
            // as an active one.
            return Qt.alpha(Kirigami.Theme.textColor, 0.6);
        default:
            // Muted, never neutral: an unknown state must not read as "fine".
            return Kirigami.Theme.disabledTextColor;
        }
    }

    implicitWidth: dot.diameter
    implicitHeight: dot.diameter
    radius: dot.diameter / 2
    color: dot.severityColor
}
