#!/usr/bin/env bash
# Ensure a seed file exists under $CDSS_SEEDS_DIR for each requested type.
#
# Resolution order per type (first that works wins):
#   1. Existing file in seeds/data/ (verified against manifest sha256 if given)
#   2. Real source from manifest.tsv  (s3://... via aws, or https://... via curl)
#   3. Synthetic generator (seeds/gen_seed.py) -- deterministic fallback
#
# Non-destructive: only writes under seeds/data/. Never touches credentials/keys.
#
# Usage: fetch_seeds.sh [--types wiki,json,log,sdf] [--size-mib 100]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../config.sh"

TYPES="$CDSS_TYPES"
SIZE_MIB="$CDSS_SEED_MIB"
while [ $# -gt 0 ]; do
  case "$1" in
    --types) TYPES="$2"; shift 2;;
    --size-mib) SIZE_MIB="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) cdss_die "unknown arg: $1";;
  esac
done

MANIFEST="$HERE/manifest.tsv"
mkdir -p "$CDSS_SEEDS_DIR"

manifest_field() { # $1=type $2=colnum
  awk -F'\t' -v t="$1" -v c="$2" '!/^#/ && $1==t {print $c; exit}' "$MANIFEST"
}

for type in $(cdss_split "$TYPES"); do
  fname="$(manifest_field "$type" 2)"
  want_sha="$(manifest_field "$type" 4)"
  source="$(manifest_field "$type" 5)"
  msize="$(manifest_field "$type" 3)"
  [ -n "$fname" ] || { fname="${type}_seed.dat"; source="-"; want_sha="-"; msize="$SIZE_MIB"; }
  dst="$CDSS_SEEDS_DIR/$fname"

  # 1. Already present?
  if [ -f "$dst" ]; then
    if [ -n "$want_sha" ] && [ "$want_sha" != "-" ]; then
      got="$(cdss_sha256 "$dst")"
      if [ "$got" = "$want_sha" ]; then cdss_info "seed ok (cached, verified): $fname"; continue; fi
      cdss_info "seed $fname checksum mismatch; refetching"
    else
      cdss_info "seed present (unverified): $fname"; continue
    fi
  fi

  # 2. Real source.
  fetched=0
  case "$source" in
    s3://*)
      if cdss_have aws; then
        cdss_info "fetching $fname from $source"
        aws s3 cp "$source" "$dst" && fetched=1 || cdss_info "aws s3 cp failed for $type"
      else cdss_info "aws CLI missing; cannot fetch $source"; fi
      ;;
    https://*|http://*)
      if cdss_have curl; then
        cdss_info "fetching $fname from $source"
        curl -fsSL "$source" -o "$dst" && fetched=1 || cdss_info "curl failed for $type"
      elif cdss_have wget; then
        curl_missing=1; wget -q "$source" -O "$dst" && fetched=1 || cdss_info "wget failed for $type"
      else cdss_info "no curl/wget; cannot fetch $source"; fi
      ;;
  esac

  # 3. Synthetic fallback.
  if [ "$fetched" -ne 1 ]; then
    gen_type="$type"
    case "$type" in wiki|json|log|sdf) ;; *) gen_type="wiki";; esac
    [ -n "$msize" ] && [ "$msize" != "-" ] || msize="$SIZE_MIB"
    cdss_info "generating synthetic $type seed ($msize MiB) -> $fname"
    python3 "$HERE/gen_seed.py" --type "$gen_type" --size-mib "$msize" --out "$dst"
  fi

  # Verify if we have an expected checksum.
  if [ -n "$want_sha" ] && [ "$want_sha" != "-" ]; then
    got="$(cdss_sha256 "$dst")"
    [ "$got" = "$want_sha" ] || cdss_die "checksum mismatch for $fname (got $got want $want_sha)"
    cdss_info "seed verified: $fname"
  fi
done
cdss_info "seeds ready in $CDSS_SEEDS_DIR"
