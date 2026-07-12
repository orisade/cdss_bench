#!/usr/bin/env python3
"""Generate a synthetic seed file for one data type.

This is the fallback used when no real seed is supplied (see fetch_seeds.sh).
Each generator produces content that is (a) representative in structure and
(b) has a realistic, non-degenerate compression ratio, so the codec/decode
benchmarks are meaningful even without the real corpora. Output is
deterministic for a fixed --rng-seed.

Types: wiki (natural-language text), json (records), log (syslog-like),
sdf (Synopsys-SDF-like nested-paren timing records).

Usage:
  gen_seed.py --type wiki --size-mib 100 --out seed.txt [--rng-seed 1]
"""
import argparse, os, random, sys

# A small vocabulary with "the" frequent, so the canonical pattern occurs at a
# realistic natural-language rate in the wiki type.
WORDS = ("the of and to in a is that for it as was with be by on not he this "
         "but are from or have an they which one you were her all she there "
         "would their we him been has when who will more no if out so said what "
         "system data value time memory kernel stream search compress decode "
         "node index buffer offset frame chunk ratio throughput latency block").split()

def _write_chunks(out, target_bytes, make_chunk, rng):
    """Call make_chunk(rng) repeatedly until target_bytes written."""
    written = 0
    with open(out, "wb") as f:
        while written < target_bytes:
            data = make_chunk(rng)
            if isinstance(data, str):
                data = data.encode("utf-8", "replace")
            f.write(data)
            written += len(data)
        # Trim to exact size for predictable corpus math.
    with open(out, "rb+") as f:
        f.truncate(target_bytes)

def make_wiki(rng):
    # ~ a paragraph of random words; "the" appears at natural frequency.
    n = 2000
    words = rng.choices(WORDS, k=n)
    # sprinkle sentence structure
    out = []
    i = 0
    while i < n:
        sent_len = rng.randint(6, 18)
        sent = " ".join(words[i:i+sent_len]).capitalize()
        out.append(sent + ". ")
        i += sent_len
    return "".join(out) + "\n"

def make_json(rng):
    recs = []
    for _ in range(400):
        recs.append(
            '{{"id":{id},"name":"{name}","ts":{ts},"level":"{lvl}",'
            '"msg":"the {w1} {w2} reached {v}","ok":{ok}}}'.format(
                id=rng.randint(1, 10**9),
                name=rng.choice(WORDS) + "_" + rng.choice(WORDS),
                ts=rng.randint(1_600_000_000, 1_800_000_000),
                lvl=rng.choice(("INFO", "WARN", "ERROR", "DEBUG")),
                w1=rng.choice(WORDS), w2=rng.choice(WORDS),
                v=round(rng.random() * 1000, 3),
                ok=rng.choice(("true", "false")),
            ))
    return "[" + ",\n".join(recs) + "]\n"

def make_log(rng):
    lines = []
    for _ in range(1500):
        lines.append(
            "{ts} {host} {proc}[{pid}]: {lvl} the {w1} {w2} for id={id} took {ms}ms".format(
                ts=rng.randint(1_600_000_000, 1_800_000_000),
                host="host-" + str(rng.randint(1, 64)),
                proc=rng.choice(("kernel", "sshd", "cron", "engine", "search")),
                pid=rng.randint(100, 99999),
                lvl=rng.choice(("INFO", "WARN", "ERROR", "DEBUG")),
                w1=rng.choice(WORDS), w2=rng.choice(WORDS),
                id=rng.randint(1, 10**7),
                ms=rng.randint(0, 5000),
            ))
    return "\n".join(lines) + "\n"

def make_sdf(rng):
    # Synopsys-SDF-like nested-paren timing records.
    recs = []
    for _ in range(300):
        cell = rng.choice(("AND2", "OR2", "DFF", "MUX2", "INV", "NAND3", "XOR2"))
        inst = "U" + str(rng.randint(1, 999999))
        r = lambda: round(rng.random() * 2, 3)
        recs.append(
            "(CELL (CELLTYPE \"{c}\") (INSTANCE {i})\n"
            "  (DELAY (ABSOLUTE\n"
            "    (IOPATH A Z ({a}:{b}:{cc}) ({d}:{e}:{ff}))\n"
            "    (IOPATH B Z ({g}:{h}:{ii}) ({j}:{k}:{ll})))))".format(
                c=cell, i=inst,
                a=r(), b=r(), cc=r(), d=r(), e=r(), ff=r(),
                g=r(), h=r(), ii=r(), j=r(), k=r(), ll=r()))
    return "(DELAYFILE\n" + "\n".join(recs) + "\n)\n"

GENERATORS = {"wiki": make_wiki, "json": make_json, "log": make_log, "sdf": make_sdf}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--type", required=True, choices=sorted(GENERATORS))
    ap.add_argument("--size-mib", type=float, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rng-seed", type=int, default=1)
    a = ap.parse_args()
    rng = random.Random(a.rng_seed)
    target = int(a.size_mib * 1024 * 1024)
    _write_chunks(a.out, target, GENERATORS[a.type], rng)
    sys.stderr.write("gen_seed: wrote %s (%s, %.1f MiB)\n"
                     % (a.out, a.type, target / 1048576.0))

if __name__ == "__main__":
    main()
