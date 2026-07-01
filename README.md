# NAITAE: JVM-native Monitor Management for Parametric Runtime Verification

This repository makes runtime-verification (RV) monitor management a first-class
JVM concern: monitor storage is lowered into the JVM and the garbage collector is
made monitor-aware, so monitors are stored, looked up, and garbage-collected
inside the JVM instead of at the Java level. It contains a modified OpenJDK 21 and
prebuilt native monitor code for the JavaMOP/TraceMOP, Valg, and LazyMOP RV tools.

Throughout, **stock** is the unmodified Java-level RV implementation and **native**
(NAITAE) uses the JVM-native indexing tree `java.lang.rv.IndexingTree`, which needs
the modified JDK in `jdk21-4-rv/`.

### Repository layout
- `jdk21-4-rv/` — modified OpenJDK 21 (native indexing tree + monitor-aware GC for Serial/Parallel/G1)
- `env/` — the Dockerfile and the prebuilt RV tool jars (`env/agents/`) it bakes in
- `experiments/` — evaluation scripts (`scripts/`), the project list (`projects/`), the analysis/plotting code (`analysis/`), a smoke test, and the DaCapo driver
- `data/` — the paper's evaluation data (`runs.csv`, `rq3-breakdown.csv`, `rq4.csv`)

## Prerequisites

NAITAE tested on:
- Java 21 (boot JDK for building the modified JDK)
- Maven 3.9.6+, Surefire 3.1.2+
- AspectJ 1.9.21 (spec weaving)
- Ubuntu 20.04 / 22.04
- Docker

The sample numbers below were measured on an Intel Xeon Gold 6348 (112 cores) with
503 GB RAM; yours will differ.

## Setting up with Docker

The Dockerfile builds and includes the following:
1) the modified OpenJDK 21.0.10 from `jdk21-4-rv/` — this holds NAITAE's in-JVM monitor manager.
2) stock (unmodified) OpenJDK 21.0.10 for comparison
3) the RV tools (JavaMOP, Valg, LazyMOP) as prebuilt jars under `env/agents/`

```bash
docker build -f env/Dockerfile -t naitae/rv-jdk21 .
```

The build takes ≈30–40 min (≈10–15 min on a many-core host). It needs network
access — it clones stock OpenJDK and downloads Maven/Temurin/AspectJ/async-profiler —
plus ~15 GB of free disk during the build, and produces a ~3 GB image.

Smoke test on one project for a quick sanity check.
```bash
bash experiments/smoke-test.sh        # defaults to agarciadom/xeger
```

Both cells should build+test `PASS` and report the **same** violation count
(native reproduces stock), with native faster. The smoke test doesn't set
`GC_LOG=1`, so it prints times and violations only:

```
project           cell            status  e2e_s  viols
agarciadom/xeger  javamop         PASS    68.8   1
agarciadom/xeger  javamop-native  PASS    35.4   1
```

Exact times vary by machine; what must hold is `PASS` for both cells and an
identical `viols` (here, 1). Peak heap and live set are shown under
[Running a project](#running-rv-tools-on-projects-with-naitae), which sets `GC_LOG=1`.

## Setting up without Docker

```bash
# Modified JDK (the RV agents are already prebuilt in env/agents/)
cd jdk21-4-rv && bash configure --with-boot-jdk=<jdk21> && make images
export RV_JDK=$PWD/build/<platform>/images/jdk
```

Native agents reference `java.lang.rv.*`, which only exists in our modified OpenJDK 21. So `RV_JDK` must be set as `JAVA_HOME` in order to run the RV tools that leverage
NAITAE's efficient monitor manager.

## Running RV tools on projects with NAITAE

The command that follows clones and compiles a project once, then runs the tests. 
Set `CELLS` to that tool's stock and native to compare the RV tools with and without Naitae. An example is as follows:

```bash
# copy over projects to run into projects.csv (multiple projects separated by new line)
echo "agarciadom/xeger,f3b8a33b0f4438d639150b57b9a0257d50c71bc2" > projects.csv

# JavaMOP 
docker run --rm -v "$PWD":/work -e CSV=/work/projects.csv -e WORK=/work/out \
  -e GC_LOG=1 -e CELLS="javamop javamop-native" naitae/rv-jdk21 run-all.sh

# Valg     — same command with  -e CELLS="valg-stock valg-native"
# LazyMOP  — same command with  -e CELLS="lazymop-stock lazymop-native"
```

Each run prints its cells and appends them to `out/results.csv`. On our hardware
(G1, abundant heap), `agarciadom/xeger` outputs:

```
# JavaMOP
cell            status  e2e_s  viols  peak_heap_mb  postgc_live_mb
javamop         PASS    47.2   1      7168          6539
javamop-native  PASS    38.6   1      2086          1216
```

Without Docker, set `JAVA_HOME=$RV_JDK`, point `STOCK_AGENT`/`NATIVE_AGENT` (and
`VALG_*`/`LAZYMOP_*` as needed) at the jars in `env/agents/`, and run
`experiments/scripts/run-all.sh`.


## Output

Each cell appends one row to the project's `result.csv` (and `run-all.sh` collects
every project into `out/results.csv`):

