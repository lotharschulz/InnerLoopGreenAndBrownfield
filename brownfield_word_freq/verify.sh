#!/usr/bin/env bash
set -uo pipefail

# verify.sh — project verification gate. Committed to the repo (project-specific):
# it drives this crate's cargo fmt/clippy/test commands.
#
# Usage:
#   ./verify.sh                fast gate: format check, lint+compile, tests
#   ./verify.sh --full         also runs a release build
#   ./verify.sh --fix          auto-fix formatting with `cargo fmt`, then run the gate
#   ./verify.sh --changed-only skip entirely if git has no changes; auto-upgrade to
#                              the full pass when the diff is large (>= THRESHOLD lines)
#   ./verify.sh --no-escalate  never escalate to the full pass, whatever the diff size
#   ./verify.sh --file=<path>  per-file mode: fast single-file format, returns before
#                              any whole-crate step (used by the PostToolUse hook)
#
# Exit codes: 0 = passed (or nothing to check), 1 = a check failed, 64 = bad flag.
# turn-gate.sh maps a failure to its own exit 2 so Claude keeps working.
#
# Failing output is mirrored to stderr, UNLESS CALLED_BY_GATE=1: turn-gate.sh already
# captures this script's combined 2>&1 output, so mirroring there would only halve the
# agent's feedback window with a duplicate copy of the same failure.

cd "$(dirname "$0")" 2>/dev/null || true   # ensure git/cargo commands run from the repo root

THRESHOLD=100   # changed lines (added+deleted) that trigger the full pass under --changed-only
CODE_EXT_RE='\.rs$'   # repo-specific: which changed files are worth the code gate.
                      # A Python repo would use '\.py$', a Go repo '\.go$', etc.

FILE=""
FULL=0; FIX=0; CHANGED_ONLY=0; NO_ESCALATE=0
for arg in "$@"; do
  case "$arg" in
    --full)          FULL=1 ;;
    --fix)           FIX=1 ;;
    --changed-only)  CHANGED_ONLY=1 ;;
    --no-escalate)   NO_ESCALATE=1 ;;
    --file=*)        FILE="${arg#--file=}" ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

# Per-file mode: fast, single-file format. Runs FIRST and returns before any whole-crate
# step, so it stays cheap when the PostToolUse hook calls it on every edit.
# THIS is the only line another Rust repo would swap — a rustfmt-less repo exits 0 here.
if [ -n "$FILE" ]; then
  command -v cargo >/dev/null 2>&1 || { echo "cargo not found — skipping" >&2; exit 0; }
  cargo fmt -- "$FILE"
  exit $?   # 0 = formatted, non-zero = rustfmt could not parse the file
fi

# --changed-only: bail cheaply when the tree is clean, and escalate to the full pass
# only when the change is large enough to be worth a release build.
if [ "$CHANGED_ONLY" -eq 1 ]; then
  # Nothing changed at all → nothing to check. `git status --porcelain` also catches
  # new untracked files (which `git diff` misses) — important for agents that create files.
  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    echo "No changes — skipping verification."
    exit 0
  fi
  # Something changed, but if none of it is code we statically check (docs/config only),
  # skip the whole code gate. Covers modified, staged, and new untracked files.
  changed_files=$(git diff HEAD --name-only; git ls-files --others --exclude-standard)
  if ! grep -qE "$CODE_EXT_RE" <<< "$changed_files"; then
    echo "No code files changed (docs/config only) — skipping code checks."
    exit 0
  fi
  if [ "$NO_ESCALATE" -eq 0 ]; then
    changed=$(git diff HEAD --numstat | awk '{s+=$1+$2} END {print s+0}')
    if [ "$changed" -ge "$THRESHOLD" ]; then
      echo "Large change ($changed lines) — running the full pass."
      FULL=1
    fi
  fi
fi

failures=()
first_failure_name=""
first_failure_output=""

# Counts toward pass/fail. Captures output; on failure prints a tail to stdout, and
# remembers the FIRST failure so it can be re-printed last (see the summary below) —
# otherwise a 150-line tail of a multi-failure run shows only the last step's noise.
run_step() {
  local name="$1"; shift
  echo ""; echo "▶ $name"
  local out
  if out=$("$@" 2>&1); then
    echo "✓ $name"
  else
    echo "✗ $name"
    echo "$out" | tail -n 30
    if [ -z "${CALLED_BY_GATE:-}" ]; then
      { echo "✗ $name"; echo "$out" | tail -n 30; } >&2
    fi
    if [ -z "$first_failure_name" ]; then
      first_failure_name="$name"
      first_failure_output="$out"
    fi
    failures+=("$name")
  fi
}

# 1. Format — `cargo fmt --check` asserts, read-only. --fix switches to the mutating form.
if [ "$FIX" -eq 1 ]; then
  run_step "format fix (cargo fmt --all)" cargo fmt --all
else
  run_step "format (cargo fmt --all -- --check)" cargo fmt --all -- --check
fi

# 2. Lint + compile — clippy subsumes compilation, so there is no separate build step.
run_step "lint (cargo clippy -- -D warnings)" cargo clippy -- -D warnings

# 3. Tests — these used to sit behind `--full`, which meant any change under THRESHOLD
# lines stopped the agent without running a single test. Tests are the whole point of
# the gate; they belong in every fast pass.
run_step "tests (cargo test)" cargo test

# 4. Release build — slower, and only in the full pass. clippy already caught type and
# lint errors; this catches release-profile-only problems.
if [ "$FULL" -eq 1 ]; then
  run_step "release build (cargo build --release)" cargo build --release
fi

echo ""
if [ "${#failures[@]}" -eq 0 ]; then
  echo "All checks passed."
  exit 0
fi

# Print the FIRST failure last: whatever tails this output (the gate takes the last
# MAX_OUTPUT_LINES) then sees the failure that actually started the cascade, not the
# last step that happened to run.
echo "Failed: ${failures[*]}"
echo ""
echo "=== First failure: $first_failure_name ==="
printf '%s\n' "$first_failure_output" | tail -n 100
if [ -z "${CALLED_BY_GATE:-}" ]; then
  {
    echo "Failed: ${failures[*]}"
    echo ""
    echo "=== First failure: $first_failure_name ==="
    printf '%s\n' "$first_failure_output" | tail -n 100
  } >&2
fi
exit 1
