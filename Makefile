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
build/libsteaminput-fix.dylib: Sources/steaminput-fix/steaminput_fix.m
	@mkdir -p build
	$(CLANG) -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -fobjc-arc -dynamiclib -O2 \
		-framework Foundation -framework IOKit $< -o $@
	codesign -s - -f $@

.PHONY: all run install clean
run: build/gcprobe
	./build/gcprobe --input

install: build/libsteaminput-fix.dylib
	@mkdir -p "$(INSTALL_DIR)"
	cp build/libsteaminput-fix.dylib Sources/steaminput-fix/launch.sh "$(INSTALL_DIR)/"
	@echo
	@echo "Steam → 遊戲右鍵 → 內容 → 一般 → 啟動選項，填入："
	@echo '$(INSTALL_DIR)/launch.sh %command%'

clean:
	rm -rf build
