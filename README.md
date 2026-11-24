# steamac-controller

新版 Steam Controller 在 macOS 上的連線診斷工具。

## 為什麼藍牙連上卻不是手柄

macOS 27.2 的 `AppleGameControllerPersonality.kext` 內建支援新版 Steam Controller，但只比對以下 PID：

| PID | 連線方式 | GameController 支援 |
| --- | --- | --- |
| `28de:1302` | USB 有線 | ✅ |
| `28de:1303` | 藍牙直連 | ❌（不在名單內） |
| `28de:1304` | Puck 接收器 (Proteus) | ✅ |
| `28de:1305` | Puck 接收器 (Nereid) | ✅ |

藍牙直連時系統只看到它的「鍵盤＋滑鼠」模式，遊戲不會當成手柄。系統檔受 SIP 保護無法修改；
自己做虛擬手柄需要 Apple 限制級的 `com.apple.developer.hid.virtual.device` entitlement（ad-hoc 簽章會被 AMFI 直接殺掉）。

**解法：改用 Puck 接收器或 USB 線連線。** Steam 遊戲則由 Steam Input 處理（Steam 需開著）。

## gcprobe

監聽 Valve HID 裝置與 GameController 手柄的接上/拔除，藍牙直連時會提示。

```bash
make run        # 會順便顯示按鍵輸入
./build/gcprobe # 只看連線
```
