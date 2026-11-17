#!/bin/bash
# Lets the Mac (Aspyr) version of Civilization V play multiplayer with the Windows version.
#
#   ./crossplay.sh install   [--app "/path/to/Civilization V.app"]
#   ./crossplay.sh uninstall [--app ...]
#   ./crossplay.sh status    [--app ...]
#
# Two changes, both reversible:
#   1. App.json: the Mac build reports its version as "1.0.3.279 (180925)", Windows as
#      "1.0.3.279 (403694)". Games only list/join when these match, so the Mac reports
#      the Windows build number.
#   2. The game executable: Lua number->integer conversion truncates on Mac (cvttsd2si)
#      but rounds on Windows (x87 fistp). Map scripts hand the engine fractional values,
#      so the two sides generate different maps and desync. Two bytes switch the Mac to
#      cvtsd2si, which rounds the same way Windows does.
set -euo pipefail

VERSION_LINE_MAC='"App.WinFileVersionStr" : "{App.WinFileVersion} ({App.Build})",'
VERSION_LINE_WIN='"App.WinFileVersionStr" : "{App.WinFileVersion} (403694)",'

# Patch sites in the x86_64 executable of Aspyr's 1.4.2 (180925) build: the opcode byte's
# file offset, and the 16 bytes around it (8 before) as shipped. Patched, 2c becomes 2d.
SITES="
0xB47645 78080375c5f2480f2c00c381feeed8ff lua_tointeger
0xB4D2E4 837808037509f20f2c00e9d70000004d luaL_optinteger
"

BACKUP_DIR="${CROSSPLAY_BACKUP_DIR:-$HOME/Library/Application Support/civ5-crossplay-fix}"

die() { echo "error: $*" >&2; exit 1; }

find_app() {
    local lib vdf="$HOME/Library/Application Support/Steam/steamapps/libraryfolders.vdf"
    local candidates=("$HOME/Library/Application Support/Steam")
    if [ -f "$vdf" ]; then
        while IFS= read -r lib; do candidates+=("$lib"); done \
            < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf")
    fi
    for lib in "${candidates[@]}"; do
        local app="$lib/steamapps/common/Sid Meier's Civilization V/Civilization V.app"
        [ -d "$app" ] && { echo "$app"; return; }
    done
    return 1
}

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Prints "original", "patched" or "unknown" for the executable.
exe_state() {
    local exe=$1 off ctx have patched n_orig=0 n_patched=0
    while read -r off ctx _; do
        [ -n "$off" ] || continue
        have=$(xxd -s $((off - 8)) -l 16 -p "$exe")
        patched="${ctx:0:17}d${ctx:18}"
        if [ "$have" = "$ctx" ]; then n_orig=$((n_orig + 1))
        elif [ "$have" = "$patched" ]; then n_patched=$((n_patched + 1))
        fi
    done <<< "$SITES"
    if [ $n_orig = 2 ]; then echo original
    elif [ $n_patched = 2 ]; then echo patched
    else echo unknown
    fi
}

# Prints "original", "patched" or "unknown" for App.json.
json_state() {
    if [ "$(grep -cF "$VERSION_LINE_WIN" "$1")" = 1 ]; then echo patched
    elif [ "$(grep -cF "$VERSION_LINE_MAC" "$1")" = 1 ]; then echo original
    else echo unknown
    fi
}

# Writes opcode byte $2 (2c or 2d) at every patch site of $1.
set_opcodes() {
    local off ctx
    while read -r off ctx _; do
        [ -n "$off" ] || continue
        echo "$2" | xxd -r -p | dd of="$1" bs=1 seek=$((off)) count=1 conv=notrunc 2>/dev/null
    done <<< "$SITES"
}

sign() {
    [ -n "${CROSSPLAY_NO_CODESIGN:-}" ] && return
    codesign --force --sign - "$1" 2>/dev/null || die "could not re-sign $1"
}

# Replaces the version line $2 with $3 in App.json $1.
set_version_line() {
    local tmp="$1.crossplay.tmp"
    awk -v old="$2" -v new="$3" '$0 == old { $0 = new } { print }' "$1" > "$tmp"
    mv "$tmp" "$1"
}

require_game_closed() {
    if pgrep -f "Civilization V.app/Contents/MacOS/Civilization V" >/dev/null; then
        die "Civilization V is running. Quit it first."
    fi
}

