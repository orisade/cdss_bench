#!/usr/bin/env bash
# Shared benchmark helpers: warm cache, 1-discard + avg-of-N timing, CSV emit.
# Source this AFTER config.sh.

CDSS_TIMER="${CDSS_TIMER:-$CDSS_ROOT/bench/timer.py}"

# Warm the page cache for a file (read it fully to /dev/null, twice).
cdss_warm() { cat "$1" > /dev/null 2>&1; cat "$1" > /dev/null 2>&1; }

# Run one command once under the timer.
#   Sets: _RT_MS (float ms), _RT_EXIT (int), _RT_OUT (captured stdout)
_cdss_run_once() {
  local cmd="$1" errf
  errf="$(mktemp)"
  _RT_OUT="$(python3 "$CDSS_TIMER" "$cmd" 2>"$errf")"
  _RT_MS="$(awk '/^__ELAPSED_MS__/{print $2}' "$errf")"
  _RT_EXIT="$(awk '/^__EXIT__/{print $2}' "$errf")"
  rm -f "$errf"
  [ -n "$_RT_MS" ] || _RT_MS=0
  [ -n "$_RT_EXIT" ] || _RT_EXIT=1
}

# Timed run: discard $CDSS_WARMUP warm-ups, then average $CDSS_TIMED runs.
#   Sets: RT_AVG_MS (avg over timed runs), RT_OUT (stdout of last timed run),
#         RT_EXIT (exit of last timed run), RT_RUNS (semicolon list of ms)
cdss_timed() {
  local cmd="$1" i sum="0" runs=""
  for ((i=0; i<CDSS_WARMUP; i++)); do _cdss_run_once "$cmd"; done
  for ((i=0; i<CDSS_TIMED; i++)); do
    _cdss_run_once "$cmd"
    sum="$(python3 -c "print($sum + $_RT_MS)")"
    runs="${runs:+$runs;}$_RT_MS"
  done
  RT_AVG_MS="$(python3 -c "print(round($sum / max(1,$CDSS_TIMED), 4))")"
  RT_OUT="$_RT_OUT"; RT_EXIT="$_RT_EXIT"; RT_RUNS="$runs"
}

# Throughput in decompressed GiB/s from bytes + ms.
cdss_gibs() { python3 -c "print(round(($1/1073741824.0)/($2/1000.0), 4) if $2>0 else 0)"; }

# CSV header + row. Columns are fixed and consumed by analyze/aggregate.py.
CDSS_CSV_HEADER='host,has_gpu,type,size_gib,codec,level,phase,tool,pattern,decomp_bytes,comp_bytes,ratio,avg_ms,gibs,match_count,expected,correct,runs_ms'
cdss_csv_init() { echo "$CDSS_CSV_HEADER" > "$1"; }
# cdss_csv_row FILE field1 field2 ...  (fields already ordered per header)
cdss_csv_row() {
  local f="$1"; shift
  local IFS=,; echo "$*" >> "$f"
}
