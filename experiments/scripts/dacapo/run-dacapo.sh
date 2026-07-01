#!/bin/bash
# DaCapo runner, run inside the image by run-dacapo-docker.sh.
#   default:   timing + gclog passes, records time and peak heap.
#   --profile: attaches async-profiler, records a JFR + monitor stats.
# Configured entirely via env vars; only OUT is required:
#   OUT=results/native-8g HEAP=8g RV_JDK=.../jdk bash run-dacapo.sh
#   OUT=results/prof PROFILE=1 EVENT=wall RV_JDK=.../jdk bash run-dacapo.sh

set -uo pipefail
BENCH=$(cd "$(dirname "$0")" && pwd)
[ -f "$BENCH/bench-env.sh" ] && source "$BENCH/bench-env.sh" 2>/dev/null || true
export RVMLOGGINGLEVEL="${RVMLOGGINGLEVEL:-UNIQUE}"

CSV_HEADER="gc,project,run,mode,time_ms,peak_heap_mb,postgc_live_mb,violations,tests_run,tests_fail,tests_error,status"
RV_OPENS="--add-opens java.base/java.lang.rv=ALL-UNNAMED"   # native indexing tree lives here

# --- config (all via env; run-dacapo-docker.sh passes these with -e) ---------
#   OUT (required)  HEAP=8g  RUNS  ITERS=10  GCS  MODES  BENCHMARKS  PASSES
#   TIMEOUT=86400  EVENT=wall  CONVERGE=0  PROFILE=0  + the JDK/agent/jar paths.
PROFILE="${PROFILE:-0}"
OUT="${OUT:-}"
HEAP="${HEAP:-8g}"
RUNS="${RUNS:-}"                          # default 3 for measure, 1 for profile
ITERS="${ITERS:-10}"
EVENT="${EVENT:-wall}"                    # async-profiler event: wall or cpu
CONVERGE="${CONVERGE:-0}"
TIMEOUT="${TIMEOUT:-86400}"               # seconds per cell; 0 = none
GCS="${GCS:-serial parallel g1}"
MODES="${MODES:-}"                        # default set per profile/measure below
PASSES="${PASSES:-gclog timing}"          # gclog (heap+time) first, then timing (clean time)
BENCHMARKS="${BENCHMARKS:-avrora fop h2 jython luindex lusearch pmd sunflow tomcat xalan}"
RVJDK="${RV_JDK:-${PATCHED_JDK:-}}"
NATIVE_JDK="${NATIVE_JDK:-${RVJDK:-/opt/jdk-native}}"
STOCK_JDK="${STOCK_JDK:-/opt/jdk-stock}"
AGENTS="${AG:-$(cd "$BENCH/../../.." 2>/dev/null && pwd)/env/agents}"   # all tool jars live here
DACAPO="${DACAPO:-$BENCH/lib/dacapo.jar}"
ASP="${ASP:-$(ls "$HOME"/async-profiler*/lib/libasyncProfiler.* \
                 "$HOME"/async-profiler*/build/libasyncProfiler.* 2>/dev/null | head -1)}"

[ -n "$OUT" ]    || { echo "Usage: OUT=<dir> [HEAP=8g] [PROFILE=1] [MODES=...] bash $0" >&2; exit 1; }
[ -f "$DACAPO" ] || { echo "no DaCapo jar: $DACAPO (set DACAPO=)" >&2; exit 1; }

# --- helpers ----------------------------------------------------------------
gc_flag() { case "$1" in
    serial) echo "-XX:+UseSerialGC";; parallel) echo "-XX:+UseParallelGC";;
    g1) echo "-XX:+UseG1GC";; *) return 1;; esac; }

# 8g -> -Xmx8g, 8g_max -> -Xmx8g, 8g_fixed -> -Xms8g -Xmx8g.
heap_args() { local t="$1" s="${t%_*}"; case "${t##*_}" in
    fixed) echo "-Xms$s -Xmx$s";; max) echo "-Xmx$s";; *) echo "-Xmx$t";; esac; }

xlog_gc() { echo "-Xlog:gc*,gc+heap=info,safepoint:file=$1:time,uptime,level,tags"; }

