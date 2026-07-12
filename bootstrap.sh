#!/usr/bin/env bash
# cdss_bench bootstrap: prepare a machine to run the benchmarks.
#
# SAFE BY DEFAULT: with no flags it only DETECTS and REPORTS. It changes nothing.
# It never reads or writes SSH keys, credentials, or any file outside this repo.
#
#   ./bootstrap.sh              # detect tools + GPU, print a report, do nothing
#   ./bootstrap.sh --install    # install any MISSING CPU tools (zstd/gzip/lz4/python3)
#   ./bootstrap.sh --gpu        # if CUDA present: clone + build the search engine
#   ./bootstrap.sh --install --gpu
#
# --install uses the system package manager (apt/dnf/yum/brew) with sudo on
# Linux, installing ONLY the specific missing packages. Review the printed plan;
# pass --yes to skip the confirmation prompt (for unattended fresh instances).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/config.sh"

DO_INSTALL=0; DO_GPU=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --install) DO_INSTALL=1; shift;;
    --gpu) DO_GPU=1; shift;;
    --yes|-y) ASSUME_YES=1; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) cdss_die "unknown arg: $1";;
  esac
done

# --- Detect OS + package manager ------------------------------------------
OS="$(uname -s)"; PKG=""
if   cdss_have apt-get; then PKG="apt";
elif cdss_have dnf;     then PKG="dnf";
elif cdss_have yum;     then PKG="yum";
elif cdss_have brew;    then PKG="brew";
fi

# --- Detect tools ----------------------------------------------------------
CPU_TOOLS="bash python3 zstd gzip lz4 grep awk"
OPT_TOOLS="curl aws nvidia-smi nvcc"
echo "== cdss_bench bootstrap =="
echo "OS: $OS   package manager: ${PKG:-none-detected}"
echo
echo "Required CPU tools:"
MISSING=""
for t in $CPU_TOOLS; do
  if cdss_have "$t"; then printf "  [ok ] %s\n" "$t";
  else printf "  [MISS] %s\n" "$t"; MISSING="$MISSING $t"; fi
done
echo "Optional tools:"
for t in $OPT_TOOLS; do
  if cdss_have "$t"; then printf "  [ok ] %s (%s)\n" "$t" "$(command -v "$t")";
  else printf "  [--] %s (absent)\n" "$t"; fi
done

# --- GPU detection ---------------------------------------------------------
HAS_GPU=0
if cdss_have nvidia-smi && nvidia-smi >/dev/null 2>&1; then HAS_GPU=1; fi
HAS_CUDA=0; cdss_have nvcc && HAS_CUDA=1
echo
if [ "$HAS_GPU" -eq 1 ]; then
  echo "GPU: present"; nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | sed 's/^/  /'
else
  echo "GPU: none detected (CPU-only host)"
fi
echo "CUDA toolchain (nvcc): $([ "$HAS_CUDA" -eq 1 ] && echo present || echo absent)"

# --- Map tool -> package name for the detected manager --------------------
pkg_name() { # $1=tool
  case "$1" in
    python3) case "$PKG" in apt) echo python3;; dnf|yum) echo python3;; brew) echo python;; esac;;
    lz4)     echo lz4;;
    zstd)    echo zstd;;
    gzip)    echo gzip;;
    grep|awk|bash) echo "$1";;
    *) echo "$1";;
  esac
}

# --- Install missing CPU tools --------------------------------------------
if [ "$DO_INSTALL" -eq 1 ] && [ -n "${MISSING# }" ]; then
  [ -n "$PKG" ] || cdss_die "no supported package manager found; install manually:$MISSING"
  PKGS=""; for t in $MISSING; do PKGS="$PKGS $(pkg_name "$t")"; done
  case "$PKG" in
    apt)  CMD="sudo apt-get update && sudo apt-get install -y$PKGS";;
    dnf)  CMD="sudo dnf install -y$PKGS";;
    yum)  CMD="sudo yum install -y$PKGS";;
    brew) CMD="brew install$PKGS";;
  esac
  echo; echo "Install plan:"; echo "  $CMD"
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf "Proceed? [y/N] "; read -r ans; case "$ans" in y|Y) ;; *) echo "skipped install"; CMD="";; esac
  fi
  [ -n "$CMD" ] && { echo "installing..."; bash -c "$CMD"; }
elif [ "$DO_INSTALL" -eq 1 ]; then
  echo; echo "All required CPU tools present; nothing to install."
fi

# --- GPU engine clone + build ---------------------------------------------
if [ "$DO_GPU" -eq 1 ]; then
  echo
  if [ "$HAS_CUDA" -ne 1 ]; then
    echo "--gpu requested but nvcc absent; skipping engine build (CPU benchmarks still work)."
  else
    if [ -d "$CDSS_ENGINE_DIR/.git" ]; then
      echo "engine present; pulling latest"
      git -C "$CDSS_ENGINE_DIR" pull --ff-only || echo "  (pull skipped/failed; keeping existing checkout)"
    else
      echo "cloning engine into $CDSS_ENGINE_DIR"
      if ! git clone --depth 1 "$CDSS_ENGINE_REPO" "$CDSS_ENGINE_DIR" 2>/dev/null; then
        echo "  ssh clone failed; trying https"
        git clone --depth 1 "$CDSS_ENGINE_REPO_HTTPS" "$CDSS_ENGINE_DIR"
      fi
    fi
    echo "building engine (make)"
    ( cd "$CDSS_ENGINE_DIR" && make ) && echo "engine build OK: $CDSS_ENGINE_BIN" \
      || echo "engine build FAILED -- see output above"
  fi
fi

echo
echo "Summary:"
echo "  CPU benchmarks: $([ -z "${MISSING# }" ] && echo READY || echo "need:$MISSING")"
echo "  GPU benchmarks: $([ -x "$CDSS_ENGINE_BIN" ] && echo READY || echo "not built (run --gpu on a CUDA host)")"
echo "Next: ./gen/make_corpora.sh   then   ./bench/bench_cpu.sh"
