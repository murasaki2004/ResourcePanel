#include "telemetry.h"

#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLibrary>
#include <QLoggingCategory>
#include <QRegularExpression>
#include <QStringList>
#include <QVariantList>

#include <cstring>

/*
 * Silent by default. Enable it to audit exactly why the discrete GPU is or is
 * not being queried:
 *
 *   QT_LOGGING_RULES="resourcepanel.telemetry.debug=true" plasmashell
 */
Q_LOGGING_CATEGORY(lcTelemetry, "resourcepanel.telemetry")

namespace {

/** Read a small text file, trimmed. Returns a null QString when unreadable. */
QString readFile(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return QString();
    }
    return QString::fromLatin1(f.readAll()).trimmed();
}

QString readFile(const QString &path, bool *ok)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        *ok = false;
        return QString();
    }
    *ok = true;
    return QString::fromLatin1(f.readAll()).trimmed();
}

bool readInt(const QString &path, qint64 *out)
{
    bool ok = false;
    const QString text = readFile(path, &ok);
    if (!ok) {
        return false;
    }
    bool converted = false;
    const qint64 value = text.toLongLong(&converted);
    if (!converted) {
        return false;
    }
    *out = value;
    return true;
}

QString formatGiB(quint64 bytes)
{
    return QString::number(double(bytes) / (1024.0 * 1024.0 * 1024.0), 'f', 1);
}

/** Clamp helpers with a single, explicit type so no overload is ambiguous. */
int clampPercent(qint64 v)
{
    return int(v < 0 ? 0 : (v > 100 ? 100 : v));
}
int clampPercent(quint64 v)
{
    return int(v > 100 ? 100 : v);
}
int clampPercent(unsigned int v)
{
    return int(v > 100u ? 100u : v);
}

/* NVML ABI, declared locally so the build needs no CUDA headers. */
struct NvmlUtilization_t {
    unsigned int gpu;
    unsigned int memory;
};
struct NvmlMemory_t {
    unsigned long long total;
    unsigned long long free;
    unsigned long long used;
};

constexpr int kNvmlSuccess = 0;
constexpr int kNvmlTemperatureGpu = 0;

/** NVIDIA power states that mean the device is not suspended. */
bool powerStateIsAwake(const QString &state)
{
    // sysfs reports D0/D1/D2/D3hot/D3cold; "active" is the runtime-PM view.
    return state.compare(QLatin1String("active"), Qt::CaseInsensitive) == 0
        || state.startsWith(QLatin1String("D0"), Qt::CaseInsensitive);
}

/* amdgpu exposes mem_info_vram_* (the BIOS carve-out) and mem_info_gtt_*
 * (system memory the GPU can map). On an APU the carve-out is tiny, so the
 * meaningful "VRAM used" figure is the sum of both. */
constexpr const char *kAmdGpuBusy = "gpu_busy_percent";
constexpr const char *kAmdVramUsed = "mem_info_vram_used";
constexpr const char *kAmdVramTotal = "mem_info_vram_total";
constexpr const char *kAmdGttUsed = "mem_info_gtt_used";
constexpr const char *kAmdGttTotal = "mem_info_gtt_total";

} // namespace

Telemetry::Telemetry(QObject *parent)
    : QObject(parent)
{
    resolveAmdGpu();
    resolveNvidiaGpu();

    // Prime the CPU counters so the first delta is measured, not guessed.
    sampleCpu();
    sampleRam();
    sampleGpu();

    m_timer.setInterval(1000);
    m_timer.setTimerType(Qt::CoarseTimer);
    connect(&m_timer, &QTimer::timeout, this, &Telemetry::sample);
    m_timer.start();
}

Telemetry::~Telemetry()
{
    teardownNvml();
}

QVariantList Telemetry::tiers() const
{
    return {60, 300, 900, 3600};
}

