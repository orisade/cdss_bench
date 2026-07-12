#!/usr/bin/env python3
"""Aggregate cdss_bench result CSVs into a readable summary.

Reads one or more result CSVs (from bench_cpu.sh / bench_gpu.sh), and prints a
grouped summary: for each (type, size, codec, phase) the average throughput and
correctness. Optionally writes a tidy summary CSV.

Usage:
  aggregate.py results/*.csv [--out results/summary.csv]
"""
import argparse, csv, glob, sys
from collections import defaultdict

def load(paths):
    rows = []
    for pat in paths:
        for p in glob.glob(pat):
            with open(p, newline="") as f:
                for r in csv.DictReader(f):
                    rows.append(r)
    return rows

def fnum(x, d=0.0):
    try: return float(x)
    except (TypeError, ValueError): return d

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csvs", nargs="+")
    ap.add_argument("--out")
    a = ap.parse_args()
    rows = load(a.csvs)
    if not rows:
        sys.stderr.write("no rows found\n"); sys.exit(1)

    # Group key -> list of gibs
    agg = defaultdict(lambda: {"gibs": [], "ms": [], "correct": [], "ratio": None,
                               "count": None, "expected": None})
    for r in rows:
        key = (r.get("host",""), int(fnum(r.get("has_gpu"))), r["type"],
               r["size_units"], r["codec"], r["phase"])
        g = agg[key]
        g["gibs"].append(fnum(r.get("gibs")))
        g["ms"].append(fnum(r.get("avg_ms")))
        if r.get("correct") not in (None, ""): g["correct"].append(int(fnum(r["correct"])))
        g["ratio"] = r.get("ratio"); g["count"] = r.get("match_count"); g["expected"] = r.get("expected")

    hdr = ["host","has_gpu","type","size","codec","phase","avg_ms","gibs","ratio","correct","count","expected"]
    print("  ".join(f"{h:>9}" if h not in ("type","codec","phase") else f"{h:>7}" for h in hdr))
    out_rows = []
    for key in sorted(agg):
        g = agg[key]
        host, gpu, typ, size, codec, phase = key
        gibs = sum(g["gibs"])/len(g["gibs"]) if g["gibs"] else 0
        ms = sum(g["ms"])/len(g["ms"]) if g["ms"] else 0
        corr = "-" if not g["correct"] else ("ok" if all(c==1 for c in g["correct"]) else "FAIL")
        vals = [host, gpu, typ, size, codec, phase, f"{ms:.1f}", f"{gibs:.2f}",
                g["ratio"] or "-", corr, g["count"] or "-", g["expected"] or "-"]
        print("  ".join(f"{str(v):>9}" if h not in ("type","codec","phase") else f"{str(v):>7}"
                         for v, h in zip(vals, hdr)))
        out_rows.append(dict(zip(hdr, vals)))

    if a.out:
        with open(a.out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=hdr); w.writeheader(); w.writerows(out_rows)
        sys.stderr.write("wrote %s\n" % a.out)

if __name__ == "__main__":
    main()