# Each mode -> "<jdk> <agent-jar|-> <opens>". All jars derive from $AGENTS by the
# convention <tool>-<stock|native>[-gen].jar; stats=1 picks the -stats variant.
# (lazymop uses a -gen suffix and has no -stats build.)
mode_spec() { local m="$1" v=""; [ "${2:-0}" = 1 ] && v="-stats"; case "$m" in
    norv-stock)     echo "$STOCK_JDK - " ;;
    norv-mod)       echo "$NATIVE_JDK - " ;;
    javamop)        echo "$NATIVE_JDK $AGENTS/javamop-stock$v.jar " ;;
    javamop-native) echo "$NATIVE_JDK $AGENTS/javamop-native$v.jar $RV_OPENS" ;;
    valg-stock)     echo "$NATIVE_JDK $AGENTS/valg-stock$v.jar " ;;
    valg-native)    echo "$NATIVE_JDK $AGENTS/valg-native$v.jar $RV_OPENS" ;;
    lazymop-stock)  echo "$NATIVE_JDK $AGENTS/lazymop-stock-gen.jar " ;;
    lazymop-native) echo "$NATIVE_JDK $AGENTS/lazymop-native-gen.jar $RV_OPENS" ;;
    baseline)       echo "$RVJDK - " ;;
    old)            echo "$RVJDK $AGENTS/javamop-stock$v.jar " ;;
    new)            echo "$RVJDK $AGENTS/javamop-native$v.jar $RV_OPENS" ;;
    *) return 1 ;;
esac; }
mode_is_baseline() { case "$1" in norv-stock|norv-mod|baseline) return 0;; *) return 1;; esac; }

# Peak used heap (MB) from a -Xlog:gc file: "100M->40M" lines + the exit dump.
parse_peak_heap() {
    [ -f "$1" ] || { echo 0; return; }
    local peak=0 line val
    while IFS= read -r line; do
        if   [[ "$line" =~ ([0-9]+)M-\>[0-9]+M ]]; then val=${BASH_REMATCH[1]}
        elif [[ "$line" =~ \[gc,heap,exit\] && ! "$line" =~ (Metaspace|class.space) \
                 && "$line" =~ used[[:space:]]+([0-9]+)K ]]; then val=$(( BASH_REMATCH[1] / 1024 ))
        else continue; fi
        (( val > peak )) && peak=$val
    done < "$1"
    echo "$peak"
}

# Post-GC live set (MB): right-hand side of "100M->40M" (what survives each GC) plus
# the exit dump; the max approximates peak retained live data (paper's live metric).
parse_postgc_live() {
    [ -f "$1" ] || { echo 0; return; }
    local live=0 line val
    while IFS= read -r line; do
        if   [[ "$line" =~ [0-9]+M-\>([0-9]+)M ]]; then val=${BASH_REMATCH[1]}
        elif [[ "$line" =~ \[gc,heap,exit\] && ! "$line" =~ (Metaspace|class.space) \
                 && "$line" =~ used[[:space:]]+([0-9]+)K ]]; then val=$(( BASH_REMATCH[1] / 1024 ))
        else continue; fi
        (( val > live )) && live=$val
    done < "$1"
    echo "$live"
}

viol_total() { [ -s "$1" ] && awk '{s+=$1} END{print s+0}' "$1" 2>/dev/null || echo 0; }

# TIMEOUT if killed, ERR if the metric is missing, else OK.
run_status() { case "$1" in 124|137) echo TIMEOUT;; *) [ "$2" = 0 ] && echo OK || echo ERR;; esac; }

RESUME_OK="${RESUME_OK:-1}"   # skip cells already recorded OK
already_ok() {
    [ "$RESUME_OK" = 1 ] && [ -f "$1" ] || return 1
    awk -F, -v gc="$2" -v b="$3" -v r="$4" -v m="$5" \
        'NR>1 && $1==gc && $2==b && $3==r && $4==m && $12=="OK"{f=1} END{exit f?0:1}' "$1"
}

