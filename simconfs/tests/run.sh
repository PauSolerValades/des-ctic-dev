#!/bin/bash
# Run each error-test config and show the stderr output
set -e

BIN="./zig-out/bin/bskysim"
DATA="data/10K_monotonous.bin"
TESTS="simconfs/tests"

echo "=== TEST SUITE: Config error handling ==="
echo ""

run_test() {
    local name="$1"
    local config="$2"
    echo "--- $name ---"
    $BIN "$DATA" "$config" 2>&1 || true
    echo ""
}

# 1. Valid config (should succeed)
run_test "valid" "$TESTS/valid.json" | head -5

# 2. Unknown distribution
run_test "unknown-distribution" "$TESTS/unknown-distribution.json" | head -5

# 3. Unknown parameter in distribution
run_test "unknown-param-in-dist" "$TESTS/unknown-param-in-dist.json" | head -5

# 4. Invalid interval
run_test "invalid-interval" "$TESTS/invalid-interval.json" | head -5

# 5. Invalid action
run_test "invalid-action" "$TESTS/invalid-action.json" | head -5

# 6. Malformed JSON
run_test "malformed-json" "$TESTS/malformed-json.json" | head -5

# 7. Incomplete JSON
run_test "incomplete-json" "$TESTS/incomplete-json.json" | head -5

# 8. Invalid number
run_test "invalid-number" "$TESTS/invalid-number.json" | head -5

# 9. Unknown config field
run_test "unknown-config-field" "$TESTS/unknown-config-field.json" | head -5

# 10. Normal warning (should succeed but warn)
run_test "normal-warning" "$TESTS/normal-warning.json" | head -5

# 11. Missing categorical field
run_test "missing-categorical-field" "$TESTS/missing-categorical-field.json" | head -5

# 12. Missing dist param
run_test "missing-dist-param" "$TESTS/missing-dist-param.json" | head -5

echo "=== Done ==="
