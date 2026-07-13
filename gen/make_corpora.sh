#!/usr/bin/env bash
# Build benchmark corpora from the ~100 MB base seeds.
#
# Model (simple): for each requested size (in GiB), DUPLICATE the base seed up to
# that size to form a plain file, then COMPRESS that plain file once per codec.
# The plain is grepped for the exact reference match count, then (by default)
# deleted. No "unit" abstraction -- size N means N GiB of decompressed data.
#
# Writes $CDSS_CORPORA_DIR/corpus_index.tsv describing every artifact, consumed
# by the bench scripts.
#
# Usage:
#   make_corpora.sh [--types wiki,json,log,sdf] [--sizes 1,2,10]
#                   [--codecs gzip,zstd,lz4] [--pattern the] [--keep-plain]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../config.sh"

TYPES="$CDSS_TYPES"; SIZES="$CDSS_SIZES"
CODECS="$CDSS_CODECS"; PATTERN="$CDSS_PATTERN"; KEEP_PLAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --types) TYPES="$2"; shift 2;;
    --sizes) SIZES="$2"; shift 2;;
    --codecs) CODECS="$2"; shift 2;;
    --pattern) PATTERN="$2"; shift 2;;
    --keep-plain) KEEP_PLAIN=1; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) cdss_die "unknown arg: $1";;
  esac
done

INDEX="$CDSS_CORPORA_DIR/corpus_index.tsv"
mkdir -p "$CDSS_CORPORA_DIR"
: > "$INDEX"
printf '# type\tcodec\tsize_gib\tdecomp_bytes\tcomp_bytes\tratio\tpath\texp_lines\texp_occ\tlevel\n' >> "$INDEX"

GIB=1073741824

codec_ext()  { case "$1" in gzip) echo gz;; zstd) echo zst;; lz4) echo lz4;; *) echo "$1";; esac; }
codec_level(){ case "$1" in gzip) echo "$CDSS_GZIP_LEVEL";; zstd) echo "$CDSS_ZSTD_LEVEL";; lz4) echo "$CDSS_LZ4_LEVEL";; *) echo 0;; esac; }
compress_file() { # $1=codec $2=level $3=in_plain $4=out
  case "$1" in
    gzip) gzip -q -"$2" -c "$3" > "$4";;
    zstd) zstd -q -f -"$2" -c "$3" > "$4";;
    lz4)  lz4  -q -f -"$2" -c "$3" > "$4";;
    *) cdss_die "no CPU compressor for codec $1 (ans is GPU-only)";;
  esac
}

# Ensure seeds exist for the requested types.
"$CDSS_ROOT/seeds/fetch_seeds.sh" --types "$TYPES"

seed_for_type() {
  local t="$1" f
  f="$(awk -F'\t' -v t="$t" '!/^#/ && $1==t {print $2; exit}' "$CDSS_ROOT/seeds/manifest.tsv")"
  [ -n "$f" ] && [ -f "$CDSS_SEEDS_DIR/$f" ] && { echo "$CDSS_SEEDS_DIR/$f"; return; }
  ls "$CDSS_SEEDS_DIR/${t}"* 2>/dev/null | head -1
}

for type in $(cdss_split "$TYPES"); do
  seed="$(seed_for_type "$type")"
  [ -n "$seed" ] && [ -f "$seed" ] || cdss_die "no seed for type $type"
  seed_bytes=$(cdss_filesize "$seed")
  tdir="$CDSS_CORPORA_DIR/$type"; mkdir -p "$tdir"

  for n in $(cdss_split "$SIZES"); do
    target=$(( n * GIB ))
    plain="$tdir/${type}_${n}gib.plain"
    cdss_info "[$type/${n}GiB] duplicating seed -> plain ($n GiB)"
    copies=$(( (target + seed_bytes - 1) / seed_bytes ))
    # Bounded tiling; final cat may get SIGPIPE when head stops (benign).
    ( i=0; while [ "$i" -lt "$copies" ]; do cat "$seed"; i=$((i+1)); done ) 2>/dev/null \
      | head -c "$target" > "$plain" || true
    [ "$(cdss_filesize "$plain")" -eq "$target" ] || cdss_die "tiling produced wrong size for $type/${n}GiB"

    # Exact reference counts on this plain. ref_lines via grep -c (fast); ref_occ
    # (non-overlapping literal occurrences) via a single-pass awk index counter
    # (far faster than `grep -o | wc -l`, which would emit ~100M lines at 10 GiB).
    set +e
    ref_lines=$(grep -c -F "$PATTERN" "$plain"); [ $? -gt 1 ] && ref_lines=0
    set -e
    ref_occ=$(awk -v p="$PATTERN" '{s=$0;L=length(p);i=index(s,p);while(i){n++;s=substr(s,i+L);i=index(s,p)}} END{print n+0}' "$plain")
    cdss_info "[$type/${n}GiB] reference for '$PATTERN': lines=$ref_lines occ=$ref_occ"

    for codec in $(cdss_split "$CODECS"); do
      case "$codec" in
        gzip|zstd|lz4) cdss_have "$codec" || { cdss_info "[$type/${n}GiB] skip codec '$codec' (CLI not installed)"; continue; };;
        ans) cdss_info "[$type/${n}GiB] skip codec 'ans' (GPU-only; use bench_gpu.sh)"; continue;;
      esac
      ext="$(codec_ext "$codec")"; lvl="$(codec_level "$codec")"
      art="$tdir/${type}_${n}gib.$ext"
      cdss_info "[$type/${n}GiB/$codec] compressing (level $lvl)"
      compress_file "$codec" "$lvl" "$plain" "$art"
      comp=$(cdss_filesize "$art")
      ratio=$(python3 -c "print(round($comp/$target,4))")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$type" "$codec" "$n" "$target" "$comp" "$ratio" "$art" "$ref_lines" "$ref_occ" "$lvl" >> "$INDEX"
    done

    if [ "$KEEP_PLAIN" -eq 1 ]; then
      printf '%s\tplain\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$type" "$n" "$target" "$target" "1.0000" "$plain" "$ref_lines" "$ref_occ" "0" >> "$INDEX"
    else
      rm -f "$plain"
    fi
  done
done

cdss_info "corpus index written: $INDEX"
column -t -s "$(printf '\t')" "$INDEX" 2>/dev/null || cat "$INDEX"
