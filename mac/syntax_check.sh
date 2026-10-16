#!/bin/bash
# usage: syntax_check.sh [files...]  (default: sources.txt) -> per-file error counts + log in /tmp
cd "$(dirname "$0")/../reshade"; . ../mac/flags.sh
files=${@:-$(cat ../mac/sources.txt)}
mkdir -p ../work/syn
for f in $files; do
  ( out=../work/syn/$(echo $f | tr '/' '_').log
    clang++ $FLAGS -fsyntax-only -ferror-limit=0 $f >$out 2>&1; echo "$(grep -c 'error:' $out) $f" ) &
done | sort -n; wait
