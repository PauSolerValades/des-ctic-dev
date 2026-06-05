#!/bin/bash
set -euo pipefail

BIN="./zig-out/bin"
DATA_10K="./data/10K_monotonous.bin"
DATA_100K="./data/100K_monotonous.bin"
CONF_FALSE="./simconfs/benchmark_false.json"
CONF_TRUE="./simconfs/benchmark_true.json"

RUNS=500
WORKERS=4

# --- 10K ---
echo "=== 10K ==="

# general  ReleaseFast
"$BIN/bskysim-bench-general-ReleaseFast"      -n "$RUNS" -w "$WORKERS" -o "./traces/10K_general-ReleaseFast_false"    "$DATA_10K" "$CONF_FALSE"
"$BIN/bskysim-bench-general-ReleaseFast"      -n "$RUNS" -w "$WORKERS" -o "./traces/10K_general-ReleaseFast_true"     "$DATA_10K" "$CONF_TRUE"

# general  ReleaseSafe
"$BIN/bskysim-bench-general-ReleaseSafe"      -n "$RUNS" -w "$WORKERS" -o "./traces/10K_general-ReleaseSafe_false"    "$DATA_10K" "$CONF_FALSE"
"$BIN/bskysim-bench-general-ReleaseSafe"      -n "$RUNS" -w "$WORKERS" -o "./traces/10K_general-ReleaseSafe_true"     "$DATA_10K" "$CONF_TRUE"

# general  ReleaseSmall
"$BIN/bskysim-bench-general-ReleaseSmall"     -n "$RUNS" -w "$WORKERS" -o "./traces/10K_general-ReleaseSmall_false"   "$DATA_10K" "$CONF_FALSE"
"$BIN/bskysim-bench-general-ReleaseSmall"     -n "$RUNS" -w "$WORKERS" -o "./traces/10K_general-ReleaseSmall_true"    "$DATA_10K" "$CONF_TRUE"

# specific ReleaseFast
"$BIN/bskysim-bench-specific-ReleaseFast-trace"    -n "$RUNS" -w "$WORKERS" -o "./traces/10K_specific-ReleaseFast-trace"    "$DATA_10K"
"$BIN/bskysim-bench-specific-ReleaseFast-notrace"  -n "$RUNS" -w "$WORKERS" -o "./traces/10K_specific-ReleaseFast-notrace"  "$DATA_10K"

# specific ReleaseSafe
"$BIN/bskysim-bench-specific-ReleaseSafe-trace"    -n "$RUNS" -w "$WORKERS" -o "./traces/10K_specific-ReleaseSafe-trace"    "$DATA_10K"
"$BIN/bskysim-bench-specific-ReleaseSafe-notrace"  -n "$RUNS" -w "$WORKERS" -o "./traces/10K_specific-ReleaseSafe-notrace"  "$DATA_10K"

# specific ReleaseSmall
"$BIN/bskysim-bench-specific-ReleaseSmall-trace"   -n "$RUNS" -w "$WORKERS" -o "./traces/10K_specific-ReleaseSmall-trace"   "$DATA_10K"
"$BIN/bskysim-bench-specific-ReleaseSmall-notrace" -n "$RUNS" -w "$WORKERS" -o "./traces/10K_specific-ReleaseSmall-notrace" "$DATA_10K"

# --- 100K ---
echo "=== 100K ==="

# general  ReleaseFast
"$BIN/bskysim-bench-general-ReleaseFast"      -n "$RUNS" -w "$WORKERS" -o "./traces/100K_general-ReleaseFast_false"   "$DATA_100K" "$CONF_FALSE"
"$BIN/bskysim-bench-general-ReleaseFast"      -n "$RUNS" -w "$WORKERS" -o "./traces/100K_general-ReleaseFast_true"    "$DATA_100K" "$CONF_TRUE"

# general  ReleaseSafe
"$BIN/bskysim-bench-general-ReleaseSafe"      -n "$RUNS" -w "$WORKERS" -o "./traces/100K_general-ReleaseSafe_false"   "$DATA_100K" "$CONF_FALSE"
"$BIN/bskysim-bench-general-ReleaseSafe"      -n "$RUNS" -w "$WORKERS" -o "./traces/100K_general-ReleaseSafe_true"    "$DATA_100K" "$CONF_TRUE"

# general  ReleaseSmall
"$BIN/bskysim-bench-general-ReleaseSmall"     -n "$RUNS" -w "$WORKERS" -o "./traces/100K_general-ReleaseSmall_false"  "$DATA_100K" "$CONF_FALSE"
"$BIN/bskysim-bench-general-ReleaseSmall"     -n "$RUNS" -w "$WORKERS" -o "./traces/100K_general-ReleaseSmall_true"   "$DATA_100K" "$CONF_TRUE"

# specific ReleaseFast
"$BIN/bskysim-bench-specific-ReleaseFast-trace"    -n "$RUNS" -w "$WORKERS" -o "./traces/100K_specific-ReleaseFast-trace"    "$DATA_100K"
"$BIN/bskysim-bench-specific-ReleaseFast-notrace"  -n "$RUNS" -w "$WORKERS" -o "./traces/100K_specific-ReleaseFast-notrace"  "$DATA_100K"

# specific ReleaseSafe
"$BIN/bskysim-bench-specific-ReleaseSafe-trace"    -n "$RUNS" -w "$WORKERS" -o "./traces/100K_specific-ReleaseSafe-trace"    "$DATA_100K"
"$BIN/bskysim-bench-specific-ReleaseSafe-notrace"  -n "$RUNS" -w "$WORKERS" -o "./traces/100K_specific-ReleaseSafe-notrace"  "$DATA_100K"

# specific ReleaseSmall
"$BIN/bskysim-bench-specific-ReleaseSmall-trace"   -n "$RUNS" -w "$WORKERS" -o "./traces/100K_specific-ReleaseSmall-trace"   "$DATA_100K"
"$BIN/bskysim-bench-specific-ReleaseSmall-notrace" -n "$RUNS" -w "$WORKERS" -o "./traces/100K_specific-ReleaseSmall-notrace" "$DATA_100K"

echo ""
echo "Done."
