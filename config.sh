# cdss_bench shared configuration.
# Sourced by every script. Override any value via the environment, e.g.:
#   CDSS_SIZES="1,2,10" CDSS_PATTERN="the" ./gen/make_corpora.sh
#
# This file sets defaults only; it performs no actions and touches no system state.

# --- Repo root (directory containing this file) ---------------------------
CDSS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Engine (GPU search binary) source ------------------------------------
# Cloned by bootstrap.sh --gpu only when a CUDA toolchain is present.
: "${CDSS_ENGINE_REPO:=git@github.com:orisade/cuda-direct-stream-search.git}"
: "${CDSS_ENGINE_REPO_HTTPS:=https://github.com/orisade/cuda-direct-stream-search.git}"
: "${CDSS_ENGINE_DIR:=$CDSS_ROOT/engine}"
: "${CDSS_ENGINE_BIN:=$CDSS_ENGINE_DIR/build/cdss_search}"
: "${CDSS_ENGINE_ZST_COMPRESS:=$CDSS_ENGINE_DIR/build/cdss_compress_zst}"

# --- Working directories (all git-ignored) --------------------------------
: "${CDSS_SEEDS_DIR:=$CDSS_ROOT/seeds/data}"     # raw ~unit seeds, one per type
: "${CDSS_CORPORA_DIR:=$CDSS_ROOT/corpora}"       # generated plain + compressed corpora
: "${CDSS_RESULTS_DIR:=$CDSS_ROOT/results}"       # CSVs + plots

# --- Benchmark defaults ----------------------------------------------------
# Data types to build/benchmark. Known synthetic generators: wiki json log sdf
: "${CDSS_TYPES:=wiki,json,log,sdf}"
# Target corpus sizes in GiB (comma list). Each is built by duplicating the
# ~100 MB base seed up to that size, then compressing.
: "${CDSS_SIZES:=1,2,10}"
# Literal search pattern. "the" has no self-overlap, so grep -o agrees with the
# GPU engine's start-position count (see engine docs).
: "${CDSS_PATTERN:=the}"
# Codecs to build/benchmark. CPU-decodable: gzip zstd lz4. GPU-only: ans.
: "${CDSS_CODECS:=gzip,zstd,lz4}"
# Per-codec compression levels.
: "${CDSS_ZSTD_LEVEL:=3}"
: "${CDSS_GZIP_LEVEL:=6}"
: "${CDSS_LZ4_LEVEL:=1}"
# Timing discipline: discard N warm-up runs, then average M timed runs.
: "${CDSS_WARMUP:=1}"
: "${CDSS_TIMED:=3}"
# Default synthetic seed size (MiB) when no real seed is provided.
: "${CDSS_SEED_MIB:=100}"

# --- Helpers ---------------------------------------------------------------
cdss_have()   { command -v "$1" >/dev/null 2>&1; }
cdss_die()    { echo "cdss_bench: ERROR: $*" >&2; exit 1; }
cdss_info()   { echo "cdss_bench: $*" >&2; }
# Split a comma list into space-separated words (portable, no arrays needed).
cdss_split()  { echo "$1" | tr ',' ' '; }
# sha256 of a file, portable across Linux (sha256sum) and macOS (shasum -a 256).
cdss_sha256() {
  if cdss_have sha256sum; then sha256sum "$1" | awk '{print $1}';
  elif cdss_have shasum;   then shasum -a 256 "$1" | awk '{print $1}';
  else echo "-"; fi
}
# Portable byte size of a file.
cdss_filesize() {
  if stat -c%s "$1" >/dev/null 2>&1; then stat -c%s "$1"; else stat -f%z "$1"; fi
}