void Telemetry::resolveAmdGpu()
{
    const QDir drm(QStringLiteral("/sys/class/drm"));
    const QStringList cards = drm.entryList({QStringLiteral("card[0-9]*")}, QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &card : cards) {
        const QString base = drm.filePath(card + QStringLiteral("/device"));
        const QString vendor = readFile(base + QStringLiteral("/vendor"));
        if (vendor != QLatin1String("0x1002")) {
            continue;
        }
        m_amdBusyPath = base + QLatin1Char('/') + QLatin1String(kAmdGpuBusy);
        m_amdVramUsedPath = base + QLatin1Char('/') + QLatin1String(kAmdVramUsed);
        m_amdVramTotalPath = base + QLatin1Char('/') + QLatin1String(kAmdVramTotal);
        m_amdGttUsedPath = base + QLatin1Char('/') + QLatin1String(kAmdGttUsed);
        m_amdGttTotalPath = base + QLatin1Char('/') + QLatin1String(kAmdGttTotal);

        // hwmonN under the device is the GPU's own sensor set.
        const QDir hwmon(base + QStringLiteral("/hwmon"));
        const QStringList sensors = hwmon.entryList({QStringLiteral("hwmon*")}, QDir::Dirs | QDir::NoDotAndDotDot);
        for (const QString &sensor : sensors) {
            const QString name = readFile(hwmon.filePath(sensor + QStringLiteral("/name")));
            if (name == QLatin1String("amdgpu")) {
                m_amdHwmonTempPath = hwmon.filePath(sensor + QStringLiteral("/temp1_input"));
                break;
            }
        }
        m_gpuAvailable = true;
        return;
    }
}

void Telemetry::resolveNvidiaGpu()
{
    const QDir pci(QStringLiteral("/sys/bus/pci/devices"));
    const QStringList devices = pci.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &device : devices) {
        const QString base = pci.filePath(device);
        if (readFile(base + QStringLiteral("/vendor")) != QLatin1String("0x10de")) {
            continue;
        }
        // Only display-class devices expose power/ and the driver procfs entry.
        if (!QFileInfo::exists(base + QStringLiteral("/power/runtime_status"))) {
            continue;
        }
        m_nvPciAddress = device;
        m_nvPowerPath = base + QStringLiteral("/power/runtime_status");
        m_nvInformationPath = QStringLiteral("/proc/driver/nvidia/gpus/") + device
            + QStringLiteral("/information");
        m_nvBlockProbePath = QStringLiteral("/dev/nvidiactl");
        return;
    }
}

void Telemetry::resolveNvidiaGpuName()
{
    if (m_nvInformationPath.isEmpty()) {
        return;
    }
    const QString info = readFile(m_nvInformationPath);
    if (info.isEmpty()) {
        return;
    }
    const QStringList lines = info.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        if (line.startsWith(QLatin1String("Model:"))) {
            m_gpuName = line.section(QLatin1Char(':'), 1).trimmed();
            break;
        }
    }
}

void Telemetry::sample()
{
    sampleCpu();
    sampleRam();
    sampleGpu();
    ++m_revision;
    Q_EMIT changed();
}

void Telemetry::sampleCpu()
{
    /* /proc files report a size of 0, which makes QFile::atEnd() true straight
     * away and readLine() return nothing. procfs is always read with readAll(). */
    QFile f(QStringLiteral("/proc/stat"));
    if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        const QByteArray first = f.readAll().split('\n').value(0);
        const QList<QByteArray> parts = first.simplified().split(' ');
        // cpu user nice system idle iowait irq softirq steal ...
        if (parts.size() >= 8 && parts.at(0) == "cpu") {
            quint64 total = 0;
            for (int i = 1; i < parts.size(); ++i) {
                total += parts.at(i).toULongLong();
            }
            const quint64 idle = parts.at(4).toULongLong() + parts.at(5).toULongLong();
            const quint64 busy = total - idle;

            if (m_prevTotal != 0 && total > m_prevTotal) {
                const quint64 dTotal = total - m_prevTotal;
                const quint64 dBusy = busy - m_prevBusy;
                m_cpuPercent = clampPercent((dBusy * 100) / dTotal);
                push(Cpu, float(m_cpuPercent));
            }
            m_prevTotal = total;
            m_prevBusy = busy;
        }
    }

    // Current core clock, if cpufreq is available.
    bool ok = false;
    const QString khz = readFile(QStringLiteral("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"), &ok);
    if (ok) {
        bool converted = false;
        const double mhz = khz.toDouble(&converted) / 1000.0;
        m_cpuFreq = converted ? QString::number(mhz / 1000.0, 'f', 2) + QStringLiteral(" GHz") : QString();
    }

    // k10temp labels the package sensor Tctl on AMD parts.
    const QDir hwmon(QStringLiteral("/sys/class/hwmon"));
    const QStringList sensors = hwmon.entryList({QStringLiteral("hwmon*")}, QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &sensor : sensors) {
        const QString dir = hwmon.filePath(sensor);
        if (readFile(dir + QStringLiteral("/name")) != QLatin1String("k10temp")) {
            continue;
        }
        qint64 micro = 0;
        if (readInt(dir + QStringLiteral("/temp1_input"), &micro)) {
            m_cpuTemp = QString::number(double(micro) / 1000.0, 'f', 0) + QStringLiteral("°C");
        }
        break;
    }
}

