#!/bin/bash
# Starts every game of the launcher one after the other through the app (so copy, signing and settings are exactly what a user gets), waits, and writes a report:
# ReShade loaded? graphics path? still running after 30 s?  -> GAMES.md in the project folder.  Refuses to run while one of the games is already running.
cd "$(dirname "$0")/.."
APP=App/MacShade.app
S="$HOME/Library/Application Support/MacShade"
python3 - "$S/games.json" <<'PY' > /tmp/check_games.list
import json, sys
for g in json.load(open(sys.argv[1])): print(g["id"], g["name"], g["sourcePath"], sep="\t")
PY
OUT=GAMES.md
{ echo "# Compatibility check ($(date '+%Y-%m-%d %H:%M'))"; echo; echo "| Game | ReShade loaded | Path | Runs 30 s | Note |"; echo "|---|---|---|---|---|"; } > $OUT
while IFS=$'\t' read -r ID NAME SRC; do
  EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$SRC/Contents/Info.plist" 2>/dev/null)
  if pgrep -x "$EXE" >/dev/null; then echo "| $NAME | – | – | – | skipped: already running |" >> $OUT; continue; fi
  LOG="$S/Instances/$ID/ReShade.log"; rm -f "$LOG"
  pkill -x MacShade; sleep 1
  open -n "$APP" --args --start "$NAME"
  loaded=no; path="–"; alive=no
  for i in $(seq 1 24); do   # up to 2 minutes for copy + signing + start
    sleep 5
    if [ -f "$LOG" ] && grep -aq "Initializing ReShade" "$LOG"; then loaded=yes; break; fi
  done
  if [ $loaded = yes ]; then
    for i in $(seq 1 12); do sleep 5; grep -aq "Bridge: processing\|pipelined processing\|Running on" "$LOG" && break; done   # the graphics path shows up a few seconds after ReShade loads
    sleep 20
    GP=$(pgrep -f "Games/$ID" | head -1); [ -n "$GP" ] && alive=yes
    if grep -aq "pipelined processing of .* Metal" "$LOG"; then path="Metal bridge (pipelined)"
    elif grep -aq "pipelined processing" "$LOG"; then path="OpenGL bridge (pipelined)"
    elif grep -aq "Bridge: processing .* Metal" "$LOG"; then path="Metal bridge"
    elif grep -aq "Bridge: processing .* OpenGL" "$LOG"; then path="OpenGL bridge"
    elif grep -aq "Running on" "$LOG"; then path="Vulkan (direct)"; fi
  fi
  note=$(grep -a -E "ERROR|error" "$LOG" 2>/dev/null | head -1 | sed 's/.*| //' | cut -c1-80)
  echo "| $NAME | $loaded | $path | $alive | $note |" >> $OUT
  pkill -f "Games/$ID" ; pkill -x MacShade; sleep 2
done < /tmp/check_games.list
open "$APP"
cat $OUT
