# 用 Xcode 的工具鏈，避免 swiftly 工具鏈與 SDK 不相容
SWIFTC := xcrun swiftc
CLANG  := xcrun clang
# 路徑不能有空格：Steam 啟動選項不吃引號
INSTALL_DIR := $(HOME)/.local/share/steamac-controller

all: build/gcprobe build/libsteaminput-fix.dylib

build/gcprobe: Sources/gcprobe/main.swift
	@mkdir -p build
	$(SWIFTC) -O $< -o $@

# 遊戲可能是 arm64 或 Rosetta 下的 x86_64，做 universal
FIX_SOURCES := Sources/steaminput-fix/steaminput_fix.m Sources/steaminput-fix/spawn_inject.m
build/libsteaminput-fix.dylib: $(FIX_SOURCES)
	@mkdir -p build
	$(CLANG) -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -fobjc-arc -dynamiclib -O2 \
		-framework Foundation -framework AppKit -framework IOKit $(FIX_SOURCES) -o $@
	codesign -s - -f $@

.PHONY: all run install patch-steam unpatch-steam clean
run: build/gcprobe
	./build/gcprobe --input

install: build/libsteaminput-fix.dylib
	@mkdir -p "$(INSTALL_DIR)"
	cp build/libsteaminput-fix.dylib Sources/steaminput-fix/launch.sh "$(INSTALL_DIR)/"
	@echo
	@echo "所有遊戲自動套用：make patch-steam（修補 /Applications/Steam.app）"
	@echo "單一遊戲：Steam 啟動選項填 $(INSTALL_DIR)/launch.sh %command%"

patch-steam: install
	Sources/steam-patch/patch.sh patch

unpatch-steam:
	Sources/steam-patch/patch.sh unpatch

clean:
	rm -rf build