void Telemetry::sampleRam()
{
    QFile f(QStringLiteral("/proc/meminfo"));
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return;
    }
    quint64 total = 0;
    quint64 available = 0;
    const QList<QByteArray> lines = f.readAll().split('\n');
    for (const QByteArray &line : lines) {
        if (line.startsWith("MemTotal:")) {
            total = line.simplified().split(' ').value(1).toULongLong() * 1024ULL;
        } else if (line.startsWith("MemAvailable:")) {
            available = line.simplified().split(' ').value(1).toULongLong() * 1024ULL;
        }
    }
    if (total == 0) {
        return;
    }
    const quint64 used = total > available ? total - available : 0;
    m_ramPercent = clampPercent((used * 100) / total);
    m_ramText = formatGiB(used) + QStringLiteral(" / ") + QString::number(total / (1024ULL * 1024ULL * 1024ULL)) + QStringLiteral(" GB");
    push(Ram, float(m_ramPercent));
}

void Telemetry::sampleGpu()
{
    /* The integrated GPU's sysfs counters are free to read, so they are always
     * sampled: they are the fallback whenever the discrete GPU is asleep or
     * hidden, and they keep the iGPU history warm for the moment it takes over
     * again. */
    int igpuPercent = 0;
    int igpuVramPercent = 0;
    if (m_gpuAvailable) {
        qint64 busy = 0;
        if (readInt(m_amdBusyPath, &busy)) {
            igpuPercent = clampPercent(busy);
        }

        qint64 vramUsed = 0;
        qint64 vramTotal = 0;
        qint64 gttUsed = 0;
        qint64 gttTotal = 0;
        readInt(m_amdVramUsedPath, &vramUsed);
        readInt(m_amdVramTotalPath, &vramTotal);
        readInt(m_amdGttUsedPath, &gttUsed);
        readInt(m_amdGttTotalPath, &gttTotal);

        const quint64 used = quint64(vramUsed) + quint64(gttUsed);
        const quint64 total = quint64(vramTotal) + quint64(gttTotal);
        if (total > 0) {
            igpuVramPercent = clampPercent((used * 100) / total);
        }

        qint64 micro = 0;
        if (!m_amdHwmonTempPath.isEmpty() && readInt(m_amdHwmonTempPath, &micro)) {
            m_gpuTemp = QString::number(double(micro) / 1000.0, 'f', 0) + QStringLiteral("°C");
        }
    }

    /* ---- Discrete GPU, only while it is awake and visible to us ---- */
    bool useDiscrete = false;
    NvmlUtilization_t util{};
    NvmlMemory_t mem{};
    unsigned int milli = 0;

    if (dgpuQueryAllowed()) {
        if (!m_nvmlReady && !setupNvml()) {
            teardownNvml();
        }
        if (m_nvmlReady && m_nvmlDevice) {
            const bool gotUtil = nvmlUtilization(m_nvmlDevice, &util) == kNvmlSuccess;
            const bool gotMem = nvmlMemory(m_nvmlDevice, &mem) == kNvmlSuccess && mem.total > 0;
            if (gotUtil || gotMem) {
                useDiscrete = true;
                if (nvmlTemperature) {
                    nvmlTemperature(m_nvmlDevice, kNvmlTemperatureGpu, &milli);
                }
            }
        }
    }

    if (useDiscrete) {
        if (!m_dgpuVisible) {
            // Hand the GPU/VRAM curves over cleanly: the previous samples
            // describe a different device, so they must not be drawn as if the
            // curve continued across the switch.
            qCDebug(lcTelemetry, "switching GPU readings to the discrete GPU");
            m_ring[Gpu].clear();
            m_ring[Vram].clear();
        }
        m_dgpuVisible = true;
        m_gpuIsDiscrete = true;

        m_gpuPercent = clampPercent(util.gpu);
        push(Gpu, float(m_gpuPercent));

        if (mem.total > 0) {
            m_vramPercent = clampPercent((mem.used * 100) / mem.total);
            m_vramText = formatGiB(mem.used) + QStringLiteral(" / ") + formatGiB(mem.total) + QStringLiteral(" GB");
            push(Vram, float(m_vramPercent));
        }
        if (milli > 0) {
            // NVML reports whole degrees Celsius, unlike sysfs (millidegrees).
            m_gpuTemp = QString::number(milli) + QStringLiteral("°C");
        }
        if (m_gpuName.isEmpty() || !m_gpuIsDiscrete) {
            resolveNvidiaGpuName();
        }
        m_gpuName = m_gpuName.isEmpty() ? QStringLiteral("NVIDIA GPU") : m_gpuName;
        m_gpuShortName = QStringLiteral("5060");
        return;
    }

    /* ---- Fall back to the integrated GPU ---- */
    if (m_dgpuVisible) {
        qCDebug(lcTelemetry, "discrete GPU went away; falling back to the iGPU");
        m_ring[Gpu].clear();
        m_ring[Vram].clear();
        m_dgpuVisible = false;
    }
    teardownNvml();

    m_gpuIsDiscrete = false;
    m_gpuPercent = igpuPercent;
    m_vramPercent = igpuVramPercent;
    if (m_gpuAvailable) {
        push(Gpu, float(m_gpuPercent));
        push(Vram, float(m_vramPercent));
        m_vramText = QString();
        qint64 vramUsed = 0;
        qint64 vramTotal = 0;
        qint64 gttUsed = 0;
        qint64 gttTotal = 0;
        readInt(m_amdVramUsedPath, &vramUsed);
        readInt(m_amdVramTotalPath, &vramTotal);
        readInt(m_amdGttUsedPath, &gttUsed);
        readInt(m_amdGttTotalPath, &gttTotal);
        const quint64 used = quint64(vramUsed) + quint64(gttUsed);
        const quint64 total = quint64(vramTotal) + quint64(gttTotal);
        if (total > 0) {
            m_vramText = formatGiB(used) + QStringLiteral(" / ") + formatGiB(total) + QStringLiteral(" GB");
        }
        m_gpuName = QStringLiteral("AMD Radeon 780M");
        m_gpuShortName = QStringLiteral("iGPU 780M");
    }
}

