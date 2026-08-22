# Cowsaver — build with Xcode Command Line Tools; no Xcode project is required.

SWIFT           ?= swift
SWIFTC          ?= swiftc
SOURCES_DIR     := Sources
KIT_DIR         := $(SOURCES_DIR)/CowsayKit
CONFIG          ?= debug
BIN             := .build/$(CONFIG)/cowsaver-cli

VERSION         := 1.0.0
SAVER           := Cowsaver.saver
APP             := Cowsaver.app
BUILD_DIR       := build
INSTALL_DIR     := $(HOME)/Library/Screen Savers

# Keep the deployment target independent of the macOS version used for the build.
TARGET_TRIPLE   := $(shell uname -m)-apple-macosx13.0

# The products' modules are built separately and linked statically. Separate modules retain
# their import boundaries, while product-specific intermediate directories make parallel
# cleanup and compilation safe.
SAVER_MODULES_DIR := $(BUILD_DIR)/modules/saver
APP_MODULES_DIR   := $(BUILD_DIR)/modules/app
KIT_SOURCES       := $(wildcard $(SOURCES_DIR)/CowsayKit/*.swift)
RENDER_SOURCES    := $(wildcard $(SOURCES_DIR)/CowsaverRender/*.swift)
SAVER_SOURCES     := $(wildcard $(SOURCES_DIR)/CowsaverSaver/*.swift)
APP_SUPPORT_SOURCES := $(wildcard $(SOURCES_DIR)/CowsaverAppSupport/*.swift)
APP_SOURCES       := $(wildcard $(SOURCES_DIR)/CowsaverApp/*.swift)
SWIFTC_FLAGS      := -target $(TARGET_TRIPLE) -O -wmo

# Stamped into Info.plist so a bug report can identify the environment that produced a
# bundle, rather than asking a reporter to reconstruct it from memory.
BUILD_OS        := $(shell sw_vers -productVersion) ($(shell sw_vers -buildVersion))
BUILD_CLT       := $(shell pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | awk '/^version:/{print $$2}')
BUILD_SWIFT     := $(shell $(SWIFTC) --version 2>/dev/null | head -1)
BUILD_COMMIT    := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

# Frameworks excluded from the rendering surface and checked by `make check`.
GPU_FRAMEWORKS  := Metal|MetalKit|SceneKit|SpriteKit|WebKit|GLKit|OpenGL|OpenGLES

# CowsayKit is Foundation-only, so the renderer core remains portable and independently testable.
KIT_FORBIDDEN   := AppKit|Cocoa|ScreenSaver|CoreGraphics|QuartzCore|SwiftUI
IOKIT_BOUNDARY_DIRS := $(SOURCES_DIR)/CowsaverRender $(SOURCES_DIR)/CowsaverSaver

IMPORT_RE       := ^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+

.PHONY: all saver app cli test smoke test-diagnostics check golden import-fortunes install uninstall doctor clean

all: saver app

# --- The screensaver bundle ---------------------------------------------------------
#
# SwiftPM has no product type for a legacy `.saver` bundle, so this target assembles the
# bundle from `swiftc` output. The build inputs remain ordinary text files.

saver: check
	@echo "==> building $(SAVER)"
	@rm -rf "$(BUILD_DIR)/$(SAVER)" "$(SAVER_MODULES_DIR)"
	@mkdir -p "$(BUILD_DIR)/$(SAVER)/Contents/MacOS" "$(BUILD_DIR)/$(SAVER)/Contents/Resources" "$(SAVER_MODULES_DIR)"
	@echo "  -> CowsayKit"
	@$(SWIFTC) $(SWIFTC_FLAGS) -module-cache-path "$(SAVER_MODULES_DIR)/module-cache" -module-name CowsayKit \
		-emit-module -emit-module-path "$(SAVER_MODULES_DIR)/CowsayKit.swiftmodule" \
		-emit-object -o "$(SAVER_MODULES_DIR)/CowsayKit.o" $(KIT_SOURCES)
	@echo "  -> CowsaverRender"
	@$(SWIFTC) $(SWIFTC_FLAGS) -module-cache-path "$(SAVER_MODULES_DIR)/module-cache" -module-name CowsaverRender -I "$(SAVER_MODULES_DIR)" \
		-emit-module -emit-module-path "$(SAVER_MODULES_DIR)/CowsaverRender.swiftmodule" \
		-emit-object -o "$(SAVER_MODULES_DIR)/CowsaverRender.o" $(RENDER_SOURCES)
	@echo "  -> CowsaverSaver (bundle)"
	@$(SWIFTC) $(SWIFTC_FLAGS) -module-cache-path "$(SAVER_MODULES_DIR)/module-cache" -module-name CowsaverSaver -I "$(SAVER_MODULES_DIR)" \
		-emit-library -Xlinker -bundle \
		-o "$(BUILD_DIR)/$(SAVER)/Contents/MacOS/Cowsaver" \
		"$(SAVER_MODULES_DIR)/CowsayKit.o" "$(SAVER_MODULES_DIR)/CowsaverRender.o" $(SAVER_SOURCES)
	# Swift may weak-link libswiftIOKit through Foundation-generated linker options without a source import; the source check and direct framework absence define this boundary.
	@if otool -L "$(BUILD_DIR)/$(SAVER)/Contents/MacOS/Cowsaver" | grep -E '^[[:space:]]+/System/Library/Frameworks/IOKit\.framework/.*/IOKit[[:space:]]'; then \
		echo "ERROR: the saver must not directly link IOKit.framework."; \
		exit 1; \
	fi
	@cp -R Resources/cows Resources/fortune-curated "$(BUILD_DIR)/$(SAVER)/Contents/Resources/"
	@sed -e 's|__VERSION__|$(VERSION)|g' \
	     -e 's|__BUILD_OS__|$(BUILD_OS)|g' \
	     -e 's|__BUILD_CLT__|$(BUILD_CLT)|g' \
	     -e 's|__BUILD_SWIFT__|$(BUILD_SWIFT)|g' \
	     -e 's|__BUILD_COMMIT__|$(BUILD_COMMIT)|g' \
	     Resources/Info.plist > "$(BUILD_DIR)/$(SAVER)/Contents/Info.plist"
	@plutil -lint "$(BUILD_DIR)/$(SAVER)/Contents/Info.plist" >/dev/null
	@echo "==> built $(BUILD_DIR)/$(SAVER)"

# --- The standalone app -------------------------------------------------------------
#
# The standalone front end supports development, offscreen rendering tests, and manual
# fullscreen display. It imports no ScreenSaver APIs and does not participate in screen lock.

app: check
	@echo "==> building $(APP)"
	@rm -rf "$(BUILD_DIR)/$(APP)" "$(APP_MODULES_DIR)"
	@mkdir -p "$(BUILD_DIR)/$(APP)/Contents/MacOS" "$(BUILD_DIR)/$(APP)/Contents/Resources" "$(APP_MODULES_DIR)"
	@$(SWIFTC) $(SWIFTC_FLAGS) -module-cache-path "$(APP_MODULES_DIR)/module-cache" -module-name CowsayKit \
		-emit-module -emit-module-path "$(APP_MODULES_DIR)/CowsayKit.swiftmodule" \
		-emit-object -o "$(APP_MODULES_DIR)/CowsayKit.o" $(KIT_SOURCES)
	@$(SWIFTC) $(SWIFTC_FLAGS) -module-cache-path "$(APP_MODULES_DIR)/module-cache" -module-name CowsaverRender -I "$(APP_MODULES_DIR)" \
		-emit-module -emit-module-path "$(APP_MODULES_DIR)/CowsaverRender.swiftmodule" \
		-emit-object -o "$(APP_MODULES_DIR)/CowsaverRender.o" $(RENDER_SOURCES)
	@$(SWIFTC) $(SWIFTC_FLAGS) -parse-as-library -module-cache-path "$(APP_MODULES_DIR)/module-cache" -module-name CowsaverAppSupport \
		-emit-module -emit-module-path "$(APP_MODULES_DIR)/CowsaverAppSupport.swiftmodule" \
		-emit-object -o "$(APP_MODULES_DIR)/CowsaverAppSupport.o" $(APP_SUPPORT_SOURCES)
	@$(SWIFTC) $(SWIFTC_FLAGS) -module-cache-path "$(APP_MODULES_DIR)/module-cache" -module-name CowsaverApp -I "$(APP_MODULES_DIR)" \
		-o "$(BUILD_DIR)/$(APP)/Contents/MacOS/Cowsaver" \
		"$(APP_MODULES_DIR)/CowsayKit.o" "$(APP_MODULES_DIR)/CowsaverRender.o" "$(APP_MODULES_DIR)/CowsaverAppSupport.o" $(APP_SOURCES)
	@cp -R Resources/cows Resources/fortune-curated "$(BUILD_DIR)/$(APP)/Contents/Resources/"
	@sed -e 's|__VERSION__|$(VERSION)|g' \
	     -e 's|__BUILD_OS__|$(BUILD_OS)|g' \
	     -e 's|__BUILD_CLT__|$(BUILD_CLT)|g' \
	     -e 's|__BUILD_SWIFT__|$(BUILD_SWIFT)|g' \
	     -e 's|__BUILD_COMMIT__|$(BUILD_COMMIT)|g' \
	     Resources/App-Info.plist > "$(BUILD_DIR)/$(APP)/Contents/Info.plist"
	@plutil -lint "$(BUILD_DIR)/$(APP)/Contents/Info.plist" >/dev/null
	@echo "==> built $(BUILD_DIR)/$(APP)"
	@echo "    Try it: ./$(BUILD_DIR)/$(APP)/Contents/MacOS/Cowsaver --window"

install: saver
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_DIR)/$(SAVER)"
	@cp -R "$(BUILD_DIR)/$(SAVER)" "$(INSTALL_DIR)/"
	@echo "==> installed to $(INSTALL_DIR)/$(SAVER)"
	@echo "    Open System Settings > Wallpaper > Screen Saver to select it."
	@echo "    (Screen Saver is no longer its own pane; it opens from Wallpaper.)"

