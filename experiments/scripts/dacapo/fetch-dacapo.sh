#!/bin/bash
# Download the pinned DaCapo jar into lib/, which is kept out of git.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VER="${VER:-23.11-MR2}"
URL="${URL:-https://download.dacapobench.org/chopin/dacapo-${VER}-chopin.zip}"
JAR="$HERE/lib/dacapo-${VER}-chopin.jar"

[ -f "$JAR" ] && { echo "[have] $JAR"; exit 0; }
mkdir -p "$HERE/lib"
echo "[get] $URL"
curl -fL "$URL" -o "$HERE/lib/dacapo.zip"
unzip -o "$HERE/lib/dacapo.zip" -d "$HERE/lib" >/dev/null   # unpacks the jar (+ any data) into lib/
rm -f "$HERE/lib/dacapo.zip"
[ -f "$JAR" ] || { echo "no $JAR after unzip, check the chopin layout" >&2; exit 1; }
echo "[ok] $JAR"
