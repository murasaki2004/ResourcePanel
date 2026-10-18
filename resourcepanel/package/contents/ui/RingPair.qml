import QtQuick
import QtQuick.Shapes

/*
 * Two concentric utilisation rings sharing one centre label.
 *
 * A group switch is a three-step sequence, driven from here so the timing
 * lives in exactly one place:
 *   1. retract  — both arcs snap back to zero with no transition
 *   2. recolour — track and arc take the incoming metric's colour while the
 *                 ring is visually empty, so the tint change is never hidden
 *                 behind a filled arc
 *   3. refill   — both arcs animate to the live value with an ease-out
 *
 * The geometry is expressed as a 0..1 fraction of the full circle, and the
 * dash offset is derived from the actual circumference, so the component
 * stays correct at any size.
 */
Item {
    id: root

    /// Metric ids currently in use, outermost first.
    property string outerMetric: ""
    property string innerMetric: ""
    /// Active values, 0..100.
    property real outerValue: 0
    property real innerValue: 0

    /// Accent colours, supplied by the caller so the palette lives in one place.
    property color outerColor: "transparent"
    property color innerColor: "transparent"

    /// Alpha of the unfilled track tint. The light surface needs a touch more
    /// than the dark one for the track to read against white.
    property real trackOpacity: 0.15

    /// Shown in the middle of the rings. Names only — never a number.
    property string outerLabel: ""
    property string innerLabel: ""

    readonly property real outerRadius: Math.min(width, height) / 2 - outerStroke / 2
    readonly property real innerRadius: outerRadius - outerStroke - gap

    property real outerStroke: 9
    property real gap: 4.5

    readonly property real outerCircumference: 2 * Math.PI * outerRadius
    readonly property real innerCircumference: 2 * Math.PI * innerRadius

    /// Fraction of the ring that is currently filled, 0..1.
    property real outerFraction: outerValue / 100
    property real innerFraction: innerValue / 100

    /// True only while the arcs are snapping back to zero. Disabling the
    /// animation for that single step makes the retract instant while the
    /// refill still eases, without needing a timer or two code paths.
    property bool retracting: false

    Behavior on outerFraction {
        enabled: !root.retracting
        NumberAnimation { duration: 620; easing.type: Easing.OutCubic }
    }
    Behavior on innerFraction {
        enabled: !root.retracting
        NumberAnimation { duration: 620; easing.type: Easing.OutCubic }
    }

    signal activated()

    implicitWidth: 104
    implicitHeight: 104

    onOuterValueChanged: if (!root.retracting) root.outerFraction = outerValue / 100
    onInnerValueChanged: if (!root.retracting) root.innerFraction = innerValue / 100

    /**
     * Runs the switch sequence.
     *
     * The arcs are emptied and only refilled after a short beat. Without that
     * beat both steps land in the same frame, and because the retract has no
     * animation the transition would read as a plain colour change — the
     * emptying of the ring would never actually be visible.
     */
    function switchTo() {
        retracting = true;
        outerFraction = 0;
        innerFraction = 0;

        // The caller recolours and relabels the ring here, while it is
        // visually empty, so the tint change is never hidden behind an arc.
        holdTimer.restart();
    }

    Timer {
        id: holdTimer
        interval: 150
        repeat: false
        onTriggered: {
            root.retracting = false;
            root.outerFraction = root.outerValue / 100;
            root.innerFraction = root.innerValue / 100;
        }
    }

    // Track rings: a faint tint of the metric colour, permanently visible and
    // revealed in full as the value arc retracts.
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: Qt.rgba(root.outerColor.r, root.outerColor.g, root.outerColor.b, root.trackOpacity)
            strokeWidth: root.outerStroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: root.outerRadius
                radiusY: root.outerRadius
                startAngle: -90
                sweepAngle: 360
            }
        }
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: Qt.rgba(root.innerColor.r, root.innerColor.g, root.innerColor.b, root.trackOpacity)
            strokeWidth: root.outerStroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: root.innerRadius
                radiusY: root.innerRadius
                startAngle: -90
                sweepAngle: 360
            }
        }
    }

    // Value arcs.
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: root.outerColor
            strokeWidth: root.outerStroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                id: outerArc
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: root.outerRadius
                radiusY: root.outerRadius
                startAngle: -90
                sweepAngle: 360 * Math.max(0, Math.min(1, root.outerFraction))
            }
        }
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: root.innerColor
            strokeWidth: root.outerStroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: root.innerRadius
                radiusY: root.innerRadius
                startAngle: -90
                sweepAngle: 360 * Math.max(0, Math.min(1, root.innerFraction))
            }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 5

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.outerLabel
            color: root.outerColor
            font.pixelSize: 11
            font.bold: true
            font.letterSpacing: 1.6
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.innerLabel
            color: root.innerColor
            font.pixelSize: 11
            font.bold: true
            font.letterSpacing: 1.6
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }
}
