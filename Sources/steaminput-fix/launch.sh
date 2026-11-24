#!/bin/bash
# Steam 啟動選項用的 wrapper：在環境裡注入 steaminput-fix 後再啟動遊戲。
# 用法（Steam 啟動選項）：~/.local/share/steamac-controller/launch.sh %command%
#
# DYLD_* 必須在腳本內 export：SIP 會把它從 /bin/bash 這類系統程式的環境中移除。
# 也因為這樣，Steam 原本用來注入內嵌介面（overlay）的 DYLD_INSERT_LIBRARIES 會遺失，要自己補回。
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/steaminput-fix.log"
STEAM_OVERLAY="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/gameoverlayrenderer.dylib"

# %command% 可能是 .app，轉成裡面的執行檔，否則 DYLD 變數不會被帶進去
if [[ "$1" == *.app || "$1" == *.app/ ]]; then
    app="${1%/}"
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    shift
    set -- "$app/Contents/MacOS/$exe" "$@"
fi

libs="$DIR/libsteaminput-fix.dylib"
if [[ -n "$DYLD_INSERT_LIBRARIES" ]]; then
    libs="$DYLD_INSERT_LIBRARIES:$libs"
elif [[ -f "$STEAM_OVERLAY" ]]; then
    libs="$STEAM_OVERLAY:$libs"
fi
export DYLD_INSERT_LIBRARIES="$libs"

echo "[launch.sh] $(date '+%F %T') DYLD_INSERT_LIBRARIES=$DYLD_INSERT_LIBRARIES exec: $*" >> "$LOG"
exec "$@"