uninstall:
	@rm -rf "$(INSTALL_DIR)/$(SAVER)"
	@echo "==> removed $(INSTALL_DIR)/$(SAVER)"

# Prints the build environment against the running one. Every bug report should start
# here: a screensaver built on one macOS can fail on another through no fault of the code.
doctor:
	@echo "running macOS:   $$(sw_vers -productVersion) ($$(sw_vers -buildVersion))"
	@echo "running arch:    $$(uname -m)"
	@echo "CLT version:     $(BUILD_CLT)"
	@echo "swiftc:          $(BUILD_SWIFT)"
	@if command -v cowsay >/dev/null 2>&1; then \
		echo "cowsay:          $$(cowsay --version 2>&1 | head -1)"; \
	else \
		echo "cowsay:          not installed"; \
	fi
	@if [ -d "$(INSTALL_DIR)/$(SAVER)" ]; then \
		echo "installed saver: $(INSTALL_DIR)/$(SAVER)"; \
		for k in CowsaverBuildOSVersion CowsaverBuildCLTVersion CowsaverSwiftVersion CowsaverGitCommit CFBundleShortVersionString LSMinimumSystemVersion; do \
			printf '  %-28s %s\n' "$$k" "$$(defaults read "$(INSTALL_DIR)/$(SAVER)/Contents/Info" $$k 2>/dev/null || echo '-')"; \
		done; \
	else \
		echo "installed saver: none (run 'make install')"; \
	fi
	@echo "config:"
	@cli="$$(ls .build/*/cowsaver-cli 2>/dev/null | head -1)"; \
	if [ -n "$$cli" ]; then \
		"$$cli" --validate-config | sed 's/^/  /'; \
	else \
		echo "  run 'make cli' for config validation"; \
	fi

