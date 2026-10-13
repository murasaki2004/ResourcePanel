#!/usr/bin/env bash
#
# Removes everything scripts/install.sh added:
#   * the applet package
#   * the native QML plugin, using the install manifest for exact paths
#
# Safe to run repeatedly: anything already absent is reported and skipped.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$SRC_DIR/plugin"
BUILD_DIR="$PLUGIN_DIR/build"
MANIFEST="$BUILD_DIR/install_manifest.txt"

PLASMOID_ID="org.murasaki.resourcepanel"
PLASMOID_DEST="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/$PLASMOID_ID"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# ── never run as root ────────────────────────────────────────────────────
# $HOME decides which applet package this script looks for, so under sudo it
# would hunt in root's home and leave the real one in place. Only removing the
# QML plugin needs root, and this script asks for that on its own.
if [ "$(id -u)" -eq 0 ]; then
    die "不要用 sudo 运行本脚本：\$HOME 会变成 /root，脚本将去错误的位置查找小程序包。
     请直接运行：make uninstall   （脚本只在移除 Qt 的 QML 插件时自己提权）"
fi

# ── plasmoid package ─────────────────────────────────────────────────────
info "移除 plasmoid 包"
if command -v kpackagetool6 >/dev/null; then
    if kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID" >/dev/null 2>&1; then
        info "已通过 kpackagetool6 移除"
    elif [ -d "$PLASMOID_DEST" ]; then
        rm -rf -- "$PLASMOID_DEST"
        info "已直接删除 $PLASMOID_DEST"
    else
        info "未安装，跳过"
    fi
elif [ -d "$PLASMOID_DEST" ]; then
    rm -rf -- "$PLASMOID_DEST"
    info "已直接删除 $PLASMOID_DEST"
else
    info "未安装，跳过"
fi

# ── native QML plugin ────────────────────────────────────────────────────
info "移除 QML 插件"
QML_DIR=""
if command -v qmake6 >/dev/null; then
    QML_DIR="$(qmake6 -query QT_INSTALL_QML 2>/dev/null || true)"
fi

need_root=0
[ -n "$QML_DIR" ] && [ ! -w "$QML_DIR" ] && need_root=1

SUDO=""
if [ "$need_root" -eq 1 ]; then
    if command -v sudo >/dev/null; then
        sudo -v || { warn "无法获取 sudo 权限，跳过插件移除"; exit 1; }
        SUDO="sudo"
    else
        warn "$QML_DIR 不可写且没有 sudo，跳过插件移除"
        exit 1
    fi
fi

if [ -f "$MANIFEST" ]; then
    # The CMake uninstall target uses the manifest, so it removes exactly what was
    # installed and prunes only directories that ended up empty.
    if [ -n "$SUDO" ]; then
        sudo cmake --build "$BUILD_DIR" --target uninstall
    else
        cmake --build "$BUILD_DIR" --target uninstall
    fi
else
    # No build tree: fall back to the one directory this project owns. Paths
    # are resolved and checked before anything is deleted.
    if [ -z "$QML_DIR" ]; then
        warn "找不到 qmake6，无法确定插件目录，跳过"
        exit 1
    fi
    target="$QML_DIR/org/murasaki/resourcepanel"
    case "$target" in
        */org/murasaki/resourcepanel) ;;
        *) warn "拒绝删除可疑路径: $target"; exit 1 ;;
    esac
    if [ -d "$target" ]; then
        if [ -n "$SUDO" ]; then
            sudo rm -rf -- "$target"
        else
            rm -rf -- "$target"
        fi
        info "已删除 $target"
        # Remove the parent only when this project was its sole content.
        parent="$QML_DIR/org/murasaki"
        if [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ]; then
            if [ -n "$SUDO" ]; then sudo rmdir -- "$parent"; else rmdir -- "$parent"; fi
            info "已删除空目录 $parent"
        fi
    else
        info "插件未安装，跳过"
    fi
fi

info "卸载完成"
cat <<EOF

重启 plasmashell 以应用更改：

    kquitapp6 plasmashell && kstart plasmashell
EOF
