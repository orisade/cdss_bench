#!/usr/bin/env bash
# CPU decompression + search benchmark.
#
# Reads corpora/corpus_index.tsv and, for every artifact, measures on a WARM
# page cache with 1 discarded warm-up + avg-of-N timed runs (see config.sh):
#   * decode      : <decoder> -dc FILE > /dev/null          (pure decompression)
#   * search      : <decoder> -dc FILE | grep -c PATTERN     (decompress+search)
# plain corpora (if built with --keep-plain) get a search-only roofline row.
#
# Correctness: the grep -c line count is compared to the per-unit reference
# scaled by the size multiplier, with a small boundary tolerance.
#
# GPU-only codecs (ans) are skipped here.
#
# Usage:
#   bench_cpu.sh [--index PATH] [--pattern the] [--out results/cpu_<host>.csv]
#                [--types ...] [--sizes ...] [--codecs gzip,zstd,lz4]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../config.sh"; . "$HERE/lib.sh"

INDEX="$CDSS_CORPORA_DIR/corpus_index.tsv"
PATTERN="$CDSS_PATTERN"
HOST="$(hostname 2>/dev/null || echo unknown)"
OUT="$CDSS_RESULTS_DIR/cpu_${HOST}.csv"
ONLY_TYPES=""; ONLY_SIZES=""; ONLY_CODECS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --index) INDEX="$2"; shift 2;;
    --pattern) PATTERN="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --types) ONLY_TYPES="$2"; shift 2;;
    --sizes) ONLY_SIZES="$2"; shift 2;;
    --codecs) ONLY_CODECS="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) cdss_die "unknown arg: $1";;
  esac
done
[ -f "$INDEX" ] || cdss_die "no corpus index at $INDEX (run gen/make_corpora.sh first)"
mkdir -p "$CDSS_RESULTS_DIR"
cdss_csv_init "$OUT"

in_list() { # $1=needle $2=comma-list ("" means match-all)
  [ -z "$2" ] && return 0
  case ",$2," in *",$1,"*) return 0;; *) return 1;; esac
}
decoder_cmd() { # $1=codec $2=file  -> echoes a decode-to-stdout command
  case "$1" in
    gzip) echo "gzip -dc '$2'";;
    zstd) echo "zstd -dc -q '$2'";;
    lz4)  echo "lz4 -dc -q '$2'";;
    plain) echo "cat '$2'";;
    *) return 1;;
  esac
}
decoder_tool() { case "$1" in gzip) echo gzip;; zstd) echo zstd;; lz4) echo lz4;; plain) echo cat;; esac; }

cdss_info "CPU benchmark on $HOST -> $OUT (pattern='$PATTERN', warmup=$CDSS_WARMUP timed=$CDSS_TIMED)"

# Read index (skip comments).
while IFS=$'\t' read -r type codec size decomp comp ratio path exp_lines exp_occ level; do
  case "$type" in \#*|"") continue;; esac
  in_list "$type" "$ONLY_TYPES"   || continue
  in_list "$size" "$ONLY_SIZES"   || continue
  in_list "$codec" "$ONLY_CODECS" || continue
  case "$codec" in ans) cdss_info "skip $codec (GPU-only)"; continue;; esac
  [ -f "$path" ] || { cdss_info "missing artifact, skip: $path"; continue; }

  dcmd="$(decoder_cmd "$codec" "$path")" || { cdss_info "no CPU decoder for $codec"; continue; }
  tool="$(decoder_tool "$codec")"
  cdss_warm "$path"

  # --- decode-only (skip for plain: nothing to decode) ---
  if [ "$codec" != "plain" ]; then
    cdss_timed "$dcmd > /dev/null"
    gibs="$(cdss_gibs "$decomp" "$RT_AVG_MS")"
    cdss_csv_row "$OUT" "$HOST" 0 "$type" "$size" "$codec" "$level" \
      decode "$tool" "$PATTERN" "$decomp" "$comp" "$ratio" "$RT_AVG_MS" "$gibs" "" "" "" "\"$RT_RUNS\""
    cdss_info "  [$type/$codec/${size}GiB] decode  ${RT_AVG_MS} ms  ${gibs} GiB/s"
  fi

  # --- search (decompress | grep -c) ---
  if [ "$codec" = "plain" ]; then
    scmd="LC_ALL=C grep -c -F -- '$PATTERN' '$path' || true"
  else
    scmd="$dcmd | LC_ALL=C grep -c -F -- '$PATTERN' || true"
  fi
  cdss_timed "$scmd"
  count="$(echo "$RT_OUT" | tr -dc '0-9')"; [ -n "$count" ] || count=0
  gibs="$(cdss_gibs "$decomp" "$RT_AVG_MS")"
  correct=$(python3 -c "print(1 if $count==$exp_lines else 0)")
  cdss_csv_row "$OUT" "$HOST" 0 "$type" "$size" "$codec" "$level" \
    search "$tool|grep" "$PATTERN" "$decomp" "$comp" "$ratio" "$RT_AVG_MS" "$gibs" "$count" "$exp_lines" "$correct" "\"$RT_RUNS\""
  cdss_info "  [$type/$codec/${size}GiB] search  ${RT_AVG_MS} ms  ${gibs} GiB/s  count=$count exp=$exp_lines correct=$correct"
done < "$INDEX"

cdss_info "CPU results written: $OUT"
