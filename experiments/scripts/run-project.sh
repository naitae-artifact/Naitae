#!/bin/bash
# Run one project across its cells. Clone and compile once, then run each cell
# over the same repo and append a result.csv row (status, end-to-end time,
# violations, peak heap, unique traces). The scripts README lists the env knobs.
# Usage: run-project.sh <repo> <sha> <out-dir>
SCRIPT_DIR=$(cd $(dirname $0) && pwd)
REPO=$1; SHA=$2; OUTPUT_DIR=$3
[[ -n ${OUTPUT_DIR} ]] || { echo "usage: run-project.sh <repo> <sha> <out-dir>"; exit 1; }
[[ ${OUTPUT_DIR} = /* ]] || OUTPUT_DIR=${SCRIPT_DIR}/${OUTPUT_DIR}
PROJECT_NAME=${REPO//\//-}

STOCK_AGENT=${STOCK_AGENT:-/agents/javamop-stock.jar}
NATIVE_AGENT=${NATIVE_AGENT:-/agents/javamop-native.jar}
VALG_STOCK_AGENT=${VALG_STOCK_AGENT:-/agents/valg-stock.jar}
VALG_NATIVE_AGENT=${VALG_NATIVE_AGENT:-/agents/valg-native.jar}
EXTENSION=${EXTENSION:-/extensions/javamop-extension-1.0.jar}

NATIVE_JDK=${NATIVE_JDK:-/opt/jdk-native}; STOCK_JDK=${STOCK_JDK:-/opt/jdk-stock}
COMPILE_JDK=${COMPILE_JDK:-${NATIVE_JDK}}
COMPILE_FALLBACK_JDK=${COMPILE_FALLBACK_JDK:-}   # e.g. /opt/jdk8 for old projects that only javac under 8
BASE_PATH=${PATH}

CELLS=${CELLS:-norv-stock norv-mod javamop native}
GCS=${GCS:-}   # empty = JVM default, else a subset of {serial parallel g1} swept in-task
WARMUP=${WARMUP:-true}   # one discarded no-agent run to warm caches
TEST_GOAL=${TEST_GOAL:-surefire:test}   # run the pre-compiled tests, no recompile under JDK21
PER_STAGE_TIMEOUT=${PER_STAGE_TIMEOUT:-0}
JVM_HEAP=${JVM_HEAP:-}; HEAP_OPT=""; [[ -n ${JVM_HEAP} ]] && HEAP_OPT=" -Xmx${JVM_HEAP}"
# uncompressed oops in both heap regimes for a fair comparison; set empty to disable
EXTRA_JVM_OPTS=${EXTRA_JVM_OPTS--XX:-UseCompressedOops}
LAZYMOP_COLLECT_TRACES=${LAZYMOP_COLLECT_TRACES:-1}
GC_OPT=""
RV_OPENS="--add-opens java.base/java.lang.rv=ALL-UNNAMED"   # native cells only
APP_OPENS="--add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.lang.reflect=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED --add-opens java.base/java.util.stream=ALL-UNNAMED --add-opens java.base/java.util.concurrent=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED --add-opens java.base/java.nio=ALL-UNNAMED --add-opens java.base/java.net=ALL-UNNAMED --add-opens java.base/java.text=ALL-UNNAMED"

export RVMLOGGINGLEVEL=${RVMLOGGINGLEVEL:-UNIQUE}
TIMEFORMAT='RVWALL %R'                             # unique marker; record greps '^RVWALL ' (app output may print 'real')
REPO_LOCAL=${MVN_REPO:-${OUTPUT_DIR}/repo}; LOGS=${OUTPUT_DIR}/logs; RESULT=${OUTPUT_DIR}/result.csv
mkdir -p ${LOGS}

use_jdk()  { export JAVA_HOME=$1; export PATH=$1/bin:${BASE_PATH}; }
gc_flag()  { case $1 in serial) echo -XX:+UseSerialGC;; parallel) echo -XX:+UseParallelGC;; g1) echo -XX:+UseG1GC;; *) echo;; esac; }

clone() {
  echo "[OK] clone ${REPO}"; local t=0
  until git clone https://github.com/${REPO} ${OUTPUT_DIR}/project &> ${LOGS}/clone.log; do
    t=$((t+1)); [[ $t -ge 5 ]] && { echo "[ERROR] clone failed"; exit 1; }
    rm -rf ${OUTPUT_DIR}/project; sleep $((t*15))
  done
  pushd ${OUTPUT_DIR}/project &> /dev/null; git checkout ${SHA} &> ${LOGS}/checkout.log
}

compile() {                                        # primary COMPILE_JDK (21), fall back to COMPILE_FALLBACK_JDK (8) for old projects
  use_jdk ${COMPILE_JDK}; echo "[OK] compile (${JAVA_HOME})"
  (time mvn -B clean test-compile -DskipTests -Dmaven.repo.local=${REPO_LOCAL}) &> ${LOGS}/compile.log && return 0
  [[ -n ${COMPILE_FALLBACK_JDK} && ${COMPILE_FALLBACK_JDK} != ${COMPILE_JDK} ]] || { echo "[ERROR] compile failed"; exit 1; }
  echo "[WARN] retry compile under ${COMPILE_FALLBACK_JDK}"; use_jdk ${COMPILE_FALLBACK_JDK}
  (time mvn -B clean test-compile -DskipTests -Dmaven.repo.local=${REPO_LOCAL}) &> ${LOGS}/compile-fallback.log || { echo "[ERROR] compile failed"; exit 1; }
}

mvn_test() {                                        # $1=ext-jar : run the suite in the current env/cwd
  # timeout wraps the mvn binary here (not the mvn_test function) so `timeout` can
  # actually exec it; a rc of 124 propagates out and record() maps it to TIMEOUT.
  local to=""; [[ -n ${PER_STAGE_TIMEOUT} && ${PER_STAGE_TIMEOUT} != 0 ]] && \
    to="timeout --signal=TERM --kill-after=120 ${PER_STAGE_TIMEOUT}s"
  ${to} mvn -B ${TEST_GOAL} -Dmaven.repo.local=${REPO_LOCAL} \
    -Dsurefire.exitTimeout=86400 -Dsurefire.shutdown=kill -DforkCount=1 -DreuseForks=true \
    -Dmaven.ext.class.path=$1
}

warmup() {
  [[ ${WARMUP} == true ]] || return 0; echo "[OK] warmup (discarded)"
  ( export MOP_AGENT_PATH="" ARG_LINE=" ${APP_OPENS}${HEAP_OPT}"; mvn_test ${EXTENSION} ) &> ${LOGS}/warmup.log
}

# run_cell <label> <jdk> <agent-arg> <extra-opens>
run_cell() {
  local label=$1 jdk=$2 mop=$3 opens=$4
  use_jdk ${jdk}
  local prof=""; [[ -n ${ASYNC_PROFILER_LIB} ]] && \
    prof=" -agentpath:${ASYNC_PROFILER_LIB}=start,event=${PROFILE_EVENT:-wall},interval=${PROFILE_INTERVAL:-5ms},file=${LOGS}/${label}.jfr"
  local gclog=""; [[ -n ${GC_LOG:-} ]] && gclog=" -Xlog:gc:file=${LOGS}/${label}.gc.log:time,uptime,level,tags"
  echo "[OK] ${label} (JDK=${jdk})"
  find ${OUTPUT_DIR}/project \( -name violation-counts -o -name '*-violations' \) -delete 2>/dev/null
  ( export MOP_AGENT_PATH="${mop}" ARG_LINE=" ${opens}${HEAP_OPT}${GC_OPT}${EXTRA_JVM_OPTS:+ ${EXTRA_JVM_OPTS}}${prof}${gclog}"
    local ext=${EXTENSION}
    if [[ ${label} == lazymop-* ]]; then   # lazymop self-collects traces into its own dir via the tinymop extension
      mkdir -p ${LOGS}/lztr-${label}
      export TINYMOP_TRACEDB_PATH=${LOGS}/lztr-${label} TINYMOP_COLLECT_TRACES=${LAZYMOP_COLLECT_TRACES}
      [[ ${LAZYMOP_COLLECT_TRACES} == 1 ]] && export COLLECT_TRACES=1
      ext=${LAZYMOP_EXT}
    fi
    time mvn_test ${ext} ) &> ${LOGS}/${label}.log
  record ${label} $?
}

peak_heap_mb() { [[ -f $1 ]] || { echo; return; }; grep -oE '[0-9]+M->[0-9]+M' $1 2>/dev/null | grep -oE '^[0-9]+' | sort -n | tail -1; }
# Post-GC live set (MB): the right-hand side of "100M->40M", i.e. what survives each
# GC; the run's max approximates peak retained live data (paper's live-set metric).
postgc_live_mb() { [[ -f $1 ]] || { echo; return; }; grep -oE '[0-9]+M->[0-9]+M' $1 2>/dev/null | sed -E 's/.*->([0-9]+)M/\1/' | sort -n | tail -1; }

lazymop_root() { find ${LOGS}/lztr-$1 -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -1; }
lazymop_count() {
  local root=$1 pattern=$2 skip=$3
  find ${root} -maxdepth 1 -type f -name "${pattern}" -print0 2>/dev/null \
    | xargs -0r awk -v skip="${skip}" 'NF && $1 != skip && $1 != "Total" {n++} END{print n+0}' 2>/dev/null
}

# row: project,cell,status,e2e_s,viols,peak_heap_mb,postgc_live_mb,trace_uniq
record() {
  local label=$1 rc=${2:-0} log=${LOGS}/${label}.log
  local e2e=$(grep -m1 '^RVWALL ' ${log} | awk '{print $2}')
  local status=FAIL; grep -q 'BUILD SUCCESS' ${log} && status=PASS
  [[ ${rc} -eq 124 ]] && status=TIMEOUT
  local viols=$(grep -c 'has been violated' ${log} 2>/dev/null)
  grep -h 'has been violated' ${log} 2>/dev/null | sort | uniq -c | sort -rn > ${LOGS}/${label}.viols 2>/dev/null
  find ${OUTPUT_DIR}/project -name violation-counts -exec cat {} + 2>/dev/null \
    | awk 'NF { c=$1; $1=""; sub(/^ +/,""); counts[$0]+=c }
           END { for (msg in counts) printf "%d %s\n", counts[msg], msg }' \
    | sort -rn > ${LOGS}/${label}.violation-counts 2>/dev/null
  local peak=$(peak_heap_mb ${LOGS}/${label}.gc.log)
  local live=$(postgc_live_mb ${LOGS}/${label}.gc.log)
  local tuniq=""
  if [[ ${label} == lazymop-* ]]; then
    local root=$(lazymop_root ${label})
    if [[ -n ${root} ]]; then
      tuniq=$(lazymop_count ${root} '*-traces' '')
      viols=$(lazymop_count ${root} '*-violations' 'MONITORING')
      find ${root} -maxdepth 1 -type f -name '*-violations' -print0 2>/dev/null \
        | xargs -0r awk 'NF && $1 != "MONITORING" && $1 != "COLLECTING" {print FILENAME " " $0}' \
        > ${LOGS}/${label}.viols 2>/dev/null
    fi
  fi
  echo "${PROJECT_NAME},${label},${status},${e2e:--1},${viols},${peak},${live},${tuniq}" >> ${RESULT}
}

# Agent jar per cell; norv-* run without one. Everything else is derived from the
# cell name: the JDK is native except norv-stock, and the -native cells add the
# java.lang.rv opens.
declare -A CELL_AGENT=(
  [javamop]=${STOCK_AGENT}               [javamop-native]=${NATIVE_AGENT}  [native]=${NATIVE_AGENT}
  [valg-stock]=${VALG_STOCK_AGENT}       [valg-native]=${VALG_NATIVE_AGENT}
  [lazymop-stock]=${LAZYMOP_STOCK_AGENT} [lazymop-native]=${LAZYMOP_NATIVE_AGENT}
)
run_one_cell() {   # $1=cell  $2=label suffix ("" or "-<gc>")
  local c=$1 s=$2
  case " norv-stock norv-mod ${!CELL_AGENT[*]} " in *" $c "*) ;; *) echo "[WARN] unknown cell '$c'"; return ;; esac
  local jdk=${NATIVE_JDK}; [[ $c == norv-stock ]] && jdk=${STOCK_JDK}
  local opens=${APP_OPENS}; [[ $c == *native* ]] && opens="${APP_OPENS} ${RV_OPENS}"
  run_cell "$c$s" "$jdk" "${CELL_AGENT[$c]:+-javaagent:${CELL_AGENT[$c]}}" "$opens"
}

echo "project,cell,status,e2e_s,viols,peak_heap_mb,postgc_live_mb,trace_uniq" > ${RESULT}
echo "[OK] CELLS=${CELLS} GCS=${GCS:-default} PROFILER=${ASYNC_PROFILER_LIB:-off} GC_LOG=${GC_LOG:-off}"
use_jdk ${NATIVE_JDK}; clone; compile; use_jdk ${NATIVE_JDK}; warmup
if [[ -z ${GCS} ]]; then
  for c in ${CELLS}; do run_one_cell ${c} ""; done
else
  for gc in ${GCS}; do
    GCFLAG=$(gc_flag ${gc}); [[ -z ${GCFLAG} ]] && { echo "[WARN] unknown gc '${gc}'"; continue; }
    GC_OPT=" ${GCFLAG}"; echo "[OK] ===== GC=${gc} ====="
    for c in ${CELLS}; do run_one_cell ${c} "-${gc}"; done
  done
fi
echo "OK!"
