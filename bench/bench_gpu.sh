#!/usr/bin/env bash
# GPU decompression + search benchmark (uses the cuda-direct-stream-search
# engine). Requires the engine to be built -- run `./bootstrap.sh --gpu` first.
#
# For each size (in GiB) it duplicates the base seed to that size, compresses it
# to a CHUNKED standard .zst with the engine's own cdss_compress_zst (64 KiB
# independent frames -- what nvCOMP batched decode needs; stock whole-file zstd
# is a single frame and is NOT used here), then:
#   * runs `cdss_search --mode streaming` and measures END-TO-END WALL with the
#     external timer (engine-agnostic), 1 discard + avg-of-N on a warm cache;
#   * scrapes the engine's stderr for the raw match count.
# --repeat N re-reads the file N times in-engine to emulate an N x larger corpus
# (for the GPU-exec roofline without building the file).
#
# NOTE: the engine's exact stderr metric labels are validated on first run on a
# GPU host; wall (external timer) is robust regardless. Tune COUNT_RE if needed.
#
# Usage:
#   bench_gpu.sh [--types ...] [--sizes 1,2,10] [--pattern the]
#                [--gpu-id 1] [--repeat N] [--out PATH]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../config.sh"; . "$HERE/lib.sh"

TYPES="$CDSS_TYPES"; SIZES="$CDSS_SIZES"
PATTERN="$CDSS_PATTERN"; GPU_ID="${CDSS_GPU_ID:-1}"; REPEAT=""
HOST="$(hostname 2>/dev/null || echo unknown)"
OUT="$CDSS_RESULTS_DIR/gpu_${HOST}.csv"
STREAMS="${CDSS_STREAMS:-4}"; BATCH="${CDSS_BATCH:-4096}"; READERS="${CDSS_READERS:-8}"
while [ $# -gt 0 ]; do
  case "$1" in
    --types) TYPES="$2"; shift 2;;
    --sizes) SIZES="$2"; shift 2;;
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

COUNT_RE='raw count|raw|matches|total'
GIB=1073741824

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
  seed_bytes=$(cdss_filesize "$seed")
  tdir="$CDSS_CORPORA_DIR/$type"; mkdir -p "$tdir"

  for n in $(cdss_split "$SIZES"); do
    target=$(( n * GIB ))
    plain="$tdir/${type}_${n}gib_gpu.plain"
    copies=$(( (target + seed_bytes - 1) / seed_bytes ))
    ( i=0; while [ "$i" -lt "$copies" ]; do cat "$seed"; i=$((i+1)); done ) 2>/dev/null \
      | head -c "$target" > "$plain" || true
    [ "$(cdss_filesize "$plain")" -eq "$target" ] || cdss_die "tiling produced wrong size for $type/${n}GiB"
    set +e
    ref_occ=$(grep -o -F "$PATTERN" "$plain" | wc -l | tr -d ' ')
    set -e

    file="$tdir/${type}_${n}gib_gpu.zst"
    cdss_info "[$type/${n}GiB] engine-compressing chunked .zst (64 KiB)"
    "$CDSS_ENGINE_ZST_COMPRESS" "$plain" "$file" 64 >/dev/null 2>&1 \
      || cdss_die "cdss_compress_zst failed for $type/${n}GiB"
    comp=$(cdss_filesize "$file"); rm -f "$plain"
    ratio=$(python3 -c "print(round($comp/$target,4))")

    rep_args=""; eff_decomp="$target"; eff_occ="$ref_occ"
    if [ -n "$REPEAT" ]; then rep_args="--repeat $REPEAT"; eff_decomp=$(( target * REPEAT )); eff_occ=$(( ref_occ * REPEAT )); fi

    errf="$(mktemp)"
    scmd="'$CDSS_ENGINE_BIN' --mode streaming --streams $STREAMS --batch $BATCH --readers $READERS $rep_args '$file' '$PATTERN' $GPU_ID 2>'$errf' >/dev/null"
    cdss_warm "$file"
    cdss_timed "$scmd"
    count="$(grep -iE "$COUNT_RE" "$errf" 2>/dev/null | grep -oE '[0-9]+' | tail -1)"; [ -n "$count" ] || count=0
    rm -f "$errf" "$file"
    gibs="$(cdss_gibs "$eff_decomp" "$RT_AVG_MS")"
    correct=$(python3 -c "print(1 if $count==$eff_occ else 0)")
    cdss_csv_row "$OUT" "$HOST" 1 "$type" "$n" zstd 3 \
      search "cdss_search" "$PATTERN" "$eff_decomp" "$comp" "$ratio" "$RT_AVG_MS" "$gibs" "$count" "$eff_occ" "$correct" "\"$RT_RUNS\""
    cdss_info "  [$type/${n}GiB${REPEAT:+ x$REPEAT}] wall ${RT_AVG_MS} ms  ${gibs} GiB/s  count=$count exp=$eff_occ correct=$correct"
  done
done
cdss_info "GPU results written: $OUT"
