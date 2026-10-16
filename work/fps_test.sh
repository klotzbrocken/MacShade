#!/bin/bash
# usage: fps_test.sh <app-copy> <instance-dir> <secs> [preset-techniques]   (env: MAPARGS, MACSHADE_* passed through)
# Runs the game with a COPY of the instance folder (work/benchbase), so the real configuration is never touched, and kills only its own process.
# Refuses to run while the game is already running (a benchmark next to a game in use is meaningless, and killing it would be rude).
COPY=$1; INST=$2; SECS=$3; TECH=$4
EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$COPY/Contents/Info.plist")
if pgrep -x "$EXE" >/dev/null; then echo "ABORT: $EXE is already running" >&2; exit 1; fi
BASE=$(dirname "$0")/benchbase; rm -rf "$BASE"; mkdir -p "$BASE"; rsync -a --exclude Screenshots --exclude ReShade.log "$INST"/ "$BASE"/
BASE=$(cd "$BASE" && pwd)
COLL=~/Library/Application\ Support/MacShade/Collections   # same search paths as the launcher would write
SP=$(for d in "$COLL"/*/Shaders; do printf '%s/**,' "$d"; done); sed -i '' "s#^EffectSearchPaths=.*#EffectSearchPaths=${SP%,}#" "$BASE/ReShade.ini"
TP=$(for d in "$COLL"/*/Textures; do printf '%s/**,' "$d"; done); sed -i '' "s#^TextureSearchPaths=.*#TextureSearchPaths=${TP%,}#" "$BASE/ReShade.ini"
if [ -n "${TECH+x}" ] && [ "$#" -ge 4 ]; then printf 'Techniques=%s\n%s\n' "$TECH" "$EXTRA_PRESET" > "$BASE/Bench.ini"; sed -i '' "s#^PresetPath=.*#PresetPath=$BASE/Bench.ini#" "$BASE/ReShade.ini"; fi
[ -n "$FPSCOUNTER" ] && sed -i '' "s#^ShowFPS=.*#ShowFPS=$FPSCOUNTER#" "$BASE/ReShade.ini"
MACSHADE_BASE="$BASE" MACSHADE_MOLTENVK=/opt/homebrew/lib/libMoltenVK.dylib MACSHADE_BRIDGE_STATS=1 DYLD_INSERT_LIBRARIES=$(cd "$(dirname "$0")/.." && pwd)/mac/build/libmacshade.dylib "$COPY/Contents/MacOS/$EXE" $MAPARGS -ApplePersistenceIgnoreState YES > /tmp/fps_game.log 2>&1 &
PID=$!
if [ -n "$POSTKEYS" ]; then sleep $((SECS-12*(${#POSTKEYS}/4+1)-2)); for k in $POSTKEYS; do "$(dirname "$0")/post_events" $PID key:$k wait:1; sleep 12; done; else sleep "$SECS"; fi
[ -n "$SHOT" ] && { id=$(swift "$(dirname "$0")/winid2.swift" "$EXE" $PID 2>/dev/null); [ -n "$id" ] && screencapture -x -o -l $id "$SHOT"; }
kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
grep -a "Bridge stats\|ReShade split" "$BASE/ReShade.log" | sed 's/.*INFO  | //' | cut -c1-200 | tail -${LINES_OUT:-2}
