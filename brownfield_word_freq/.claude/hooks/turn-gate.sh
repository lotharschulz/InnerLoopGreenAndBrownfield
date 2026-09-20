#!/usr/bin/env bash
# turn-gate.sh — Wired to the Stop hook (main agent only; SubagentStop has its own
# lean script, subagent-gate.sh).
#
# It runs the repo's fast validation when the agent thinks it's done. If invalid,
# it sends the agent back (exit 2, diagnostics on stderr) — but only up to
# MAX_ATTEMPTS times, after which it terminates (exit 1) and reports.
# That bounded budget is what makes an UNATTENDED run safe from the Stop-re-entry
# loop. NOTE: it does NOT bound the "work loop" where an agent never tries to stop
# (edit A breaks B, fix B re-breaks A). Only the harness (max-turns + wall-clock
# timeout) bounds that — set those on whatever launches the orchestrator.
set -uo pipefail

MAX_ATTEMPTS=2   # keep this BELOW the platform's consecutive-stop-block cap (default ~8)
                 # so this budget is the binding constraint, not the platform's.
MAX_OUTPUT_LINES=150   # raised from 30: enough room for a full clippy/test failure,
                       # not just its last few lines.

input=$(cat)

field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$1 // empty"
  fi
}
session=$(field '.session_id');       : "${session:=unknown}"
event=$(field '.hook_event_name');    : "${event:=Stop}"
agent=$(field '.agent_id');           : "${agent:=main}"   # empty for main agent

repo="${CLAUDE_PROJECT_DIR:-.}"

# Runtime state (audit log + retry counters + verdict cache) lives INSIDE the repo,
# because the sandbox may block /tmp. MUST be gitignored — add `.claude/gate/` to
# .gitignore, or these files pollute `git status`, which is exactly what the turn
# short-circuit below reads.
STATE_DIR="$repo/.claude/gate"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Audit trail: prove this hook ran, regardless of which exit path it takes — including
# a silent exit-0 pass or short-circuit that leaves nothing in Claude Code's debug log,
# and headless runs with no UI status. `tail -f .claude/gate/gate.log` to watch live.
echo "$(date -Iseconds) turn-gate fired: event=$event agent=$agent session=$session" \
  >> "$STATE_DIR/gate.log" 2>/dev/null || true

