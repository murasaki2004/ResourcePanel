import QtQuick
import org.murasaki.resourcepanel 1.0

/*
 * Rolling history chart.
 *
 * The axes, gridlines and labels are separate items from the curves, so
 * switching metric, group or time range only repaints the curves: the
 * coordinate frame the eye is anchored to never moves or flickers.
 *
 * Each curve is peak-preserving downsampled in the backend, so a narrow chart
 * still shows short spikes instead of averaging them away.
 */
Item {
    id: root

    /// Metric ids to plot, outermost ring first.
    property string metricA: "cpu"
    property string metricB: "ram"
    property color colorA: "transparent"
    property color colorB: "transparent"

    property int timeRange: 300
    /// Left-hand axis caption, e.g. "-5m".
    property string rangeLabel: ""

    /*
     * Coordinate-frame colours, supplied by the caller so the grid, axis and
     * captions can follow the light/dark surface. Defaults match the dark card.
     */
    property color gridColor: Qt.rgba(1, 1, 1, 0.055)
    property color axisColor: Qt.rgba(1, 1, 1, 0.13)
    property color labelColor: Qt.rgba(1, 1, 1, 0.28)

    /*
     * Effective on-screen scale of this chart, supplied by the caller while the
     * whole layout is scaled to the widget. The plots rasterise at the size
     * they end up being drawn at rather than being upscaled afterwards, which
     * is what keeps the curves and gridlines sharp.
     */
    property real renderScale: 1

    /*
     * Scale the canvases rasterise at. Clamped to 1 so a widget smaller than
     * the authored canvas does not paint into an undersized buffer.
     *
     * Canvas.canvasSize only sets the logical drawing area — it does not map
     * that area onto the item. The canvases below therefore grow their item
     * geometry by this factor and undo it with an inverse transform, which is
     * the only way to get a higher-resolution buffer without moving the
     * content relative to the QML-drawn axis labels.
     */
    readonly property real pixelScale: Math.max(1, renderScale)

    /*
     * The backend's sample counter. The series are pulled whenever it changes
     * rather than bound to it, because two consecutive empty results compare
     * equal and a binding would then never re-evaluate once data arrives.
     */
    property var revision: 0
    onRevisionChanged: refresh()
    onMetricAChanged: refresh()
    onMetricBChanged: refresh()
    onTimeRangeChanged: refresh()

    /// Downsampled samples for the pair currently being plotted.
    property var seriesA: []
    property var seriesB: []

    /**
     * Top of the value axis.
     *
     * A fixed 0..100 axis crushes ordinary readings into the bottom fifth of
     * the plot, which hides the shape of the history. The scale instead snaps
     * to the next step above the busiest curve, and only grows while a given
     * selection is on screen so the frame does not jitter as samples arrive.
     */
    property real yMax: 25
    property string axisKey: ""

    readonly property int padLeft: 17
    readonly property int padRight: 3
    readonly property int padTop: 4
    readonly property int padBottom: 11

    readonly property real plotWidth: Math.max(0, width - padLeft - padRight)
    readonly property real plotHeight: Math.max(0, height - padTop - padBottom)

    implicitWidth: 150
    implicitHeight: 100

    onColorAChanged: curves.requestPaint()
    onColorBChanged: curves.requestPaint()
    onGridColorChanged: grid.requestPaint()
    onAxisColorChanged: grid.requestPaint()
    onWidthChanged: { grid.requestPaint(); curves.requestPaint(); }
    onHeightChanged: { grid.requestPaint(); curves.requestPaint(); }
    onRenderScaleChanged: { grid.requestPaint(); curves.requestPaint(); }
    onYMaxChanged: { grid.requestPaint(); curves.requestPaint(); }

    function refresh() {
        seriesA = Telemetry.series(metricA, timeRange, 130);
        seriesB = Telemetry.series(metricB, timeRange, 130);
        rescale();
    }

    function peakOf(samples) {
        if (!samples || samples.length === undefined) {
            return 0;
        }
        let peak = 0;
        for (let i = 0; i < samples.length; ++i) {
            const v = Number(samples[i]);
            if (isFinite(v) && v > peak) {
                peak = v;
            }
        }
        return peak;
    }

    function stepFor(peak) {
        // Round numbers only, so the three gridline labels always read cleanly.
        if (peak <= 10) return 10;
        if (peak <= 25) return 25;
        if (peak <= 50) return 50;
        if (peak <= 75) return 75;
        return 100;
    }

    function rescale() {
        const peak = Math.max(peakOf(seriesA), peakOf(seriesB));
        const wanted = stepFor(peak);
        const key = rangeLabel;
        // Grow immediately, but only shrink when the selection changed.
        if (wanted > yMax || key !== axisKey) {
            yMax = Math.max(10, wanted);
        }
        axisKey = key;
        grid.requestPaint();
        curves.requestPaint();
    }

    function yFor(v) {
        return root.padTop + root.plotHeight * (1 - Math.min(v, root.yMax) / root.yMax);
    }

    // ── static coordinate frame: gridlines, axis cross, range captions ──
    Canvas {
        id: grid
        width: Math.max(1, root.width * root.pixelScale)
        height: Math.max(1, root.height * root.pixelScale)
        scale: 1 / root.pixelScale
        transformOrigin: Item.TopLeft

        canvasSize: Qt.size(Math.max(1, Math.round(width)),
                            Math.max(1, Math.round(height)))
        onCanvasSizeChanged: requestPaint()

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.scale(root.pixelScale, root.pixelScale);
            if (root.plotWidth <= 0 || root.plotHeight <= 0) {
                return;
            }

            ctx.lineWidth = 1;
            for (const frac of [0, 0.5, 1]) {
                const y = Math.round(root.padTop + root.plotHeight * (1 - frac)) + 0.5;
                // The zero line doubles as the X axis, so give it more weight.
                ctx.strokeStyle = frac === 0 ? root.axisColor : root.gridColor;
                ctx.beginPath();
                ctx.moveTo(root.padLeft, y);
                ctx.lineTo(root.width - root.padRight, y);
                ctx.stroke();
            }

            const x0 = root.padLeft + 0.5;
            const y1 = root.padTop + root.plotHeight;
            ctx.strokeStyle = root.axisColor;
            ctx.beginPath();
            ctx.moveTo(x0, root.padTop);
            ctx.lineTo(x0, y1 + 0.5);
            ctx.stroke();

            ctx.fillStyle = root.labelColor;
            ctx.font = "600 6px sans-serif";
            ctx.textBaseline = "top";
            ctx.textAlign = "left";
            ctx.fillText(root.rangeLabel, root.padLeft, y1 + 3);
            ctx.textAlign = "right";
            ctx.fillText("now", root.width - root.padRight, y1 + 3);
        }
    }

    // Axis value labels: plain Text so they track yMax without a repaint.
    Repeater {
        model: [1.0, 0.5, 0.0]

        delegate: Text {
            x: 0
            y: root.padTop + root.plotHeight * (1 - modelData) - height / 2
            width: root.padLeft - 4
            horizontalAlignment: Text.AlignRight
            text: Math.round(root.yMax * modelData)
            color: root.labelColor
            font.pixelSize: 7
            font.bold: true
        }
    }

    // ── the only thing that changes: the curves ──
    Canvas {
        id: curves
        width: Math.max(1, root.width * root.pixelScale)
        height: Math.max(1, root.height * root.pixelScale)
        scale: 1 / root.pixelScale
        transformOrigin: Item.TopLeft

        canvasSize: Qt.size(Math.max(1, Math.round(width)),
                            Math.max(1, Math.round(height)))
        onCanvasSizeChanged: requestPaint()

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.scale(root.pixelScale, root.pixelScale);
            if (root.plotWidth <= 0 || root.plotHeight <= 0) {
                return;
            }

            /*
             * Only the outer curve gets an area fill. Two translucent areas
             * stacked in one small plot muddle each other, and the inner curve
             * ends up hidden behind the outer curve's shading.
             */
            const drawCurve = (samples, colour, withFill) => {
                if (!samples || samples.length === undefined || samples.length < 2) {
                    return;
                }
                const n = samples.length;
                const xFor = i => root.padLeft + root.plotWidth * (i / (n - 1));

                // A bezier through the midpoints smooths the line without the
                // overshoot a plain spline would introduce.
                const tracePath = () => {
                    ctx.beginPath();
                    ctx.moveTo(xFor(0), root.yFor(samples[0]));
                    for (let i = 1; i < n; ++i) {
                        const x0 = xFor(i - 1);
                        const y0 = root.yFor(samples[i - 1]);
                        const x1 = xFor(i);
                        const y1 = root.yFor(samples[i]);
                        const cx = (x0 + x1) / 2;
                        ctx.bezierCurveTo(cx, y0, cx, y1, x1, y1);
                    }
                };

                if (withFill) {
                    const grad = ctx.createLinearGradient(0, root.padTop, 0, root.padTop + root.plotHeight);
                    grad.addColorStop(0, Qt.rgba(colour.r, colour.g, colour.b, 0.20));
                    grad.addColorStop(1, Qt.rgba(colour.r, colour.g, colour.b, 0));
                    tracePath();
                    ctx.lineTo(xFor(n - 1), root.padTop + root.plotHeight);
                    ctx.lineTo(xFor(0), root.padTop + root.plotHeight);
                    ctx.closePath();
                    ctx.fillStyle = grad;
                    ctx.fill();
                }

                tracePath();
                ctx.strokeStyle = colour;
                ctx.lineWidth = 1.6;
                ctx.lineJoin = "round";
                ctx.lineCap = "round";
                ctx.stroke();

                ctx.beginPath();
                ctx.arc(xFor(n - 1), root.yFor(samples[n - 1]), 2, 0, 2 * Math.PI);
                ctx.fillStyle = colour;
                ctx.fill();
            };

            drawCurve(root.seriesA, root.colorA, true);
            drawCurve(root.seriesB, root.colorB, false);
        }
    }
}
