# 用 Xcode 的工具鏈，避免 swiftly 工具鏈與 SDK 不相容
SWIFTC := xcrun swiftc
CLANG  := xcrun clang
INSTALLER := build/SteamInputMac Installer.app
# 有 Apple Development 憑證就用它簽安裝程式，「App 管理」授權在重新編譯後才不會失效；否則 ad-hoc
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')
SIGN_ID := $(if $(SIGN_ID),$(SIGN_ID),-)

FIX_SOURCES := Sources/dylib/hid_fix.m Sources/dylib/spawn_inject.m Sources/dylib/rumble.m Sources/dylib/mono_rumble.m
INSTALLER_RESOURCES := Sources/steam-patch/patch.sh Sources/steam-patch/steam_osx Sources/dylib/launch.sh

all: build/gcprobe build/rumbletest installer

build/gcprobe: Sources/gcprobe/main.swift
	@mkdir -p build
	$(SWIFTC) -O $< -o $@

# 直接對手柄送震動，驗證震動協定
build/rumbletest: Sources/rumbletest/main.swift
	@mkdir -p build
	$(SWIFTC) -O $< -o $@

# 遊戲可能是 arm64 或 Rosetta 下的 x86_64，做 universal
build/libSteamInputMac.dylib: $(FIX_SOURCES) Sources/dylib/rumble.h
	@mkdir -p build
	$(CLANG) -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -fobjc-arc -dynamiclib -O2 \
		-framework Foundation -framework AppKit -framework IOKit $(FIX_SOURCES) -o $@
	codesign -s - -f $@

build/SteamInputMacInstaller: Sources/installer/InstallerApp.swift
	@mkdir -p build
	$(SWIFTC) -O -parse-as-library -target arm64-apple-macos14.0 $< -o $@-arm64
	$(SWIFTC) -O -parse-as-library -target x86_64-apple-macos14.0 $< -o $@-x86_64
	lipo -create $@-arm64 $@-x86_64 -output $@

# 圖形安裝程式：內附 dylib、wrapper 與安裝腳本，使用者不需要 Xcode
installer: build/SteamInputMacInstaller build/libSteamInputMac.dylib Sources/installer/Info.plist $(INSTALLER_RESOURCES)
	@mkdir -p "$(INSTALLER)/Contents/MacOS" "$(INSTALLER)/Contents/Resources"
	cp build/SteamInputMacInstaller "$(INSTALLER)/Contents/MacOS/"
	cp Sources/installer/Info.plist "$(INSTALLER)/Contents/"
	cp $(INSTALLER_RESOURCES) build/libSteamInputMac.dylib "$(INSTALLER)/Contents/Resources/"
	-cp /Applications/Steam.app/Contents/Resources/Steam.icns "$(INSTALLER)/Contents/Resources/AppIcon.icns"
	codesign -f -s "$(SIGN_ID)" "$(INSTALLER)"
	@echo "已產生 $(INSTALLER)（簽章：$(SIGN_ID)）"

# 打包成 DMG（內含安裝程式與「應用程式」捷徑），VERSION 可由 CI 帶入 tag
VERSION ?= dev
DMG := build/SteamInputMac-$(VERSION).dmg
dmg: installer
	rm -rf build/dmg "$(DMG)"
	mkdir -p build/dmg
	cp -R "$(INSTALLER)" build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "SteamInputMac $(VERSION)" -srcfolder build/dmg -ov -format UDZO "$(DMG)"
	rm -rf build/dmg
	@echo "已產生 $(DMG)"

.PHONY: all installer dmg run install uninstall status clean
run: build/gcprobe
	./build/gcprobe --input

# 指令列版本（與安裝程式相同的動作）
install: installer
	"$(INSTALLER)/Contents/Resources/patch.sh" install

uninstall:
	Sources/steam-patch/patch.sh uninstall

status:
	Sources/steam-patch/patch.sh status

clean:
	rm -rf build
