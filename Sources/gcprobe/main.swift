// gcprobe：列出 macOS 目前辨識到的手柄，並診斷 Steam Controller 的連線方式。
import Foundation
import GameController
import IOKit.hid

let valveVID = 0x28DE

/// macOS 內建 Steam Controller 2 支援（AppleGameControllerPersonality.kext）。
let steamPIDs: [Int: (name: String, nativeGC: Bool)] = [
    0x1302: ("Steam Controller 有線 USB", true),
    0x1303: ("Steam Controller 藍牙直連", false),
    0x1304: ("Steam Controller Puck 接收器 (Proteus)", true),
    0x1305: ("Steam Controller Puck 接收器 (Nereid)", true),
]

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

func log(_ s: String) { print("[\(timestamp())] \(s)"); fflush(stdout) }

// MARK: - IOHID：看實體裝置

func intProp(_ dev: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(dev, key as CFString) as? NSNumber)?.intValue ?? 0
}

func strProp(_ dev: IOHIDDevice, _ key: String) -> String {
    IOHIDDeviceGetProperty(dev, key as CFString) as? String ?? "?"
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: valveVID] as CFDictionary)

/// 同一支手柄會有多個 HID 介面，依 PID 計數，只在第一個接上／最後一個拔除時印出。
var interfaceCount: [Int: Int] = [:]

func describeHID(_ dev: IOHIDDevice, _ verb: String) {
    let pid = intProp(dev, kIOHIDProductIDKey)
    let before = interfaceCount[pid, default: 0]
    interfaceCount[pid] = max(0, before + (verb == "接上" ? 1 : -1))
    guard (verb == "接上" && before == 0) || (verb == "拔除" && before == 1) else { return }
    let info = steamPIDs[pid]
    let name = info?.name ?? ([0x1146, 0x1147].contains(pid) ? "Steam 建立的虛擬鍵鼠" : "未知 Valve 裝置")
    log("HID \(verb)：\(strProp(dev, kIOHIDProductKey)) [28de:\(String(format: "%04x", pid))] \(name)，傳輸=\(strProp(dev, kIOHIDTransportKey))")
    if verb == "接上", let info, !info.nativeGC {
        log("  ⚠️ macOS 的 GameController 不支援這種連線方式，遊戲不會把它當手柄。")
        log("     請改插 Puck 接收器或 USB 線。")
    }
}

IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, dev in describeHID(dev, "接上") }, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, dev in describeHID(dev, "拔除") }, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

// MARK: - GameController：看遊戲實際會看到什麼

func describeGC(_ c: GCController) -> String {
    let profile = c.extendedGamepad != nil ? "extendedGamepad" : (c.microGamepad != nil ? "microGamepad" : "無標準輸入")
    return "\(c.vendorName ?? "?")（類別=\(c.productCategory)，\(profile)）"
}

var watchInput = CommandLine.arguments.contains("--input")

func attachInputLogger(_ c: GCController) {
    guard watchInput, let pad = c.extendedGamepad else { return }
    pad.valueChangedHandler = { pad, element in
        if let b = element as? GCControllerButtonInput, !(element is GCControllerDirectionPad) {
            if b.isPressed { log("  輸入：\(b.localizedName ?? "按鈕") 按下") }
        } else if let d = element as? GCControllerDirectionPad,
                  abs(d.xAxis.value) > 0.5 || abs(d.yAxis.value) > 0.5 {
            log(String(format: "  輸入：%@ x=%.2f y=%.2f", d.localizedName ?? "搖桿", d.xAxis.value, d.yAxis.value))
        }
    }
}

GCController.shouldMonitorBackgroundEvents = true

NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
    guard let c = n.object as? GCController else { return }
    log("✅ GameController 辨識到手柄：\(describeGC(c))")
    attachInputLogger(c)
}
NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { n in
    guard let c = n.object as? GCController else { return }
    log("❎ GameController 手柄斷線：\(describeGC(c))")
}

log("gcprobe 監聽中（Ctrl+C 結束）\(watchInput ? "，會顯示按鍵輸入" : "；加 --input 可顯示按鍵輸入")")
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    if GCController.controllers().isEmpty {
        log("目前 GameController 沒有任何手柄。")
    }
}

RunLoop.main.run()
