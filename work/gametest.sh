#!/bin/bash
# usage: gametest.sh <game> [secs]   Runs every bundled preset of one game in that game (copy of the real instance), screenshots each, reports ReShade errors and bridge cost.
# game: quake | doom | quetoo | ut99 | ut2004
cd "$(dirname "$0")/.."
A=~/Library/Application\ Support/MacShade; SECS=${2:-40}
case $1 in
 quake)  ID=7F6767AA-11C7-4C3F-9844-1D68F20B6E84; APP=vkQuake.app;  ARGS='-basedir /Volumes/Daten/Games/Quake -window -width 1280 -height 800 +map e1m1' ;;
 doom)   ID=B4A73A1E-A064-43C8-B8F1-B450DB417824; APP=UZDoom.app;   ARGS='-iwad /Volumes/Daten/Games/Doom/DOOM2.WAD -warp 1 -width 1280 -height 800' ;;
 quetoo) ID=BF58EA26-3A06-4C7B-AEFC-87EF7A4127AB; APP=Quetoo.app;   ARGS='+set r_fullscreen 0 +set r_windowWidth 1280 +set r_windowHeight 800 +map torn' ;;
 ut99)   ID=3D95F0A5-2327-4EDD-9B48-E0826580FCE6; APP=UnrealTournament.app; ARGS='DM-Deck16][?game=Botpack.DeathMatchPlus?numbots=6 -nointro' ;;
 ut2004) ID=A0F33758-322A-4376-ABF4-ED8C1E9208E9; APP=UT2004.app;   ARGS='DM-Rankin?Game=XGame.xDeathMatch?numbots=6' ;;
esac
export MAPARGS="$ARGS"
mkdir -p work/shots
rm -f ~/Library/Application\ Support/UT2004/System/Running.ini 2>/dev/null
for f in ${3:-App/Resources/Presets/$1/*.ini App/Resources/Presets/_all/*.ini}; do
  n=$(basename "$f" .ini)
  cp "$f" "$A/Instances/$ID/$n.ini"          # make sure the instance has it (the real app seeds it the same way)
  tech=$(sed -n 's/^Techniques=//p' "$f")
  export EXTRA_PRESET="$(sed 1,2d "$f")"
  echo "## $1 / $n"
  SHOT=work/shots/$1-$n.png LINES_OUT=2 ./work/fps_test.sh "$A/Games/$ID/$APP" "$A/Instances/$ID" $SECS "$tech" 2>&1 | grep -a "split\|stats\|ABORT" | tail -1
  grep -a "error\|failed to compile\|X[0-9][0-9][0-9][0-9]" work/benchbase/ReShade.log | head -3
done
