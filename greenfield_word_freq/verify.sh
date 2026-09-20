#!/bin/bash
set -e

echo "=== Word Freq - Verification Loop ==="

echo ""
echo "[1/3] Code formatting (cargo fmt --all -- --check)..."
cargo fmt --all -- --check

echo ""
echo "[2/3] Compilation & Linting (cargo clippy --all-targets)..."
cargo clippy --all-targets -- -D warnings

echo ""
echo "[3/3] Tests (cargo test)..."
cargo test --manifest-path Cargo.toml

echo ""
echo "✓ All checks passed!"
