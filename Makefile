APP       := CameraShot.app
MACOS     := $(APP)/Contents/MacOS
RESOURCES := $(APP)/Contents/Resources
SIGN_IDENTITY ?=
NOTARY_PROFILE ?=

.PHONY: build run clean

build:
	swift build -c release
	@mkdir -p $(MACOS) $(RESOURCES)/Resources
	@BUILD_DIR=$$(swift build -c release --show-bin-path); cp "$$BUILD_DIR/CameraShot" $(MACOS)/CameraShot
	@cp -R Sources/CameraShot/Resources/. $(RESOURCES)/Resources/
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
run: build
	./$(APP)/Contents/MacOS/CameraShot $(ARGS)

clean:
	rm -rf .build $(APP)
