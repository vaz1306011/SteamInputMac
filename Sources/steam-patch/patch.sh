#!/bin/bash
# 安裝／解除安裝 SteamInputMac，讓 Steam 開的所有遊戲自動套用 SteamInputMac。
#   patch.sh install    安裝修正檔並修補 Steam.app（第一次會完整備份原版；已安裝則更新）
#   patch.sh uninstall  從備份還原 Steam.app，並移除所有安裝的檔案
#   patch.sh status     查看狀態
# 這個腳本旁邊要有 steam_osx（wrapper）、libSteamInputMac.dylib、launch.sh。
# STEAM_APP 可指定要修補的 Steam.app（預設 /Applications/Steam.app）。
# SIM_VERSION 可指定這次安裝的版本號；沒給就讀腳本旁的 VERSION 檔。
# 需要「系統設定 → 隱私權與安全性 → App 管理」授權給執行這個腳本的 app。
set -euo pipefail

STEAM_APP="${STEAM_APP:-/Applications/Steam.app}"
DATA_DIR="$HOME/.local/share/steaminputmac"
BACKUP="$DATA_DIR/Steam.app.orig"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS="$STEAM_APP/Contents/MacOS"
CLIENT="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"

is_patched() { [[ -f "$MACOS/steam_osx.valve" ]]; }
steam_running() { pgrep -x steam_osx >/dev/null; }

# 先複製到暫存檔再 rename：直接覆寫正在被 Steam／遊戲載入的 dylib 會讓它們當掉
install_file() {
    local src="$1" dest="$2"
    cp "$src" "$dest.tmp.$$"
    chmod +x "$dest.tmp.$$"
    mv -f "$dest.tmp.$$" "$dest"
}

check_writable() {
    if ! touch "$STEAM_APP/Contents/.steaminputmac-test" 2>/dev/null; then
        echo "沒有權限修改 $STEAM_APP。" >&2
        echo "請到「系統設定 → 隱私權與安全性 → App 管理」允許這個 app，再試一次。" >&2
        exit 3
    fi
    rm -f "$STEAM_APP/Contents/.steaminputmac-test"
}

resign() {
    # 內容變了，Valve 的簽章失效；改用 ad-hoc 簽章（不含 hardened runtime）。
    # Valve 啟動器的簽章綁定原 bundle，也要重簽，否則整個 bundle 驗證不過。
    codesign -f -s - "$MACOS/steam_osx.valve" 2>/dev/null
    codesign -f -s - "$STEAM_APP" 2>/dev/null
}

# 舊版（steamac-controller）裝在別的路徑，搬過來，原版 Steam.app 備份才不會遺失
migrate_old_install() {
    local old="$HOME/.local/share/steamac-controller"
    [[ -d "$old" ]] || return 0
    if [[ -d "$DATA_DIR" ]]; then
        [[ -d "$old/Steam.app.orig" && ! -d "$BACKUP" ]] && mv "$old/Steam.app.orig" "$BACKUP"
        rm -rf "$old"
    else
        mkdir -p "$(dirname "$DATA_DIR")"
        mv "$old" "$DATA_DIR"
    fi
    rm -f "$DATA_DIR/libsteaminput-fix.dylib"
    echo "已將舊版安裝搬移到 $DATA_DIR"
}
migrate_old_install

case "${1:-status}" in
install)
    [[ -d "$STEAM_APP" ]] || { echo "找不到 $STEAM_APP，請先安裝 Steam。" >&2; exit 4; }
    check_writable
    mkdir -p "$DATA_DIR"
    install_file "$SRC_DIR/libSteamInputMac.dylib" "$DATA_DIR/libSteamInputMac.dylib"
    install_file "$SRC_DIR/launch.sh" "$DATA_DIR/launch.sh"
    version="${SIM_VERSION:-$(cat "$SRC_DIR/VERSION" 2>/dev/null || true)}"
    if [[ -n "$version" ]]; then echo "$version" > "$DATA_DIR/VERSION"; else rm -f "$DATA_DIR/VERSION"; fi
    echo "已安裝修正檔 ${version:-（版本不明）} 到 $DATA_DIR"

    if is_patched; then
        install_file "$SRC_DIR/steam_osx" "$MACOS/steam_osx"
        resign
        echo "Steam.app 已是修補狀態，已更新。"
    else
        rm -rf "$BACKUP"
        ditto "$STEAM_APP" "$BACKUP"
        echo "已備份原版 Steam.app 到 $BACKUP"
        mv "$MACOS/steam_osx" "$MACOS/steam_osx.valve"
        install_file "$SRC_DIR/steam_osx" "$MACOS/steam_osx"
        resign
        echo "已修補 Steam.app。"
    fi
    [[ -x "$CLIENT" ]] || echo "注意：Steam 還沒下載過用戶端，請先開一次 Steam 並登入，結束後再開才會生效。"
    if steam_running; then echo "Steam 正在執行，重開 Steam 後才會生效。"; fi
    ;;
uninstall)
    if is_patched; then
        check_writable
        if [[ -d "$BACKUP" ]]; then
            rm -rf "$STEAM_APP"
            ditto "$BACKUP" "$STEAM_APP"
            echo "已從備份還原原版 Steam.app（含 Valve 簽章）。"
        else
            # 沒有備份：手動換回 Valve 啟動器，只能用 ad-hoc 簽章
            mv -f "$MACOS/steam_osx.valve" "$MACOS/steam_osx"
            codesign -f -s - "$STEAM_APP" 2>/dev/null
            echo "找不到備份，已手動還原 Steam.app（簽章為 ad-hoc，重新安裝 Steam 可恢復 Valve 簽章）。"
        fi
    else
        echo "Steam.app 沒有被修補。"
    fi
    rm -rf "$DATA_DIR"
    echo "已移除 $DATA_DIR"
    if steam_running; then echo "Steam 正在執行，重開 Steam 後才會完全停用修正。"; fi
    ;;
status)
    if is_patched; then echo "Steam.app：已修補"; else echo "Steam.app：原版"; fi
    if [[ -f "$DATA_DIR/libSteamInputMac.dylib" ]]; then
        echo "修正檔：已安裝（版本 $(cat "$DATA_DIR/VERSION" 2>/dev/null || echo 不明)）"
    else
        echo "修正檔：未安裝"
    fi
    if [[ -x "$CLIENT" ]]; then echo "Steam 用戶端：已下載"; else echo "Steam 用戶端：尚未下載"; fi
    ;;
*)
    echo "用法：$0 install|uninstall|status" >&2; exit 2 ;;
esac