cli: check
	$(SWIFT) build --product cowsaver-cli -c $(CONFIG)

# Diagnose after failure rather than probing first: a bare `swiftc -typecheck` probe
# cannot see the module paths SwiftPM wires up, so it rejects toolchains whose
# `swift test` works (CLT 6.1.2 bundles swift-testing; the standalone probe still fails).
test: check
	@log="$$(mktemp)"; \
	{ $(SWIFT) test 2>&1; echo "$$?" > "$$log.status"; } | tee "$$log"; \
	status="$$(cat "$$log.status")"; \
	if [ "$$status" -ne 0 ] && grep -q "no such module 'Testing'" "$$log"; then \
		echo "==> test: this toolchain does not provide Swift Testing to 'swift test'."; \
		echo "    Install Xcode or a swift.org toolchain, or run 'make smoke' for the framework-free golden suite."; \
	fi; \
	rm -f "$$log" "$$log.status"; \
	exit "$$status"

smoke: cli
	scripts/run-goldens.sh "$(BIN)"

test-diagnostics:
	bash scripts/test-diagnostic-tools.sh

# Architectural checks run before every build.
check:
	@echo "==> check: no GPU frameworks anywhere in $(SOURCES_DIR)/"
	@if grep -rnE '$(IMPORT_RE)($(GPU_FRAMEWORKS))\b' $(SOURCES_DIR) ; then \
		echo ""; \
		echo "ERROR: a GPU-accelerated framework is imported in $(SOURCES_DIR)/."; \
		echo "       Cowsaver must not add a dependency on GPU-rendering frameworks."; \
		echo "       See docs/power.md and CONTRIBUTING.md before changing this."; \
		exit 1; \
	fi
	@echo "==> check: CowsayKit imports no platform frameworks"
	@if grep -rnE '$(IMPORT_RE)($(KIT_FORBIDDEN))\b' $(KIT_DIR) ; then \
		echo ""; \
		echo "ERROR: $(KIT_DIR) imports a platform framework."; \
		echo "       The core must stay portable — it is what survives when .saver dies."; \
		echo "       Put platform code in CowsaverRender/ or a front-end target instead."; \
		exit 1; \
	fi
	@echo "==> check: IOKit is app-only idle support"
	@if grep -rnE '$(IMPORT_RE)IOKit\b' $(IOKIT_BOUNDARY_DIRS) ; then \
		echo ""; \
		echo "ERROR: IOKit belongs to the standalone app's idle support, not the shared renderer or saver."; \
		exit 1; \
	fi
	@echo "==> check: ok"

# Regenerates compatibility fixtures from a local cowsay installation.
golden:
	scripts/generate-goldens.sh

# Copies personal fortune data into the screensaver container. Imported content supplements
# the bundled curated collection; see README.md for its format.
import-fortunes:
	scripts/import-fortunes.sh

clean:
	rm -rf .build $(BUILD_DIR)
