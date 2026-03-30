#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v hyperfine &>/dev/null; then
    echo "Error: hyperfine is not installed."
    echo "Install it from https://github.com/sharkdp/hyperfine"
    exit 1
fi

if ! command -v nvim &>/dev/null; then
    echo "Error: nvim is not installed."
    exit 1
fi

BIN="$(mktemp -d)/nvcat"
echo "Building nvcat..."
go build -o "$BIN" .

SAMPLE_FILES=("testdata/sample.go" "testdata/sample.lua")
for f in "${SAMPLE_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "Warning: $f not found, skipping"
        continue
    fi
done

echo ""
echo "=== Go benchmarks (unit) ==="
go test -bench=. -benchmem -count=3 -run='^$' .

echo ""
echo "=== End-to-end benchmarks (hyperfine) ==="

for f in "${SAMPLE_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        continue
    fi
    echo ""
    echo "--- $f ---"
    hyperfine \
        --warmup 3 \
        --min-runs 10 \
        "$BIN -clean $f"
done

# Compare with and without line numbers
echo ""
echo "--- Line numbers overhead (testdata/sample.go) ---"
hyperfine \
    --warmup 3 \
    --min-runs 10 \
    "$BIN -clean testdata/sample.go" \
    "$BIN -clean -n testdata/sample.go"

# Benchmark against cat as a baseline
if command -v cat &>/dev/null; then
    echo ""
    echo "--- nvcat vs cat baseline (testdata/sample.go) ---"
    hyperfine \
        --warmup 3 \
        --min-runs 10 \
        "cat testdata/sample.go" \
        "$BIN -clean testdata/sample.go"
fi

rm -f "$BIN"
echo ""
echo "Done."
