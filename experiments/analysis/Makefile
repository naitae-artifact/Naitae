# Minimal artifact: regenerate every figure and headline number from data/.
#
#   make figures   the summary violins + RQ3 breakdown bars -> figures/
#   make stats     Table 1-2 numbers, abstract maxima, and RQ4 Table 3 counts
#   make all       both
#
# Needs Python with pandas, seaborn, matplotlib, numpy. The repo venv works:
#   make PYTHON=../eval/.venv/bin/python all
PYTHON ?= python3

.PHONY: all figures stats
all: figures stats

figures:
	$(PYTHON) scripts/plot_summary.py
	$(PYTHON) scripts/plot_rq3_breakdown.py

stats:
	$(PYTHON) scripts/stats.py