cmd_status() {
    local e j
    e=$(exe_state "$EXE"); j=$(json_state "$JSON")
    echo "Game:        $APP"
    echo "Executable:  $e"
    echo "App.json:    $j"
    if [ "$e" = patched ] && [ "$j" = patched ]; then
        echo "Cross-play fix is installed."
    elif [ "$e" = original ] && [ "$j" = original ]; then
        echo "Cross-play fix is not installed."
    elif [ "$e" = unknown ] || [ "$j" = unknown ]; then
        echo "Unrecognised game files: a different game version, or modified by something else."
    else
        echo "Partly installed (a Steam update or file verification may have undone part of it)."
        echo "Run: $0 install"
    fi
}

cmd_install() {
    local e j tmp
    e=$(exe_state "$EXE"); j=$(json_state "$JSON")
    [ "$e" != unknown ] || die "the game executable is not the build this fix knows (Aspyr 1.4.2, 180925). Nothing was changed."
    [ "$j" != unknown ] || die "App.json does not have the expected version line. Nothing was changed."
    require_game_closed

    mkdir -p "$BACKUP_DIR"
    if [ "$e" = original ]; then
        cp -p "$EXE" "$BACKUP_DIR/Civilization V"
        tmp="$EXE.crossplay.tmp"
        cp -p "$EXE" "$tmp"
        set_opcodes "$tmp" 2d
        sign "$tmp"
        [ "$(exe_state "$tmp")" = patched ] || { rm -f "$tmp"; die "patch did not verify. Nothing was changed."; }
        mv "$tmp" "$EXE"
        echo "Patched the executable (Lua rounding now matches Windows)."
    else
        echo "Executable already patched."
    fi
    if [ "$j" = original ]; then
        cp -p "$JSON" "$BACKUP_DIR/App.json"
        set_version_line "$JSON" "$VERSION_LINE_MAC" "$VERSION_LINE_WIN"
        echo "App.json now reports the Windows build number (403694)."
    else
        echo "App.json already patched."
    fi
    echo "Done. Originals are backed up in: $BACKUP_DIR"
}

cmd_uninstall() {
    local e j tmp backup="$BACKUP_DIR/Civilization V"
    e=$(exe_state "$EXE"); j=$(json_state "$JSON")
    require_game_closed

    if [ "$e" = patched ]; then
        # Aspyr's signed original when the backup is intact; else flip the bytes back.
        if [ -f "$backup" ] && [ "$(exe_state "$backup")" = original ]; then
            cp -p "$backup" "$EXE"
            echo "Restored the original executable from the backup."
        else
            tmp="$EXE.crossplay.tmp"
            cp -p "$EXE" "$tmp"
            set_opcodes "$tmp" 2c
            sign "$tmp"
            mv "$tmp" "$EXE"
            echo "Reverted the two patched bytes (no backup found)."
            echo "For a byte-exact original, use Steam: Properties > Installed Files > Verify integrity."
        fi
    elif [ "$e" = original ]; then
        echo "Executable is already original."
    else
        echo "Executable not recognised; left untouched. Steam's 'Verify integrity' restores it."
    fi
    if [ "$j" = patched ]; then
        set_version_line "$JSON" "$VERSION_LINE_WIN" "$VERSION_LINE_MAC"
        echo "App.json restored."
    elif [ "$j" = original ]; then
        echo "App.json is already original."
    else
        echo "App.json not recognised; left untouched."
    fi
}

main() {
    local cmd=${1:-}
    [ $# -gt 0 ] && shift
    APP=""
    while [ $# -gt 0 ]; do
        case $1 in
            --app) APP=${2:-}; shift 2 ;;
            *) die "unknown option: $1" ;;
        esac
    done
    case $cmd in install|uninstall|status) ;; *)
        sed -n '2,6s/^# \{0,1\}//p' "$0"; exit 2 ;;
    esac
    if [ -z "$APP" ]; then
        APP=$(find_app) || die "Civilization V not found in your Steam libraries. Pass --app \"/path/to/Civilization V.app\"."
    fi
    EXE="$APP/Contents/MacOS/Civilization V"
    JSON="$APP/Contents/AspyrAssets/global/String/App.json"
    [ -f "$EXE" ] || die "no executable at $EXE"
    [ -f "$JSON" ] || die "no App.json at $JSON"
    "cmd_$cmd"
}

main "$@"
