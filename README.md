# SteamInputMac

讓新版 Steam Controller 在 macOS 上的 Steam 遊戲裡可以操控。

## 安裝

從 [Releases](../../releases) 下載 `SteamInputMac-版本.dmg`，打開後把安裝程式拖到「應用程式」。
安裝程式未經 Apple 公證，第一次開啟請在 Finder 按右鍵 →「打開」。

1. 安裝 Steam，**先正常開一次並登入**（讓 Steam 下載用戶端），然後結束 Steam。
2. 打開「SteamInputMac Installer.app」，選擇 Steam，按「安裝」。
3. 第一次會提示需要權限：到「系統設定 → 隱私權與安全性 → App 管理」允許安裝程式，
   重開安裝程式再按一次「安裝」。
4. 照常點 Steam 圖示開 Steam、玩遊戲。Steam 若正在執行，可按安裝程式裡的「重新啟動 Steam」。

- **重新安裝 / 修復**：更新修正檔，或 Steam.app 被重裝、覆蓋後重新修補。
- **更新**：安裝程式會顯示目前安裝的版本與 GitHub 上的最新版本；有新版時按「更新到 x.y.z」，
  會直接下載最新 Release 的 DMG 取出檔案安裝，不必重新下載安裝程式（檔案暫存在 `~/Library/Caches/SteamInputMac`）。
- **解除安裝**：從備份還原原版 Steam.app（含 Valve 簽章），並移除所有安裝的檔案。

自行編譯安裝程式（需要 Xcode）：

```bash
make installer   # 產生 build/SteamInputMac Installer.app
make dmg         # 打包成 build/SteamInputMac-dev.dmg
make install     # 指令列安裝（同安裝程式的「安裝」）
make uninstall   # 指令列解除安裝
make status
```

發佈新版：推送 `v*` tag（例如 `git tag v1.0.0 && git push origin v1.0.0`），
GitHub Actions 會自動打包 DMG 並建立 Release。

紀錄檔：`~/Library/Logs/SteamInputMac.log`

## 原理

### Steam 遊戲裡不能操控

Steam 手柄一定走 Steam Input（無法停用）。Steam 在 Mac 上會建立虛擬 Xbox 360 手柄
`GamePad-1`（045e:028e），格式與 360Controller 驅動相同，但很多遊戲認不得它：

- Unity 遊戲把它命名為「Microsoft GamePad-1」，InControl 用名稱比對設定檔，對不上就忽略
  （例：Hollow Knight: Silksong）。
- `GCController.supportsHIDDevice` 說它歸 GameController 管，但 GameController 不接虛擬的 Xbox 360 手柄。
- Steam 給遊戲的 `SDL_GAMECONTROLLER_IGNORE_DEVICES` 含有 045e:028e。新版 SDL 會先認出虛擬手柄，
  但 SDL 2.0.14 等舊版不會，連虛擬手柄一起忽略（例：Celeste，以前要自己換新版 libSDL2 才能玩）。
- 同一批舊版 SDL 在忽略裝置時有 bug：虛擬手柄已加入後，再看到被忽略的實體手柄（例：藍牙 Xbox 手柄）就會崩潰。

`libSteamInputMac.dylib` 注入遊戲後，把虛擬手柄的名稱改報成「Xbox 360 Wired Controller」，
讓 `supportsHIDDevice` 對它回傳 NO，並在沒有實體 Xbox 360 手柄時把 045e:028e 從 SDL 忽略清單拿掉；
忽略清單裡的實體手柄則直接不讓遊戲的 IOHIDManager 看到。不改系統，也不改遊戲檔案。

### 震動傳不到手柄

Steam 的虛擬手柄沒有輸出 report（`MaxOutputReportSize = 0`），遊戲的震動送不到手柄。
dylib 直接對 Steam Controller 送震動（output report `0x80`，協定參考 SDL3 的
`SDL_hidapi_steam_triton.c`，每 40ms 重送）與藍牙 Xbox 手柄（output report `0x03`，協定參考 SDL 的
`SDL_hidapi_xboxone.c`，持續時間上限 2.55 秒，每秒重送），並從三個地方接收遊戲的震動：

