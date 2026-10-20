import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: page

    property alias cfg_timeRange: rangeBox.currentValue
    property alias cfg_startGroup: groupBox.currentIndex
    property alias cfg_sizePreset: sizeBox.currentIndex

    implicitWidth: 340
    implicitHeight: 260

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.gridUnit
        spacing: Kirigami.Units.largeSpacing

        QQC.Label {
            text: i18n("History window")
            font.bold: true
        }

        QQC.ComboBox {
            id: rangeBox
            Layout.fillWidth: true
            textRole: "label"
            valueRole: "value"
            model: [
                { label: i18n("1 minute"), value: 60 },
                { label: i18n("5 minutes"), value: 300 },
                { label: i18n("15 minutes"), value: 900 },
                { label: i18n("1 hour"), value: 3600 }
            ]
            Component.onCompleted: currentIndex = indexOfValue(cfg_timeRange)
        }

        QQC.Label {
            text: i18n("Group shown on startup")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        QQC.ComboBox {
            id: groupBox
            Layout.fillWidth: true
            model: [i18n("CPU + RAM"), i18n("GPU + VRAM")]
        }

        QQC.Label {
            text: i18n("Widget size (desktop)")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        QQC.ComboBox {
            id: sizeBox
            Layout.fillWidth: true
            model: [
                i18n("Free resize"),
                i18n("Small"),
                i18n("Medium"),
                i18n("Large")
            ]
            Component.onCompleted: currentIndex = Math.max(0, Math.min(3, cfg_sizePreset))
        }

        Item { Layout.fillHeight: true }
    }
}
