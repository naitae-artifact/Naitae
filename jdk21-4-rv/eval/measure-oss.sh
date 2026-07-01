#!/bin/bash
# measure-oss.sh — performance + memory for OSS Maven projects (NO profiler).
#
# Each project is run with no agent (baseline), the stock agent (old), and the
# native agent (new). Two passes are written:
#
#     <out>/timing/   clean wall time   (no GC logging)
#     <out>/gclog/    + peak heap        (GC-logged, forced shutdown GC)
#
# Common usage:
#     RV_JDK=.../jdk  bash measure-oss.sh \
#         --out results/oss/native-8g_fixed --projects ~/gc-profile.txt --heap 8g_fixed

set -uo pipefail
BENCH=$(cd "$(dirname "$0")" && pwd)
source "$BENCH/lib-bench.sh"
[ -f "$BENCH/bench-env.sh" ] && source "$BENCH/bench-env.sh" 2>/dev/null || true

# ---- options (only --out and --projects are required) ----------------------
OUT=""
PROJECTS=""
HEAP="8g_fixed"
RUNS=2
GCS="serial parallel g1"
MODES="baseline old new"
RVJDK="${RV_JDK:-${PATCHED_JDK:-}}"
AGENTS="${AG:-$(cd "$BENCH/../.." 2>/dev/null && pwd)/tracemop}"
TIMEOUT_SEC=1800
MAVEN_HEAP="-Xmx4g"

while [ $# -gt 0 ]; do
    case "$1" in
        --out)      OUT="$2";         shift 2 ;;
        --projects) PROJECTS="$2";    shift 2 ;;
        --heap)     HEAP="$2";        shift 2 ;;
        --runs)     RUNS="$2";        shift 2 ;;
        --gcs)      GCS="$2";         shift 2 ;;
        --modes)    MODES="$2";       shift 2 ;;
        --rv-jdk)   RVJDK="$2";       shift 2 ;;
        --agents)   AGENTS="$2";      shift 2 ;;
        --timeout)  TIMEOUT_SEC="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---- validate --------------------------------------------------------------
[ -n "$OUT" ] && [ -n "$PROJECTS" ] || {
    echo "Usage: $0 --out <dir> --projects <file> [--heap 8g_fixed] [--runs 2]" >&2; exit 1; }
[ -f "$PROJECTS" ]       || { echo "no projects list: $PROJECTS" >&2; exit 1; }
[ -x "$RVJDK/bin/java" ] || { echo "no RV JDK: $RVJDK (set RV_JDK=...)" >&2; exit 1; }
EXT=$(find "$AGENTS" -name 'javamop-extension*.jar' 2>/dev/null | head -1)
[ -n "$EXT" ] && [ -f "$EXT" ] || { echo "no javamop-extension under $AGENTS" >&2; exit 1; }
FORCER="$BENCH/lib/gc-forcer.jar"
[ -f "$FORCER" ] || { echo "no gc-forcer: $FORCER (needed for the gclog pass)" >&2; exit 1; }

# ---- set up ----------------------------------------------------------------
HEAP_ARGS=$(heap_args "$HEAP")
SUREFIRE="surefire:test"   # match run-project.sh (project's own surefire), not a pinned version
# Optional per-run timeout. TIMEOUT_SEC=0 (--timeout 0) disables it entirely —
# required for the heavy projects whose monitored runs legitimately take hours.
TO=""; [ "${TIMEOUT_SEC:-0}" -gt 0 ] 2>/dev/null && TO="timeout --kill-after=60 ${TIMEOUT_SEC}"
export JAVA_HOME="$RVJDK" PATH="$RVJDK/bin:$PATH" MAVEN_OPTS="$MAVEN_HEAP"
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)

echo "=== measure-oss $(date) | heap=$HEAP [$HEAP_ARGS] | gcs=[$GCS] modes=[$MODES] runs=$RUNS"
echo "    RVJDK=$RVJDK  agents=$AGENTS  out=$OUT"

