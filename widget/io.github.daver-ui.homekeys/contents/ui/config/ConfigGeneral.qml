import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

/*
 * Plasma binds every "cfg_<entryName>" alias to the matching entry in
 * contents/config/main.xml. Each alias target is a plain writable property --
 * never an expression -- because aliasing an expression is a silent no-op on
 * save.
 */
Kirigami.FormLayout {
    id: configPage

    property alias cfg_hubBaseUrl: hubBaseUrl.text
    property alias cfg_pollIntervalSeconds: pollInterval.value
    property alias cfg_walletName: walletName.text
    property alias cfg_walletFolder: walletFolder.text
    property alias cfg_walletKey: walletKey.text
    property alias cfg_tecla1SwitchEntity: tecla1SwitchEntity.text
    property alias cfg_tecla1BulbEntities: tecla1BulbEntities.text
    property alias cfg_tecla2SwitchEntity: tecla2SwitchEntity.text
    property alias cfg_tecla2BulbEntities: tecla2BulbEntities.text
    property alias cfg_iconOn: iconOn.text
    property alias cfg_iconOff: iconOff.text
    property alias cfg_iconUnknown: iconUnknown.text

    QQC2.TextField {
        id: hubBaseUrl
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Home Assistant URL:")

        QQC2.ToolTip.text: i18n("Base URL of the hub, e.g. http://127.0.0.1:8123. No trailing slash is required.")
        QQC2.ToolTip.visible: hovered
    }

    QQC2.SpinBox {
        id: pollInterval
        Kirigami.FormData.label: i18n("Poll interval (seconds):")
        from: 1
        to: 60
        stepSize: 1

        QQC2.ToolTip.text: i18n("How often every tracked entity is read. Each poll makes one GET request per entity.")
        QQC2.ToolTip.visible: hovered
    }

    // --- KWallet -------------------------------------------------------------
    QQC2.Label {
        Kirigami.FormData.isSection: true
        text: i18n("Token custody (KWallet)")
    }

    QQC2.TextField {
        id: walletName
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Wallet:")

        QQC2.ToolTip.text: i18n("KWallet wallet name, usually kdewallet.")
        QQC2.ToolTip.visible: hovered
    }

    QQC2.TextField {
        id: walletFolder
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Folder:")

        QQC2.ToolTip.text: i18n("KWallet folder that holds the Home Assistant token entry.")
        QQC2.ToolTip.visible: hovered
    }

    QQC2.TextField {
        id: walletKey
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Entry key:")

        QQC2.ToolTip.text: i18n("KWallet entry key that holds the token, e.g. ha-token.")
        QQC2.ToolTip.visible: hovered
    }

    QQC2.Label {
        Layout.fillWidth: true
        text: i18n("The Home Assistant token is NOT entered here. It lives in KWallet; provision it once with widget/install.sh token.")
        wrapMode: Text.WordWrap
        opacity: 0.8
        font: Kirigami.Theme.smallFont
    }

    // --- Key 1 ---------------------------------------------------------------
    QQC2.Label {
        Kirigami.FormData.isSection: true
        text: i18n("Key 1")
    }

    QQC2.TextField {
        id: tecla1SwitchEntity
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Switch entity:")

        QQC2.ToolTip.text: i18n("The wall-switch channel entity. This is the only entity key 1 writes.")
        QQC2.ToolTip.visible: hovered
    }

    QQC2.TextField {
        id: tecla1BulbEntities
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Bulb entities:")

        QQC2.ToolTip.text: i18n("Comma-separated light entities the key drives, e.g. light.sala_luz_izquierda, light.sala_luz_derecha. Display-only.")
        QQC2.ToolTip.visible: hovered
    }

    // --- Key 2 ---------------------------------------------------------------
    QQC2.Label {
        Kirigami.FormData.isSection: true
        text: i18n("Key 2")
    }

    QQC2.TextField {
        id: tecla2SwitchEntity
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Switch entity:")

        QQC2.ToolTip.text: i18n("The wall-switch channel entity. This is the only entity key 2 writes.")
        QQC2.ToolTip.visible: hovered
    }

    QQC2.TextField {
        id: tecla2BulbEntities
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Bulb entities:")

        QQC2.ToolTip.text: i18n("Comma-separated light entities the key drives. Display-only.")
        QQC2.ToolTip.visible: hovered
    }

    QQC2.Label {
        Layout.fillWidth: true
        text: i18n("Bulb entities are display-only. Home Assistant's automations write them when the switch channel changes; the widget never does.")
        wrapMode: Text.WordWrap
        opacity: 0.8
        font: Kirigami.Theme.smallFont
    }

    // --- Panel icons ---------------------------------------------------------
    QQC2.Label {
        Kirigami.FormData.isSection: true
        text: i18n("Panel")
    }

    QQC2.TextField {
        id: iconOn
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Icon while on:")

        QQC2.ToolTip.text: i18n("Any icon name from the active theme, e.g. flashlight-on-symbolic.")
        QQC2.ToolTip.visible: hovered
    }

    QQC2.TextField {
        id: iconOff
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Icon while off:")

        QQC2.ToolTip.text: i18n("Any icon name from the active theme, e.g. flashlight-off-symbolic.")
        QQC2.ToolTip.visible: hovered
    }

    QQC2.TextField {
        id: iconUnknown
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n("Icon while unknown:")

        QQC2.ToolTip.text: i18n("Shown when the state is unknown, unavailable or mixed, e.g. dialog-information-symbolic. Never reuse the off icon here.")
        QQC2.ToolTip.visible: hovered
    }
}
