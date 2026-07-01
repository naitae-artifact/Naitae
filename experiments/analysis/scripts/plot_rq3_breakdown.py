#!/usr/bin/env python3
"""RQ3 Figure: 18 stacked bars (base vs +Naitae, per collector, per tool) showing
each monitoring component as a percent of baseline wall time."""
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

from data import GCS, TOOLS
from rq3 import pooled, share

OUT = os.path.join(os.path.dirname(__file__), "..", "figures", "rq3")

# label, color, greyscale hatch -- ordered so adjacent segments contrast
CATS = [
    ("Dispatch",   "#0072b2", ""),
    ("Lookup",     "#e69f00", "//"),
    ("Sync",       "#009e73", "\\\\"),
    ("Mon. other", "#cc79a7", ".."),
    ("GC",         "#56b4e9", "xx"),
]
matplotlib.rcParams["hatch.linewidth"] = 0.5
VARS = [("stock", "base"), ("native", "+N")]

BARW, PAIR_GAP, GC_STEP, TOOL_GAP = 0.90, 1.04, 2.45, 1.30


def darker(hexc, f=0.62):
    r, g, b = (int(hexc[i:i + 2], 16) for i in (1, 3, 5))
    return (r * f / 255.0, g * f / 255.0, b * f / 255.0)


def text_color(hexc):
    r, g, b = (int(hexc[i:i + 2], 16) / 255.0 for i in (1, 3, 5))
    return "white" if (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.48 else "black"


def main():
    pool = pooled()

    # x layout: a (base, +N) pair per collector; collectors grouped per tool.
    bars, gc_marks, tool_spans, x = [], [], [], 0.0
    for tool, tlabel in TOOLS:
        lo = x
        for gc, glabel in GCS:
            for off, (arm, _) in zip((0.0, PAIR_GAP), VARS):
                bars.append((x + off, tool, gc, arm))
            gc_marks.append((x + PAIR_GAP / 2.0, glabel))
            x += GC_STEP
        tool_spans.append((tlabel, lo, x - GC_STEP + PAIR_GAP))
        x += TOOL_GAP

    ymax = max(sum(share(pool, t, gc, arm, cat) for cat, _, _ in CATS)
               for _, t, gc, arm in bars)

    fig, ax = plt.subplots(figsize=(8.75, 2.25))
    for xx, tool, gc, arm in bars:
        bottom = 0.0
        for cat, color, hatch in CATS:
            h = share(pool, tool, gc, arm, cat)
            ax.bar(xx, h, width=BARW, bottom=bottom, color=color,
                   edgecolor="white", linewidth=0.6)
            if hatch:
                ax.bar(xx, h, width=BARW, bottom=bottom, facecolor="none",
                       edgecolor=darker(color), hatch=hatch, linewidth=0.0)
            if h >= 4.0:
                ax.text(xx, bottom + h / 2.0, f"{h:.0f}", ha="center", va="center",
                        fontsize=6.2, color=text_color(color), clip_on=True)
            bottom += h

    ax.set_ylim(0, ymax * 1.05)
    ax.set_xlim(-0.7, bars[-1][0] + 0.7)
    ax.set_xticks([])
    ax.tick_params(axis="y", labelsize=6.6, pad=1, length=2)
    ax.grid(axis="y", color="#d0d0d0", lw=0.3)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.set_ylabel("Monitoring overhead (%)", fontsize=7.6, labelpad=3)

    for xc, glabel in gc_marks:
        ax.text(xc, ymax * 1.075, glabel, ha="center", va="bottom", fontsize=6.6)
    for tlabel, lo, hi in tool_spans:
        ax.text((lo + hi) / 2.0, -ymax * 0.045, tlabel, ha="center", va="top",
                fontsize=7.6, fontweight="bold", clip_on=False)
    for i in range(len(TOOLS) - 1):
        ax.axvline((tool_spans[i][2] + tool_spans[i + 1][1]) / 2.0,
                   color="#cccccc", lw=0.5, ymax=0.93)

    handles = [Patch(facecolor=color, hatch=hatch, edgecolor=darker(color) if hatch
                     else "white", linewidth=0.0, label=cat)
               for cat, color, hatch in CATS]
    fig.legend(handles=handles, ncol=len(CATS), fontsize=8.5, loc="upper center",
               bbox_to_anchor=(0.5, 1.02), frameon=False, handlelength=1.3,
               columnspacing=1.2, handletextpad=0.5)
    fig.subplots_adjust(top=0.86, bottom=0.16, left=0.085, right=0.992)

    os.makedirs(OUT, exist_ok=True)
    fig.savefig(f"{OUT}/breakdown-bars.pdf", bbox_inches="tight", pad_inches=0.01)
    fig.savefig(f"{OUT}/breakdown-bars.png", dpi=200, bbox_inches="tight", pad_inches=0.01)
    print("wrote breakdown-bars.pdf")
    for gc, glabel in GCS:
        line = "  ".join(
            f"{tl}: {sum(share(pool, t, gc, 'stock', c) for c, _, _ in CATS):.0f}%"
            f"->{sum(share(pool, t, gc, 'native', c) for c, _, _ in CATS):.0f}%"
            for t, tl in TOOLS)
        print(f"  {glabel:8} monitoring share  {line}")


if __name__ == "__main__":
    main()
