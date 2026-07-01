#!/usr/bin/env python3
"""RQ1/RQ2 summary violins: baseline/Naitae speedup (time) and live-set reduction.

Produces the four panels the paper includes:
    violin-96g-time.pdf   violin-96g-live.pdf    (abundant, 96 GB heap)
    violin-8g-time.pdf    violin-8g-live.pdf     (constrained, 8 GB heap)
Each violin is the 60 OSS projects; the x marks are the 16 DaCapo benchmarks.
"""
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns

from data import GCS, TOOLS, load_runs

OUT = os.path.join(os.path.dirname(__file__), "..", "figures", "summary")
PAL = {"Serial": "#4c72b0", "Parallel": "#dd8452", "G1": "#55a868"}

# One log y range for time (tighter) and one for the memory panels.
TIME_LO, TIME_HI = 0.2, 20.0
TIME_TICKS = [0.2, 0.5, 1, 2, 5, 10, 20]
MEM_LO, MEM_HI = 0.07, 260.0
MEM_TICKS = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200]


def ratios(heap, metric):
    """Long-form baseline/Naitae ratios for one heap and metric ('e2e' or 'live')."""
    shared = load_runs()
    recs = []
    for tool, tlabel in TOOLS:
        for gc, glabel in GCS:
            for r in shared.get((heap, tool, gc), []):
                pair = r["e2e"] if metric == "e2e" else r["live"]
                if not pair or not (pair[0] and pair[1]):
                    continue
                s, n = pair
                recs.append({"tool": tlabel, "gc": glabel, "v": s / n,
                             "src": "dacapo" if r["suite"] == "dacapo" else "oss"})
    return pd.DataFrame(recs)


def clamp_log(v, lo, hi):
    return float(np.log10(min(max(v, lo), hi)))


def draw(ax, df, lo, hi, ticks):
    """One panel: nine violins (tool x GC), log y, parity line at 1x."""
    recs, xs, centers, x = [], [], [], 0
    for tool, tlabel in TOOLS:
        for gi, (_, glabel) in enumerate(GCS):
            sub = df[(df.tool == tlabel) & (df.gc == glabel)]
            for _, row in sub.iterrows():
                recs.append({"x": x, "v": clamp_log(row["v"], lo, hi),
                             "gc": glabel, "src": row["src"]})
            xs.append((x, glabel))
            if gi == 1:
                centers.append((x, tlabel))
            x += 1
        x += 0.55   # gap between tools
    pdf = pd.DataFrame(recs)
    xorder = [xx for xx, _ in xs]
    palette = {xx: PAL[gl] for xx, gl in xs}
    oss, dac = pdf[pdf.src == "oss"], pdf[pdf.src == "dacapo"]

    sns.violinplot(data=oss, x="x", y="v", order=xorder, hue="x", palette=palette,
                   legend=False, cut=0, bw_adjust=0.8, inner="box", linewidth=0.7,
                   density_norm="width", width=0.92, ax=ax)
    for c in ax.collections:
        c.set_alpha(0.78)
    sns.stripplot(data=oss, x="x", y="v", order=xorder, color="#222", size=1.6,
                  alpha=0.42, jitter=0.18, ax=ax)
    if len(dac):
        sns.stripplot(data=dac, x="x", y="v", order=xorder, color="#9467bd",
                      marker="x", size=2.2, alpha=0.95, jitter=0.12,
                      linewidth=0.6, ax=ax)
    for i, xx in enumerate(xorder):
        vals = oss.loc[oss.x == xx, "v"]
        if len(vals):
            m = float(vals.median())
            ax.plot([i - 0.13, i + 0.13], [m, m], color="white", lw=1.05,
                    solid_capstyle="round", zorder=10)
    ax.axhline(0.0, color="red", lw=1.0, zorder=6)   # log10(1x) parity

    short = {"Serial": "Ser.", "Parallel": "Par.", "G1": "G1"}
    ax.set_xticks(range(len(xs)))
    ax.set_xticklabels([short[g] for _, g in xs], fontsize=6.4)
    tr = ax.get_xaxis_transform()
    xmap = {xx: i for i, xx in enumerate(xorder)}
    for xx, label in centers:
        ax.text(xmap[xx], -0.13, label, transform=tr, ha="center", va="top",
                fontsize=7.0, fontweight="bold")
    top = float(np.log10(hi))
    for xx in xorder:
        ax.text(xmap[xx], top * 0.995, f"{len(oss[oss.x == xx])}", ha="center",
                va="top", fontsize=4.2, color="#555", zorder=8)
    ax.set_ylim(float(np.log10(lo)), top)
    ax.set_yticks([float(np.log10(t)) for t in ticks])
    ax.set_yticklabels([f"{t:g}" if t >= 1 else f"{t}" for t in ticks])
    ax.set_xlim(-0.46, len(xorder) - 0.54)
    ax.set_ylabel("baseline / Naitae", fontsize=7)
    ax.set_xlabel("")
    ax.tick_params(axis="y", labelsize=6.8, pad=1.5)
    ax.grid(axis="y", color="#d0d0d0", lw=0.45)
    ax.grid(axis="x", visible=False)
    ax.set_axisbelow(True)


def panel(heap, metric, title, fname, lo, hi, ticks):
    fig, ax = plt.subplots(figsize=(3.4, 2.4))
    draw(ax, ratios(heap, metric), lo, hi, ticks)
    ax.set_title(title, fontsize=7.8, pad=1.5)
    fig.subplots_adjust(bottom=0.20, top=0.88, left=0.10, right=0.995)
    fig.savefig(f"{OUT}/{fname}.pdf", bbox_inches="tight", pad_inches=0.01)
    fig.savefig(f"{OUT}/{fname}.png", dpi=160, bbox_inches="tight", pad_inches=0.01)
    plt.close(fig)
    print(f"wrote {fname}.pdf")


def main():
    sns.set_style("whitegrid")
    os.makedirs(OUT, exist_ok=True)
    panel("abundant", "e2e", "End-to-end speedup", "violin-96g-time",
          TIME_LO, TIME_HI, TIME_TICKS)
    panel("abundant", "live", "Live set (post-GC retained)", "violin-96g-live",
          MEM_LO, MEM_HI, MEM_TICKS)
    panel("constrained", "e2e", "End-to-end speedup", "violin-8g-time",
          TIME_LO, TIME_HI, TIME_TICKS)
    panel("constrained", "live", "Live set (post-GC retained)", "violin-8g-live",
          MEM_LO, MEM_HI, MEM_TICKS)


if __name__ == "__main__":
    main()
