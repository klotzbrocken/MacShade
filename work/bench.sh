#!/bin/bash
# usage: bench.sh "name:Tech@file.fx,Tech2@file.fx" ...   -> bridge cost per frame in UT2004 for each technique list ("name:" alone = no effects)
cd "$(dirname "$0")/.."
A=~/Library/Application\ Support/MacShade; ID=A0F33758-322A-4376-ABF4-ED8C1E9208E9
export MAPARGS='DM-Rankin?Game=XGame.xDeathMatch?numbots=6 -nosound'
for spec in "$@"; do echo "## ${spec%%:*}"; ./work/fps_test.sh "$A/Games/$ID/UT2004.app" "$A/Instances/$ID" 45 "${spec#*:}"; done
