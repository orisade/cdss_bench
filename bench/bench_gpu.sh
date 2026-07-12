#!/usr/bin/env bash
# GPU decompression + search benchmark (uses the cuda-direct-stream-search
# engine). Requires the engine to be built -- run `./bootstrap.sh --gpu` first.
#
# For each type it builds a CHUNKED standard .zst with the engine's own
# cdss_compress_zst (64 KiB independent frames -- what nvCOMP batched decode
# needs; stock whole-file zstd is a single frame and is NOT used here), then:
#   * runs `cdss_search --mode streaming` and measures END-TO-END WALL with the
#     external timer (engine-agnostic), 1 discard + avg-of-N on a warm cache;
#   * scrapes the engine's stderr for the raw match count.
# Larger sizes are produced by concatenating the chunked .zst (valid multiframe)
# for honest wall, and/or via the engine's --repeat for the GPU-exec roofline.
#
# NOTE: the engine's exact stderr metric labels are validated on first run on
# the GPU host; wall (external timer) is robust regardless. Tune COUNT_RE /
# EXTRA_ARGS below if the engine build differs.
#
# Usage:
#   bench_gpu.sh [--types ...] [--sizes 1,2,10] [--unit-mib 1024]
#                [--pattern the] [--gpu-id 1] [--repeat N] [--out PATH]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../config.sh"; . "$HERE/lib.sh"

TYPES="$CDSS_TYPES"; SIZES="$CDSS_SIZES"; UNIT_MIB="$CDSS_UNIT_MIB"
PATTERN="$CDSS_PATTERN"; GPU_ID="${CDSS_GPU_ID:-1}"; REPEAT=""
HOST="$(hostname 2>/dev/null || echo unknown)"
OUT="$CDSS_RESULTS_DIR/gpu_${HOST}.csv"
STREAMS="${CDSS_STREAMS:-4}"; BATCH="${CDSS_BATCH:-4096}"; READERS="${CDSS_READERS:-8}"
while [ $# -gt 0 ]; do
  case "$1" in
    --types) TYPES="$2"; shift 2;;
    --sizes) SIZES="$2"; shift 2;;
    --unit-mib) UNIT_MIB="$2"; shift 2;;
    --pattern) PATTERN="$2"; shift 2;;
    --gpu-id) GPU_ID="$2"; shift 2;;
    --repeat) REPEAT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) cdss_die "unknown arg: $1";;
  esac
done

[ -x "$CDSS_ENGINE_BIN" ] || cdss_die "engine not built: $CDSS_ENGINE_BIN (run ./bootstrap.sh --gpu)"
[ -x "$CDSS_ENGINE_ZST_COMPRESS" ] || cdss_die "engine zst compressor missing: $CDSS_ENGINE_ZST_COMPRESS"
mkdir -p "$CDSS_RESULTS_DIR" "$CDSS_CORPORA_DIR"
cdss_csv_init "$OUT"

# Regex used to scrape the engine's true match total from stderr. The steering
# docs call it the "raw count" line; fall back to the last integer seen.
COUNT_RE='raw count|raw|matches|total'
UNIT_BYTES=$(( UNIT_MIB * 1024 * 1024 ))

# Ensure seeds and build the chunked .zst inputs.
"$CDSS_ROOT/seeds/fetch_seeds.sh" --types "$TYPES"
seed_for_type() {
  local t="$1" f
  f="$(awk -F'\t' -v t="$t" '!/^#/ && $1==t {print $2; exit}' "$CDSS_ROOT/seeds/manifest.tsv")"
  [ -n "$f" ] && [ -f "$CDSS_SEEDS_DIR/$f" ] && { echo "$CDSS_SEEDS_DIR/$f"; return; }
  ls "$CDSS_SEEDS_DIR/${t}"* 2>/dev/null | head -1
}

cdss_info "GPU benchmark on $HOST -> $OUT (engine=$CDSS_ENGINE_BIN gpu=$GPU_ID)"

for type in $(cdss_split "$TYPES"); do
  seed="$(seed_for_type "$type")"; [ -f "$seed" ] || cdss_die "no seed for $type"
  tdir="$CDSS_CORPORA_DIR/$type"; mkdir -p "$tdir"
  plain="$tdir/gpu_unit_plain.dat"
  seed_bytes=$(cdss_filesize "$seed")
  copies=$(( (UNIT_BYTES + seed_bytes - 1) / seed_bytes ))
  ( i=0; while [ "$i" -lt "$copies" ]; do cat "$seed"; i=$((i+1)); done ) 2>/dev/null \
    | head -c "$UNIT_BYTES" > "$plain" || true
  [ "$(cdss_filesize "$plain")" -eq "$UNIT_BYTES" ] || cdss_die "tiling produced wrong size for $type"
  set +e
  ref_occ=$(grep -o -F "$PATTERN" "$plain" | wc -l | tr -d ' ')
  set -e
  unit_zst="$tdir/gpu_unit.zst"
  cdss_info "[$type] engine-compressing chunked .zst (64 KiB)"
  "$CDSS_ENGINE_ZST_COMPRESS" "$plain" "$unit_zst" 64 >/dev/null 2>&1 \
    || cdss_die "cdss_compress_zst failed for $type"
  unit_comp=$(cdss_filesize "$unit_zst")
  rm -f "$plain"

  for n in $(cdss_split "$SIZES"); do
    file="$tdir/${type}_${n}u_gpu.zst"
    if [ "$n" -eq 1 ]; then cp -f "$unit_zst" "$file";
    else : > "$file"; i=0; while [ "$i" -lt "$n" ]; do cat "$unit_zst" >> "$file"; i=$((i+1)); done; fi
    decomp=$(( UNIT_BYTES * n )); comp=$(( unit_comp * n ))
    ratio=$(python3 -c "print(round($comp/$decomp,4))")
    exp_occ=$(( ref_occ * n ))
    rep_args=""; [ -n "$REPEAT" ] && rep_args="--repeat $REPEAT"

    errf="$(mktemp)"
    scmd="'$CDSS_ENGINE_BIN' --mode streaming --streams $STREAMS --batch $BATCH --readers $READERS $rep_args '$file' '$PATTERN' $GPU_ID 2>'$errf' >/dev/null"
    cdss_warm "$file"
    cdss_timed "$scmd"
    count="$(grep -iE "$COUNT_RE" "$errf" 2>/dev/null | grep -oE '[0-9]+' | tail -1)"; [ -n "$count" ] || count=0
    rm -f "$errf"
    eff_decomp="$decomp"; [ -n "$REPEAT" ] && eff_decomp=$(( decomp * REPEAT )) && exp_occ=$(( exp_occ * REPEAT ))
    gibs="$(cdss_gibs "$eff_decomp" "$RT_AVG_MS")"
    tol="$n"
    correct=$(python3 -c "print(1 if abs($count-$exp_occ)<=$tol else 0)")
    cdss_csv_row "$OUT" "$HOST" 1 "$type" "$n" "$UNIT_MIB" zstd 3 \
      search "cdss_search" "$PATTERN" "$eff_decomp" "$comp" "$ratio" "$RT_AVG_MS" "$gibs" "$count" "$exp_occ" "$correct" "\"$RT_RUNS\""
    cdss_info "  [$type/${n}u${REPEAT:+ x$REPEAT}] wall ${RT_AVG_MS} ms  ${gibs} GiB/s  count=$count exp=$exp_occ correct=$correct"
  done
  rm -f "$unit_zst"
done
cdss_info "GPU results written: $OUT"
