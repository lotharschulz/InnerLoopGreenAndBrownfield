#!/usr/bin/env bash
# post-edit-fmt.sh — wired to PostToolUse (Edit|Write).
#
# Cheap, silent, per-file `cargo fmt` after every edit. Always exits 0, so it can never
# block and can never contribute to a Stop-retry loop.
#
# This does NOT reintroduce the per-tool-call verification the Editor Loop post argues
# against: that objection is about running the whole verify.sh (~30s) on every tool
# call, which would void the cache. Formatting one file is ~50ms. What it buys is that
# `cargo fmt --check` failures stop being something stop-verify.sh ever has to send the
# agent back for.
set -uo pipefail

input=$(cat)

# Extract the edited file's path. Fail open if jq is missing.
if command -v jq >/dev/null 2>&1; then
  file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
else
  file=""
fi

[ -z "$file" ] && exit 0          # not a single-file edit — nothing to do
[ -f "$file" ] || exit 0          # file no longer exists — nothing to do
case "$file" in
  *.rs) ;;
  *) exit 0 ;;                    # not Rust source — rustfmt has nothing to do here
esac

# Best-effort: a file that rustfmt cannot parse stays untouched, and the real syntax
# error surfaces properly through stop-verify.sh at the end of the turn.
cargo fmt -- "$file" >/dev/null 2>&1 || true
exit 0
