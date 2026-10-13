import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: page

    property alias cfg_timeRange: rangeBox.currentValue
    property alias cfg_startGroup: groupBox.currentIndex

    implicitWidth: 340
    implicitHeight: 180

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

        Item { Layout.fillHeight: true }
    }
}
