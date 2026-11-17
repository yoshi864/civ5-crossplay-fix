#!/bin/bash
# Checks are strings eval'd by check(), so they expand late, on purpose.
# shellcheck disable=SC2016,SC2034
# Tests crossplay.sh against fake game folders (no game files needed).
#
#   tests/run.sh                       fake executables only (what CI runs)
#   tests/run.sh "/path/to/original Civilization V" "/path/to/original App.json"
#                                      also a full round trip on copies of the real files
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="$HERE/../crossplay.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A fake app whose executable holds the shipped bytes at both patch sites, and an
# App.json with the stock version line.
make_app() {
    local app="$WORK/$1/Civilization V.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/AspyrAssets/global/String"
    local exe="$app/Contents/MacOS/Civilization V"
    : > "$exe"
    printf '78080375c5f2480f2c00c381feeed8ff' | xxd -r -p | dd of="$exe" bs=1 seek=$((0xB47645 - 8)) conv=notrunc 2>/dev/null
    printf '837808037509f20f2c00e9d70000004d' | xxd -r -p | dd of="$exe" bs=1 seek=$((0xB4D2E4 - 8)) conv=notrunc 2>/dev/null
    cat > "$app/Contents/AspyrAssets/global/String/App.json" <<'EOF'
{
"App.WinFileVersion" : "1.0.3.279",
"App.WinFileVersionStr" : "{App.WinFileVersion} ({App.Build})",
"App.WinProductVersionStr" : "{App.WinFileVersionStr}"
}
EOF
    echo "$app"
}

run() { CROSSPLAY_BACKUP_DIR="$WORK/backup-$CASE" "$TOOL" "$@" --app "$APP" > "$WORK/out" 2>&1; }
byte() { xxd -s "$1" -l 1 -p "$APP/Contents/MacOS/Civilization V"; }
json() { cat "$APP/Contents/AspyrAssets/global/String/App.json"; }
out_has() { grep -qF "$1" "$WORK/out"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

export CROSSPLAY_NO_CODESIGN=1  # fake executables are not Mach-O

echo "install / uninstall"
CASE=basic APP=$(make_app basic)
orig_exe=$(sha "$APP/Contents/MacOS/Civilization V"); orig_json=$(json)
run status;    check "status: not installed" 'out_has "not installed"'
run install;   check "install succeeds" '[ $? = 0 ]'
check "lua_tointeger site patched" '[ "$(byte 0xB47645)" = 2d ]'
check "luaL_optinteger site patched" '[ "$(byte 0xB4D2E4)" = 2d ]'
check "App.json reports 403694" 'json | grep -qF "\"{App.WinFileVersion} (403694)\","'
check "rest of App.json untouched" '[ "$(json | grep -vc 403694)" = 4 ]'
run status;    check "status: installed" 'out_has "is installed"'
run install;   check "second install is a no-op" 'out_has "already patched"'
run uninstall; check "uninstall restores the executable from backup" 'out_has "from the backup" && [ "$(sha "$APP/Contents/MacOS/Civilization V")" = "$orig_exe" ]'
check "uninstall restores App.json" '[ "$(json)" = "$orig_json" ]'

echo "uninstall without a backup"
CASE=nobackup APP=$(make_app nobackup)
run install; rm -rf "$WORK/backup-nobackup"
run uninstall; check "bytes flipped back" '[ "$(byte 0xB47645)" = 2c ] && [ "$(byte 0xB4D2E4)" = 2c ] && [ "$(sha "$APP/Contents/MacOS/Civilization V")" = "$orig_exe" ]'

echo "partial state (Steam restored App.json only)"
CASE=partial APP=$(make_app partial)
run install
printf '%s\n' "$orig_json" > "$APP/Contents/AspyrAssets/global/String/App.json"
run status;  check "status: partly installed" 'out_has "Partly installed"'
run install; check "install completes it" 'out_has "already patched" && json | grep -qF 403694'

echo "refuses unknown files"
CASE=unknown APP=$(make_app unknown)
echo 00 | xxd -r -p | dd of="$APP/Contents/MacOS/Civilization V" bs=1 seek=$((0xB47645 - 3)) conv=notrunc 2>/dev/null
before=$(sha "$APP/Contents/MacOS/Civilization V")
run install; rc=$?
check "install fails on an unknown executable" '[ $rc != 0 ] && out_has "Nothing was changed"'
check "unknown executable untouched" '[ "$(sha "$APP/Contents/MacOS/Civilization V")" = "$before" ] && json | grep -qF "({App.Build})"'
CASE=badjson APP=$(make_app badjson)
sed -i '' 's/({App.Build})/(123)/' "$APP/Contents/AspyrAssets/global/String/App.json"
run install; rc=$?
check "install fails on an unknown App.json" '[ $rc != 0 ] && [ "$(byte 0xB47645)" = 2c ]'
APP="$WORK/nowhere.app"; run status; rc=$?
check "missing game folder is an error" '[ $rc != 0 ] && out_has "no executable"'

if [ $# = 2 ]; then
    echo "real game files"
    unset CROSSPLAY_NO_CODESIGN
    CASE=real APP=$(make_app real)
    real_exe=$1 real_json=$2
    cp "$real_exe" "$APP/Contents/MacOS/Civilization V"; cp "$real_json" "$APP/Contents/AspyrAssets/global/String/App.json"
    real_sha=$(sha "$real_exe")
    run status;    check "status: not installed" 'out_has "not installed"'
    run install;   check "install succeeds" '[ $? = 0 ]'
    # Past the Mach-O header and load commands (re-signing rewrites the signature command), only the two opcodes change.
    cmds_end=$((32 + $(otool -h "$real_exe" | awk 'END {print $7}')))
    check "only the two opcodes change" '[ "$(cmp -l "$real_exe" "$APP/Contents/MacOS/Civilization V" 2>/dev/null | awk "\$1 > $cmds_end && \$1 <= $((0xB4D2E4 + 1)) {print \$1 - 1}" | xargs)" = "$((0xB47645)) $((0xB4D2E4))" ]'
    cp "$APP/Contents/MacOS/Civilization V" "$WORK/signed"  # outside the fake (resource-less) bundle
    check "re-signed executable verifies" 'codesign --verify "$WORK/signed"'
    check "still x86_64 Mach-O" 'lipo -info "$APP/Contents/MacOS/Civilization V" | grep -q x86_64'
    run uninstall; check "uninstall restores Aspyr's signed original" '[ "$(sha "$APP/Contents/MacOS/Civilization V")" = "$real_sha" ]'
    check "uninstall restores App.json" 'cmp -s "$real_json" "$APP/Contents/AspyrAssets/global/String/App.json"'
fi

echo
if [ $FAILS != 0 ]; then echo "$FAILS failed"; exit 1; fi
echo "all tests passed"
