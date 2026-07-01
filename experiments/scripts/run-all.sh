#!/bin/bash
# Run every project in a CSV (owner/repo,sha rows) through run-project.sh and
# collect the per-project rows into one results.csv. This is the image's default
# entrypoint. Usage: bash run-all.sh [N]  (N = first N projects only).
SCRIPT_DIR=$( cd $( dirname $0 ) && pwd )

CSV=${CSV:-/work/projects.csv}
WORK=${WORK:-/work/out}
LIMIT=${1:-100000}

if [[ ! -f ${CSV} ]]; then echo "FATAL: csv not found: ${CSV}"; exit 1; fi
mkdir -p ${WORK}

RESULTS=${WORK}/results.csv
echo "project,cell,status,e2e_s,viols,peak_heap_mb,postgc_live_mb,trace_uniq" > ${RESULTS}

n=0
while IFS=, read -r repo sha _rest <&3; do
  repo=$(echo ${repo} | tr -d '"' | xargs)
  sha=$(echo ${sha} | tr -d '"' | xargs)
  [[ -z ${repo} || ${repo} == project ]] && continue
  n=$((n+1)); [[ ${n} -gt ${LIMIT} ]] && break

  slug=$(echo ${repo} | tr / -)
  echo "==[${n}] ${repo} @ ${sha:0:8} =="

  bash ${SCRIPT_DIR}/run-project.sh ${repo} ${sha} ${WORK}/${slug}
  tail -n +2 ${WORK}/${slug}/result.csv >> ${RESULTS} 2>/dev/null

  rm -rf ${WORK}/${slug}/project ${WORK}/${slug}/repo   # keep logs + result, drop heavy dirs
done 3< ${CSV}

echo ""; echo "===Done=="
column -t -s, ${RESULTS} 2>/dev/null || cat ${RESULTS}
