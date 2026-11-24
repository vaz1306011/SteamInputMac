#!/bin/bash
# 修補／還原 /Applications/Steam.app，讓 Steam 開的所有遊戲自動套用 steaminput-fix。
#   patch.sh patch    修補（會先完整備份）
#   patch.sh unpatch  從備份還原
#   patch.sh status   查看狀態
# 需要「系統設定 → 隱私權與安全性 → App 管理」授權給執行這個腳本的 app（終端機等）。
set -euo pipefail

STEAM_APP="${STEAM_APP:-/Applications/Steam.app}"
DATA_DIR="$HOME/.local/share/steamac-controller"
BACKUP="$DATA_DIR/Steam.app.orig"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS="$STEAM_APP/Contents/MacOS"

is_patched() { [[ -f "$MACOS/steam_osx.valve" ]]; }

steam_running() { pgrep -x steam_osx >/dev/null; }

case "${1:-status}" in
patch)
    if is_patched; then
        # 已修補：只更新 wrapper（例如改版後重新安裝）
        cp "$SRC_DIR/steam_osx" "$MACOS/steam_osx"
        codesign -f -s - "$STEAM_APP" 2>/dev/null
        echo "Steam.app 已是修補狀態，已更新 wrapper。"
        exit 0
    fi
    if ! touch "$STEAM_APP/Contents/.steamac-test" 2>/dev/null; then
        echo "沒有權限修改 $STEAM_APP。" >&2
        echo "請到「系統設定 → 隱私權與安全性 → App 管理」允許執行這個指令的 app，再試一次。" >&2
        exit 1
    fi
    rm -f "$STEAM_APP/Contents/.steamac-test"
    mkdir -p "$DATA_DIR"
    rm -rf "$BACKUP"
    ditto "$STEAM_APP" "$BACKUP"
    echo "已備份原版 Steam.app 到 $BACKUP"
    mv "$MACOS/steam_osx" "$MACOS/steam_osx.valve"
    cp "$SRC_DIR/steam_osx" "$MACOS/steam_osx"
    chmod +x "$MACOS/steam_osx"
    # 內容變了，Valve 的簽章失效；改用 ad-hoc 簽章（不含 hardened runtime）。
    # Valve 啟動器的簽章綁定原 bundle，也要重簽，否則整個 bundle 驗證不過。
    codesign -f -s - "$MACOS/steam_osx.valve"
    codesign -f -s - "$STEAM_APP"
    echo "已修補 Steam.app。"
    if steam_running; then echo "Steam 正在執行，結束後重開才會生效。"; fi
    ;;
unpatch)
    if ! is_patched; then echo "Steam.app 沒有被修補。"; exit 0; fi
    if [[ ! -d "$BACKUP" ]]; then echo "找不到備份 $BACKUP，無法還原。" >&2; exit 1; fi
    rm -rf "$STEAM_APP"
    ditto "$BACKUP" "$STEAM_APP"
    echo "已從備份還原原版 Steam.app。"
    ;;
status)
    if is_patched; then echo "Steam.app：已修補"; else echo "Steam.app：原版"; fi
    ;;
*)
    echo "用法：$0 patch|unpatch|status" >&2; exit 2 ;;
esac
