CONFIG ?= Debug
CORE_BUILD := build/core/$(CONFIG)
APP := build/xcode/Build/Products/$(CONFIG)/Viracm.app

.PHONY: deps core test project app run process clean

deps:
	scripts/fetch_deps.sh

core: deps
	cmake -S core -B $(CORE_BUILD) -DCMAKE_BUILD_TYPE=$(CONFIG)
	cmake --build $(CORE_BUILD)

test: core
	ctest --test-dir $(CORE_BUILD) --output-on-failure

project:
	cd mac && xcodegen generate

app: deps project
	xcodebuild -project mac/Viracm.xcodeproj -scheme Viracm -configuration $(CONFIG) \
		-derivedDataPath build/xcode build

run: app
	open $(APP)

# Usage: make process IMAGE=photo.jpg  (writes build/testout/<name>.png and .debug.png)
process: core
	@mkdir -p build/testout
	$(CORE_BUILD)/viracm_cli models "$(IMAGE)" build/testout/$(basename $(notdir $(IMAGE))).png
	$(CORE_BUILD)/viracm_cli models "$(IMAGE)" build/testout/$(basename $(notdir $(IMAGE))).debug.png --debug

clean:
	rm -rf build mac/Viracm.xcodeproj