```
project,cell,status,e2e_s,viols,peak_heap_mb,postgc_live_mb,trace_uniq
```

end-to-end time, violation count, peak heap, post-GC live set (retained after GC —
the paper's memory metric), and unique traces. 
Heap statistics: `peak_heap_mb`/`postgc_live_mb` are generated only under `GC_LOG=1`.
Unique traces: `trace_uniq` is reported by LazyMOP only. 
Native reproduces stock's `viols` for the deterministic tools (JavaMOP, LazyMOP),
differing only on time/heap. Valg is nondeterministic by design so its violation count may occasionally vary run to run and need not match between stock and native.
Per-cell logs (and the `*.viols` / `*.violation-counts` files) are under `logs/`.

## Running All 4 RQs for all projects
Run all 60 projects in Docker. Each RQ will take multiple days if run in sequence.

```bash
# RQ1 — time overhead (unbounded 96g; use JVM_HEAP=8g for the bounded runs)
docker run --rm -v "$PWD":/work -e CSV=/work/projects/projects.csv -e WORK=/work/out \
  -e GCS="serial parallel g1" -e JVM_HEAP=96g \
  -e CELLS="javamop javamop-native valg-stock valg-native lazymop-stock lazymop-native" \
  naitae/rv-jdk21 run-all.sh

# RQ2 — memory overhead (unbounded 96g; use JVM_HEAP=8g for the bounded runs)
docker run --rm -v "$PWD":/work -e CSV=/work/projects/projects.csv -e WORK=/work/out \
  -e GCS="serial parallel g1" -e JVM_HEAP=96g -e GC_LOG=1 \
  -e CELLS="javamop javamop-native valg-stock valg-native lazymop-stock lazymop-native" \
  naitae/rv-jdk21 run-all.sh

# RQ3 — RV wall-clock breakdown (async-profiler)
docker run --rm -v "$PWD":/work -e CSV=/work/projects/projects.csv -e WORK=/work/out \
  -e GCS="serial parallel g1" -e JVM_HEAP=96g \
  -e ASYNC_PROFILER_LIB=/opt/async-profiler/build/libasyncProfiler.so \
  -e CELLS="javamop javamop-native valg-stock valg-native lazymop-stock lazymop-native" \
  naitae/rv-jdk21 run-all.sh

# RQ4 — monitor/event counts. Each tool needs its own -stats agents; 
# LazyMOP has no stats build it produces unique traces instead (already produced by the RQ1/RQ2 runs above).
docker run --rm -v "$PWD":/work -e CSV=/work/projects/projects.csv -e WORK=/work/out \
  -e GCS="serial parallel g1" -e CELLS="javamop javamop-native" \
  -e STOCK_AGENT=/agents/javamop-stock-stats.jar \
  -e NATIVE_AGENT=/agents/javamop-native-stats.jar \
  naitae/rv-jdk21 run-all.sh

docker run --rm -v "$PWD":/work -e CSV=/work/projects/projects.csv -e WORK=/work/out \
  -e GCS="serial parallel g1" -e CELLS="valg-stock valg-native" \
  -e VALG_STOCK_AGENT=/agents/valg-stock-stats.jar \
  -e VALG_NATIVE_AGENT=/agents/valg-native-stats.jar \
  naitae/rv-jdk21 run-all.sh
```

Common options: 
- `CSV`/`WORK` (input list, output dir)
- `CELLS` (which tool cells)
- `JVM_HEAP` (`96g` unbounded / `8g` bounded) 
- `GCS` : which gc algorithms (G1, Serial, Parallel) to run  
- `GC_LOG=1` (measures heap consumption)
  
DaCapo (the other 16 subjects) is driven from `experiments/scripts/dacapo/`:

```bash
bash experiments/scripts/dacapo/fetch-dacapo.sh #DaCapo v23.11-MR2-chopin
OUT=~/dacapo-out bash experiments/scripts/dacapo/run-dacapo-docker.sh
```

## Plotting scripts

`make` reads the CSVs in `data/`. The shipped copies are the paper's data, so every
table and figure reproduces directly:

```bash
pip install pandas seaborn matplotlib numpy
make -C experiments/analysis stats      # Tables 1-2, RQ4 Table 3
make -C experiments/analysis figures    # Figs 5-6 (summary violins) and Fig 7 (RQ3 breakdown)
```

To plot **your own** RQ1/RQ2 runs, rebuild `data/runs.csv` from the `results.csv`
each sweep wrote, then re-run `make` (RQ3/RQ4 still read the frozen
`data/rq3-breakdown.csv` / `data/rq4.csv`):

```bash
python experiments/analysis/scripts/aggregate.py \
  abundant=/path/to/out-96g/results.csv \
  constrained=/path/to/out-8g/results.csv > data/runs.csv
make -C experiments/analysis stats figures
```

<!-- ## License
- **`jdk21-4-rv/`** — modified OpenJDK 21 for Naitae. GPLv2 with the Classpath Exception,
  as upstream.
- **`env/agents/`** — prebuilt jars from JavaMOP, Valg, and LazyMOP retain their upstream license.
- everything else is licensed under MIT license. -->
