#!/bin/bash
# lib-bench.sh — shared helpers for the RV evaluation drivers (run-oss.sh, run-dacapo.sh).
#
# SOURCE this file; do not execute it.
#
# Instrumentation model (the "-javaagent" path):
#   * agents are built by tracemop/rv-tests/build-agents.sh
#   * RVMLOGGINGLEVEL controls how violation prints are deduped
#   * each run drops a `violation-counts` file in the JVM working directory
#   * mode "baseline" = no agent at all (unmonitored reference)


# ---------------------------------------------------------------------------
# Canonical results.csv schema (matches data/results-eval-*/.../results.csv)
# ---------------------------------------------------------------------------
RV_CSV_HEADER="gc,project,run,mode,time_ms,peak_heap_mb,violations,tests_run,tests_fail,tests_error,status"


# ---------------------------------------------------------------------------
# Agent / JVM options
# ---------------------------------------------------------------------------

# Dedupe repeated violation prints so logs stay small.
export RVMLOGGINGLEVEL="${RVMLOGGINGLEVEL:-UNIQUE}"

# The native indexing tree lives in java.base/java.lang.rv (the patched JDK).
RV_OPENS="--add-opens java.base/java.lang.rv=ALL-UNNAMED"

# Opens that several OSS test suites need to run on recent JDKs.
APP_OPENS="\
--add-opens java.base/java.lang=ALL-UNNAMED \
--add-opens java.base/java.lang.reflect=ALL-UNNAMED \
--add-opens java.base/java.util=ALL-UNNAMED \
--add-opens java.base/java.util.stream=ALL-UNNAMED \
--add-opens java.base/java.util.concurrent=ALL-UNNAMED \
--add-opens java.base/java.io=ALL-UNNAMED \
--add-opens java.base/java.nio=ALL-UNNAMED \
--add-opens java.base/java.net=ALL-UNNAMED \
--add-opens java.base/java.text=ALL-UNNAMED"


# ---------------------------------------------------------------------------
# GC selection
# ---------------------------------------------------------------------------
gc_flag() {
    case "$1" in
        serial)   echo "-XX:+UseSerialGC"   ;;
        parallel) echo "-XX:+UseParallelGC" ;;
        g1)       echo "-XX:+UseG1GC"       ;;
        *)        return 1                  ;;
    esac
}


# ---------------------------------------------------------------------------
# Heap sizing from a tag:
#   8g_fixed -> "-Xms8g -Xmx8g"   (fixed: initial == max)
#   8g_max   -> "-Xmx8g"          (max only, default initial)
# ---------------------------------------------------------------------------
heap_args() {
    local tag="$1"
    local size="${tag%_*}"   # before the last underscore, e.g. "8g"
    local kind="${tag##*_}"  # after  the last underscore, e.g. "fixed" / "max"

    case "$kind" in
        fixed) echo "-Xms${size} -Xmx${size}" ;;
        max)   echo "-Xmx${size}"             ;;
        *)     echo "-Xmx${tag}"              ;;
    esac
}


# ---------------------------------------------------------------------------
# GC logging args (gclog lane only). The caller decides whether to emit this.
# ---------------------------------------------------------------------------
xlog_gc() {
    local file="$1"
    echo "-Xlog:gc*,gc+heap=info,safepoint:file=${file}:time,uptime,level,tags"
}


# ---------------------------------------------------------------------------
# The -javaagent argument for a mode:
#   baseline -> ""                  (no agent)
#   old      -> stock  agent jar
#   new      -> native agent jar
# stats=1 selects the *-stats variant (monitor statistics), else *-no-stats.
# ---------------------------------------------------------------------------
agent_arg() {
    local mode="$1" agents_dir="$2" stats="${3:-0}"
    local variant=""
    [ "$stats" = 1 ] && variant="-stats"

    case "$mode" in
        baseline) echo "" ;;
        old)      echo "-javaagent:${agents_dir}/javamop-stock${variant}.jar"  ;;
        new)      echo "-javaagent:${agents_dir}/javamop-native${variant}.jar" ;;
    esac
}

# The native mode needs the java.lang.rv opens; other modes need nothing extra.
rv_opens_for() {
    [ "$1" = new ] && echo "$RV_OPENS"
}


# ---------------------------------------------------------------------------
# Parse peak used heap (MB) from a -Xlog:gc file. Two line shapes contribute:
#   "100M->40M"                      a collection -> 100
#   "[gc,heap,exit] used 204800K"    the shutdown dump -> 200
# ---------------------------------------------------------------------------
parse_peak_heap() {
    local file="$1"
    local peak=0 line val
    [ -f "$file" ] || { echo 0; return; }

    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+)M-\>[0-9]+M ]]; then
            val=${BASH_REMATCH[1]}
        elif [[ "$line" =~ \[gc,heap,exit\] && ! "$line" =~ (Metaspace|class.space) ]] \
          && [[ "$line" =~ used[[:space:]]+([0-9]+)K ]]; then
            val=$(( BASH_REMATCH[1] / 1024 ))
        else
            continue
        fi
        (( val > peak )) && peak=$val
    done < "$file"

    echo "$peak"
}


# ---------------------------------------------------------------------------
# violation-counts file helpers.
# File format: one line per spec -> "<count> <Spec> has been violated ..."
# ---------------------------------------------------------------------------

# Sum of the per-spec counts.
viol_total() {
    [ -s "$1" ] && awk '{ sum += $1 } END { print sum + 0 }' "$1" 2>/dev/null || echo 0
}

# Number of distinct violated specs.
viol_distinct() {
    [ -s "$1" ] && grep -c 'has been violated' "$1" 2>/dev/null || echo 0
}


# ---------------------------------------------------------------------------
# surefire "Tests run: N, Failures: F, Errors: E" -> "N,F,E"  (portable sed)
# ---------------------------------------------------------------------------
test_summary() {
    local file="$1" line out
    line=$(grep "Tests run:" "$file" 2>/dev/null | tail -1)
    out=$(printf '%s\n' "$line" \
        | sed -nE 's/.*Tests run: ([0-9]+).*Failures: ([0-9]+).*Errors: ([0-9]+).*/\1,\2,\3/p' \
        | head -1)
    echo "${out:-0,0,0}"
}


# ---------------------------------------------------------------------------
# Run status from the exit code + whether the primary metric was produced.
#   have_metric: 0 = metric present, anything else = missing
# ---------------------------------------------------------------------------
run_status() {
    local rc="$1" have_metric="$2"
    if   [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then echo "TIMEOUT"
    elif [ "$have_metric" != 0 ];                 then echo "ERR"
    else                                               echo "OK"
    fi
}
