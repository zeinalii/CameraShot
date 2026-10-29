APP       := CameraShot.app
MACOS     := $(APP)/Contents/MacOS
RESOURCES := $(APP)/Contents/Resources
CONFIG    ?= release
SIGN_IDENTITY ?=
NOTARY_PROFILE ?=
HIDE_DOCK ?= 0
INSTALL_DIR ?= /Applications

.PHONY: build install run dev clean

build:
	swift build -c $(CONFIG)
	@mkdir -p $(MACOS) $(RESOURCES)/Resources
	@BUILD_DIR=$$(swift build -c $(CONFIG) --show-bin-path); cp "$$BUILD_DIR/CameraShot" $(MACOS)/CameraShot
	@cp -R Sources/CameraShot/Resources/. $(RESOURCES)/Resources/
	@ICON_SRC="Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"; \
	if [ -f "$$ICON_SRC" ]; then \
		ICON_TMP=$$(mktemp -d); \
		ICONSET="$$ICON_TMP/CameraShot.iconset"; \
		mkdir -p "$$ICONSET"; \
		sips -z 16 16 "$$ICON_SRC" --out "$$ICONSET/icon_16x16.png" >/dev/null; \
		sips -z 32 32 "$$ICON_SRC" --out "$$ICONSET/icon_16x16@2x.png" >/dev/null; \
		sips -z 32 32 "$$ICON_SRC" --out "$$ICONSET/icon_32x32.png" >/dev/null; \
		sips -z 64 64 "$$ICON_SRC" --out "$$ICONSET/icon_32x32@2x.png" >/dev/null; \
		sips -z 128 128 "$$ICON_SRC" --out "$$ICONSET/icon_128x128.png" >/dev/null; \
		sips -z 256 256 "$$ICON_SRC" --out "$$ICONSET/icon_128x128@2x.png" >/dev/null; \
		sips -z 256 256 "$$ICON_SRC" --out "$$ICONSET/icon_256x256.png" >/dev/null; \
		sips -z 512 512 "$$ICON_SRC" --out "$$ICONSET/icon_256x256@2x.png" >/dev/null; \
		sips -z 512 512 "$$ICON_SRC" --out "$$ICONSET/icon_512x512.png" >/dev/null; \
		sips -z 1024 1024 "$$ICON_SRC" --out "$$ICONSET/icon_512x512@2x.png" >/dev/null; \
		iconutil -c icns "$$ICONSET" -o $(RESOURCES)/CameraShot.icns; \
		rm -rf "$$ICON_TMP"; \
		echo "✓ Built icon: $(RESOURCES)/CameraShot.icns"; \
	else \
		echo "⚠ App icon source not found: $$ICON_SRC"; \
	fi
	@SIGNER="$(SIGN_IDENTITY)"; \
	if [ -z "$$SIGNER" ]; then \
		SIGNER=$$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Developer ID Application:/{print $$2; exit}'); \
	fi; \
	if [ -z "$$SIGNER" ]; then SIGNER="-"; fi; \
	echo "Using signer: $$SIGNER"; \
	rm -f $(MACOS)/opencode $(RESOURCES)/opencode; \
	CODEX_BIN=$$(command -v codex || true); \
	if [ -n "$$CODEX_BIN" ]; then \
		NATIVE_CODEX=$$(python3 -c 'import glob, os, sys; p=os.path.realpath(sys.argv[1]); pkg=os.path.dirname(os.path.dirname(p)) if p.endswith("/@openai/codex/bin/codex.js") else ""; pats=[os.path.join(pkg,"vendor","*","bin","codex"), os.path.join(pkg,"vendor","*","codex","codex"), os.path.join(pkg,"node_modules","@openai","codex-*","vendor","*","bin","codex"), os.path.join(pkg,"node_modules","@openai","codex-*","vendor","*","codex","codex")] if pkg else []; matches=[m for pat in pats for m in glob.glob(pat) if os.path.isfile(m) and os.access(m, os.X_OK)]; print(matches[0] if matches else p)' "$$CODEX_BIN"); \
		if [ ! -x "$$NATIVE_CODEX" ]; then echo "✗ Resolved Codex is not executable: $$NATIVE_CODEX" >&2; exit 1; fi; \
		cp "$$NATIVE_CODEX" $(MACOS)/codex; \
		chmod 755 $(MACOS)/codex; \
		xattr -d com.apple.quarantine $(MACOS)/codex 2>/dev/null || true; \
		xattr -d com.apple.provenance $(MACOS)/codex 2>/dev/null || true; \
		if [ "$$SIGNER" = "-" ]; then \
			codesign --force --sign - $(MACOS)/codex; \
		else \
			codesign --force --sign "$$SIGNER" --options runtime --timestamp $(MACOS)/codex; \
		fi; \
		echo "✓ Bundled Codex CLI: $$NATIVE_CODEX"; \
	else \
		echo "⚠ Codex CLI not found in PATH while building; Codex tab will ask for it at runtime"; \
	fi
	@cp Info.plist $(APP)/Contents/Info.plist
	@xattr -dr com.apple.quarantine $(APP) 2>/dev/null || true
	@xattr -dr com.apple.provenance $(APP) 2>/dev/null || true
	@SIGNER="$(SIGN_IDENTITY)"; \
	if [ -z "$$SIGNER" ]; then \
		SIGNER=$$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Developer ID Application:/{print $$2; exit}'); \
	fi; \
	if [ -z "$$SIGNER" ]; then SIGNER="-"; fi; \
	if [ "$$SIGNER" = "-" ]; then \
		codesign --force --sign - --entitlements CameraShot.entitlements $(APP); \
	else \
		codesign --force --sign "$$SIGNER" --options runtime --timestamp --entitlements CameraShot.entitlements $(APP); \
	fi
	@echo "✓ Built: $(APP)"

install: build
	@ditto "$(APP)" "$(INSTALL_DIR)/$(APP)"
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALL_DIR)/$(APP)"
	@mdimport "$(INSTALL_DIR)/$(APP)" 2>/dev/null || true
	@echo "✓ Installed: $(INSTALL_DIR)/$(APP)"

# Usage: make run ARGS="5"         (5-second interval, camera menu)
#        make run ARGS="5 1"       (5-second interval, camera index 1)
#        make run HIDE_DOCK=1      (launch without a Dock icon)
run: build
	@CODEX_BIN=$$(command -v codex || true); \
	CAMERASHOT_HIDE_DOCK=$(HIDE_DOCK) CODEX_BIN="$$CODEX_BIN" ./$(APP)/Contents/MacOS/CameraShot $(ARGS)

dev:
	$(MAKE) build CONFIG=debug SIGN_IDENTITY=-
	@echo "✓ Launching debug build. Logs will appear below."
	@CODEX_BIN=$$(command -v codex || true); \
	CAMERASHOT_HIDE_DOCK=$(HIDE_DOCK) CODEX_BIN="$$CODEX_BIN" ./$(APP)/Contents/MacOS/CameraShot $(ARGS)

clean:
	rm -rf .build $(APP)
