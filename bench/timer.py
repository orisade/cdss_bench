#!/usr/bin/env python3
"""Run a shell command, measure its wall-clock time accurately, and report it.

The command's own stdout is forwarded to this process's stdout unchanged (so
callers can capture e.g. a `grep -c` count). Timing metadata goes to stderr:

    __ELAPSED_MS__ <float>
    __EXIT__ <int>

Using a single wrapper process (rather than reading a clock before/after in the
shell) avoids charging shell/interpreter fork time to the measurement.

Usage: timer.py "<shell command string>"
"""
import subprocess, sys, time

def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: timer.py \"<command>\"\n"); sys.exit(2)
    cmd = sys.argv[1]
    t0 = time.perf_counter()
    # bash -c (non-login) for reproducibility; do not source profiles/aliases.
    r = subprocess.run(["bash", "-c", cmd],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    sys.stdout.buffer.write(r.stdout)
    sys.stdout.flush()
    sys.stderr.write("__ELAPSED_MS__ %.4f\n" % elapsed_ms)
    sys.stderr.write("__EXIT__ %d\n" % r.returncode)

if __name__ == "__main__":
    main()
