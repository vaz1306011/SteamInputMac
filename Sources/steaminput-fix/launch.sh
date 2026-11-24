#!/bin/bash
# Steam 啟動選項用的 wrapper：在環境裡注入 steaminput-fix 後再啟動遊戲。
# 用法（Steam 啟動選項）：~/.local/share/steamac-controller/launch.sh %command%
#
# DYLD_* 必須在腳本內 export：SIP 會把它從 /bin/bash 這類系統程式的環境中移除。
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/steaminput-fix.log"
echo "[launch.sh] $(date '+%F %T') args: $*" >> "$LOG"

# %command% 可能是 .app，轉成裡面的執行檔，否則 DYLD 變數不會被帶進去
if [[ "$1" == *.app || "$1" == *.app/ ]]; then
    app="${1%/}"
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    shift
    set -- "$app/Contents/MacOS/$exe" "$@"
fi

export DYLD_INSERT_LIBRARIES="$DIR/libsteaminput-fix.dylib"
exec "$@"
