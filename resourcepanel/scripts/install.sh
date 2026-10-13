#!/usr/bin/env bash
#
# Installs Resource Panel:
#   * the native QML plugin into Qt's own QML import directory (needs root,
#     because Qt only searches its install prefix for imported modules)
#   * the applet package into the current user's Plasma directory
#
# Everything is reversible with scripts/uninstall.sh.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$SRC_DIR/plugin"
PACKAGE_DIR="$SRC_DIR/package"
BUILD_DIR="$PLUGIN_DIR/build"

PLASMOID_ID="org.murasaki.resourcepanel"
PLASMOID_DEST="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# ── never run as root ────────────────────────────────────────────────────
# The applet is a per-user package and $HOME alone decides where it lands, so
# running this script under sudo would put it in root's home, where the desktop
# user's plasmashell never looks. Only the QML plugin needs root, and this
# script asks for that on its own.
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        die "不要用 sudo 运行本脚本。整个脚本会以 root 运行，小程序包会被装进
     /root/.local/share/plasma/plasmoids 而不是 $SUDO_USER 的家目录，plasmashell 将看不到它。
     请改用：make install    （脚本只在写 Qt 的 QML 目录时自己提权）"
    fi
    die "本脚本必须以桌面用户的身份运行，而不是 root：小程序包是每用户的，
     安装目的地由 \$HOME 决定，以 root 运行会让 plasmashell 看不到它。"
fi

# ── preflight ────────────────────────────────────────────────────────────
command -v cmake  >/dev/null || die "缺少 cmake"
command -v qmake6 >/dev/null || die "缺少 qmake6（请安装 qt6-base）"
command -v kpackagetool6 >/dev/null || die "缺少 kpackagetool6（请安装 kpackage）"

QML_DIR="$(qmake6 -query QT_INSTALL_QML)"
[ -n "$QML_DIR" ] || die "无法从 qmake6 获取 QT_INSTALL_QML"
MODULE_DIR="$QML_DIR/org/murasaki/resourcepanel"

info "Qt QML 模块目录: $MODULE_DIR"
info "Plasmoid 安装目录: $PLASMOID_DEST/$PLASMOID_ID"

# ── gather privileges once, and only if actually needed ───────────────────
SUDO=""
if [ ! -w "$QML_DIR" ]; then
    if command -v sudo >/dev/null; then
        info "安装 QML 插件需要 root 权限（$QML_DIR 不可写）"
        sudo -v || die "无法获取 sudo 权限"
        SUDO="sudo"
    else
        die "$QML_DIR 不可写，且没有 sudo。请先让 $QML_DIR 可写，再以普通用户运行本脚本。"
    fi
fi

# ── build ────────────────────────────────────────────────────────────────
info "配置并编译 QML 插件"
cmake -S "$PLUGIN_DIR" -B "$BUILD_DIR" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DRESOURCEPANEL_QML_DIR="$QML_DIR" \
      >/dev/null
cmake --build "$BUILD_DIR"

# ── install plugin ───────────────────────────────────────────────────────
info "安装 QML 插件"
if [ -n "$SUDO" ]; then
    sudo cmake --install "$BUILD_DIR"
    # cmake --install rewrites the manifest inside the build tree, so running it
    # under sudo would leave that one file owned by root and break later builds.
    manifest="$BUILD_DIR/install_manifest.txt"
    if [ -e "$manifest" ] && [ ! -O "$manifest" ]; then
        sudo chown "$(id -u):$(id -g)" "$manifest"
    fi
else
    cmake --install "$BUILD_DIR"
fi

# The install manifest is what uninstall.sh removes from; make sure it exists.
if [ ! -f "$BUILD_DIR/install_manifest.txt" ]; then
    warn "未生成 install_manifest.txt，卸载脚本将回退到按目录清理"
fi

# ── install plasmoid ─────────────────────────────────────────────────────
mkdir -p "$PLASMOID_DEST"
if [ -d "$PLASMOID_DEST/$PLASMOID_ID" ]; then
    info "已存在安装，先移除旧版本"
    kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID" >/dev/null 2>&1 || true
fi
info "安装 plasmoid 包"
kpackagetool6 --type Plasma/Applet --install "$PACKAGE_DIR"

# ── verify ───────────────────────────────────────────────────────────────
# Asking kpackagetool6 is what makes this check trustworthy: it reports the
# packages actually visible to this user, so a package that landed in some
# other home is caught instead of being confirmed against our own guess.
info "校验安装结果"
ok=1
[ -f "$MODULE_DIR/libresourcepanel.so" ] || { warn "缺少 libresourcepanel.so"; ok=0; }
[ -f "$MODULE_DIR/qmldir" ]              || { warn "缺少 qmldir"; ok=0; }
[ -d "$PLASMOID_DEST/$PLASMOID_ID" ]     || { warn "plasmoid 目录不存在: $PLASMOID_DEST/$PLASMOID_ID"; ok=0; }
kpackagetool6 --type Plasma/Applet --list 2>/dev/null | grep -qx "$PLASMOID_ID" \
    || { warn "kpackagetool6 看不到 $PLASMOID_ID，plasmashell 也不会看到它"; ok=0; }

if [ "$ok" -eq 1 ]; then
    info "安装完成"
else
    die "安装校验失败，请检查上面的警告"
fi

cat <<EOF

接下来需要重启 plasmashell 才能加载新的 QML 模块：

    kquitapp6 plasmashell && kstart plasmashell

然后右键面板 → 添加部件 → 搜索 “Resource Panel”。

卸载：
    $SRC_DIR/scripts/uninstall.sh
EOF
