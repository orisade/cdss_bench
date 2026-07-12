#!/usr/bin/env python3
"""Plot cdss_bench throughput vs corpus size.

One figure per data type; within it, a line per (codec, phase) of throughput
(GiB/s) against size. Skips gracefully if matplotlib is not installed.

Usage:
  plot.py results/*.csv [--phase search|decode] [--outdir results/plots]
"""
import argparse, csv, glob, sys, os
from collections import defaultdict

def fnum(x, d=0.0):
    try: return float(x)
    except (TypeError, ValueError): return d

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csvs", nargs="+")
    ap.add_argument("--phase", default="search")
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args()
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as e:
        sys.stderr.write("matplotlib unavailable (%s); skipping plots\n" % e); sys.exit(0)

    rows = []
    for pat in a.csvs:
        for p in glob.glob(pat):
            with open(p, newline="") as f:
                rows += [r for r in csv.DictReader(f)]
    rows = [r for r in rows if r.get("phase") == a.phase]
    if not rows:
        sys.stderr.write("no rows for phase=%s\n" % a.phase); sys.exit(0)

    outdir = a.outdir or os.path.join(os.path.dirname(a.csvs[0].rstrip("*")) or ".", "plots")
    os.makedirs(outdir, exist_ok=True)

    # type -> codec -> [(size, gibs)]
    by_type = defaultdict(lambda: defaultdict(list))
    for r in rows:
        lbl = ("GPU " if r.get("has_gpu") == "1" else "") + r["codec"]
        by_type[r["type"]][lbl].append((fnum(r["size_gib"]), fnum(r["gibs"])))

    for typ, codecs in sorted(by_type.items()):
        plt.figure(figsize=(7, 4.5))
        for codec, pts in sorted(codecs.items()):
            pts = sorted(set(pts))
            xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
            plt.plot(xs, ys, marker="o", label=codec)
        plt.xlabel("corpus size (GiB)"); plt.ylabel("throughput (decompressed GiB/s)")
        plt.title("%s -- %s throughput vs size" % (typ, a.phase))
        plt.grid(True, alpha=0.3); plt.legend()
        out = os.path.join(outdir, "throughput_%s_%s.png" % (typ, a.phase))
        plt.tight_layout(); plt.savefig(out, dpi=120); plt.close()
        sys.stderr.write("wrote %s\n" % out)

if __name__ == "__main__":
    main()
