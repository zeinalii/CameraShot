APP       := CameraShot.app
MACOS     := $(APP)/Contents/MacOS
RESOURCES := $(APP)/Contents/Resources

.PHONY: build run clean

build:
	swift build -c release
	@mkdir -p $(MACOS) $(RESOURCES)/Resources
	@BUILD_DIR=$$(swift build -c release --show-bin-path); cp "$$BUILD_DIR/CameraShot" $(MACOS)/CameraShot
	@cp -R Sources/CameraShot/Resources/. $(RESOURCES)/Resources/
	@cp Info.plist $(APP)/Contents/Info.plist
	@codesign --force --sign - --entitlements CameraShot.entitlements $(APP)
	@echo "✓ Built: $(APP)"

# Usage: make run ARGS="5"         (5-second interval, camera menu)
#        make run ARGS="5 1"       (5-second interval, camera index 1)
run: build
	./$(APP)/Contents/MacOS/CameraShot $(ARGS)

clean:
	rm -rf .build $(APP)
