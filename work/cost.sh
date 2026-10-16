#!/bin/bash
# ReShade cost per frame (record + GPU wait, ms) for single effects in UT2004 (OpenGL bridge, pipelined). usage: cost.sh "Tech@file.fx" ...
cd "$(dirname "$0")/.."
for t in "$@"; do echo "## $t"; LINES_OUT=4 ./work/bench.sh "x:$t" 2>&1 | grep "split" | tail -2; grep -a "error\|warning X\|failed" work/benchbase/ReShade.log 2>/dev/null | head -3; done
