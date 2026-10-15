import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import org.murasaki.resourcepanel 1.0

/*
 * Resource Panel: CPU/RAM and GPU/VRAM as paired concentric rings, with the
 * active pair's history drawn underneath.
 *
 * Occupancy numbers never appear inside the rings or in the header — the rings
 * carry the names, and one value row carries every current figure.
 */
PlasmoidItem {
    id: root

    /*
     * Plasma::Types::BackgroundHints::NoBackground: the applet draws no frame
     * of its own, so on the desktop only the card below is visible instead of
     * the card sitting inside a second, lighter rounded rectangle.
     *
     * Spelled as a value rather than PlasmaCore.Types.NoBackground because
     * org.kde.plasma.core cannot be loaded without a running Plasma session,
     * and this file is validated offscreen with only the plasma import mocked
     * (test/make_mirror.py). The flag is set on the applet handle, which is the
     * object that owns it; see validate_main.cpp, which asserts it.
     */
    readonly property int backgroundHintNone: 0

    readonly property var groups: [
        { outer: "cpu", inner: "ram", outerLabel: "CPU", innerLabel: "RAM" },
        { outer: "gpu", inner: "vram", outerLabel: "GPU", innerLabel: "VRAM" }
    ]

    /// Metric ids in display order, kept as one stable value for the value row.
    readonly property var metricOrder: ["cpu", "ram", "gpu", "vram"]

    readonly property var metricColors: ({
        cpu: "#4aa8ff",
        ram: "#a884ff",
        gpu: "#3ddc97",
        vram: "#ffb347"
    })

    /// 0 = CPU/RAM, 1 = GPU/VRAM.
    property int activeGroup: 0
    property int timeRange: 300

    /*
     * The view the user leaves the applet in is written back to the config
     * file, so it reopens on the same group and time range.
     */
    onActiveGroupChanged: plasmoid.configuration.startGroup = activeGroup
    onTimeRangeChanged: plasmoid.configuration.timeRange = timeRange

    Component.onCompleted: {
        plasmoid.backgroundHints = root.backgroundHintNone;
        timeRange = plasmoid.configuration.timeRange;
        activeGroup = (plasmoid.configuration.startGroup === 1 && gpuGroupUsable) ? 1 : 0;
    }

    readonly property var activePair: groups[activeGroup]
    readonly property string outerMetric: activePair.outer
    readonly property string innerMetric: activePair.inner
    readonly property color outerColor: metricColors[outerMetric]
    readonly property color innerColor: metricColors[innerMetric]

    /// GPU/VRAM can only be shown while a GPU is actually readable. When the
    /// discrete GPU is asleep or hidden by cardwire the readings come from the
    /// integrated GPU instead, so the pair is always populated.
    readonly property bool gpuGroupUsable: Telemetry.gpuAvailable

    /*
     * The ring animation is owned by the representation, but the group can be
     * changed from the root (config restore, cycling). The root therefore only
     * announces the intent, and the representation reacts to it.
     */
    signal groupSwitchRequested

    function valueOf(metric) {
        switch (metric) {
        case "cpu": return Telemetry.cpuPercent;
        case "ram": return Telemetry.ramPercent;
        case "gpu": return Telemetry.gpuPercent;
        case "vram": return Telemetry.vramPercent;
        }
        return 0;
    }

    function labelOf(metric) {
        return metric.toUpperCase();
    }

    function rangeLabel() {
        return timeRange < 3600 ? "-" + (timeRange / 60) + "m" : "-1h";
    }

    /// Cycle to the next usable group. A hidden discrete GPU makes GPU/VRAM
    /// unavailable, in which case the ring stays where it is.
    function cycleGroup() {
        if (!gpuGroupUsable) {
            activeGroup = 0;
            return;
        }
        selectGroup(activeGroup === 0 ? 1 : 0);
    }

    function selectGroup(index) {
        if (index === 1 && !gpuGroupUsable) {
            return;
        }
        if (index === activeGroup) {
            return;
        }
        // Ask the representation to run the retract/refill sequence, then
        // change the group so the ring relabels and recolours while empty.
        groupSwitchRequested();
        activeGroup = index;
    }

    function cycleTier(delta) {
        const tiers = Telemetry.tiers();
        let i = tiers.indexOf(timeRange);
        if (i < 0) {
            i = 1;
        }
        i = Math.max(0, Math.min(tiers.length - 1, i + delta));
        timeRange = tiers[i];
    }

    preferredRepresentation: fullRepresentation

    fullRepresentation: Item {
        id: content

        /*
         * The layout is authored on one fixed canvas and then scaled as a
         * whole, so every part keeps its proportions at any widget size rather
         * than the content staying put while the frame grows around it.
         *
         * The aspect is the reference design's. A widget with a different
         * aspect letterboxes the canvas instead of stretching it, so the rings
         * never become ellipses.
         */
        readonly property real canvasAspect: 2.16
        readonly property real canvasWidth: Kirigami.Units.gridUnit * 21
        readonly property real canvasHeight: canvasWidth / canvasAspect
        readonly property real canvasScale:
            Math.min(width / canvasWidth, height / canvasHeight)

        implicitWidth: canvasWidth
        implicitHeight: canvasHeight
        /*
         * Floor at the size the widget is actually used at on the desktop,
         * read from the saved Plasma geometry (Applet-506, 384x176 on the
         * 1463x914 logical screen). It cannot be shrunk below that.
         */
        Layout.minimumWidth: 384
        Layout.minimumHeight: 176

        Rectangle {
            id: card
            width: content.canvasWidth
            height: content.canvasHeight
            anchors.centerIn: parent
            scale: content.canvasScale
            radius: 16
            /*
             * Opaque: the applet asks for no background of its own, so this
             * card is the only surface between the content and the wallpaper.
             */
            color: "#1c1f25"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.075)

            GridLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 12
                anchors.topMargin: 10
                anchors.bottomMargin: 9
                columns: 2
                columnSpacing: 6
                rowSpacing: 1

                // ── header: group name, temperature, data-source badge ──
                RowLayout {
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    spacing: 5

                    Text {
                        text: root.labelOf(root.outerMetric)
                        color: root.outerColor
                        font.pixelSize: 12
                        font.bold: true
                    }
                    Text {
                        text: "·"
                        color: Qt.rgba(1, 1, 1, 0.35)
                        font.pixelSize: 12
                    }
                    Text {
                        text: root.labelOf(root.innerMetric)
                        color: root.innerColor
                        font.pixelSize: 12
                        font.bold: true
                    }
                    Text {
                        text: root.outerMetric === "cpu" ? Telemetry.cpuTemp : Telemetry.gpuTemp
                        color: Qt.rgba(1, 1, 1, 0.55)
                        font.pixelSize: 9
                    }
                    Item { Layout.fillWidth: true }

                    Rectangle {
                        implicitWidth: badgeText.implicitWidth + 10
                        implicitHeight: badgeText.implicitHeight + 4
                        radius: 5
                        color: Telemetry.dgpuVisible
                               ? Qt.rgba(61 / 255, 220 / 255, 151 / 255, 0.12)
                               : Qt.rgba(159 / 255, 176 / 255, 196 / 255, 0.10)
                        border.width: 1
                        border.color: Telemetry.dgpuVisible
                                      ? Qt.rgba(61 / 255, 220 / 255, 151 / 255, 0.22)
                                      : Qt.rgba(159 / 255, 176 / 255, 196 / 255, 0.20)

                        Text {
                            id: badgeText
                            anchors.centerIn: parent
                            text: Telemetry.dgpuVisible ? "5060" : "iGPU 780M"
                            color: Telemetry.dgpuVisible ? "#8fd9b4" : "#9fb0c4"
                            font.pixelSize: 8
                            font.bold: true
                        }
                    }
                }

                // ── nested rings ──
                RingPair {
                    id: rings
                    Layout.rowSpan: 1
                    Layout.preferredWidth: 104
                    Layout.preferredHeight: 104
                    Layout.alignment: Qt.AlignCenter

                    outerValue: root.valueOf(root.outerMetric)
                    innerValue: root.valueOf(root.innerMetric)
                    outerColor: root.outerColor
                    innerColor: root.innerColor
                    outerLabel: root.labelOf(root.outerMetric)
                    innerLabel: root.labelOf(root.innerMetric)

                    onActivated: root.cycleGroup()
                }

                HistoryChart {
                    id: chart
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 74
                    Layout.alignment: Qt.AlignVCenter

                    timeRange: root.timeRange
                    rangeLabel: root.rangeLabel()
                    renderScale: content.canvasScale
                    revision: Telemetry.revision
                    metricA: root.outerMetric
                    metricB: root.innerMetric
                    colorA: root.outerColor
                    colorB: root.innerColor
                }

                // ── value row: the only place current occupancy appears ──
                RowLayout {
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    spacing: 9

                    Repeater {
                        model: root.metricOrder

                        delegate: RowLayout {
                            id: valueEntry

                            /*
                             * The active pair is highlighted, the other pair
                             * stays legible but recessive. Computed once here
                             * so the three texts share one binding instead of
                             * repeating the same predicate.
                             */
                            readonly property bool highlighted:
                                modelData === root.outerMetric || modelData === root.innerMetric
                            readonly property color entryColor: highlighted ? "#e6eaf0" : "#7d8492"

                            spacing: 3
                            visible: modelData === "cpu" || modelData === "ram" || root.gpuGroupUsable

                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: 5.5
                                implicitHeight: 5.5
                                radius: 3
                                color: root.metricColors[modelData]
                                opacity: valueEntry.highlighted ? 1 : 0.5
                            }
                            Text {
                                text: modelData.toUpperCase()
                                color: valueEntry.entryColor
                                font.pixelSize: 9
                                font.bold: true
                            }
                            Text {
                                text: root.valueOf(modelData)
                                color: valueEntry.entryColor
                                font.pixelSize: 11
                                font.bold: true
                            }
                            Text {
                                text: "%"
                                color: "#69707d"
                                font.pixelSize: 8
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }

                // ── time range selector ──
                RowLayout {
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    spacing: 2

                    Repeater {
                        model: Telemetry.tiers()

                        delegate: Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 18
                            radius: 5
                            color: root.timeRange === modelData
                                   ? Qt.rgba(1, 1, 1, 0.10)
                                   : (hover.hovered ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.035))
                            border.width: 1
                            border.color: root.timeRange === modelData
                                          ? Qt.rgba(1, 1, 1, 0.13) : "transparent"

                            Text {
                                anchors.centerIn: parent
                                text: modelData < 3600 ? (modelData / 60) + "m" : "1h"
                                color: root.timeRange === modelData ? "#f2f4f7" : "#767d8b"
                                font.pixelSize: 9
                                font.bold: true
                            }

                            HoverHandler { id: hover }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.timeRange = modelData
                            }
                        }
                    }
                }
            }

            // Wheel over the card steps through the time ranges.
            WheelHandler {
                onWheel: event => root.cycleTier(event.angleDelta.y > 0 ? -1 : 1)
            }
        }

        // Runs the ring's retract → recolour → refill sequence.
        Connections {
            target: root
            function onGroupSwitchRequested() {
                rings.switchTo();
            }
        }

        /*
         * The GPU group collapses back to CPU/RAM whenever no GPU is readable.
         * This has to be a Connections block: gpuGroupUsable is a readonly
         * binding, so it has no change signal of its own to handle.
         */
        Connections {
            target: root

            function onGpuGroupUsableChanged() {
                if (!root.gpuGroupUsable && root.activeGroup !== 0) {
                    root.activeGroup = 0;
                }
            }
        }
    }
}
