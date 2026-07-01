#!/usr/bin/env python3
"""Build data/runs.csv (what the analysis reads) from raw run-all.sh output.
    aggregate.py abundant=out-96g/results.csv constrained=out-8g/results.csv > data/runs.csv
"""
import csv
import sys

GCS = {"serial", "parallel", "g1"}
CAP_MB = {"abundant": 96 * 1024, "constrained": 8 * 1024}

# results.csv cell name (minus the -<gc> suffix) -> (tool, arm)
ARM = {
    "javamop": ("javamop", "stock"), "javamop-native": ("javamop", "native"),
    "native": ("javamop", "native"),
    "valg-stock": ("valg", "stock"), "valg-native": ("valg", "native"),
    "lazymop-stock": ("lazymop", "stock"), "lazymop-native": ("lazymop", "native"),
}

COLS = ["heap", "suite", "tool", "gc", "subject", "arm", "status",
        "e2e_s", "peak_heap_mb", "postgc_live_mb", "viols"]


def over_cap(row, cap):
    for col in ("peak_heap_mb", "postgc_live_mb"):
        v = row[col]
        if v and float(v) > cap:
            return True
    return False


def main(args):
    out = csv.writer(sys.stdout)
    out.writerow(COLS)
    kept = dropped = 0
    for arg in args:
        heap, path = arg.split("=", 1)          # e.g. abundant=out/results.csv
        cap = CAP_MB[heap]
        for r in csv.DictReader(open(path)):
            gc = r["cell"].rsplit("-", 1)[-1]
            base = r["cell"][:-len(gc) - 1]
            if gc not in GCS or base not in ARM:
                continue                        # warmup, norv baselines, un-swept runs
            if r["status"] in ("PASS", "OK") and over_cap(r, cap):
                dropped += 1
                continue
            tool, arm = ARM[base]
            out.writerow([heap, "oss", tool, gc, r["project"], arm, r["status"],
                          r["e2e_s"], r["peak_heap_mb"], r["postgc_live_mb"], r["viols"]])
            kept += 1
    print(f"wrote {kept} rows, dropped {dropped} over-cap", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: aggregate.py <heap>=<results.csv> ...   (heap: abundant | constrained)")
    main(sys.argv[1:])
