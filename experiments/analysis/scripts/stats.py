#!/usr/bin/env python3
"""Print the headline numbers behind Tables 1-2, the abstract, and the RQ4
counts (Table 3), computed from the data CSVs. Lets a reviewer confirm the
paper's figures/tables line up with the minimal data."""
import math
import statistics
from collections import defaultdict

from data import GCS, PASS, TOOLS, load_runs, num, rows


def geomean(xs):
    pos = [x for x in xs if x > 0]
    return math.exp(sum(map(math.log, pos)) / len(pos)) if pos else float("nan")


def ranked_cells(pairs):
    """Min/Median/Max = worst/typical/best project by amount saved."""
    ranked = sorted(pairs, key=lambda t: t[0] - t[1])   # ascending amount saved
    n = len(ranked)
    base = [b for b, _ in pairs]
    nait = [x for _, x in pairs]
    return dict(median=ranked[n // 2], min=ranked[0], max=ranked[-1],
                geo=(geomean(base), geomean(nait)),
                mean=(statistics.fmean(base), statistics.fmean(nait)))


def _pr(p):
    return f"{p[0]:6.1f}->{p[1]:<6.1f}"


def _table(shared, heap, title, key, div):
    """One ranked table (time or a memory metric), all five cells per row."""
    print(f"\n--- {title} ---")
    print(f"{'tool':8} {'gc':8} {'n':>3}  "
          f"{'Median':>14}{'Geo':>14}{'Arith':>14}{'Min':>14}{'Max':>14}")
    for tool, tlabel in TOOLS:
        for gc, glabel in GCS:
            recs = shared.get((heap, tool, gc), [])
            pairs = [(r[key][0] / div, r[key][1] / div) for r in recs if r.get(key)]
            if not pairs:
                continue
            c = ranked_cells(pairs)
            print(f"{tlabel:8} {glabel:8} {len(pairs):3d}  "
                  f"{_pr(c['median']):>14}{_pr(c['geo']):>14}{_pr(c['mean']):>14}"
                  f"{_pr(c['min']):>14}{_pr(c['max']):>14}")


def main():
    shared = load_runs()
    best_speedup = best_live = (0.0, None)
    for (heap, tool, gc), recs in shared.items():
        for r in recs:
            sp = r["e2e"][0] / r["e2e"][1]
            if sp > best_speedup[0]:
                best_speedup = (sp, (heap, tool, gc, r["subject"]))
            if r["live"]:
                red = r["live"][0] / r["live"][1]
                if red > best_live[0]:
                    best_live = (red, (heap, tool, gc, r["subject"]))

    for heap in ("abundant", "constrained"):
        print(f"\n=========== {heap.upper()} heap ===========")
        _table(shared, heap, "Table I  wall time (s), baseline->Naitae", "e2e", 1.0)
        _table(shared, heap, "Table II peak heap (GB), baseline->Naitae", "peak", 1024.0)
        _table(shared, heap, "Table II live set (GB), baseline->Naitae", "live", 1024.0)

    print("\n=== Abstract headline maxima ===")
    sp, w = best_speedup
    print(f"max speedup     : {sp:.1f}x   ({w})")
    red, w = best_live
    print(f"max live-set red: {red:.1f}x   ({w})")

    rq4_counts()


def rq4_counts():
    """Table 3 (RQ4) counts from data/rq4.csv (OSS + DaCapo).  LazyMOP reports unique traces; Valg and JavaMOP report monitors+events."""
    print("\n=== RQ4 counts (Table 3) — from data/rq4.csv (OSS + DaCapo) ===")
    by = defaultdict(dict)
    for r in rows("rq4.csv"):
        by[(r["tool"], r["subject"], r["gc"])][r["arm"]] = r

    def pairs(tool, key):
        b, n = [], []
        for (t, _s, _g), arms in by.items():
            if t != tool:
                continue
            s, na = arms.get("stock"), arms.get("native")
            if not s or not na or s["status"] not in PASS or na["status"] not in PASS:
                continue
            sv, nv = num(s[key]), num(na[key])
            if sv is not None and nv is not None:
                b.append(sv); n.append(nv)
        return b, n

    tb, tn = pairs("lazymop", "traces")
    print(f"LazyMOP unique traces (n={len(tb)} runs):")
    print(f"  mean/run : {statistics.fmean(tb) / 1e3:.2f}K -> {statistics.fmean(tn) / 1e3:.2f}K")
    print(f"  total    : {sum(tb) / 1e6:.2f}M -> {sum(tn) / 1e6:.2f}M")

    mb, mn = pairs("valg", "monitors"); eb, en = pairs("valg", "events")
    print(f"Valg (n={len(mb)} runs):")
    print(f"  monitors : {statistics.fmean(mb) / 1e6:.2f}M -> {statistics.fmean(mn) / 1e6:.2f}M")
    print(f"  events   : {statistics.fmean(eb) / 1e6:.1f}M -> {statistics.fmean(en) / 1e6:.1f}M")

    jmb, jmn = pairs("javamop", "monitors"); jeb, jen = pairs("javamop", "events")
    mratio = statistics.fmean(jmn) / statistics.fmean(jmb)
    eratio = statistics.fmean(jen) / statistics.fmean(jeb)
    print(f"JavaMOP (n={len(jmb)} runs; native/baseline ratio {mratio:.2f} monitors, {eratio:.2f} events)")


if __name__ == "__main__":
    main()
