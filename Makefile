# 用 Xcode 的 swiftc，避免 swiftly 工具鏈與 SDK 不相容
SWIFTC := xcrun swiftc

build/gcprobe: Sources/gcprobe/main.swift
	@mkdir -p build
	$(SWIFTC) -O $< -o $@

.PHONY: run clean
run: build/gcprobe
	./build/gcprobe --input

clean:
	rm -rf build
