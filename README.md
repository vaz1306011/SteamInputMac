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

**解法：改用 Puck 接收器或 USB 線連線。**

## Steam 遊戲裡不能操控（steaminput-fix）

Steam 手柄一定走 Steam Input（無法停用）。Steam 在 Mac 上會建立虛擬 Xbox 360 手柄
`GamePad-1`（045e:028e），但很多遊戲認不得它：

- Unity 遊戲把它命名為「Microsoft GamePad-1」，InControl 用名稱比對設定檔，對不上就忽略
  （例：Hollow Knight: Silksong）。
- `GCController.supportsHIDDevice` 說它歸 GameController 管，但 GameController 不接虛擬的 Xbox 360 手柄。

`steaminput-fix` 是注入遊戲的 dylib，把虛擬手柄的名稱改報成「Xbox 360 Wired Controller」，
並讓 `supportsHIDDevice` 對它回傳 NO。只影響加了啟動選項的遊戲，不改系統、不改遊戲檔案。

```bash
make install
```

然後在 Steam → 遊戲右鍵 → 內容 → 一般 → 啟動選項填入：

```
~/.local/share/steamac-controller/launch.sh %command%
```

（請填完整路徑 `/Users/<你>/.local/share/steamac-controller/launch.sh`；路徑不能有空格，
Steam for Mac 也不支援 `VAR=值 %command%` 的寫法。）

紀錄檔在 `~/Library/Logs/steaminput-fix.log`。只對沒開 hardened runtime 的遊戲有效（多數 Steam Mac 遊戲是 ad-hoc 簽章）。

## gcprobe

監聽 Valve HID 裝置與 GameController 手柄的接上/拔除，藍牙直連時會提示。

```bash
make run        # 會順便顯示按鍵輸入
./build/gcprobe # 只看連線
```
