"""Shared data access for the artifact scripts.

Everything reads the plain CSVs in ../data. The only non-trivial step is pairing
each subject's baseline (stock) and Naitae (native) runs, which load_runs() does.
"""
import csv
import os

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "data")

TOOLS = [("javamop", "JavaMOP"), ("valg", "Valg"), ("lazymop", "LazyMOP")]
GCS = [("serial", "Serial"), ("parallel", "Parallel"), ("g1", "G1")]
PASS = {"PASS", "OK"}


def rows(name):
    """All rows of a data CSV as dicts."""
    with open(os.path.join(DATA, name)) as f:
        return list(csv.DictReader(f))


def num(x):
    """Positive float, or None for blank/non-positive (a missing measurement)."""
    try:
        v = float(x)
        return v if v > 0 else None
    except (TypeError, ValueError):
        return None


def load_runs():
    """runs.csv paired into per-(heap, tool, gc) lists of subjects that PASS under
    both arms with a time and a peak-heap measurement."""
    by = {}   # (heap, tool, gc) -> subject -> arm -> measurements
    for r in rows("runs.csv"):
        if r["status"] not in PASS:
            continue
        e, pk, lv = num(r["e2e_s"]), num(r["peak_heap_mb"]), num(r["postgc_live_mb"])
        if not e or not pk:
            continue
        cell = by.setdefault((r["heap"], r["tool"], r["gc"]), {})
        cell.setdefault(r["subject"], {})[r["arm"]] = (r["suite"], e, pk, lv)

    out = {}
    for key, subs in by.items():
        recs = []
        for subject, arms in subs.items():
            if "stock" not in arms or "native" not in arms:
                continue
            (suite, se, spk, slv), (_, ne, npk, nlv) = arms["stock"], arms["native"]
            recs.append({
                "subject": subject, "suite": suite,
                "e2e": (se, ne), "peak": (spk, npk),
                "live": (slv, nlv) if slv and nlv else None,
            })
        out[key] = recs
    return out