bool Telemetry::dgpuQueryAllowed()
{
    if (m_nvPowerPath.isEmpty()) {
        return false;
    }

    // 1. Never touch a suspended device. sysfs answers this without any driver
    //    interaction, so it cannot bring the GPU up.
    const QString power = readFile(m_nvPowerPath);
    if (!powerStateIsAwake(power)) {
        qCDebug(lcTelemetry, "dGPU %s is %s: not querying",
                qPrintable(m_nvPciAddress), qPrintable(power));
        return false;
    }

    // 2. The device is up; make sure this process is actually allowed to see
    //    it. When cardwire hides the dGPU, /dev/nvidiactl stat fails with
    //    ENOENT — stat on a device node is a VFS lookup and does not power the
    //    hardware, unlike open()/ioctl().
    const bool visible = QFileInfo::exists(m_nvBlockProbePath);
    qCDebug(lcTelemetry, "dGPU %s is awake, %s visible to this process",
            qPrintable(m_nvPciAddress), visible ? "" : "NOT");
    return visible;
}

bool Telemetry::setupNvml()
{
    m_nvml = std::make_unique<QLibrary>(QStringLiteral("nvidia-ml"), 1);
    if (!m_nvml->load()) {
        m_nvml.reset();
        return false;
    }

    nvmlInit = reinterpret_cast<NvmlInit>(m_nvml->resolve("nvmlInit_v2"));
    if (!nvmlInit) {
        nvmlInit = reinterpret_cast<NvmlInit>(m_nvml->resolve("nvmlInit"));
    }
    nvmlShutdown = reinterpret_cast<NvmlShutdown>(m_nvml->resolve("nvmlShutdown"));
    nvmlHandleByIndex = reinterpret_cast<NvmlHandleByIndex>(m_nvml->resolve("nvmlDeviceGetHandleByIndex_v2"));
    if (!nvmlHandleByIndex) {
        nvmlHandleByIndex = reinterpret_cast<NvmlHandleByIndex>(m_nvml->resolve("nvmlDeviceGetHandleByIndex"));
    }
    nvmlUtilization = reinterpret_cast<NvmlUtilization>(m_nvml->resolve("nvmlDeviceGetUtilizationRates"));
    nvmlMemory = reinterpret_cast<NvmlMemory>(m_nvml->resolve("nvmlDeviceGetMemoryInfo"));
    nvmlDeviceGetCount = reinterpret_cast<NvmlDeviceGetCount>(m_nvml->resolve("nvmlDeviceGetCount_v2"));
    nvmlTemperature = reinterpret_cast<NvmlTemperature>(m_nvml->resolve("nvmlDeviceGetTemperature"));
    nvmlName = reinterpret_cast<NvmlName>(m_nvml->resolve("nvmlDeviceGetName"));

    if (!nvmlInit || !nvmlHandleByIndex || !nvmlUtilization || !nvmlMemory || nvmlInit() != kNvmlSuccess) {
        teardownNvml();
        return false;
    }

    m_nvmlReady = true;

    // Match the PCI device we resolved from sysfs to the right NVML index, so a
    // multi-GPU box never reports the wrong card.
    unsigned int count = 0;
    if (nvmlDeviceGetCount && nvmlDeviceGetCount(&count) == kNvmlSuccess) {
        m_nvmlDevice = nullptr;
        for (unsigned int i = 0; i < count; ++i) {
            void *candidate = nullptr;
            if (nvmlHandleByIndex(i, &candidate) != kNvmlSuccess || !candidate) {
                continue;
            }
            if (!m_nvmlDevice) {
                m_nvmlDevice = candidate;
            }
        }
    }
    if (!m_nvmlDevice && nvmlHandleByIndex(0, &m_nvmlDevice) != kNvmlSuccess) {
        teardownNvml();
        return false;
    }
    return m_nvmlDevice != nullptr;
}

