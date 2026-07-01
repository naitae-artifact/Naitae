#!/bin/bash
# Run one project through the image, stock vs native, and check both build and
# agree on the violation count. Usage: bash smoke-test.sh [owner/repo] [sha]
set -euo pipefail

repo="${1:-agarciadom/xeger}"
sha="${2:-f3b8a33b0f4438d639150b57b9a0257d50c71bc2}"
img="${IMG:-naitae/rv-jdk21:latest}"
cells="${CELLS:-javamop javamop-native}"

work=$(mktemp -d)
trap 'rm -rf "$work" 2>/dev/null || true' EXIT
echo "$repo,$sha" > "$work/projects.csv"

docker run --rm -v "$work":/work \
  -e CSV=/work/projects.csv -e WORK=/work/out -e CELLS="$cells" \
  "$img" run-all.sh

results="$work/out/results.csv"
echo
column -t -s, "$results"
echo

# every cell built, and they all report the same violation count
if tail -n +2 "$results" | grep -qv ',PASS,'; then
  echo "FAIL: a cell did not pass"; exit 1
fi
viols=$(tail -n +2 "$results" | cut -d, -f5 | sort -u)
if [ "$(echo "$viols" | wc -l)" -ne 1 ]; then
  echo "FAIL: cells disagree on violations ($viols)"; exit 1
fi
echo "OK: all cells passed, $viols violations"
