#!/bin/bash
# Run the DaCapo suite (stock vs native RV) inside the evaluation image, driven from
# the host with bind mounts. It calls run-dacapo.sh over the four cells:
# norv-stock and norv-mod with no agent, and javamop and javamop-native with the
# stock and native agents. The image already has /opt/jdk-{stock,native} and
# /agents/javamop-{stock,native}.jar, so only the DaCapo jar is bound in.
#
# Fetch the jar once with fetch-dacapo.sh, then run e.g.
#   OUT=~/dacapo-out bash run-dacapo-docker.sh              # timing + heap
#   OUT=~/dacapo-prof PROFILE=1 bash run-dacapo-docker.sh   # async-profiler JFR + stats
#
# Knobs: IMG OUT HEAP ITERS RUNS GCS BENCHMARKS TIMEOUT PASSES JAR, plus PROFILE
# with EVENT and ASP for the profiling run, LAZYMOP_AGENTS_HOST (dir holding
# lazymop-{stock,native}-gen.jar), and CPUSET/MEMS for NUMA pinning, e.g.
# CPUSET=$(seq -s, 0 2 110) MEMS=0.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

IMG="${IMG:-naitae/rv-jdk21:latest}"
OUT="${OUT:-$HOME/dacapo-out}"
HEAP="${HEAP:-96g}"
ITERS="${ITERS:-10}"
RUNS="${RUNS:-1}"
GCS="${GCS:-serial parallel g1}"
BENCHMARKS="${BENCHMARKS:-avrora h2 jython luindex lusearch pmd sunflow xalan}"
TIMEOUT="${TIMEOUT:-86400}"     # seconds; 24h/cell by default; 0 = no timeout (coreutils `timeout 0`)
PASSES="${PASSES:-gclog timing}"     # gclog (heap+time) first, then timing (clean time)
JAR="${JAR:-$HERE/lib/dacapo-23.11-MR2-chopin.jar}"

# BENCHMARKS=all runs the full chopin 23.11 set of 22 benches. Some ERR on JDK21, which is recorded not skipped.
ALL_CHOPIN="avrora batik biojava cassandra eclipse fop graphchi h2 h2o jme jython kafka luindex lusearch pmd spring sunflow tomcat tradebeans tradesoap xalan zxing"
[ "$BENCHMARKS" = all ] && BENCHMARKS="$ALL_CHOPIN"
NATIVE_JDK="${NATIVE_JDK:-/opt/jdk-native}"
STOCK_JDK="${STOCK_JDK:-/opt/jdk-stock}"

[ -f "$JAR" ] || { echo "no DaCapo jar: $JAR  (run fetch-dacapo.sh first, or set JAR=)" >&2; exit 1; }
mkdir -p "$OUT"

PIN=""
[ -n "${CPUSET:-}" ] && PIN="--cpuset-cpus=${CPUSET}"
[ -n "${MEMS:-}" ]   && PIN="$PIN --cpuset-mems=${MEMS}"
# Optionally override the baked lazymop jars by mounting host copies over the
# /agents convention names the runner derives (run-dacapo.sh picks them up).
LAZYMOP_ARGS=()
if [ -n "${LAZYMOP_AGENTS_HOST:-}" ]; then
  for j in lazymop-stock-gen lazymop-native-gen; do
    [ -f "$LAZYMOP_AGENTS_HOST/$j.jar" ] || { echo "missing $LAZYMOP_AGENTS_HOST/$j.jar" >&2; exit 1; }
    LAZYMOP_ARGS+=(-v "$LAZYMOP_AGENTS_HOST/$j.jar:/agents/$j.jar")
  done
fi

NAME="${NAME:-dacapo-23-${HEAP}b}"        # e.g. dacapo-23-96gb

# PROFILE=1 runs run-dacapo.sh --profile (async-profiler JFR + monitor stats,
# old/new modes on the native JDK). Otherwise it runs the timing + heap passes.
if [ "${PROFILE:-0}" = 1 ]; then
  MODES="${MODES:-old new}"
  ASP="${ASP:-/opt/async-profiler/build/libasyncProfiler.so}"
  EVENT="${EVENT:-wall}"
  echo "=== dacapo profile '$NAME': modes=[$MODES] gcs=[$GCS] heap=$HEAP iters=$ITERS event=$EVENT timeout=$TIMEOUT ==="
  echo "    rv-jdk=$NATIVE_JDK asp=$ASP benchmarks=[$BENCHMARKS]"
  docker run --rm --name "dacapo-$NAME" --user "$(id -u):$(id -g)" $PIN \
    -v "$HERE":/eval -v "$OUT":/out -e AG=/agents "${LAZYMOP_ARGS[@]}" \
    -e PROFILE=1 -e RV_JDK="$NATIVE_JDK" -e ASP="$ASP" -e EVENT="$EVENT" \
    -e DACAPO="/eval/lib/$(basename "$JAR")" -e OUT="/out/$NAME" \
    -e HEAP="$HEAP" -e ITERS="$ITERS" -e RUNS="$RUNS" -e GCS="$GCS" \
    -e TIMEOUT="$TIMEOUT" -e MODES="$MODES" -e BENCHMARKS="$BENCHMARKS" \
    "$IMG" bash /eval/run-dacapo.sh
  echo "=== done -> $OUT/$NAME/profile/results.csv ==="
  exit 0
fi

MODES="${MODES:-norv-stock norv-mod javamop javamop-native}"
echo "=== dacapo '$NAME': modes=[$MODES] gcs=[$GCS] heap=$HEAP iters=$ITERS converge=${CONVERGE:-0} timeout=$TIMEOUT ==="
echo "    native=$NATIVE_JDK stock=$STOCK_JDK benchmarks=[$BENCHMARKS]"
docker run --rm --name "dacapo-$NAME" --user "$(id -u):$(id -g)" $PIN \
  -v "$HERE":/eval -v "$OUT":/out -e AG=/agents "${LAZYMOP_ARGS[@]}" \
  -e SKIP_IF_BASELINE_FAILS="${SKIP_IF_BASELINE_FAILS:-1}" \
  -e NATIVE_JDK="$NATIVE_JDK" -e STOCK_JDK="$STOCK_JDK" \
  -e DACAPO="/eval/lib/$(basename "$JAR")" -e OUT="/out/$NAME" \
  -e HEAP="$HEAP" -e ITERS="$ITERS" -e RUNS="$RUNS" -e GCS="$GCS" \
  -e TIMEOUT="$TIMEOUT" -e PASSES="$PASSES" -e CONVERGE="${CONVERGE:-0}" \
  -e MODES="$MODES" -e BENCHMARKS="$BENCHMARKS" \
  "$IMG" bash /eval/run-dacapo.sh
echo "=== done -> $OUT/$NAME/{$(echo $PASSES | tr ' ' ,)}/results.csv ==="
