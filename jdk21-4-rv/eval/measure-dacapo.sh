#!/bin/bash
# measure-dacapo.sh — performance + memory for the DaCapo suite (NO profiler).
#
# Each benchmark is run with no agent (baseline), the stock agent (old), and the
# native agent (new). Two passes are written:
#
#     <out>/timing/   clean time   (DaCapo's "PASSED in N msec")
#     <out>/gclog/    + peak heap   (GC-logged, forced shutdown GC)
#
# Common usage:
#     RV_JDK=.../jdk  bash measure-dacapo.sh \
#         --out results/dacapo/native-2g --heap 2g --iters 10

set -uo pipefail
BENCH=$(cd "$(dirname "$0")" && pwd)
source "$BENCH/lib-bench.sh"
[ -f "$BENCH/bench-env.sh" ] && source "$BENCH/bench-env.sh" 2>/dev/null || true

# ---- options (only --out is required) --------------------------------------
OUT=""
HEAP="2g"
RUNS=3
ITERS=10                                  # DaCapo iterations; the last is timed
GCS="serial parallel g1"
MODES="baseline old new"
BENCHMARKS="avrora fop h2 jython luindex lusearch pmd sunflow tomcat xalan"
RVJDK="${RV_JDK:-${PATCHED_JDK:-}}"
AGENTS="${AG:-$(cd "$BENCH/../.." 2>/dev/null && pwd)/tracemop}"
DACAPO="${DACAPO:-$BENCH/lib/dacapo.jar}"
TIMEOUT_SEC=3600

while [ $# -gt 0 ]; do
    case "$1" in
        --out)        OUT="$2";         shift 2 ;;
        --heap)       HEAP="$2";        shift 2 ;;
        --runs)       RUNS="$2";        shift 2 ;;
        --iters)      ITERS="$2";       shift 2 ;;
        --gcs)        GCS="$2";         shift 2 ;;
        --modes)      MODES="$2";       shift 2 ;;
        --benchmarks) BENCHMARKS="$2";  shift 2 ;;
        --rv-jdk)     RVJDK="$2";       shift 2 ;;
        --agents)     AGENTS="$2";      shift 2 ;;
        --dacapo)     DACAPO="$2";      shift 2 ;;
        --timeout)    TIMEOUT_SEC="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---- validate --------------------------------------------------------------
[ -n "$OUT" ] || { echo "Usage: $0 --out <dir> [--heap 2g] [--iters 10] [--runs 3]" >&2; exit 1; }
[ -x "$RVJDK/bin/java" ] || { echo "no RV JDK: $RVJDK (set RV_JDK=...)" >&2; exit 1; }
[ -f "$DACAPO" ]         || { echo "no DaCapo jar: $DACAPO (set --dacapo)" >&2; exit 1; }
FORCER="$BENCH/lib/gc-forcer.jar"
[ -f "$FORCER" ] || { echo "no gc-forcer: $FORCER (needed for the gclog pass)" >&2; exit 1; }

# ---- set up ----------------------------------------------------------------
JAVA="$RVJDK/bin/java"
HEAP_ARGS=$(heap_args "$HEAP")
DACAPO_FLAGS="-s default --no-validation -n $ITERS"
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
WORK="$OUT/.work"; mkdir -p "$WORK"        # DaCapo scratch + violation-counts live here

echo "=== measure-dacapo $(date) | heap=$HEAP [$HEAP_ARGS] iters=$ITERS | gcs=[$GCS] modes=[$MODES] runs=$RUNS"
echo "    RVJDK=$RVJDK  agents=$AGENTS  out=$OUT"

# ---- run one (pass, gc, bench, mode, run); append a CSV row ----------------
run_one() {
    local pass="$1" gc="$2" bench="$3" mode="$4" run="$5" csv="$6"
    local rdir="$OUT/$pass/$gc/$bench/r$run"; mkdir -p "$rdir"
    local rl="$rdir/$mode-run.log" gl="$rdir/$mode-gc.log" vc="$rdir/$mode-violation-counts"
    local agent; agent=$(agent_arg "$mode" "$AGENTS" 0)   # "" for baseline

    local args="$(gc_flag "$gc") $HEAP_ARGS $(rv_opens_for "$mode")"
    [ "$pass" = gclog ] && args+=" $(xlog_gc "$gl") -javaagent:$FORCER"

    rm -f "$WORK/violation-counts"
    ( cd "$WORK" && timeout --kill-after=60 "$TIMEOUT_SEC" \
        "$JAVA" $args $agent -jar "$DACAPO" $DACAPO_FLAGS "$bench" ) >"$rl" 2>&1
    local rc=$?
    [ -s "$WORK/violation-counts" ] && cp "$WORK/violation-counts" "$vc"

    local time_ms
    time_ms=$(grep -oE 'PASSED in [0-9]+ msec' "$rl" | grep -oE '[0-9]+' | tail -1)
    local heap_mb=0
    [ "$pass" = gclog ] && heap_mb=$(parse_peak_heap "$gl")
    local viols have status
    viols=$(viol_total "$vc")
    have=0; [ -z "$time_ms" ] && have=1
    status=$(run_status "$rc" "$have")

    # DaCapo has no test counts -> three blank columns before status.
    echo "$gc,$bench,$run,$mode,${time_ms:-0},$heap_mb,$viols,,,,$status" >> "$csv"
    printf "  %-6s %-8s %-10s r%s %-9s time=%-7s heap=%-5s viol=%-6s %s\n" \
        "$pass" "$gc" "$bench" "$run" "$mode" "${time_ms:-ERR}ms" "${heap_mb}M" "$viols" "$status"
}

# ---- main: timing + gclog passes ------------------------------------------
for pass in ${PASSES:-timing gclog}; do
    mkdir -p "$OUT/$pass"
    csv="$OUT/$pass/results.csv"; [ -f "$csv" ] || echo "$RV_CSV_HEADER" > "$csv"
    for run in $(seq 1 "$RUNS"); do
        for gc in $GCS; do
            for bench in $BENCHMARKS; do
                echo "=== $pass / r$run / $gc / $bench ==="
                for mode in $MODES; do
                    run_one "$pass" "$gc" "$bench" "$mode" "$run" "$csv"
                done
            done
        done
    done
done

rm -rf "$WORK"
echo "=== done $(date) -> $OUT/{timing,gclog}/results.csv ==="
