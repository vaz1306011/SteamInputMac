// rumbletest：直接對 Steam Controller 2 送震動，驗證能否繞過 Steam 讓手柄震動。
// 協定參考 SDL3 src/joystick/hidapi/SDL_hidapi_steam_triton.c：
//   output report 0x80 = MsgHapticRumble { u8 type; u16 intensity; {u16 speed; i8 gain} left, right; }
//   手柄約 50ms 沒收到就停，所以要每 40ms 重送。
import Foundation
import IOKit.hid

let tritonPIDs: Set<Int> = [0x1302, 0x1303, 0x1304, 0x1305]

func prop(_ d: IOHIDDevice, _ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? 0 }

func rumbleReport(left: UInt16, right: UInt16) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 10)
    r[0] = 0x80
    r[4] = UInt8(left & 0xff); r[5] = UInt8(left >> 8)
    r[7] = UInt8(right & 0xff); r[8] = UInt8(right >> 8)
    return r
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x28DE] as CFDictionary)
IOHIDManagerOpen(manager, 0)
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [])
    .filter { tritonPIDs.contains(prop($0, kIOHIDProductIDKey)) && prop($0, kIOHIDMaxOutputReportSizeKey) > 0 }

if devices.isEmpty { print("找不到可送震動的 Steam Controller 介面"); exit(1) }

let left = UInt16(CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 40000)
let right = UInt16(CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? Int(left))
let seconds = Double(CommandLine.arguments.dropFirst(3).first ?? "1") ?? 1

for d in devices {
    let pid = prop(d, kIOHIDProductIDKey)
    let page = prop(d, kIOHIDPrimaryUsagePageKey), usage = prop(d, kIOHIDPrimaryUsageKey)
    print(String(format: "介面 28de:%04x usage=%x:%x out=%d", pid, page, usage, prop(d, kIOHIDMaxOutputReportSizeKey)))
}

let end = Date().addingTimeInterval(seconds)
var results: [String: IOReturn] = [:]
while Date() < end {
    for d in devices {
        let r = rumbleReport(left: left, right: right)
        let rc = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x80, r, r.count)
        results[String(format: "%p", unsafeBitCast(d, to: Int.self))] = rc
    }
    usleep(40_000)
}
for d in devices { let r = rumbleReport(left: 0, right: 0); IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x80, r, r.count) }
print("結果：", results.map { String(format: "%@=0x%x", $0.key, $0.value) }.joined(separator: " "))
