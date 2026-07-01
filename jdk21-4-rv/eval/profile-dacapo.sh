#!/bin/bash
# profile-dacapo.sh — async-profiler JFR + monitor statistics for the DaCapo suite.
#
# Uses the *-stats agents and attaches async-profiler. One pass:
#
#     <out>/profile/<gc>/<bench>/r<run>/<mode>-<event>.jfr   (flame data)
#                                        <mode>-stats.txt     (monitor stats)
#                                        <mode>-violation-counts
#
# Common usage:
#     RV_JDK=.../jdk  bash profile-dacapo.sh \
#         --out results/dacapo/native-2g --heap 2g --event wall

set -uo pipefail
BENCH=$(cd "$(dirname "$0")" && pwd)
source "$BENCH/lib-bench.sh"
[ -f "$BENCH/bench-env.sh" ] && source "$BENCH/bench-env.sh" 2>/dev/null || true

# ---- options (only --out is required) --------------------------------------
OUT=""
HEAP="2g"
EVENT="wall"                              # async-profiler event: wall | cpu
RUNS=1
ITERS=10
GCS="serial parallel g1"
MODES="old new"                           # profiling baseline is rarely useful
BENCHMARKS="avrora fop h2 jython luindex lusearch pmd sunflow tomcat xalan"
RVJDK="${RV_JDK:-${PATCHED_JDK:-}}"
AGENTS="${AG:-$(cd "$BENCH/../.." 2>/dev/null && pwd)/tracemop}"
DACAPO="${DACAPO:-$BENCH/lib/dacapo.jar}"
ASP="${ASP:-$(ls "$HOME"/async-profiler*/lib/libasyncProfiler.* \
                 "$HOME"/async-profiler*/build/libasyncProfiler.* 2>/dev/null | head -1)}"
TIMEOUT_SEC=3600

while [ $# -gt 0 ]; do
    case "$1" in
        --out)        OUT="$2";         shift 2 ;;
        --heap)       HEAP="$2";        shift 2 ;;
        --event)      EVENT="$2";       shift 2 ;;
        --runs)       RUNS="$2";        shift 2 ;;
        --iters)      ITERS="$2";       shift 2 ;;
        --gcs)        GCS="$2";         shift 2 ;;
        --modes)      MODES="$2";       shift 2 ;;
        --benchmarks) BENCHMARKS="$2";  shift 2 ;;
        --rv-jdk)     RVJDK="$2";       shift 2 ;;
        --agents)     AGENTS="$2";      shift 2 ;;
        --dacapo)     DACAPO="$2";      shift 2 ;;
        --asp)        ASP="$2";         shift 2 ;;
        --timeout)    TIMEOUT_SEC="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---- validate --------------------------------------------------------------
[ -n "$OUT" ] || { echo "Usage: $0 --out <dir> [--heap 2g] [--event wall|cpu]" >&2; exit 1; }
[ -x "$RVJDK/bin/java" ] || { echo "no RV JDK: $RVJDK (set RV_JDK=...)" >&2; exit 1; }
[ -f "$DACAPO" ]         || { echo "no DaCapo jar: $DACAPO (set --dacapo)" >&2; exit 1; }
[ -n "$ASP" ] && [ -f "$ASP" ] || { echo "no async-profiler (set ASP=...)" >&2; exit 1; }
for m in $MODES; do a=$(agent_arg "$m" "$AGENTS" 1); [ -z "$a" ] && continue
    f=${a#-javaagent:}; [ -f "$f" ] || { echo "no stats agent: $f (build-agents.sh)" >&2; exit 1; }; done

# ---- set up ----------------------------------------------------------------
JAVA="$RVJDK/bin/java"
HEAP_ARGS=$(heap_args "$HEAP")
DACAPO_FLAGS="-s default --no-validation -n $ITERS"
mkdir -p "$OUT/profile"; OUT=$(cd "$OUT" && pwd)
WORK="$OUT/.work"; mkdir -p "$WORK"
CSV="$OUT/profile/results.csv"; [ -f "$CSV" ] || echo "$RV_CSV_HEADER" > "$CSV"

echo "=== profile-dacapo $(date) | heap=$HEAP [$HEAP_ARGS] event=$EVENT iters=$ITERS | gcs=[$GCS] modes=[$MODES] runs=$RUNS"
echo "    RVJDK=$RVJDK  agents=$AGENTS  asp=$ASP  out=$OUT/profile"

# ---- run one (gc, bench, mode, run); append a CSV row ----------------------
run_one() {
    local gc="$1" bench="$2" mode="$3" run="$4"
    local rdir="$OUT/profile/$gc/$bench/r$run"; mkdir -p "$rdir"
    local rl="$rdir/$mode-run.log" jfr="$rdir/$mode-$EVENT.jfr" vc="$rdir/$mode-violation-counts"
    local agent; agent=$(agent_arg "$mode" "$AGENTS" 1)   # stats variant

    local args="$(gc_flag "$gc") $HEAP_ARGS $(rv_opens_for "$mode")"
    args+=" -agentpath:$ASP=start,event=$EVENT,file=$jfr"

    rm -f "$WORK/violation-counts"
    ( cd "$WORK" && timeout --kill-after=60 "$TIMEOUT_SEC" \
        "$JAVA" $args $agent -jar "$DACAPO" $DACAPO_FLAGS "$bench" ) >"$rl" 2>&1
    local rc=$?
    [ -s "$WORK/violation-counts" ] && cp "$WORK/violation-counts" "$vc"
    grep -E '^(== .* ==|#monitors:|#event|#category)' "$rl" >"$rdir/$mode-stats.txt" 2>/dev/null
    [ -s "$rdir/$mode-stats.txt" ] || rm -f "$rdir/$mode-stats.txt"

    local time_ms viols have status
    time_ms=$(grep -oE 'PASSED in [0-9]+ msec' "$rl" | grep -oE '[0-9]+' | tail -1)
    viols=$(viol_total "$vc")
    have=0; [ -z "$time_ms" ] && have=1
    status=$(run_status "$rc" "$have")

    echo "$gc,$bench,$run,$mode,${time_ms:-0},0,$viols,,,,$status" >> "$CSV"
    printf "  %-8s %-10s r%s %-9s %s -> %s\n" "$gc" "$bench" "$run" "$mode" "$status" "$(basename "$jfr")"
}

# ---- main ------------------------------------------------------------------
for run in $(seq 1 "$RUNS"); do
    for gc in $GCS; do
        for bench in $BENCHMARKS; do
            echo "=== r$run / $gc / $bench ==="
            for mode in $MODES; do
                run_one "$gc" "$bench" "$mode" "$run"
            done
        done
    done
done

rm -rf "$WORK"
echo "=== done $(date) -> $OUT/profile/ (jfr + stats) ==="
