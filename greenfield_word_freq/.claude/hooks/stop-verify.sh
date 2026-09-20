#!/bin/bash
# stop-verify.sh — wired to Stop and SubagentStop (the same script for both: a
# subagent's work gets exactly the same verification, and the same retry budget, as
# the main agent's).
#
# Exit codes (Claude Code Stop/SubagentStop hook contract):
#   0 -> verification passed, or cache hit; agent may stop
#   2 -> blocking: agent receives stderr as feedback and must continue fixing
#   1 -> non-blocking error shown to the user (used when giving up after MAX_ATTEMPTS)
set -e

MAX_ATTEMPTS=3
MAX_OUTPUT_LINES=150

input=$(cat)

# jq is used only to namespace the retry counter per session. Without it the counter
# falls back to a shared "unknown" slot — degraded, but never a hard failure.
field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$1 // empty"
  fi
}
session=$(field '.session_id');    : "${session:=unknown}"
event=$(field '.hook_event_name'); : "${event:=Stop}"

# CLAUDE_PROJECT_DIR is normally set by Claude Code to this crate's dir. The
# git-toplevel fallback would resolve to the parent repo root (this crate has no .git
# of its own), so fall back to the script's own location instead.
repo="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$repo" || exit 1

# Runtime state lives INSIDE the repo rather than in TMPDIR: a sandboxed session may
# not be able to write to /tmp, and a dropped counter would defeat the loop guard.
# MUST be gitignored (see .gitignore).
STATE_DIR="$repo/.claude/gate"
mkdir -p "$STATE_DIR" 2>/dev/null || true
COUNTER_FILE="$STATE_DIR/${session}.count"   # per session: two sessions open on this
                                             # repo must not share — and prematurely
                                             # exhaust — one retry budget.
GREEN_FILE="$STATE_DIR/green.fingerprint"    # per repo, NOT per session: this is a
                                             # shared cache of "this exact content
                                             # already passed", and staying shared is
                                             # what makes it useful across sessions.

# Audit trail: every exit path leaves a line, including the silent cache-hit pass that
# otherwise proves nothing ran. `tail -f .claude/gate/gate.log` to watch live.
echo "$(date -Iseconds) stop-verify fired: event=$event session=$session" \
  >> "$STATE_DIR/gate.log" 2>/dev/null || true

# Concurrency guard: Stop and SubagentStop share this script, so a subagent's verify
# and the main agent's verify can otherwise run on top of each other (cargo serialises
# them on its own lock, but the waiting one still burns the hook timeout).
# mkdir is atomic — first process wins, others skip.
lockdir="$STATE_DIR/verify.lock.d"
LOCK_STALE_MIN=15
# A hard-killed run can't fire its trap and leaves the lock behind; without this reaper
# the gate would skip every future run — silently disabled forever.
if [ -n "$(find "$lockdir" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
  rmdir "$lockdir" 2>/dev/null || true
fi
if ! mkdir "$lockdir" 2>/dev/null; then
  echo "$(date -Iseconds) skipped — another verify run is in progress" \
    | tee -a "$STATE_DIR/gate.log" >&2
  exit 0
fi
trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT INT TERM

# Fingerprint everything verify.sh depends on: source tree (tracked + untracked,
# content-hashed), manifests, and the script itself. Identical fingerprint to the last
# green run -> identical verdict -> safe to skip.
# The fingerprint omits Cargo.lock so a dependency bump wouldn't invalidate the cache.
# That's fine for a crate with no dependencies; revisit it once there are real ones.
#
# The leading rev-parse guard is load-bearing: without a git repository `git ls-files`
# fails, but the rest of the pipeline would happily carry on and hash Cargo.toml plus
# verify.sh alone — a stable value that matches on every later run and turns every
# source edit into a false cache hit. Returning early makes that case produce an EMPTY
# fingerprint, which is what the caller below already assumes it produces.
# shasum -a 256 is macOS; Linux users may use sha256sum.
compute_fingerprint() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local rustc_ver files_hash
  rustc_ver=$(rustc --version) || return 1
  files_hash=$(
    { git ls-files -coz --exclude-standard src
      printf '%s\0' Cargo.toml verify.sh; } | xargs -0 shasum -a 256
  ) || return 1
  printf '%s\n%s\n' "$rustc_ver" "$files_hash" | shasum -a 256 | cut -d' ' -f1
}

# Fail open when the repo has no verify.sh: otherwise `bash verify.sh` fails with
# "No such file or directory", and THAT becomes the reason the agent is told it may
# not stop yet.
if [ ! -f verify.sh ]; then
  echo "$(date -Iseconds) no verify.sh — stop-verify skipped" \
    | tee -a "$STATE_DIR/gate.log" >&2
  exit 0
fi

# An empty fingerprint (no git, or computation failed) never matches -> full
# verification runs.
inputs_hash=$(compute_fingerprint 2>/dev/null || true)

if [ -n "$inputs_hash" ] && [ "$(cat "$GREEN_FILE" 2>/dev/null)" = "$inputs_hash" ]; then
  rm -f "$COUNTER_FILE"
  echo "$(date -Iseconds) content already proven green — skipped" \
    >> "$STATE_DIR/gate.log" 2>/dev/null || true
  exit 0
fi

# "|| status=$?" keeps set -e from aborting here; failure must reach the exit-2 logic below
status=0
output=$(bash verify.sh 2>&1) || status=$?

if [ "$status" -eq 0 ]; then
  rm -f "$COUNTER_FILE"
  echo "$(date -Iseconds) verify passed" >> "$STATE_DIR/gate.log" 2>/dev/null || true
  # Recompute instead of reusing inputs_hash: cargo may have touched tracked files.
  compute_fingerprint > "$GREEN_FILE" 2>/dev/null || rm -f "$GREEN_FILE"
  exit 0
fi

attempts=$(($(cat "$COUNTER_FILE" 2>/dev/null || echo 0) + 1))
echo "$attempts" > "$COUNTER_FILE"

if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
  # Give up blocking to avoid an infinite loop; surface the failure to the user instead.
  rm -f "$COUNTER_FILE"
  {
    echo "verify.sh still failing after $MAX_ATTEMPTS consecutive attempts; giving up. Last output:"
    echo "$output" | tail -n "$MAX_OUTPUT_LINES"
  } | tee -a "$STATE_DIR/gate.log" >&2
  exit 1
fi

{
  echo "verify.sh failed (attempt $attempts/$MAX_ATTEMPTS). Fix the issues below before stopping:"
  echo "$output" | tail -n "$MAX_OUTPUT_LINES"
} | tee -a "$STATE_DIR/gate.log" >&2
exit 2