| 來源 | 做法 | 適用 |
| --- | --- | --- |
| HID | 虛擬手柄改報 8 bytes 輸出，攔截送給它的 Xbox 360 震動 report（`00 08 00 左 右 …`、hidapi 的 `08 00 左 右 …`、SDL 2.0.x 的 `00 04 左 右`） | 直接對 HID 送震動的遊戲、SDL 遊戲（例：Celeste） |
| Unity Input System | 攔截 `NativeInputSystem::IOCTL` 的 `'RMBL'` 指令，原生層不支援時改送給手柄 | 用 Unity 新版 Input System 的遊戲（例：Silksong） |
| InControl 舊式輸入 | Mono profiler 在 JIT 後把空的 `InputDevice.Vibrate` 換成 hook | InControl + Unity 舊式搖桿輸入的遊戲 |

`make build/rumbletest && ./build/rumbletest` 可直接讓手柄震動，確認協定可用。

### 怎麼讓所有遊戲自動套用

安裝時會把 Steam.app 完整備份到 `~/.local/share/steaminputmac/Steam.app.orig`，
把主程式換成 wrapper（Valve 啟動器改名為 `steam_osx.valve`），再以 ad-hoc 重新簽章。

- Valve 啟動器有 hardened runtime 會清掉 `DYLD_*`，wrapper 改為直接 `exec` 沒有 hardened runtime
  的 Steam 用戶端（`Steam.AppBundle/.../steam_osx`），並帶上 dylib；不會多出背景程序。
- dylib 在 Steam 用戶端內只負責轉交：攔截 NSWorkspace 啟動遊戲，把 dylib 加進遊戲的
  `DYLD_INSERT_LIBRARIES`（與 Steam 內嵌介面並存）；不改 Steam 自己的 HID。
- Steam 已在執行、或用戶端尚未下載時，wrapper 交回 Valve 啟動器處理。
- dylib 被移除後就不再注入，避免遊戲因找不到 dylib 而無法啟動。
- Steam 自我更新後重新啟動時，可能會回到一般模式；結束 Steam 再從圖示開一次就好。
- 只對沒開 hardened runtime 的遊戲有效（多數 Steam Mac 遊戲是 ad-hoc 簽章）。

### 單一遊戲（啟動選項，進階）

不想修補 Steam.app 時，可在 Steam → 遊戲右鍵 → 內容 → 一般 → 啟動選項填入
（完整路徑、不能有空格；Steam for Mac 不支援 `VAR=值 %command%` 的寫法）：

```
/Users/<你>/.local/share/steaminputmac/launch.sh %command%
```

`launch.sh` 會補回 Steam 內嵌介面的 dylib（SIP 會清掉 Steam 傳進來的 `DYLD_INSERT_LIBRARIES`）。

## 非 Steam 遊戲：藍牙直連不是手柄

macOS 27.2 的 `AppleGameControllerPersonality.kext` 內建支援新版 Steam Controller，但只比對以下 PID：

| PID | 連線方式 | GameController 支援 |
| --- | --- | --- |
| `28de:1302` | USB 有線 | ✅ |
| `28de:1303` | 藍牙直連 | ❌（不在名單內） |
| `28de:1304` | Puck 接收器 (Proteus) | ✅ |
| `28de:1305` | Puck 接收器 (Nereid) | ✅ |

藍牙直連時系統只看到它的「鍵盤＋滑鼠」模式。系統檔受 SIP 保護無法修改；自己做虛擬手柄需要
Apple 限制級的 `com.apple.developer.hid.virtual.device` entitlement。
**不經過 Steam 的遊戲請改用 Puck 接收器或 USB 線。**（Steam 遊戲走 Steam Input，藍牙也可以。）

### gcprobe

監聽 Valve HID 裝置與 GameController 手柄的接上/拔除，藍牙直連時會提示。

```bash
make run        # 會順便顯示按鍵輸入
./build/gcprobe # 只看連線
```
