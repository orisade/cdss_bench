# cdss_bench — Cuda Direct Stream Search Benchmark Harness

A **portable, self-contained** harness to benchmark decompression + literal
search throughput over compressed corpora, on **fresh CPU or GPU instances**.

- **CPU path** uses only stock CLIs (`zstd`/`gzip`/`lz4` + `grep`) — no build,
  no CUDA. Clone and run.
- **GPU path** clones and builds the [cuda-direct-stream-search](https://github.com/orisade/cuda-direct-stream-search)
  engine (nvCOMP) and benchmarks `cdss_search`.
- Runs **out-of-the-box anywhere**: if no real corpora are supplied it generates
  deterministic **synthetic seeds** for the four data types.

## Quick start (CPU-only instance)

```bash
git clone git@github.com:orisade/cdss_bench.git && cd cdss_bench
./bootstrap.sh                 # detect tools + GPU; report only (changes nothing)
./bootstrap.sh --install       # (if any tools are missing) install them
./gen/make_corpora.sh          # build corpora (default: wiki,json,log,sdf @ 1,2,10 GiB)
./bench/bench_cpu.sh           # decompress + search, 1-discard avg-of-3, warm cache
python3 analyze/aggregate.py results/*.csv --out results/summary.csv
```

## Quick start (GPU instance)

```bash
./bootstrap.sh --install --gpu # also clones + builds the engine (needs nvcc)
./bench/bench_gpu.sh           # cdss_search streaming; --repeat N for virtual sizes
python3 analyze/aggregate.py results/*.csv
```

## What it measures

Per (data type × size × codec), on a **warm page cache**, **1 discarded warm-up +
average of 3** timed runs (configurable):

- **decode**: `<codec> -dc FILE > /dev/null` — pure decompression throughput.
- **search**: `<codec> -dc FILE | grep -c PATTERN` — end-to-end decompress+search.
- **GPU**: end-to-end wall of `cdss_search --mode streaming`, plus scraped match count.

Correctness is self-checked: the match count is compared to a reference computed
from the plain seed, scaled by size (with a small boundary tolerance).

Results are one row per run in `results/<cpu|gpu>_<host>.csv` (19 columns, see
`bench/lib.sh`). `analyze/aggregate.py` summarizes; `analyze/plot.py` plots
throughput vs size (skips cleanly if matplotlib is absent).

## Corpora model

One 100 MiB **seed** per type → tiled to a **unit** plain (`--unit-mib`, default
1024 = 1 GiB) → compressed once per codec → **concatenated N times** for each
requested size (valid multiframe `.zst` / multi-member `.gz` / concatenated
`.lz4`; the GPU path uses the engine's chunked `.zst`). This pins the ratio to
the real 1-unit ratio and never writes a huge plain file. Generated data lives
under `corpora/` and `results/` (both git-ignored).

## Using REAL corpora instead of synthetic

Stage your four seed files (e.g. in S3), then edit `seeds/manifest.tsv` to set
each type's `sha256` and `source` (`s3://bucket/key` or `https://…`).
`fetch_seeds.sh` prefers a verified local file, then the manifest source, then
the synthetic generator. Dropping files directly into `seeds/data/` also works.

## Configuration

All defaults live in `config.sh` and are env-overridable, e.g.:

```bash
CDSS_SIZES="1,2,10,20" CDSS_PATTERN="the" CDSS_ZSTD_LEVEL=9 ./gen/make_corpora.sh
CDSS_WARMUP=1 CDSS_TIMED=5 ./bench/bench_cpu.sh
```

Key knobs: `CDSS_TYPES`, `CDSS_SIZES`, `CDSS_UNIT_MIB`, `CDSS_CODECS`,
`CDSS_PATTERN`, `CDSS_{ZSTD,GZIP,LZ4}_LEVEL`, `CDSS_WARMUP`, `CDSS_TIMED`,
`CDSS_STREAMS/BATCH/READERS/GPU_ID` (GPU).

## Layout

```
bootstrap.sh          detect/install tools; clone+build engine (--gpu)
config.sh             all defaults (env-overridable)
seeds/                manifest.tsv, gen_seed.py (synthetic), fetch_seeds.sh
gen/make_corpora.sh   build corpora + corpus_index.tsv
bench/                lib.sh (+ timer.py), bench_cpu.sh, bench_gpu.sh
analyze/              aggregate.py, plot.py
corpora/ results/ engine/   generated / cloned (git-ignored)
```

## Safety

`bootstrap.sh` is **non-destructive by default** (report only). `--install`
installs only the specific missing packages after showing the plan. Nothing here
reads or writes SSH keys or credentials, and all generated data stays under this
repo.
