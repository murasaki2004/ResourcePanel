# Resource Panel

一个 KDE Plasma 6 面板小部件，以成对的同心圆环显示 **CPU / RAM** 与 **GPU / VRAM**，并在下方绘制当前一对的历史曲线。

为一台双显卡笔记本（AMD Radeon 780M + NVIDIA RTX 5060）打造，配合 [cardwire](https://github.com/OpenGamingCollective/cardwire) 使用，并且设计上保证它自己绝不会唤醒独立显卡。

![states](resourcepanel/test/states.png)

*左上：CPU+RAM · 右上：GPU+VRAM · 左下：稳定后的 GPU+VRAM ·
右下：切换中途定格，弧线收回，轨道已换上新配色。*

## 行为

- **成对圆环。** CPU 在外 / RAM 在内，或 GPU 在外 / VRAM 在内。圆环中央只显示指标名称——绝不显示数字。
- **切换动画。** 点击圆环循环切换分组。弧线先排空，轨道与标签在圆环可见为空时换上新的配色，然后弧线再缓动回升到实时数值。
- **历史曲线。** 坐标轴、网格线和标签与曲线相互独立，因此切换分组、指标或时间范围时只重绘曲线——坐标系纹丝不动。只绘制当前激活的一对。
- **自适应量程。** 固定的 0–100% 坐标轴会把寻常读数压扁在图底部，因此坐标轴向上吸附到比最忙碌曲线高一档的整数刻度，并且只在有曲线出现在屏幕上时才随之增长。
- **单行数值。** 所有当前数值都排在图下方的一行里。激活的一对高亮显示；其余的保持可读但退居其后。
- **时间范围。** 1m / 5m / 15m / 1h，可通过按钮或滚轮切换。
- **整体缩放。** 布局绘制在一块固定画布上，整块画布按比例缩放到部件大小，因此调整尺寸时圆环、曲线图和文字一同放大，而不是把内容遗弃在一个更大的空框里。宽高比不同的部件会让画布上下留边（letterbox）而不是拉伸变形，圆环永远不会变成椭圆。

## 独立显卡只在它本来就醒着时才会被读取

这是省电时最要紧的部分。插件恪守一条规则：

> 独立显卡只有在**已经**处于 `D0`/`active` **且** 本进程被允许看见它时，才会被查询。

`Telemetry::dgpuQueryAllowed()` 要通过两道门，两道门都不可能把设备唤醒：

1. **电源状态。** `/sys/bus/pci/devices/<pci>/power/runtime_status` 是普通的 sysfs 属性。读它不触碰驱动，所以检查一颗休眠中的 GPU 不产生任何代价。
2. **可见性。** 对 `/dev/nvidiactl` 的 `stat()` 是一次 VFS 查找。cardwire 的 eBPF 钩子在 GPU 被屏蔽时以 `ENOENT` 应答它，而只有 `open()` 或 `ioctl()` 才会触达驱动。因此一次探测不可能把 GPU 从 `D3cold` 拉出来。

任何一道门不通过，就什么都不查询。NVML 根本不会被加载：只有两道门都通过之后才用 `dlopen` 解析该库，GPU 一消失就立刻卸载。从不调用 `nvidia-smi`。

你能注意到的后果：

- 独立显卡休眠或被隐藏时，GPU/VRAM 组显示的是**核显 780M**，标题徽标读作 `iGPU 780M`。
- 独立显卡一旦可用，该组立即切到它，并且**两条 GPU 曲线都会清空**。之前的采样描述的是另一颗设备，把它们画成一条连续曲线就是撒谎。
- 对被隐藏的 dGPU，`series()` 返回空列表，小部件据此跳过整条曲线。

### 在本机验证过

独立显卡休眠时，轮询 3.5 秒（五次门检查）后它未被唤醒：

| | 之前 | 之后 |
|---|---|---|
| `runtime_status` | `suspended` | `suspended` |
| `runtime_active_time` | 29320 ms | 29320 ms |
| `runtime_suspended_time` | 316712 ms | 320971 ms |

active-time 计数没有变化，说明 GPU 从未被唤醒。启用日志分类可以实时观察这一判定：

```sh
QT_LOGGING_RULES="resourcepanel.telemetry.debug=true" plasmashell
# dGPU 0000:01:00.0 is suspended: not querying
```

### 核显 VRAM 的计算

在 APU 上，`mem_info_vram_total` 只报告 BIOS 划出的保留区（这里是 512 MB），会让圆环看起来永远接近满格。因此 VRAM 取 `mem_info_vram_used + mem_info_gtt_used` 除以 `mem_info_vram_total + mem_info_gtt_total`，反映 iGPU 实际能分配的量。

## 布局

| | |
|---|---|
| 画布 | `Kirigami.Units.gridUnit * 21` 宽，2.16:1（≈380 × 176 px） |
| 尺寸 | 画布作为整体缩放到部件的实际大小 |
| 圆环 | 外环 Ø109，内环 Ø82，9 px 描边 |
| 采样 | 1 Hz，保留 3600 个样本（1 小时） |
| 数据源 | `/proc/stat`、`/proc/meminfo`、amdgpu sysfs、NVML（有门控） |

小部件自身不绘制背景（卡片除外）：它请求 `BackgroundHints::NoBackground`，所以在桌面上是卡片直接坐在壁纸上，而不是卡片嵌在第二层主题绘制的框里。

## 安装

原生插件必须放进 Qt 自己的 QML import 目录：Qt 解析 `import` 时参照它的安装前缀（以及 app 目录 / `qrc:`），而 KDE 包无法携带编译好的模块。小部件包本身按用户安装。

```sh
make install      # 编译插件、安装插件、安装小部件
kquitapp6 plasmashell && kstart plasmashell
```

然后在面板上右键 → *添加部件* → 搜索 **Resource Panel**。

请以你自己的用户身份运行——绝不要 `sudo make install`。小部件是按用户安装的包，目标路径来自 `$HOME`，在 sudo 下会装进 root 的家目录，而你的 plasmashell 根本不会去那里找。只有 QML 插件需要 root，脚本会自己提出请求。

`make install` 只在 QML 目录不可写时才要求 `sudo`，并在报告成功之前用 `kpackagetool6 --list` 校验结果。

## 卸载

```sh
make uninstall    # 或 scripts/uninstall.sh
kquitapp6 plasmashell && kstart plasmashell
```

卸载走 CMake 安装清单，因此精确删除当初添加的两个文件——`libresourcepanel.so` 和 `qmldir`——然后仅在该目录为空时才清理模块目录。小部件包用 `kpackagetool6` 移除。脚本可以安全地重复执行，对已经不存在的文件会如实报告而不是报错。

要在不重启面板的情况下预览 UI 改动：

```sh
make preview      # 把四种状态离屏渲染到 test/states.png
```

## 配置

`contents/config/main.xml` 持久化分组和时间范围，小部件会按上次离开时的视图重新打开。设置页还可以选择启动时的默认分组和历史窗口。

## 开发

`make validate` 用一份 mock 的 plasma API 加载**真实的** `contents/ui/main.qml`，并断言它能实例化、采纳持久化配置、并响应交互：

```
PASS main.qml instantiates
PASS timeRange adopted from config  (300)
PASS activeGroup adopted from config  (0)
PASS outer metric is cpu  (cpu)
PASS inner metric is ram  (ram)
PASS cycleTier advances to 15m  (900)
PASS cycleTier steps back to 5m  (300)
PASS cycleGroup stays on CPU/RAM when no dGPU  (gpuGroupUsable=1 activeGroup=1)
VALIDATION PASSED
```

`test/make_mirror.py` 构建 `test/ui/`：拷贝小部件的 UI 文件并只改写一行——plasma API 的 import，指向 `MockPlasma.qml`。其余分毫不动，被测文件与最终安装的文件逐字节相同，发布的包里不混入任何仅开发用的文件。任何 UI 修改之后都值得跑一遍：它能捕获 plasmashell 只有在 journal 里才报得出来的那类错误。

`make preview` 把四种状态离屏渲染到 `test/states.png`（CPU/RAM、GPU/VRAM、稳定后的 GPU/VRAM、以及切换中途定格的瞬间），UI 工作无需重启面板即可评审。

## 后续改动注意事项

- `/proc` 文件报告的大小为 0，这让 `QFile::atEnd()` 立刻返回 true。所有 procfs 读取必须用 `readAll()`。
- `HistoryChart` 依据后端的 `revision` 计数器拉取曲线，而不是绑定到它们：两次连续的空曲线相等，绑定一旦在第一个样本到来前求值就永远不会重新求值。
- `gpuGroupUsable` 是 `readonly`，没有变更信号——用 `Connections` 块响应它，不要用 `on...Changed` 处理器。
- Repeater 的 model 保持为稳定值（`root.metricOrder`），不要用内联数组字面量；重建字面量会让每个 delegate 都折腾一遍。
- 避免把属性命名为 `palette`：它会遮蔽 `Item` 的内建属性并产生警告。强调色映射表叫 `metricColors`。
- 画布内的每个尺寸都用画布单位；只有 `content.canvasWidth`、`canvasHeight` 和 `canvasScale` 知道部件的实际大小。在卡片内部添加部件尺寸相关的常量会破坏缩放。
- 因为画布经 transform 缩放，它的两个 `Canvas` 绘图若不加处理会先按画布尺寸光栅化再放大。`HistoryChart` 因此接收 `renderScale`，按实际绘制尺寸渲染。
- `backgroundHints` 用数值常量设置而不是 `PlasmaCore.Types.NoBackground`：没有运行中的 Plasma 会话时 `org.kde.plasma.core` 无法加载，而离屏 harness 只刻意 mock plasma 这一个 import。`validate_main.cpp` 会断言这个标志位，而 mock 的默认值是 Plasma 的 `DefaultBackground`，所以断言只有当 `main.qml` 真的设置过它时才可能通过。
- `TestStage.source.qml` 是仅供预览的渲染目标。`make_mirror.py` 把它放到 `test/ui/TestStage.qml`，与它绘制的组件并列；它绝不会被安装。
