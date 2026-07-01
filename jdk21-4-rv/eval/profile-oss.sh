#!/bin/bash
# profile-oss.sh — async-profiler JFR + monitor statistics for OSS Maven projects.
#
# Uses the *-stats agents (so RVMonitor prints per-spec stats) and attaches
# async-profiler. One pass:
#
#     <out>/profile/<gc>/<project>/r<run>/<mode>-<event>.jfr   (flame data)
#                                          <mode>-stats.txt     (monitor stats)
#                                          <mode>-violation-counts
#
# Common usage:
#     RV_JDK=.../jdk  bash profile-oss.sh \
#         --out results/oss/native-8g_fixed --projects ~/gc-profile.txt \
#         --heap 8g_fixed --event wall

set -uo pipefail
BENCH=$(cd "$(dirname "$0")" && pwd)
source "$BENCH/lib-bench.sh"
[ -f "$BENCH/bench-env.sh" ] && source "$BENCH/bench-env.sh" 2>/dev/null || true

# ---- options (only --out and --projects are required) ----------------------
OUT=""
PROJECTS=""
HEAP="8g_fixed"
EVENT="wall"                              # async-profiler event: wall | cpu
RUNS=1
GCS="serial parallel g1"
MODES="old new"                           # profiling baseline is rarely useful
RVJDK="${RV_JDK:-${PATCHED_JDK:-}}"
AGENTS="${AG:-$(cd "$BENCH/../.." 2>/dev/null && pwd)/tracemop}"
ASP="${ASP:-$(ls "$HOME"/async-profiler*/lib/libasyncProfiler.* \
                 "$HOME"/async-profiler*/build/libasyncProfiler.* 2>/dev/null | head -1)}"
TIMEOUT_SEC=1800
MAVEN_HEAP="-Xmx4g"

while [ $# -gt 0 ]; do
    case "$1" in
        --out)      OUT="$2";         shift 2 ;;
        --projects) PROJECTS="$2";    shift 2 ;;
        --heap)     HEAP="$2";        shift 2 ;;
        --event)    EVENT="$2";       shift 2 ;;
        --runs)     RUNS="$2";        shift 2 ;;
        --gcs)      GCS="$2";         shift 2 ;;
        --modes)    MODES="$2";       shift 2 ;;
        --rv-jdk)   RVJDK="$2";       shift 2 ;;
        --agents)   AGENTS="$2";      shift 2 ;;
        --asp)      ASP="$2";         shift 2 ;;
        --timeout)  TIMEOUT_SEC="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---- validate --------------------------------------------------------------
[ -n "$OUT" ] && [ -n "$PROJECTS" ] || {
    echo "Usage: $0 --out <dir> --projects <file> [--heap 8g_fixed] [--event wall|cpu]" >&2; exit 1; }
