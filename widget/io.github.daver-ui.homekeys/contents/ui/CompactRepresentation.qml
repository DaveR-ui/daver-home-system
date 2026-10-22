import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "homekeys.js" as Homekeys

/*
 * Panel representation: the configured state icon, the widget name, an
 * explicit error icon when a failure is active, a busy indicator while the
 * wallet is being read, and a severity dot.
 *
 * main.qml chooses the state, severity and error flag; this file maps none of
 * them itself.
 */
Item {
    id: compactRoot

    property string overallState: Homekeys.STATE_UNKNOWN
    property string severity: Homekeys.SEVERITY_MUTED
    property string iconName: ""
    property bool errorActive: false
    property bool loading: false

    implicitWidth: compactLayout.implicitWidth
    implicitHeight: compactLayout.implicitHeight

    RowLayout {
        id: compactLayout

        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        // The configured iconOn/iconOff value, tinted by the aggregate state:
        // this is what makes the panel icon follow the keys without opening the
        // popup.
        Kirigami.Icon {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            source: compactRoot.iconName
            opacity: compactRoot.severity === Homekeys.SEVERITY_POSITIVE ? 1.0 : 0.6
        }

        PlasmaComponents3.Label {
            Layout.alignment: Qt.AlignVCenter
            Layout.maximumWidth: Kirigami.Units.gridUnit * 8
            text: i18n("Home Keys")
            elide: Text.ElideRight
        }

        PlasmaComponents3.BusyIndicator {
            visible: compactRoot.loading
            running: compactRoot.loading
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }

        // The severity dot already reads negative through its colour; this icon
        // makes a failure unmistakable at a glance.
        Kirigami.Icon {
            visible: compactRoot.errorActive
            source: "data-error"
            color: Kirigami.Theme.negativeTextColor
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }

        SeverityDot {
            Layout.alignment: Qt.AlignVCenter
            severity: compactRoot.severity
        }
    }
}
