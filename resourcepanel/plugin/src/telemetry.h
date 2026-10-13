#pragma once

#include <QHash>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariant>
#include <QVariantList>
#include <QVector>

#include <memory>

class QLibrary;

/**
 * Telemetry samples CPU, RAM and GPU utilisation once per second and keeps a
 * rolling one-hour history so the applet can draw any window without needing a
 * separate buffer per time range.
 *
 * Data sources, cheapest first:
 *   - /proc/stat and /proc/meminfo for CPU and RAM (no hardware access at all)
 *   - /sys/class/drm/<card>/device/* for the AMD integrated GPU
 *   - NVML for the NVIDIA discrete GPU, and *only* while that GPU is already
 *     awake and not hidden from this process by cardwire.
 */
class Telemetry : public QObject
{
    Q_OBJECT

    Q_PROPERTY(int cpuPercent READ cpuPercent NOTIFY changed)
    Q_PROPERTY(int ramPercent READ ramPercent NOTIFY changed)
    Q_PROPERTY(int gpuPercent READ gpuPercent NOTIFY changed)
    Q_PROPERTY(int vramPercent READ vramPercent NOTIFY changed)

    Q_PROPERTY(QString cpuTemp READ cpuTemp NOTIFY changed)
    Q_PROPERTY(QString gpuTemp READ gpuTemp NOTIFY changed)
    Q_PROPERTY(QString cpuFreq READ cpuFreq NOTIFY changed)
    Q_PROPERTY(QString ramText READ ramText NOTIFY changed)
    Q_PROPERTY(QString vramText READ vramText NOTIFY changed)

    Q_PROPERTY(QString gpuName READ gpuName NOTIFY changed)
    Q_PROPERTY(QString gpuShortName READ gpuShortName NOTIFY changed)
    Q_PROPERTY(bool dgpuVisible READ dgpuVisible NOTIFY changed)
    /// True when any GPU can be read, so a GPU/VRAM group can be populated.
    Q_PROPERTY(bool gpuAvailable READ gpuAvailable NOTIFY changed)

    /*
     * Bumped once per sample. QML bindings that call series() depend on this,
     * which guarantees they re-evaluate every tick — an empty result compared
     * equal to the previous empty result would otherwise never re-trigger.
     */
    Q_PROPERTY(quint64 revision READ revision NOTIFY changed)

public:
    explicit Telemetry(QObject *parent = nullptr);
    ~Telemetry() override;

    /** Time ranges offered in the UI, in seconds. */
    Q_INVOKABLE QVariantList tiers() const;

    /**
     * History for one metric, downsampled to at most @p buckets peak-preserving
     * samples covering the last @p seconds. Returns an empty list when the
     * metric is unavailable, which is how the applet knows to skip a curve.
     */
    Q_INVOKABLE QVector<float> series(const QString &metric, int seconds, int buckets) const;

    int cpuPercent() const { return m_cpuPercent; }
    int ramPercent() const { return m_ramPercent; }
    int gpuPercent() const { return m_gpuPercent; }
    int vramPercent() const { return m_vramPercent; }

    QString cpuTemp() const { return m_cpuTemp; }
    QString gpuTemp() const { return m_gpuTemp; }
    QString cpuFreq() const { return m_cpuFreq; }
    QString ramText() const { return m_ramText; }
    QString vramText() const { return m_vramText; }

    QString gpuName() const { return m_gpuName; }
    QString gpuShortName() const { return m_gpuShortName; }
    bool dgpuVisible() const { return m_dgpuVisible; }
    bool gpuAvailable() const { return m_gpuAvailable || m_dgpuVisible; }
    quint64 revision() const { return m_revision; }

Q_SIGNALS:
    void changed();

private:
    void sample();
    void sampleCpu();
    void sampleRam();
    void sampleGpu();
    void push(int metric, float value);