[ -f "$PROJECTS" ]       || { echo "no projects list: $PROJECTS" >&2; exit 1; }
[ -x "$RVJDK/bin/java" ] || { echo "no RV JDK: $RVJDK (set RV_JDK=...)" >&2; exit 1; }
[ -n "$ASP" ] && [ -f "$ASP" ] || { echo "no async-profiler (set ASP=...)" >&2; exit 1; }
EXT=$(find "$AGENTS" -name 'javamop-extension*.jar' 2>/dev/null | head -1)
[ -n "$EXT" ] && [ -f "$EXT" ] || { echo "no javamop-extension under $AGENTS" >&2; exit 1; }
# stats agents must exist for the non-baseline modes
for m in $MODES; do a=$(agent_arg "$m" "$AGENTS" 1); [ -z "$a" ] && continue
    f=${a#-javaagent:}; [ -f "$f" ] || { echo "no stats agent: $f (build-agents.sh)" >&2; exit 1; }; done

# ---- set up ----------------------------------------------------------------
HEAP_ARGS=$(heap_args "$HEAP")
SUREFIRE="org.apache.maven.plugins:maven-surefire-plugin:3.1.2:test"
export JAVA_HOME="$RVJDK" PATH="$RVJDK/bin:$PATH" MAVEN_OPTS="$MAVEN_HEAP"
mkdir -p "$OUT/profile"; OUT=$(cd "$OUT" && pwd)
CSV="$OUT/profile/results.csv"; [ -f "$CSV" ] || echo "$RV_CSV_HEADER" > "$CSV"

echo "=== profile-oss $(date) | heap=$HEAP [$HEAP_ARGS] event=$EVENT | gcs=[$GCS] modes=[$MODES] runs=$RUNS"
echo "    RVJDK=$RVJDK  agents=$AGENTS  asp=$ASP  out=$OUT/profile"

# ---- run one (gc, mode, run); append a CSV row -----------------------------
run_one() {
    local gc="$1" mode="$2" run="$3"
    local rdir="$OUT/profile/$gc/$P/r$run"; mkdir -p "$rdir"
    local rl="$rdir/$mode-run.log" jfr="$rdir/$mode-$EVENT.jfr" vc="$rdir/$mode-violation-counts"
    local agent; agent=$(agent_arg "$mode" "$AGENTS" 1)   # stats variant

    local al=" $(gc_flag "$gc") $HEAP_ARGS $(rv_opens_for "$mode") $APP_OPENS"
    al+=" -agentpath:$ASP=start,event=$EVENT,file=$jfr"

    find "$PDIR" -name violation-counts -delete 2>/dev/null || true
    local t0; t0=$(date +%s%3N)
    ( cd "$PDIR" && MOP_AGENT_PATH="$agent" ARG_LINE="$al" \
        timeout --kill-after=60 "$TIMEOUT_SEC" mvn $SUREFIRE \
            -Dmaven.repo.local="$REPOM" -Dsurefire.exitTimeout=86400 \
            -DforkCount=1 -DreuseForks=true -Dmaven.ext.class.path="$EXT" ) >"$rl" 2>&1
    local rc=$? t1; t1=$(date +%s%3N)

    find "$PDIR" -name violation-counts -exec cat {} + >"$vc" 2>/dev/null
    [ -s "$vc" ] || rm -f "$vc"
    grep -E '^(== .* ==|#monitors:|#event|#category)' "$rl" >"$rdir/$mode-stats.txt" 2>/dev/null
    [ -s "$rdir/$mode-stats.txt" ] || rm -f "$rdir/$mode-stats.txt"

    local time_ms=$(( t1 - t0 )) viols tests have status
    viols=$(viol_total "$vc"); tests=$(test_summary "$rl")
    have=0; grep -q "Tests run:" "$rl" || have=1
    status=$(run_status "$rc" "$have")

    echo "$gc,$P,$run,$mode,$time_ms,0,$viols,$tests,$status" >> "$CSV"
    printf "  %-8s %-26s r%s %-9s %s -> %s\n" "$gc" "$P" "$run" "$mode" "$status" "$(basename "$jfr")"
}

# ---- main ------------------------------------------------------------------
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "###") break ;; ""|\#*) continue ;; esac
    REPO="${line%%,*}"; SHA="${line##*,}"; P="${REPO//\//-}"
    echo "=== $P ($SHA) ==="

    WORK="/tmp/rv-oss-$$-$P"; PDIR="$WORK/project"; REPOM="$WORK/.m2"
    rm -rf "$WORK"; mkdir -p "$WORK"

    if ! git clone --quiet "https://github.com/$REPO" "$PDIR" 2>/dev/null; then
        echo "  CLONE_FAIL"; rm -rf "$WORK"; continue; fi
    git -C "$PDIR" checkout --quiet "$SHA" 2>/dev/null
    if ! ( cd "$PDIR" && mvn -q test-compile -Dmaven.repo.local="$REPOM" -Dsurefire.exitTimeout=86400 ) >/dev/null 2>&1; then
        echo "  COMPILE_FAIL"; rm -rf "$WORK"; continue; fi
    ( cd "$PDIR" && timeout "$TIMEOUT_SEC" mvn $SUREFIRE \
        -Dmaven.repo.local="$REPOM" -Dsurefire.exitTimeout=86400 ) >/dev/null 2>&1 || true   # warmup

    for run in $(seq 1 "$RUNS"); do
        for gc in $GCS; do
            for mode in $MODES; do
                run_one "$gc" "$mode" "$run"
            done
        done
    done
    rm -rf "$WORK"
done < "$PROJECTS"

echo "=== done $(date) -> $OUT/profile/ (jfr + stats) ==="
