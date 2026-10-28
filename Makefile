CONFIG ?= Debug
# NO, YES, or DEV; see mac/Config/Vircam.xcconfig. Empty uses the xcconfig default.
SIGNED ?=
CORE_BUILD := build/core/$(CONFIG)
APP := build/xcode/Build/Products/$(CONFIG)/Vircam.app

.PHONY: icons deps core test project app run dmg process clean

deps:
	scripts/fetch_deps.sh

# Regenerates mac/App/Assets.xcassets from design/icons.
icons:
	scripts/make_icons.sh

core: deps
	cmake -S core -B $(CORE_BUILD) -DCMAKE_BUILD_TYPE=$(CONFIG)
	cmake --build $(CORE_BUILD)

test: core
	ctest --test-dir $(CORE_BUILD) --output-on-failure

project:
	cd mac && xcodegen generate

app: deps project
	xcodebuild -project mac/Vircam.xcodeproj -scheme Vircam -configuration $(CONFIG) \
		-derivedDataPath build/xcode $(if $(SIGNED),VIRCAM_SIGNED=$(SIGNED)) build

run: app
	open $(APP)

# Usage: make dmg CONFIG=Release [SIGNED=DEV]  (writes build/Vircam.dmg)
dmg: app
	rm -rf build/dmg && mkdir -p build/dmg
	cp -R $(APP) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Vircam -srcfolder build/dmg -ov -format UDZO build/Vircam.dmg
	rm -rf build/dmg

# Usage: make process IMAGE=photo.jpg  (writes build/testout/<name>.png and .debug.png)
process: core
	@mkdir -p build/testout
	$(CORE_BUILD)/vircam_cli models "$(IMAGE)" build/testout/$(basename $(notdir $(IMAGE))).png
	$(CORE_BUILD)/vircam_cli models "$(IMAGE)" build/testout/$(basename $(notdir $(IMAGE))).debug.png --debug

clean:
	rm -rf build mac/Vircam.xcodeproj
