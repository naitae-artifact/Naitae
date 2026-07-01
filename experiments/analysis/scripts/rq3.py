"""Shared RQ3 pooling: turn per-run profiler timings into per-(tool, GC) component
shares of baseline wall time. Used by both RQ3 figures."""
from collections import defaultdict

from data import GCS, TOOLS, rows

# Pool only runs whose Naitae/baseline wall ratio is well-behaved. A run outside
# this band is dominated by noise unrelated to monitoring (startup, scheduling),
# so its per-component split is not meaningful to pool. This is the *only*
# selection criterion -- there is no per-project blocklist.
RATIO_LO, RATIO_HI = 0.2, 3.0


def _f(r, c):
    try:
        return float(r[c])
    except (TypeError, ValueError):
        return 0.0


def components(r):
    """The five monitoring components (ms) the paper reports."""
    return {
        "Dispatch": _f(r, "dispatch_ms"),
        "Lookup": _f(r, "rcr_ms") + _f(r, "weakref_hotpath_ms"),
        "Sync": _f(r, "sync_ms"),
        "Mon. other": _f(r, "update_ms") + _f(r, "monitor_handler_ms"),
        "GC": _f(r, "gc_ms"),
    }


def pooled():
    """Return pool[(tool, gc)] = {stock:{cat:ms}, native:{cat:ms}, wall:baseline_ms, n:runs}.
    Shares are then component_ms / wall (percent of baseline wall time)."""
    cell = defaultdict(dict)
    for r in rows("rq3-breakdown.csv"):
        if _f(r, "wall_ms") > 0:
            cell[(r["project"], r["tool"], r["gc"])][r["arm"]] = r

    pool = defaultdict(lambda: {"stock": defaultdict(float),
                                "native": defaultdict(float), "wall": 0.0, "n": 0})
    for (project, tool, gc), arms in cell.items():
        if "stock" not in arms or "native" not in arms:
            continue
        base, nat = _f(arms["stock"], "wall_ms"), _f(arms["native"], "wall_ms")
        if base <= 0 or nat <= 0 or not (RATIO_LO <= nat / base <= RATIO_HI):
            continue
        p = pool[(tool, gc)]
        p["wall"] += base
        p["n"] += 1
        for arm in ("stock", "native"):
            for cat, ms in components(arms[arm]).items():
                p[arm][cat] += ms
    return pool


def share(pool, tool, gc, arm, cat):
    """Percent of baseline wall time spent in `cat` for one (tool, gc, arm)."""
    p = pool[(tool, gc)]
    return 100.0 * p[arm][cat] / (p["wall"] or 1.0)
