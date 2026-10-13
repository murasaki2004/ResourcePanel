# Resource Panel — Plasma 6 applet with a native telemetry plugin.
#
#   make            build the QML plugin
#   make install    install plugin + applet (asks for sudo if needed)
#   make uninstall  remove both, using the install manifest
#   make preview    render the UI offscreen to test/states.png
#   make clean      drop build output

SHELL      := /bin/bash
ROOT       := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
PLUGIN_DIR := $(ROOT)plugin
TEST_DIR   := $(ROOT)test
BUILD_DIR  := $(PLUGIN_DIR)/build

QMAKE6 ?= qmake6
QML_DIR ?= $(shell $(QMAKE6) -query QT_INSTALL_QML 2>/dev/null)

.PHONY: all build install uninstall preview validate clean distclean

all: build

build:
	cmake -S $(PLUGIN_DIR) -B $(BUILD_DIR) -G Ninja \
	      -DCMAKE_BUILD_TYPE=Release \
	      -DRESOURCEPANEL_QML_DIR="$(QML_DIR)"
	cmake --build $(BUILD_DIR)

install:
	$(ROOT)scripts/install.sh

uninstall:
	$(ROOT)scripts/uninstall.sh

# Stage the freshly built module where the harnesses can import it.
stage: build
	@mkdir -p $(PLUGIN_DIR)/stage/org/murasaki/resourcepanel
	@cp $(BUILD_DIR)/libresourcepanel.so $(PLUGIN_DIR)/stage/org/murasaki/resourcepanel/
	@cp $(PLUGIN_DIR)/qmlmodule/qmldir $(PLUGIN_DIR)/stage/org/murasaki/resourcepanel/

# Loads the real contents/ui/main.qml against a mocked plasma API and asserts
# the load, the config wiring and the interactions. This is the check that
# catches errors a live plasmashell would only report in the journal.
validate: stage
	@cd $(TEST_DIR) && python3 make_mirror.py
	@cd $(TEST_DIR) && g++ -fPIC -std=c++20 validate_main.cpp -o validate_main \
	    $$(pkg-config --cflags --libs Qt6Core Qt6Qml Qt6Gui Qt6Quick)
	@cd $(TEST_DIR) && QT_QPA_PLATFORM=offscreen ./validate_main \
	    "$(PLUGIN_DIR)/stage" "$(TEST_DIR)/ui/validate.qml" \
	    "$(TEST_DIR)/applet.png"
	@echo "--- validate.log ---"
	@cat $(TEST_DIR)/validate.log

# Offscreen renders of the applet at four states: CPU/RAM, GPU/VRAM, settled
# GPU/VRAM, and the frozen mid-switch moment. Useful for reviewing UI changes
# without restarting plasmashell.
preview: stage
	@cd $(TEST_DIR) && python3 make_mirror.py
	cd $(TEST_DIR) && g++ -fPIC -std=c++20 variation_main.cpp -o variation_main \
	    $$(pkg-config --cflags --libs Qt6Core Qt6Qml Qt6Gui Qt6Quick)
	@cd $(TEST_DIR) && for g in 0 1 2 3; do \
	    QT_QPA_PLATFORM=offscreen ./variation_main \
	        "$(PLUGIN_DIR)/stage" "$(TEST_DIR)/variation_probe.qml" \
	        "$(TEST_DIR)/ui/TestStage.qml" \
	        "$(TEST_DIR)/st$$g.png" $$g >/dev/null 2>&1 || exit 1; \
	done
	@cd $(TEST_DIR) && magick montage st0.png st1.png st2.png st3.png \
	    -tile 2x2 -geometry +14+14 -background '#101215' states.png
	@echo "wrote $(TEST_DIR)/states.png"

clean:
	rm -rf $(BUILD_DIR) $(PLUGIN_DIR)/stage $(TEST_DIR)/ui
	rm -f $(TEST_DIR)/variation_main $(TEST_DIR)/validate_main
	rm -f $(TEST_DIR)/st*.png $(TEST_DIR)/states.png $(TEST_DIR)/applet.png
	rm -f $(TEST_DIR)/*.log

distclean: clean
	rm -rf $(PLUGIN_DIR)/build-test