# ---- run one (pass, gc, mode, run); append a CSV row -----------------------
# Reads globals: P PDIR REPOM EXT SUREFIRE AGENTS HEAP_ARGS APP_OPENS FORCER TIMEOUT_SEC OUT
run_one() {
    local pass="$1" gc="$2" mode="$3" run="$4" csv="$5"
    local rdir="$OUT/$pass/$gc/$P/r$run"; mkdir -p "$rdir"
    local rl="$rdir/$mode-run.log" gl="$rdir/$mode-gc.log" vc="$rdir/$mode-violation-counts"
    local agent; agent=$(agent_arg "$mode" "$AGENTS" 0)

    # forked-JVM arg line (the leading space is required by the javamop-extension)
    local al=" $(gc_flag "$gc") $HEAP_ARGS $(rv_opens_for "$mode") $APP_OPENS"
    [ "$pass" = gclog ] && al+=" $(xlog_gc "$gl") -javaagent:$FORCER"

    find "$PDIR" -name violation-counts -delete 2>/dev/null || true
    local t0; t0=$(date +%s%3N)
    ( cd "$PDIR" && MOP_AGENT_PATH="$agent" ARG_LINE="$al" \
        $TO mvn $SUREFIRE \
            -Dmaven.repo.local="$REPOM" -Dsurefire.exitTimeout=86400 \
            -DforkCount=1 -DreuseForks=true -Dmaven.ext.class.path="$EXT" ) >"$rl" 2>&1
    local rc=$? t1; t1=$(date +%s%3N)

    find "$PDIR" -name violation-counts -exec cat {} + >"$vc" 2>/dev/null
    [ -s "$vc" ] || rm -f "$vc"

    local time_ms=$(( t1 - t0 )) heap_mb=0
    [ "$pass" = gclog ] && heap_mb=$(parse_peak_heap "$gl")
    local viols tests have status
    viols=$(viol_total "$vc"); tests=$(test_summary "$rl")
    have=0; grep -q "Tests run:" "$rl" || have=1
    status=$(run_status "$rc" "$have")

    echo "$gc,$P,$run,$mode,$time_ms,$heap_mb,$viols,$tests,$status" >> "$csv"
    printf "  %-6s %-8s %-26s r%s %-9s time=%-7s heap=%-5s viol=%-6s %s\n" \
        "$pass" "$gc" "$P" "$run" "$mode" "${time_ms}ms" "${heap_mb}M" "$viols" "$status"
}

# ---- main: clone each project once, then run the timing + gclog passes ------
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "###") break ;; ""|\#*) continue ;; esac
    REPO="${line%%,*}"; SHA="${line##*,}"; P="${REPO//\//-}"
    echo "=== $P ($SHA) ==="

    WORK="/tmp/rv-oss-$$-$P"; PDIR="$WORK/project"; REPOM="$WORK/.m2"
    rm -rf "$WORK"; mkdir -p "$WORK"

    if ! git clone --quiet "https://github.com/$REPO" "$PDIR" 2>/dev/null; then
        echo "  CLONE_FAIL"; rm -rf "$WORK"; continue; fi
    git -C "$PDIR" checkout --quiet "$SHA" 2>/dev/null
    if ! ( cd "$PDIR" && mvn -B clean test-compile -DskipTests -Dmaven.repo.local="$REPOM" -Dsurefire.exitTimeout=86400 ) >/dev/null 2>&1; then
        echo "  COMPILE_FAIL"; rm -rf "$WORK"; continue; fi
    ( cd "$PDIR" && $TO mvn $SUREFIRE \
        -Dmaven.repo.local="$REPOM" -Dsurefire.exitTimeout=86400 ) >/dev/null 2>&1 || true   # warmup

    for pass in ${PASSES:-timing gclog}; do
        mkdir -p "$OUT/$pass"
        csv="$OUT/$pass/results.csv"; [ -f "$csv" ] || echo "$RV_CSV_HEADER" > "$csv"
        for run in $(seq 1 "$RUNS"); do
            for gc in $GCS; do
                for mode in $MODES; do
                    run_one "$pass" "$gc" "$mode" "$run" "$csv"
                done
            done
        done
    done
    rm -rf "$WORK"
done < "$PROJECTS"

echo "=== done $(date) -> $OUT/{timing,gclog}/results.csv ==="
