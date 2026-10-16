#!/bin/bash
# usage: test_game.sh <path-to.app> [secs] [game args...]   -> signed copy in work/, ReShade base in work/base-<name>, screenshot of the largest window
APP=$1; SECS=${2:-25}; shift 2
cd "$(dirname "$0")"
NAME=$(basename "$APP" .app); COPY=work/$NAME.app; BASE=$PWD/work/base-$NAME
if [ ! -d "$COPY" ]; then ditto "$APP" "$COPY" && chmod -R u+w "$COPY" && xattr -cr "$COPY" && codesign --force --deep -s - "$COPY" 2>&1 | tail -1; fi
mkdir -p "$BASE/screenshots" "$BASE/cache"; [ -f "$BASE/ReShade.ini" ] || sed "s|base-vkquake|base-$NAME|g" work/base-vkquake/ReShade.ini > "$BASE/ReShade.ini"
ln -sfn "$PWD/third_party/reshade-shaders" "$BASE/reshade-shaders"
EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$COPY/Contents/Info.plist")
export MACSHADE_BASE="$BASE" MACSHADE_MOLTENVK=/opt/homebrew/lib/libMoltenVK.dylib
killall -9 "$EXE" 2>/dev/null; sleep 1
DYLD_INSERT_LIBRARIES=$PWD/mac/build/libmacshade.dylib "$COPY/Contents/MacOS/$EXE" -ApplePersistenceIgnoreState YES "$@" > work/game_$NAME.log 2>&1 &
sleep $SECS
pid=$(pgrep -f "$COPY/Contents/MacOS/$EXE" | head -1)
if [ -n "$pid" ]; then ./work/post_events $pid key:115 wait:1.2; fi
id=$(swift work/winid2.swift "$EXE" $pid 2>/dev/null); [ -n "$id" ] && screencapture -x -o -l $id work/t_$NAME.png && sips -Z 800 work/t_$NAME.png --out work/ts_$NAME.png >/dev/null
alive=no; [ -n "$pid" ] && alive=yes
killall -9 "$EXE" 2>/dev/null
echo "== $NAME alive=$alive window=$id"
grep -a -E "Bridge:|Running on|ERROR|Registered input|WARN" "$BASE/ReShade.log" 2>/dev/null | cut -c1-170 | head -8
