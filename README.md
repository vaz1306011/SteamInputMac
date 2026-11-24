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
make patch-steam     # 修補 /Applications/Steam.app，所有遊戲自動套用（建議）
make unpatch-steam   # 從備份還原原版 Steam.app
```

### 所有遊戲自動套用（修補 Steam.app）

`make patch-steam` 會先把原版完整備份到 `~/.local/share/steamac-controller/Steam.app.orig`，
再把 Steam.app 的主程式換成 wrapper（Valve 啟動器改名為 `steam_osx.valve`），最後以 ad-hoc 重新簽章。
之後照常點 Steam 圖示開啟即可，不會多出其他 app 或背景程序。

- Valve 啟動器有 hardened runtime 會清掉 `DYLD_*`，wrapper 改為直接 `exec` 沒有 hardened runtime
  的 Steam 用戶端（`Steam.AppBundle/.../steam_osx`），並帶上 `libsteaminput-fix.dylib`。
- 修正在 Steam 用戶端內只負責轉交：攔截 NSWorkspace 啟動遊戲，把 dylib 加進遊戲的
  `DYLD_INSERT_LIBRARIES`（與 Steam 內嵌介面並存）；不改 Steam 自己的 HID。
- Steam 已在執行、或用戶端尚未安裝時，wrapper 交回 Valve 啟動器處理。
- 需要「系統設定 → 隱私權與安全性 → App 管理」授權給執行指令的 app。
- 若重新安裝 Steam 或 Steam.app 被更新覆蓋，重新 `make patch-steam` 即可。
- Steam 自我更新後重新啟動時，可能會回到一般模式；結束 Steam 再從圖示開一次就好。

### 單一遊戲（啟動選項）

在 Steam → 遊戲右鍵 → 內容 → 一般 → 啟動選項填入：

```
~/.local/share/steamac-controller/launch.sh %command%
```

（請填完整路徑 `/Users/<你>/.local/share/steamac-controller/launch.sh`；路徑不能有空格，
Steam for Mac 也不支援 `VAR=值 %command%` 的寫法。）

`launch.sh` 會順便補回 Steam 內嵌介面（overlay）的 dylib：SIP 會清掉 Steam 傳進來的 `DYLD_INSERT_LIBRARIES`。
紀錄檔在 `~/Library/Logs/steaminput-fix.log`。只對沒開 hardened runtime 的遊戲有效（多數 Steam Mac 遊戲是 ad-hoc 簽章）。

## gcprobe

監聽 Valve HID 裝置與 GameController 手柄的接上/拔除，藍牙直連時會提示。

```bash
make run        # 會順便顯示按鍵輸入
./build/gcprobe # 只看連線
```
