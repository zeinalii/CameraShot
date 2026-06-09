APP       := CameraShot.app
MACOS     := $(APP)/Contents/MacOS
RESOURCES := $(APP)/Contents/Resources
CONFIG    ?= release
SIGN_IDENTITY ?=
NOTARY_PROFILE ?=
HIDE_DOCK ?= 0

.PHONY: build run dev clean

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
	OPENCODE_BIN=$$(command -v opencode || true); \
	if [ -n "$$OPENCODE_BIN" ]; then \
		REAL_BIN=$$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$$OPENCODE_BIN"); \
		cp "$$REAL_BIN" $(MACOS)/opencode; \
		rm -f $(RESOURCES)/opencode; \
		chmod 755 $(MACOS)/opencode; \
		xattr -d com.apple.quarantine $(MACOS)/opencode 2>/dev/null || true; \
		xattr -d com.apple.provenance $(MACOS)/opencode 2>/dev/null || true; \
		if [ "$$SIGNER" = "-" ]; then \
			codesign --force --sign - $(MACOS)/opencode; \
		else \
			codesign --force --sign "$$SIGNER" --options runtime --timestamp $(MACOS)/opencode; \
		fi; \
		echo "✓ Bundled opencode: $$REAL_BIN"; \
	else \
		echo "⚠ opencode not found in PATH while building"; \
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

# Usage: make run ARGS="5"         (5-second interval, camera menu)
#        make run ARGS="5 1"       (5-second interval, camera index 1)
#        make run HIDE_DOCK=1      (launch without a Dock icon)
run: build
	CAMERASHOT_HIDE_DOCK=$(HIDE_DOCK) ./$(APP)/Contents/MacOS/CameraShot $(ARGS)

dev:
	$(MAKE) build CONFIG=debug SIGN_IDENTITY=-
	@echo "✓ Launching debug build. Logs will appear below."
	CAMERASHOT_HIDE_DOCK=$(HIDE_DOCK) ./$(APP)/Contents/MacOS/CameraShot $(ARGS)

clean:
	rm -rf .build $(APP)
