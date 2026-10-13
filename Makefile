# Convenience entry point.
#
# The project lives in resourcepanel/; this forwards the usual targets so
# `make install` works from the workspace root as well.

SHELL := /bin/bash
SUB   := resourcepanel

.PHONY: all build install uninstall validate preview clean distclean help

all build install uninstall validate preview clean distclean:
	@$(MAKE) --no-print-directory -C $(SUB) $@

help:
	@echo "Resource Panel targets (forwarded to $(SUB)/):"
	@echo "  make install    安装插件与小部件（必要时才问 sudo）"
	@echo "  make uninstall  卸载，使用安装清单精确删除"
	@echo "  make validate   用 mock plasma API 加载真实 main.qml 并断言"
	@echo "  make preview    离屏渲染四种状态到 test/states.png"
	@echo "  make build      只编译 QML 插件"
	@echo "  make clean      清理构建产物"