# Concurrency guard: two sessions can be open on the same repo, and a subagent gate can
# still be running. mkdir is atomic — the first process wins; others skip rather than
# race over build temp dirs.
lockdir="$STATE_DIR/verify.lock.d"
LOCK_STALE_MIN=15
# A hard-killed run (SIGKILL, closed terminal) can't run its trap and leaves the lock
# behind. Without this the gate would skip every future turn — silently disabled forever.
if [ -n "$(find "$lockdir" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
  rmdir "$lockdir" 2>/dev/null || true
fi
if ! mkdir "$lockdir" 2>/dev/null; then
  echo "$(date -Iseconds) skipped — another gate run is in progress" \
    | tee -a "$STATE_DIR/gate.log" >&2
  exit 0
fi
trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT INT TERM

# Must stay identical to the copy in prompt-snapshot.sh — see the comment there for why
# `git status` alone is not a sufficient fingerprint.
fingerprint() {
  {
    git -C "$repo" status --porcelain
    git -C "$repo" diff HEAD
    git -C "$repo" ls-files --others --exclude-standard \
      | while IFS= read -r f; do git -C "$repo" hash-object "$f"; done
  } 2>/dev/null | git -C "$repo" hash-object --stdin 2>/dev/null
}

# Short-circuit #1: skip validation when THIS TURN made no changes.
# Primary path  — snapshot taken by the UserPromptSubmit hook at turn start:
#   compare the current fingerprint to the snapshot; equal → nothing changed this turn.
# Fallback path — snapshot missing (hook not wired up yet):
#   clean tree check; still catches fully-clean repos.
if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  snapshot="$STATE_DIR/${session}-snapshot.txt"
  if [ -s "$snapshot" ]; then
    if [ "$(fingerprint)" = "$(cat "$snapshot")" ]; then
      echo "$(date -Iseconds) no changes this turn — skipped" \
        | tee -a "$STATE_DIR/gate.log" >&2
      exit 0
    fi
  elif [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    echo "nothing to validate - turn gate skipped" | tee -a "$STATE_DIR/gate.log" >&2
    exit 0
  fi
fi

# Repo's validity definition. Fail OPEN if a repo hasn't adopted it (rollout safety):
verify="$repo/verify.sh"
if [ ! -x "$verify" ]; then
  echo "no verify.sh in this repo — turn gate skipped" >&2
  exit 0
fi

# Short-circuit #2 (verdict cache): this turn DID change something, but is the resulting
# content identical to a state already proven green? (A revert, or edits that cancel
# out.) Complementary to #1, not a replacement: #1 makes question-only turns free, this
# makes revert-and-retry turns free. Keyed on content + toolchain, not on the git diff.
green_file="$STATE_DIR/green-fingerprint.txt"
verdict_fingerprint() {
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local rustc_ver files_hash
  rustc_ver=$(rustc --version) || return 1
  files_hash=$(
    { git -C "$repo" ls-files -coz --exclude-standard src
      printf '%s\0' "$repo/Cargo.toml" "$verify"; } | xargs -0 shasum -a 256
  ) || return 1
  printf '%s\n%s\n' "$rustc_ver" "$files_hash" | shasum -a 256 | cut -d' ' -f1
}
green_hash=$(verdict_fingerprint 2>/dev/null || true)
if [ -n "$green_hash" ] && [ "$(cat "$green_file" 2>/dev/null)" = "$green_hash" ]; then
  echo "$(date -Iseconds) content already proven green — skipped" \
    | tee -a "$STATE_DIR/gate.log" >&2
  exit 0
fi

# Retry budget, one per session. Kept in-repo (see STATE_DIR note above) so the sandbox
# can't silently drop the writes — a dropped counter would defeat the termination guard
# and let a real failure loop. Deleted on the first passing run.
counter="$STATE_DIR/${session}.count"
attempts=$(cat "$counter" 2>/dev/null || echo 0)

# Run the repo's fast, change-scoped validation. CALLED_BY_GATE tells verify.sh's
# run_step to skip its own stderr mirror — we already capture 2>&1 here, so mirroring
# would just burn half of MAX_OUTPUT_LINES on a duplicate copy of the same failure.
if out=$(CALLED_BY_GATE=1 "$verify" --changed-only 2>&1); then
  { echo "$(date -Iseconds) verify passed"; printf '%s\n' "$out"; } \
    >> "$STATE_DIR/gate.log" 2>/dev/null || true
  rm -f "$counter"
  # Recompute rather than reuse: verify.sh (--fix, cargo itself) may have touched files.
  verdict_fingerprint > "$green_file" 2>/dev/null || rm -f "$green_file"
  exit 0
fi

# Invalid. If the budget is spent, TERMINATE rather than loop — exit 1 rather than 0, so
# an attended session sees the give-up instead of only gate.log recording it.
if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
  rm -f "$counter"
  {
    echo "Still failing after ${MAX_ATTEMPTS} attempts — stopping to avoid a loop. Last output:"
    printf '%s\n' "$out" | tail -n "$MAX_OUTPUT_LINES"
  } | tee -a "$STATE_DIR/gate.log" >&2
  exit 1
fi

# Otherwise send the agent back with the diagnostics (exit 2 → stderr → agent).
echo $((attempts + 1)) > "$counter"
{
  echo "Validation failed (attempt $((attempts + 1))/${MAX_ATTEMPTS}). Fix these before finishing:"
  printf '%s\n' "$out" | tail -n "$MAX_OUTPUT_LINES"
} | tee -a "$STATE_DIR/gate.log" >&2
exit 2
