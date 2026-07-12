#!/usr/bin/env bash
# Build benchmark corpora from seeds.
#
# For each type: tile the seed to a UNIT plain (CDSS_UNIT_MIB), compute the
# reference match counts, compress that unit once per codec, then for each
# requested size concatenate the compressed unit N times (valid multiframe
# .zst / multi-member .gz / concatenated .lz4 -- all decode natively). This
# keeps the compression ratio pinned to the real 1-unit ratio and never
# materializes a huge plain file.
#
# Writes $CDSS_CORPORA_DIR/corpus_index.tsv describing every artifact, consumed
# by the bench scripts.
#
# Usage:
#   make_corpora.sh [--types wiki,json,log,sdf] [--sizes 1,2,10]
#                   [--unit-mib 1024] [--codecs gzip,zstd,lz4]
#                   [--pattern the] [--keep-plain]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../config.sh"

TYPES="$CDSS_TYPES"; SIZES="$CDSS_SIZES"; UNIT_MIB="$CDSS_UNIT_MIB"
CODECS="$CDSS_CODECS"; PATTERN="$CDSS_PATTERN"; KEEP_PLAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --types) TYPES="$2"; shift 2;;
    --sizes) SIZES="$2"; shift 2;;
    --unit-mib) UNIT_MIB="$2"; shift 2;;
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
printf '# type\tcodec\tsize\tdecomp_bytes\tcomp_bytes\tratio\tpath\texp_lines\texp_occ\tlevel\n' >> "$INDEX"

# Codec -> (extension, compress-command-template). $LVL and files substituted below.
codec_ext()  { case "$1" in gzip) echo gz;; zstd) echo zst;; lz4) echo lz4;; *) echo "$1";; esac; }
codec_level(){ case "$1" in gzip) echo "$CDSS_GZIP_LEVEL";; zstd) echo "$CDSS_ZSTD_LEVEL";; lz4) echo "$CDSS_LZ4_LEVEL";; *) echo 0;; esac; }
compress_unit() { # $1=codec $2=level $3=in_plain $4=out
  case "$1" in
    gzip) gzip -q -"$2" -c "$3" > "$4";;
    zstd) zstd -q -f -"$2" -c "$3" > "$4";;
    lz4)  lz4  -q -f -"$2" -c "$3" > "$4";;
    *) cdss_die "no CPU compressor for codec $1 (ans is GPU-only)";;
  esac
}

# Ensure seeds exist for the requested types.
"$CDSS_ROOT/seeds/fetch_seeds.sh" --types "$TYPES"

UNIT_BYTES=$(( UNIT_MIB * 1024 * 1024 ))

seed_for_type() { # echo seed path for a type (first matching file in seeds/data)
  local t="$1" f
  f="$(awk -F'\t' -v t="$t" '!/^#/ && $1==t {print $2; exit}' "$CDSS_ROOT/seeds/manifest.tsv")"
  [ -n "$f" ] && [ -f "$CDSS_SEEDS_DIR/$f" ] && { echo "$CDSS_SEEDS_DIR/$f"; return; }
  # fall back to any seed file starting with the type name
  ls "$CDSS_SEEDS_DIR/${t}"* 2>/dev/null | head -1
}

for type in $(cdss_split "$TYPES"); do
  seed="$(seed_for_type "$type")"
  [ -n "$seed" ] && [ -f "$seed" ] || cdss_die "no seed for type $type"
  tdir="$CDSS_CORPORA_DIR/$type"; mkdir -p "$tdir"
  plain="$tdir/unit_plain.dat"

  cdss_info "[$type] tiling seed -> unit plain ($UNIT_MIB MiB)"
  # Tile the seed to exactly UNIT_BYTES using a BOUNDED loop (a bounded number
  # of copies piped through head -c). The final cat may get SIGPIPE when head
  # stops; that is benign and the loop still terminates -> guard with || true.
  seed_bytes=$(cdss_filesize "$seed")
  copies=$(( (UNIT_BYTES + seed_bytes - 1) / seed_bytes ))
  ( i=0; while [ "$i" -lt "$copies" ]; do cat "$seed"; i=$((i+1)); done ) 2>/dev/null \
    | head -c "$UNIT_BYTES" > "$plain" || true
  [ "$(cdss_filesize "$plain")" -eq "$UNIT_BYTES" ] || cdss_die "tiling produced wrong size for $type"

  # Reference counts on the unit plain (grep exits 1 when zero matches).
  set +e
  ref_lines=$(grep -c -F "$PATTERN" "$plain"); [ $? -gt 1 ] && ref_lines=0
  ref_occ=$(grep -o -F "$PATTERN" "$plain" | wc -l | tr -d ' ')
  set -e
  cdss_info "[$type] reference for '$PATTERN': lines=$ref_lines occ=$ref_occ (per unit)"

  for codec in $(cdss_split "$CODECS"); do
    ext="$(codec_ext "$codec")"; lvl="$(codec_level "$codec")"
    unit_art="$tdir/unit.$ext"
    cdss_info "[$type/$codec] compressing unit (level $lvl)"
    compress_unit "$codec" "$lvl" "$plain" "$unit_art"
    unit_comp=$(cdss_filesize "$unit_art")

    for n in $(cdss_split "$SIZES"); do
      out="$tdir/${type}_${n}u.$ext"
      if [ "$n" -eq 1 ]; then
        cp -f "$unit_art" "$out"
      else
        : > "$out"
        i=0; while [ "$i" -lt "$n" ]; do cat "$unit_art" >> "$out"; i=$((i+1)); done
      fi
      decomp=$(( UNIT_BYTES * n )); comp=$(( unit_comp * n ))
      ratio=$(python3 -c "print(round($comp/$decomp,4))")
      exp_lines=$(( ref_lines * n )); exp_occ=$(( ref_occ * n ))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$type" "$codec" "$n" "$decomp" "$comp" "$ratio" "$out" "$exp_lines" "$exp_occ" "$lvl" >> "$INDEX"
    done
    rm -f "$unit_art"
  done

  # Optional plain corpora (for the search-only roofline).
  if [ "$KEEP_PLAIN" -eq 1 ]; then
    for n in $(cdss_split "$SIZES"); do
      out="$tdir/${type}_${n}u.plain"
      if [ "$n" -eq 1 ]; then cp -f "$plain" "$out";
      else : > "$out"; i=0; while [ "$i" -lt "$n" ]; do cat "$plain" >> "$out"; i=$((i+1)); done; fi
      decomp=$(( UNIT_BYTES * n ))
      printf '%s\tplain\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$type" "$n" "$decomp" "$decomp" "1.0000" "$out" "$(( ref_lines * n ))" "$(( ref_occ * n ))" "0" >> "$INDEX"
    done
  fi
  rm -f "$plain"
done

cdss_info "corpus index written: $INDEX"
column -t -s "$(printf '\t')" "$INDEX" 2>/dev/null || cat "$INDEX"