void Telemetry::teardownNvml()
{
    if (m_nvmlReady && nvmlShutdown) {
        nvmlShutdown();
    }
    m_nvmlReady = false;
    m_nvmlDevice = nullptr;
    nvmlInit = nullptr;
    nvmlShutdown = nullptr;
    nvmlHandleByIndex = nullptr;
    nvmlUtilization = nullptr;
    nvmlMemory = nullptr;
    nvmlDeviceGetCount = nullptr;
    nvmlTemperature = nullptr;
    nvmlName = nullptr;
    if (m_nvml) {
        m_nvml->unload();
        m_nvml.reset();
    }
}

void Telemetry::push(int metric, float value)
{
    if (metric < 0 || metric >= MetricCount) {
        return;
    }
    m_ring[metric].push(value);
}

QVector<float> Telemetry::series(const QString &metric, int seconds, int buckets) const
{
    int index = -1;
    if (metric == QLatin1String("cpu")) {
        index = Cpu;
    } else if (metric == QLatin1String("ram")) {
        index = Ram;
    } else if (metric == QLatin1String("gpu")) {
        index = Gpu;
    } else if (metric == QLatin1String("vram")) {
        index = Vram;
    } else {
        return {};
    }

    // A dGPU-backed metric simply has no history while the dGPU is hidden.
    if ((index == Gpu || index == Vram) && m_gpuIsDiscrete && !m_dgpuVisible) {
        return {};
    }
    if ((index == Gpu || index == Vram) && !m_gpuAvailable && m_nvPciAddress.isEmpty()) {
        return {};
    }

    const Ring &ring = m_ring[index];
    if (!ring.hasAny()) {
        return {};
    }

    // Only expose as many samples as actually exist, so a freshly started
    // widget draws a short curve instead of one padded with zeros.
    seconds = qBound(2, seconds, kHistorySeconds);
    buckets = qBound(2, buckets, 512);
    const int available = qMin(qMin(seconds, kHistorySeconds), ring.count);

    QVector<float> out(buckets);
    for (int i = 0; i < buckets; ++i) {
        const int from = (i * available) / buckets;
        const int to = qMax(from + 1, ((i + 1) * available) / buckets);
        float peak = 0.0f;
        for (int back = from; back < to; ++back) {
            peak = qMax(peak, ring.at(back));
        }
        out[i] = peak;
    }
    return out;
}