    /** Locate the amdgpu DRM card and its hwmon directory once, then cache. */
    void resolveAmdGpu();
    /** Locate the NVIDIA PCI device and remember how to reach it. */
    void resolveNvidiaGpu();
    /** Read the marketing name from the driver's procfs entry. */
    void resolveNvidiaGpuName();

    /**
     * Decide whether the discrete GPU may be queried this tick.
     *
     * The probe deliberately only ever touches things that cannot power the GPU
     * up. abs() can be answered without a driver round-trip, so a cardwire
     * block surfaces as a plain "not visible" rather than waking the hardware.
     */
    bool dgpuQueryAllowed();
    void teardownNvml();
    bool setupNvml();

    enum Metric { Cpu = 0, Ram, Gpu, Vram, MetricCount };
    static constexpr int kHistorySeconds = 3600;

    struct Ring {
        QVector<float> values = QVector<float>(kHistorySeconds, 0.0f);
        int head = 0;
        int count = 0;   ///< valid samples, saturating at kHistorySeconds
        void push(float v)
        {
            values[head] = v;
            head = (head + 1) % kHistorySeconds;
            if (count < kHistorySeconds) {
                ++count;
            }
        }
        void clear()
        {
            values.fill(0.0f);
            head = 0;
            count = 0;
        }
        /** Oldest-to-newest sample @p back steps from the newest. */
        float at(int back) const
        {
            const int idx = (head - 1 - back + 2 * kHistorySeconds) % kHistorySeconds;
            return values[idx];
        }
        bool hasAny() const { return count > 0; }
    };
    Ring m_ring[MetricCount];

    QTimer m_timer;

    // ---- CPU ----
    quint64 m_prevBusy = 0;
    quint64 m_prevTotal = 0;
    int m_cpuPercent = 0;
    QString m_cpuFreq;
    QString m_cpuTemp;

    // ---- RAM ----
    int m_ramPercent = 0;
    QString m_ramText;

    // ---- GPU ----
    bool m_gpuAvailable = false;
    bool m_gpuIsDiscrete = false;
    QString m_gpuName;
    QString m_gpuShortName;
    QString m_gpuTemp;
    QString m_vramText;
    int m_gpuPercent = 0;
    int m_vramPercent = 0;

    // AMD sysfs paths, resolved once
    QString m_amdBusyPath;
    QString m_amdVramUsedPath;
    QString m_amdVramTotalPath;
    QString m_amdGttUsedPath;
    QString m_amdGttTotalPath;
    QString m_amdHwmonTempPath;

    // NVIDIA
    QString m_nvPciAddress;
    QString m_nvPowerPath;
    QString m_nvInformationPath;
    QString m_nvBlockProbePath;
    bool m_nvmlReady = false;
    std::unique_ptr<QLibrary> m_nvml;

    // NVML entry points, resolved lazily via dlopen so the applet runs on
    // systems that have no NVIDIA driver at all.
    using NvmlInit = int (*)();
    using NvmlShutdown = int (*)();
    using NvmlHandleByIndex = int (*)(unsigned int, void **);
    using NvmlUtilization = int (*)(void *, void *);
    using NvmlMemory = int (*)(void *, void *);
    using NvmlDeviceGetCount = int (*)(unsigned int *);
    using NvmlTemperature = int (*)(void *, int, unsigned int *);
    using NvmlName = int (*)(void *, char *, unsigned int);

    NvmlInit nvmlInit = nullptr;
    NvmlShutdown nvmlShutdown = nullptr;
    NvmlHandleByIndex nvmlHandleByIndex = nullptr;
    NvmlUtilization nvmlUtilization = nullptr;
    NvmlMemory nvmlMemory = nullptr;
    NvmlDeviceGetCount nvmlDeviceGetCount = nullptr;
    NvmlTemperature nvmlTemperature = nullptr;
    NvmlName nvmlName = nullptr;
    void *m_nvmlDevice = nullptr;

    bool m_dgpuVisible = false;
    quint64 m_revision = 0;
};