# --- one cell ---------------------------------------------------------------
LAST_STATUS=""
run_one() {
    local pass="$1" gc="$2" bench="$3" mode="$4" run="$5" csv="$6"
    local rdir="$OUT/$pass/$gc/$bench/r$run"; mkdir -p "$rdir"
    local rl="$rdir/$mode-run.log" gl="$rdir/$mode-gc.log" vc="$rdir/$mode-violation-counts"

    if already_ok "$csv" "$gc" "$bench" "$run" "$mode"; then
        LAST_STATUS=OK
        printf "  %-7s %-8s %-10s r%s %-9s skip=already-OK\n" "$pass" "$gc" "$bench" "$run" "$mode"
        return
    fi

    local stats=0; [ "$pass" = profile ] && stats=1
    read -r jdk jar opens < <(mode_spec "$mode" "$stats")
    local agent=""; [ "$jar" != - ] && agent="-javaagent:$jar"
    local args; args="$(gc_flag "$gc") $HEAP_ARGS $opens"
    local jfr=""
    if   [ "$pass" = profile ]; then jfr="$rdir/$mode-$EVENT.jfr"; args+=" -agentpath:$ASP=start,event=$EVENT,file=$jfr"
    elif [ "$pass" = gclog   ]; then args+=" $(xlog_gc "$gl")"; fi

    rm -f "$WORK/violation-counts"
    ( cd "$WORK" && timeout --kill-after=60 "$TIMEOUT" \
        "$jdk/bin/java" $args $agent -jar "$DACAPO" $DACAPO_FLAGS "$bench" ) >"$rl" 2>&1
    local rc=$?
    [ -s "$WORK/violation-counts" ] && cp "$WORK/violation-counts" "$vc"
    if [ "$pass" = profile ]; then
        grep -E '^(== .* ==|#monitors:|#event|#category)' "$rl" >"$rdir/$mode-stats.txt" 2>/dev/null
        [ -s "$rdir/$mode-stats.txt" ] || rm -f "$rdir/$mode-stats.txt"
    fi

    local time_ms heap_mb=0 live_mb=0 viols status
    time_ms=$(grep -oE 'PASSED in [0-9]+ msec' "$rl" | grep -oE '[0-9]+' | tail -1)
    [ "$pass" = gclog ] && { heap_mb=$(parse_peak_heap "$gl"); live_mb=$(parse_postgc_live "$gl"); }
    viols=$(viol_total "$vc")
    status=$(run_status "$rc" "$([ -z "$time_ms" ] && echo 1 || echo 0)"); LAST_STATUS="$status"

    echo "$gc,$bench,$run,$mode,${time_ms:-0},$heap_mb,$live_mb,$viols,,,,$status" >> "$csv"
    printf "  %-7s %-8s %-10s r%s %-9s time=%-7s heap=%-5s live=%-5s viol=%-6s %s\n" \
        "$pass" "$gc" "$bench" "$run" "$mode" "${time_ms:-ERR}ms" "${heap_mb}M" "${live_mb}M" "$viols" "$status"
}

# --- setup + driver ---------------------------------------------------------
HEAP_ARGS=$(heap_args "$HEAP")
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd); WORK="$OUT/.work"; mkdir -p "$WORK"

if [ "$PROFILE" = 1 ]; then
    PASSES="profile"; RUNS="${RUNS:-1}"; MODES="${MODES:-old new}"
    DACAPO_FLAGS="-s default --no-validation -n $ITERS"
    [ -x "$RVJDK/bin/java" ]        || { echo "no RV JDK: $RVJDK (set RV_JDK=...)" >&2; exit 1; }
    [ -n "$ASP" ] && [ -f "$ASP" ]  || { echo "no async-profiler (set ASP=...)" >&2; exit 1; }
    for m in $MODES; do read -r _ j _ < <(mode_spec "$m" 1)
        [ "$j" = - ] || [ -f "$j" ] || { echo "no stats agent: $j (build-agents.sh)" >&2; exit 1; }; done
else
    RUNS="${RUNS:-3}"; MODES="${MODES:-norv-stock norv-mod javamop javamop-native}"
    [ "$CONVERGE" = 1 ] && DACAPO_FLAGS="-s default --no-validation --converge --max-iterations $ITERS" \
                        || DACAPO_FLAGS="-s default --no-validation -n $ITERS"
    [ -x "$NATIVE_JDK/bin/java" ] || { echo "no native JDK: $NATIVE_JDK (--native-jdk/--rv-jdk)" >&2; exit 1; }
    [ -x "$STOCK_JDK/bin/java"  ] || { echo "no stock JDK: $STOCK_JDK (--stock-jdk)" >&2; exit 1; }
fi

echo "=== run-dacapo $(date) | heap=$HEAP [$HEAP_ARGS] iters=$ITERS converge=$CONVERGE profile=$PROFILE"
echo "    passes=[$PASSES] gcs=[$GCS] modes=[$MODES] runs=$RUNS"
echo "    native=$NATIVE_JDK stock=$STOCK_JDK rv=$RVJDK agents=$AGENTS out=$OUT"

SKIP_IF_BASELINE_FAILS="${SKIP_IF_BASELINE_FAILS:-0}"   # 1: if baseline isn't OK, skip rest of bench/gc
for pass in $PASSES; do
    mkdir -p "$OUT/$pass"; csv="$OUT/$pass/results.csv"
    [ -f "$csv" ] || echo "$CSV_HEADER" > "$csv"
    for run in $(seq 1 "$RUNS"); do for gc in $GCS; do for bench in $BENCHMARKS; do
        echo "=== $pass / r$run / $gc / $bench ==="
        for mode in $MODES; do
            run_one "$pass" "$gc" "$bench" "$mode" "$run" "$csv"
            if [ "$SKIP_IF_BASELINE_FAILS" = 1 ] && mode_is_baseline "$mode" && [ "$LAST_STATUS" != OK ]; then
                echo "  [skip] $bench/$gc: $mode=$LAST_STATUS -> skip rest of bench"; break
            fi
        done
    done; done; done
done
rm -rf "$WORK"
echo "=== done $(date) -> $OUT/*/results.csv ==="
